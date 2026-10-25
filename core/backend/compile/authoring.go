package compile

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"core/backend/authoring"
)

// ShareLinkDecoder is a pure host helper. It may parse protocols supported by
// the linked mihomo version but must not start or mutate the running engine.
type ShareLinkDecoder func(context.Context, string) ([]Object, error)

func declaration(row authoring.Object) Object { return Object(authoring.Decode(row)) }
func declarationID(value any) string          { raw, _ := json.Marshal(value); return authoring.ID(raw) }

// customConfig assembles only proxies and providers used by this profile.
// All user-controlled paths are discarded; sources are captured repository data.
func (c *Compiler) customConfig(ctx context.Context, request Input) (Object, error) {
	id := request.Profile.ID
	groups := []any{}
	named := map[string]bool{}
	used := map[string]bool{}
	allProxies, allProviders := false, false
	for _, row := range authoring.Scoped(request.Authoring["proxyGroups"], id) {
		group := groupDefinition(declaration(row))
		groups = append(groups, group)
		for _, proxy := range list(group["proxies"]) {
			named[text(proxy)] = true
		}
		if fallback := text(group["empty-fallback"]); fallback != "" {
			named[fallback] = true
		}
		for _, provider := range list(group["use"]) {
			used[text(provider)] = true
		}
		allProxies = allProxies || group["include-all-proxies"] == true
		allProviders = allProviders || group["include-all-providers"] == true
	}
	profileRules := authoring.Scoped(request.Authoring["rules"], id)
	for _, rule := range profileRules {
		// SUB-RULE names a rule section rather than an outbound.
		if target := authoring.String(rule, "ruleTarget"); target != "" && authoring.Action(rule) != "SUB-RULE" {
			named[target] = true
		}
	}
	dialers := map[string]string{}
	for _, row := range authoring.Scoped(request.Authoring["proxyDialers"], id) {
		dialers[authoring.ID(row["proxyId"])] = authoring.String(row, "target")
	}
	defs := []Object{}
	byName := map[string]Object{}
	dialByName := map[string]string{}
	for _, row := range authoring.Ordered(request.Authoring["customProxies"]) {
		def := copyObject(object(declaration(row)["definition"]))
		name := text(def["name"])
		delete(def, "dialer-proxy")
		if dialer := dialers[authoring.ID(row["id"])]; dialer != "" {
			def["dialer-proxy"] = dialer
			dialByName[name] = dialer
		}
		defs = append(defs, def)
		byName[name] = def
	}
	// A dialer target is a dependency even when a group does not list it directly.
	visiting, done := map[string]bool{}, map[string]bool{}
	var include func(string) error
	include = func(name string) error {
		if visiting[name] {
			return errors.New("cyclic custom dialer chain")
		}
		if done[name] {
			return nil
		}
		visiting[name] = true
		if byName[name] != nil {
			named[name] = true
			if target := dialByName[name]; target != "" {
				if err := include(target); err != nil {
					return err
				}
			}
		}
		for _, entry := range groups {
			g := object(entry)
			if text(g["name"]) == name {
				for _, p := range list(g["proxies"]) {
					if err := include(text(p)); err != nil {
						return err
					}
				}
			}
		}
		delete(visiting, name)
		done[name] = true
		return nil
	}
	for name := range named {
		if err := include(name); err != nil {
			return nil, err
		}
	}
	proxies := []any{}
	for _, def := range defs {
		if allProxies || named[text(def["name"])] {
			proxies = append(proxies, def)
		}
	}
	providers := Object{}
	options := object(object(request.Profile.Metadata["overrides"])["proxy-providers"])
	sourceIDs := make([]string, 0, len(request.Profiles))
	for key := range request.Profiles {
		sourceIDs = append(sourceIDs, key)
	}
	sort.Strings(sourceIDs)
	for _, sourceID := range sourceIDs {
		source := request.Profiles[sourceID]
		label := text(source.Metadata["label"])
		if label == "" {
			label = source.ID
		}
		if !allProviders && !used[label] {
			continue
		}
		if source.SourceMissing {
			return nil, fmt.Errorf("provider %s source is unavailable", label)
		}
		parsed, err := ParseProfile(source.Text)
		if err != nil {
			return nil, fmt.Errorf("provider %s: %w", label, err)
		}
		payload := list(parsed["proxies"])
		providers[label] = Object{"type": "inline", "payload": payload}
		for key, value := range providerDefinition(object(options[label])) {
			object(providers[label])[key] = value
		}
	}
	config := copyObject(object(request.Profile.Metadata["customConfig"]))
	for key, value := range (Object{"proxies": proxies, "proxy-groups": groups, "proxy-providers": providers, "rule-providers": Object{}, "rules": []any{}}) {
		config[key] = value
	}
	for name := range used {
		if providers[name] == nil {
			return nil, fmt.Errorf("missing proxy provider %s", name)
		}
	}
	rules := []any{}
	for _, row := range profileRules {
		line, err := authoring.RuleLine(row)
		if err != nil {
			return nil, err
		}
		rules = append(rules, line)
	}
	config["rules"] = rules
	if err := c.injectRuleProviders(ctx, config, request); err != nil {
		return nil, err
	}
	return config, nil
}
func groupDefinition(row Object) Object {
	out := Object{}
	for _, key := range strings.Fields("name type proxies use use-position interval lazy disable-udp url timeout max-failed-times filter exclude-filter exclude-type expected-status tolerance strategy hash-key default-selected empty-fallback include-all-proxies include-all-providers hidden icon") {
		value := row[key]
		if value == nil || value == "" {
			continue
		}
		if (key == "proxies" || key == "use") && len(list(value)) == 0 {
			continue
		}
		out[key] = value
	}
	if row["include-all"] == true {
		out["include-all-proxies"] = true
		out["include-all-providers"] = true
	}
	if row["type"] != "url-test" {
		delete(out, "tolerance")
	}
	if row["type"] != "select" {
		delete(out, "default-selected")
	}
	if row["type"] != "load-balance" {
		delete(out, "strategy")
		delete(out, "hash-key")
	} else if row["strategy"] == "round-robin" {
		delete(out, "hash-key")
	}
	positions := Object{}
	count := len(list(row["proxies"]))
	for _, provider := range list(row["use"]) {
		name := text(provider)
		n, ok := number(object(row["use-position"])[name])
		if ok && n < float64(count) {
			if n < 0 {
				n = 0
			}
			positions[name] = int(n)
		}
	}
	if len(positions) > 0 {
		out["use-position"] = positions
	} else {
		delete(out, "use-position")
	}
	return out
}
func providerDefinition(row Object) Object {
	out := Object{}
	for _, key := range []string{"filter", "exclude-filter"} {
		if row[key] != nil {
			out[key] = row[key]
		}
	}
	if check := object(row["health-check"]); len(check) > 0 {
		check = copyObject(check)
		for key, value := range check {
			if value == nil || value == "" {
				delete(check, key)
			}
		}
		if len(check) > 0 {
			check["enable"] = true
			if text(check["url"]) == "" {
				check["url"] = "https://www.gstatic.com/generate_204"
			}
			out["health-check"] = check
		}
	}
	if overrides := object(row["override"]); len(overrides) > 0 {
		overrides = copyObject(overrides)
		for key, value := range overrides {
			if value == nil || value == "" {
				delete(overrides, key)
			}
		}
		if len(overrides) > 0 {
			out["override"] = overrides
		}
	}
	return out
}
func (c *Compiler) injectRuleProviders(ctx context.Context, config Object, request Input) error {
	// Includes RULE-SET within logical payloads and DNS rule-set declarations.
	used := map[string]bool{}
	var scan func(any)
	scan = func(v any) {
		switch value := v.(type) {
		case string:
			for _, part := range strings.Split(value, "rule-set:")[1:] {
				for _, name := range strings.Split(firstRuleSetToken(part), ",") {
					used[name] = true
				}
			}
			fields := strings.Split(value, ",")
			for i, field := range fields {
				if strings.Trim(field, " ()") == "RULE-SET" && i+1 < len(fields) {
					used[strings.Trim(fields[i+1], " ()")] = true
				}
			}
		case []any:
			for _, entry := range value {
				scan(entry)
			}
		case Object:
			for k, entry := range value {
				scan(k)
				scan(entry)
			}
		case map[string]any:
			scan(Object(value))
		}
	}
	scan(config["rules"])
	scan(request.Profile.Metadata["overrides"])
	// RawMessage cannot be scanned; metadata was decoded with UseNumber by prepare.
	providers := object(config["rule-providers"])
	for _, row := range request.Authoring["clashProviders"] {
		label := authoring.String(row, "label")
		if !used[label] || providers[label] != nil {
			continue
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		def, err := c.ruleProvider(ctx, row)
		if err != nil {
			return fmt.Errorf("rule provider %s: %w", label, err)
		}
		providers[label] = def
	}
	config["rule-providers"] = providers
	for name := range used {
		if providers[name] == nil {
			return fmt.Errorf("missing rule provider %s", name)
		}
	}
	return nil
}
func (c *Compiler) ruleProvider(ctx context.Context, row authoring.Object) (Object, error) {
	behavior := authoring.String(row, "behavior")
	if behavior == "" {
		behavior = "classical"
	}
	format := authoring.String(row, "format")
	if format == "" {
		format = "yaml"
	}
	def := Object{"behavior": behavior, "format": format}
	data, hasContent, err := RuleResourceBytes(row)
	if err != nil {
		return nil, err
	}
	if !hasContent {
		if address := authoring.String(row, "url"); address != "" {
			def["type"] = "http"
			def["url"] = address
			def["interval"] = 86400
			def["path"] = filepath.Join(c.Capabilities.ProfilesDir, "providers", "authoring", md5Text(authoring.ID(row["id"])+"@"+address))
			return def, nil
		}
		return nil, errors.New("resource has no content")
	}
	if len(data) > 16<<20 {
		return nil, errors.New("rule resource exceeds size limit")
	}
	compiled, e := c.CompileResource(ctx, data)
	if e != nil {
		return nil, e
	}
	if compiled.Content != nil {
		data = compiled.Content
		format = "mrs"
	} else {
		format = compiled.Format
	}
	def["format"] = format
	def["behavior"] = compiled.Behavior

	if len(data) > 16<<20 {
		return nil, errors.New("resource exceeds size limit")
	}
	// Files are immutable and content-addressed: rollback and an active generation
	// keep reading the same bytes even when an editor replaces the resource.
	hash := sha256.Sum256(data)
	name := hex.EncodeToString(hash[:]) + "." + format
	directory := filepath.Join(c.Capabilities.ProfilesDir, "providers", "authoring")
	if !filepath.IsAbs(directory) {
		return nil, errors.New("private resource directory is required")
	}
	if err = os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	target := filepath.Join(directory, name)
	if _, err = os.Stat(target); errors.Is(err, os.ErrNotExist) {
		file, e := os.CreateTemp(directory, ".resource-*")
		if e != nil {
			return nil, e
		}
		defer os.Remove(file.Name())
		if e = file.Chmod(0600); e == nil {
			_, e = file.Write(data)
		}
		if e == nil {
			e = file.Sync()
		}
		closeErr := file.Close()
		if e == nil {
			e = closeErr
		}
		if e != nil {
			return nil, e
		}
		if e = os.Rename(file.Name(), target); e != nil {
			return nil, e
		}
	} else if err != nil {
		return nil, err
	}
	def["type"] = "file"
	def["path"] = target
	return def, nil
}

func authoredScript(request Input) (string, error) {
	if request.Profile == nil {
		return currentScript(request.Settings), nil
	}
	metadata := request.Profile.Metadata
	if metadata["type"] == "custom" {
		return "", nil
	}
	extend, has := metadata["extendType"]
	if !has {
		return currentScript(request.Settings), nil
	}
	if extend != "script" {
		return "", nil
	}
	id := declarationID(metadata["scriptId"])
	if id == "" {
		return "", nil
	}
	for _, row := range request.Authoring["scripts"] {
		if authoring.ID(row["id"]) == id {
			if _, ok := row["content"]; !ok {
				return "", errors.New("selected script content is unavailable")
			}
			return authoring.String(row, "content"), nil
		}
	}
	return "", errors.New("selected script is unavailable")
}
func authoredRules(config Object, request Input, script string) ([]any, error) {
	rules := list(config["rules"])
	if request.Profile == nil || request.Profile.Metadata["type"] == "custom" || script != "" {
		return rules, nil
	}
	if extend, exists := request.Profile.Metadata["extendType"]; exists && extend != "standard" {
		return rules, nil
	}
	id := request.Profile.ID
	disabled := map[string]bool{}
	for _, row := range authoring.Scoped(request.Authoring["disabledRules"], id) {
		disabled[authoring.ID(row["ruleId"])] = true
	}
	extra := []any{}
	target := strings.TrimSpace(text(request.Profile.Metadata["matchTarget"]))
	if target == "" {
		for i := len(rules) - 1; i >= 0; i-- {
			if parsed, err := authoring.ParseRule(text(rules[i])); err == nil && authoring.Action(parsed) == "MATCH" {
				target = authoring.String(parsed, "ruleTarget")
				break
			}
		}
	}
	for _, pid := range []string{id, ""} {
		for _, row := range authoring.Scoped(request.Authoring["rules"], pid) {
			if disabled[authoring.ID(row["id"])] {
				continue
			}
			rowCopy := declaration(row)
			if strings.EqualFold(text(rowCopy["ruleTarget"]), "MATCH") && target != "" {
				rowCopy["ruleTarget"] = target
			}
			line, err := authoring.RuleLine(authoring.Object(toRaw(rowCopy)))
			if err != nil {
				return nil, err
			}
			extra = append(extra, line)
		}
	}
	return append(extra, rules...), nil
}
func toRaw(value Object) map[string]json.RawMessage {
	out := map[string]json.RawMessage{}
	for key, v := range value {
		out[key], _ = json.Marshal(v)
	}
	return out
}

type proxySlot struct {
	values []any
	index  int
}

func proxySlots(config Object) []proxySlot {
	out := []proxySlot{}
	appendSlots := func(values []any) {
		for i := range values {
			out = append(out, proxySlot{values, i})
		}
	}
	appendSlots(list(config["proxies"]))
	names := []string{}
	for name := range object(config["proxy-providers"]) {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		provider := object(object(config["proxy-providers"])[name])
		if provider["type"] == "inline" {
			appendSlots(list(provider["payload"]))
		}
	}
	return out
}

// BuildProfile returns the validated compiled document without submitting it to
// the coordinator or acquiring any execution capability.
func (c *Compiler) BuildProfile(ctx context.Context, input []byte) (Object, error) {
	prepared, err := c.prepare(ctx, input)
	return prepared.Config, err
}

func firstRuleSetToken(part string) string {
	fields := strings.FieldsFunc(part, func(r rune) bool { return r == ')' || r == '(' || r == '#' || r == ' ' })
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
}
