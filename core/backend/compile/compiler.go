// Package compile prepares application-owned immutable plans from original
// profile text and settings. It has no engine, Android, or Flutter dependency.
package compile

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"core/backend"
)

type RawProfile struct {
	SourceMissing bool   `json:"sourceMissing,omitempty"`
	ID            string `json:"id"`
	Revision      uint64 `json:"revision,omitempty"`
	Text          string `json:"text"`
	Metadata      Object `json:"metadata"`
}
type Input struct {
	Version         int         `json:"version"`
	CatalogRevision uint64      `json:"catalogRevision,omitempty"`
	Profile         *RawProfile `json:"profile"`
	Settings        Object      `json:"settings"`
}
type Capabilities struct {
	Platform          string
	HomeDir           string
	ProfilesDir       string
	SelfPackages      []string
	InstalledPackages func(context.Context) ([]string, error)
}
type ScriptEvaluator interface {
	Evaluate(context.Context, string, Object) (Object, error)
}
type NodeCompiler interface {
	Compile(context.Context, Object, Object, string) ([]Node, error)
}
type EngineValidator func(context.Context, Object) error

type Node struct {
	ID         string            `json:"nodeId"`
	Type       string            `json:"type"`
	Name       string            `json:"name"`
	Host       string            `json:"host"`
	Port       int               `json:"port"`
	UDP        bool              `json:"udp"`
	Files      map[string]string `json:"files"`
	Metadata   map[string]string `json:"metadata"`
	Check      Object            `json:"connectivityCheck"`
	Activation Object            `json:"activation,omitempty"`
}
type Prepared struct {
	ProfileID                string   `json:"profileId"`
	Config                   Object   `json:"config"`
	Selected                 Object   `json:"selected-map"`
	TestURL                  string   `json:"test-url"`
	Nodes                    []Node   `json:"nodes"`
	CoreState                Object   `json:"coreState"`
	Patch                    Object   `json:"patch"`
	Diagnostics              []string `json:"diagnostics"`
	ProfileAccessControl     Object   `json:"profileAccessControl,omitempty"`
	CloseConnectionsOnSelect bool     `json:"closeConnectionsOnSelect"`
}
type Compiler struct {
	Capabilities Capabilities
	Scripts      ScriptEvaluator
	Nodes        NodeCompiler
	Validate     EngineValidator
	Lists        PackageLists
	Policy       SecurityPolicy
}
type PackageLists interface {
	Read(context.Context, string, string) (string, error)
}

func (c *Compiler) Compile(ctx context.Context, input backend.Input, generation uint64) (*backend.RuntimePlan, error) {
	prepared, err := c.prepare(ctx, input)
	if err != nil {
		return nil, backend.WithFailure(err, "profile_invalid", nil)
	}
	return backend.NewRuntimePlan(generation, prepared)
}

// prepare builds the plan payload. Its JSON encoding is the engine contract,
// including the member order of order-sensitive dictionaries.
func (c *Compiler) prepare(ctx context.Context, input backend.Input) (Prepared, error) {
	// Settings stay raw at first so the declaration order of order-sensitive
	// dictionaries survives decoding into Go maps.
	var wire struct {
		Input
		Settings json.RawMessage `json:"settings"`
	}
	decoder := json.NewDecoder(bytes.NewReader(input))
	decoder.UseNumber()
	if err := decoder.Decode(&wire); err != nil {
		return Prepared{}, err
	}
	request := wire.Input
	if len(wire.Settings) > 0 {
		decoder = json.NewDecoder(bytes.NewReader(wire.Settings))
		decoder.UseNumber()
		if err := decoder.Decode(&request.Settings); err != nil {
			return Prepared{}, err
		}
	}
	if request.Version != 1 {
		return Prepared{}, errors.New("unsupported preparation input version")
	}
	if c.Validate == nil {
		return Prepared{}, errors.New("engine validator is required")
	}
	if request.Profile != nil && request.Profile.SourceMissing {
		return Prepared{}, errors.New("profile source is unavailable")
	}
	settings := request.Settings
	patch := defaults()
	mergePatch(patch, object(settings["patchClashConfig"]), "")
	patchPolicyOrder := jsonKeyOrder(defaultPatch, "dns", "nameserver-policy")
	if order := jsonKeyOrder(wire.Settings, "patchClashConfig", "dns", "nameserver-policy"); order != nil {
		patchPolicyOrder = order
	}
	var profilePolicyOrder []string
	app := object(settings["appSetting"])
	override := app["overrideNetworkSettings"] == true
	testURL, hasTestURL := app["testUrl"].(string)
	if !hasTestURL {
		testURL = "https://www.gstatic.com/generate_204"
	}
	config := Object{}
	metadata := Object{}
	selected := Object{}
	profileID := ""
	if request.Profile != nil {
		profileID = request.Profile.ID
		if profileID == "" || strings.ContainsAny(profileID, "/\\\x00") || profileID == "." || profileID == ".." {
			return Prepared{}, errors.New("invalid profile id")
		}
		var err error
		config, profilePolicyOrder, err = parseProfile(request.Profile.Text)
		if err != nil {
			return Prepared{}, err
		}
		metadata = request.Profile.Metadata
		selected = object(metadata["selectedMap"])
	}
	script := currentScript(settings)
	if script != "" {
		if c.Scripts == nil {
			return Prepared{}, errors.New("script evaluator is required")
		}
		if config["proxy-providers"] == nil {
			config["proxy-providers"] = Object{}
		}
		var err error
		config, err = c.Scripts.Evaluate(ctx, script, config)
		if err != nil {
			return Prepared{}, err
		}
	}
	if !override {
		for _, key := range []string{"ipv6", "allow-lan", "mixed-port", "find-process-mode", "tcp-concurrent", "unified-delay", "log-level", "keep-alive-interval", "external-controller"} {
			if value, ok := config[key]; ok && validProviderHint(key, value) {
				switch key {
				case "mixed-port", "keep-alive-interval":
					n, _ := number(value)
					patch[key] = int(n)
				case "find-process-mode":
					patch[key] = strings.ToLower(text(value))
				case "log-level", "external-controller":
					patch[key] = strings.TrimSpace(text(value))
				default:
					patch[key] = value
				}
			}
		}
		tun := object(config["tun"])
		if contains([]string{"gvisor", "system", "mixed"}, strings.ToLower(text(tun["stack"]))) {
			object(patch["tun"])["stack"] = strings.ToLower(text(tun["stack"]))
		}
	}
	android := c.Capabilities.Platform == "android"
	c.Policy.ApplyPatch(patch, metadata, c.Capabilities)

	tun := object(patch["tun"])
	if text(object(settings["networkProps"])["routeMode"]) == "bypassPrivate" {
		tun["route-address"] = bypassPrivateRoutes()
	}
	routes, _ := tun["route-address"].([]any)
	tun["auto-route"] = len(routes) == 0
	patch["tun"] = tun
	diagnostics := []string{}
	var profileAccess Object
	if android {
		var err error
		profileAccess, err = c.splitPackages(ctx, config, profileID, &diagnostics)
		if err != nil {
			return Prepared{}, err
		}
	}
	nodes := []Node{}
	if c.Nodes != nil {
		var err error
		nodes, err = c.Nodes.Compile(ctx, config, patch, testURL)
		if err != nil {
			return Prepared{}, err
		}
	} else {
		for _, entry := range list(config["proxies"]) {
			if isExternal(text(object(entry)["type"])) {
				return Prepared{}, errors.New("external transport compiler is required")
			}
		}
	}
	config["interface-name"] = ""
	if android && text(config["external-ui"]) != "" {
		diagnostics = append(diagnostics, "Android ignored unsupported local profile path `external-ui`.")
	}
	if android || text(config["external-ui"]) == "" {
		config["external-ui"] = filepath.Join(c.Capabilities.HomeDir, "zashboard")
	}
	if config["external-ui-url"] == nil {
		config["external-ui-url"] = ""
	}
	config["secret"] = strings.TrimSpace(text(config["secret"]))
	for _, key := range []string{"external-controller", "tcp-concurrent", "unified-delay", "log-level", "keep-alive-interval", "port", "socks-port", "redir-port", "tproxy-port", "mode", "find-process-mode", "allow-lan", "ipv6", "mixed-port", "geodata-loader", "global-ua"} {
		config[key] = patch[key]
	}
	actualTun := object(config["tun"])
	for key, value := range tun {
		actualTun[key] = value
	}
	config["tun"] = actualTun
	for _, sniffer := range object(object(config["sniffer"])["sniff"]) {
		s := object(sniffer)
		if values, ok := s["ports"].([]any); ok {
			for i, v := range values {
				values[i] = fmt.Sprint(v)
			}
		}
	}
	for section, kind := range map[string]string{"proxy-providers": "proxies", "rule-providers": "rules"} {
		for _, value := range object(config[section]) {
			provider := object(value)
			if provider["type"] == "http" {
				if address, ok := provider["url"].(string); ok {
					provider["path"] = filepath.Join(c.Capabilities.ProfilesDir, "providers", profileID, kind, md5Text(address))
				}
			}
		}
	}
	profile := object(config["profile"])
	profile["store-selected"] = false
	config["profile"] = profile
	geo := object(patch["geox-url"])
	merge(geo, object(config["geox-url"]))
	config["geox-url"] = geo
	hosts := object(config["hosts"])
	for name, value := range object(patch["hosts"]) {
		hosts[name] = splitValues(text(value))
	}
	config["hosts"] = hosts
	dns := object(config["dns"])
	enabled := dns["enable"] == true
	policyOrder := profilePolicyOrder
	if settings["overrideDns"] == true || !enabled {
		dns = copyObject(object(patch["dns"]))
		if !enabled {
			dns["nameserver"] = append(list(dns["nameserver"]), "system://")
		}
		policy := object(dns["nameserver-policy"])
		for key, value := range policy {
			policy[key] = splitValues(text(value))
		}
		dns["nameserver-policy"] = policy
		policyOrder = patchPolicyOrder
	}
	config["dns"] = dns
	rules := list(config["rules"])
	delete(config, "rules")
	overrideData := object(metadata["overrideData"])
	if overrideData["enable"] == true && script == "" {
		rule := object(overrideData["rule"])
		key := "addedRules"
		if rule["type"] == "override" {
			key = "overrideRules"
			rules = []any{}
		}
		extra := []any{}
		for _, item := range list(rule[key]) {
			extra = append(extra, text(object(item)["value"]))
		}
		rules = append(extra, rules...)
	}
	// The engine loader uses YAML tags, including when the payload is JSON.
	// RawConfig's JSON tag is "rule", but UnmarshalRawConfig reads "rules".
	config["rules"] = rules
	if android {
		for _, item := range list(config["proxy-groups"]) {
			group := object(item)
			if contains([]string{"fallback", "url-test", "load-balance"}, text(group["type"])) && group["lazy"] == false {
				group["lazy"] = true
			}
		}
	}
	if err := ctx.Err(); err != nil {
		return Prepared{}, err
	}
	vpn := copyObject(object(settings["vpnProps"]))
	if _, ok := vpn["enable"]; !ok {
		vpn["enable"] = true
	}
	if _, ok := vpn["ipv6"]; !ok {
		vpn["ipv6"] = true
	}
	access := object(vpn["accessControl"])
	if profileAccess != nil {
		access = profileAccess
	}
	access = c.Policy.AccessControl(access, c.Capabilities)
	vpn["accessControl"] = access
	name := text(metadata["label"])
	if name == "" {
		name = profileID
	}
	bypass := object(settings["networkProps"])["bypassDomain"]
	if bypass == nil {
		bypass = defaultBypassDomains()
	}
	state := Object{"vpn-props": vpn, "current-profile-name": name, "bypass-domain": bypass}
	if profileAccess != nil {
		profileAccess = c.Policy.AccessControl(profileAccess, c.Capabilities)
		actual := object(config["tun"])
		if profileAccess["mode"] == "acceptSelected" {
			actual["include-package"] = profileAccess["acceptList"]
			delete(actual, "exclude-package")
		} else {
			actual["exclude-package"] = profileAccess["rejectList"]
			delete(actual, "include-package")
		}
		config["tun"] = actual
	}
	for _, value := range selected {
		if _, ok := value.(string); !ok {
			return Prepared{}, errors.New("profile selections must contain proxy names")
		}
	}
	// The engine evaluates nameserver-policy entries in declaration order. This
	// is the last step before sealing: later code must not read the dictionary.
	if policy, ok := asObject(dns["nameserver-policy"]); ok {
		dns["nameserver-policy"] = newOrderedObject(policy, policyOrder)
	}
	if err := c.Validate(ctx, config); err != nil {
		return Prepared{}, err
	}
	closeOnSelect := true
	if value, ok := app["closeConnections"].(bool); ok {
		closeOnSelect = value
	}
	return Prepared{ProfileID: profileID, Config: config, Selected: selected, TestURL: testURL, Nodes: nodes, CoreState: state, Patch: patch, Diagnostics: diagnostics, ProfileAccessControl: profileAccess, CloseConnectionsOnSelect: closeOnSelect}, nil
}
func text(value any) string { v, _ := value.(string); return v }
func list(value any) []any {
	v, _ := value.([]any)
	if v == nil {
		return []any{}
	}
	return v
}
func merge(target, source Object) {
	for key, value := range source {
		if child, ok := asObject(value); ok {
			old, exists := asObject(target[key])
			if !exists {
				old = Object{}
			}
			merge(old, child)
			target[key] = old
		} else {
			target[key] = value
		}
	}
}

// replacedPatchMaps are dictionaries that the legacy ClashConfig model decoded
// as whole maps: a saved value replaces the defaults instead of being merged,
// so entries the user deleted do not return.
var replacedPatchMaps = map[string]bool{"hosts": true, "dns.nameserver-policy": true}

// mergePatch applies saved settings over defaults like the legacy model:
// nested structures are filled field by field, dictionaries are replaced.
func mergePatch(target, source Object, path string) {
	for key, value := range source {
		name := key
		if path != "" {
			name = path + "." + key
		}
		if child, ok := asObject(value); ok && !replacedPatchMaps[name] {
			old, exists := asObject(target[key])
			if !exists {
				old = Object{}
			}
			mergePatch(old, child, name)
			target[key] = old
		} else {
			target[key] = value
		}
	}
}
func copyObject(value Object) Object {
	raw, _ := json.Marshal(value)
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var result Object
	_ = decoder.Decode(&result)
	if result == nil {
		return Object{}
	}
	return result
}
func md5Text(value string) string { sum := md5.Sum([]byte(value)); return hex.EncodeToString(sum[:]) }
func validProviderHint(key string, value any) bool {
	switch key {
	case "ipv6", "allow-lan", "tcp-concurrent", "unified-delay":
		_, ok := value.(bool)
		return ok
	case "mixed-port", "keep-alive-interval":
		_, ok := number(value)
		return ok
	case "find-process-mode":
		return contains([]string{"always", "strict", "off"}, strings.ToLower(text(value)))
	default:
		return strings.TrimSpace(text(value)) != ""
	}
}
func currentScript(settings Object) string {
	scripts := object(settings["scriptProps"])
	id := text(scripts["currentId"])
	for _, entry := range list(scripts["scripts"]) {
		script := object(entry)
		if id != "" && text(script["id"]) == id {
			return text(script["content"])
		}
	}
	return ""
}
func isExternal(kind string) bool {
	return contains([]string{"naiveproxy", "byedpi", "olcrtc", "stormdns"}, strings.ToLower(strings.TrimSpace(kind)))
}
func splitValues(value string) any {
	values := strings.FieldsFunc(value, func(r rune) bool { return r == ',' || r == ';' || r == ' ' })
	if len(values) > 1 {
		return values
	}
	return value
}
func selfBypass(access Object, self []string) Object {
	access = copyObject(access)
	if len(self) == 0 {
		self = []string{"com.makriq.flclash", "com.makriq.flclash.dev"}
	}
	if access["enable"] != true {
		access["enable"] = true
		access["mode"] = "rejectSelected"
		access["rejectList"] = self
		return access
	}
	if access["mode"] == "acceptSelected" {
		accepted := []any{}
		for _, name := range list(access["acceptList"]) {
			if !contains(self, text(name)) {
				accepted = append(accepted, name)
			}
		}
		access["acceptList"] = accepted
		if len(accepted) > 0 {
			return access
		}
		access["mode"] = "rejectSelected"
		access["rejectList"] = self
		return access
	}
	rejected := list(access["rejectList"])
	for _, name := range self {
		found := false
		for _, old := range rejected {
			found = found || old == name
		}
		if !found {
			rejected = append(rejected, name)
		}
	}
	access["rejectList"] = rejected
	return access
}
