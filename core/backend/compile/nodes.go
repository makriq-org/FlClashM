package compile

import (
	"context"
	"core/backend/netpolicy"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"
)

//go:embed byebyeedpi-strategies.list
var bundledStrategies string

type ExternalCompiler struct {
	Lists             PackageLists
	RemoteLists       RemoteLists
	BuiltinStrategies []string
}

func (e *ExternalCompiler) Compile(ctx context.Context, config, patch Object, testURL string) ([]Node, error) {
	if strings.EqualFold(strings.TrimSpace(text(object(config["x-flclashm-runtime"])["engine"])), "naiveproxy") {
		return nil, errors.New("legacy top-level naiveproxy runtime selection is unsupported")
	}
	delete(config, "x-flclashm-runtime")
	requests, err := collectRemoteRequests(config)
	if err != nil {
		return nil, err
	}
	local := *e
	if len(local.BuiltinStrategies) == 0 {
		for _, line := range strings.Split(bundledStrategies, "\n") {
			line = strings.TrimSpace(line)
			if line != "" && !strings.HasPrefix(line, "#") {
				local.BuiltinStrategies = append(local.BuiltinStrategies, line)
			}
		}
	}
	if e.RemoteLists != nil {
		resolved, err := e.RemoteLists.Resolve(ctx, requests)
		if err != nil {
			return nil, err
		}
		local.Lists = resolvedLists(resolved)
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	e = &local
	reserved := map[int]bool{}
	for _, source := range []Object{config, patch} {
		for _, key := range []string{"port", "socks-port", "redir-port", "tproxy-port", "mixed-port"} {
			if n, ok := number(source[key]); ok && n > 0 {
				reserved[int(n)] = true
			}
		}
	}
	nodes := []Node{}
	for index, entry := range list(config["proxies"]) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		raw := object(entry)
		kind := strings.ToLower(strings.TrimSpace(text(raw["type"])))
		if !isExternal(kind) {
			continue
		}
		normalized, err := normalizeNode(raw, kind)
		if err != nil {
			return nil, err
		}
		raw = normalized
		mode := text(raw["mode"])
		if kind == "byedpi" && mode == "" {
			mode = "auto"
			if _, ok := raw["strategy"]; ok {
				mode = "manual"
			}
			raw["mode"] = mode
		}
		if err = ValidateNode(raw, kind, mode); err != nil {
			return nil, err
		}
		name := strings.TrimSpace(text(raw["name"]))
		if name == "" {
			return nil, errors.New("external node name is required")
		}
		start, size := 35000, 512
		switch kind {
		case "byedpi":
			start, size = 35600, 256
		case "olcrtc":
			start, size = 35900, 256
		case "stormdns":
			start, size = 36200, 256
		}
		seed := 0
		for _, r := range md5Text(name) {
			seed += int(r)
		}
		port := 0
		for offset := 0; offset < size; offset++ {
			candidate := start + (seed+offset)%size
			if !reserved[candidate] {
				port = candidate
				break
			}
		}
		if port == 0 {
			return nil, errors.New("external listener port range exhausted")
		}
		reserved[port] = true
		udp := kind == "byedpi"
		if value, ok := raw["udp"]; ok {
			udp = value == true
		}
		if udp && kind != "byedpi" {
			return nil, errors.New("external transport does not support UDP")
		}
		check, activation, err := nodeChecks(raw, kind, name, config, testURL)
		if err != nil {
			return nil, err
		}
		node := Node{ID: kind + "-" + md5Text(name), Type: kind, Name: name, Host: "127.0.0.1", Port: port, UDP: udp, Files: map[string]string{}, Metadata: map[string]string{}, Check: check, Activation: activation}
		switch kind {
		case "naiveproxy":
			err = buildNaive(raw, &node)
		case "olcrtc":
			err = buildOlcRTC(raw, &node)
		case "byedpi":
			err = e.buildByeDPI(ctx, raw, &node)
		case "stormdns":
			err = e.buildStormDNS(ctx, raw, &node)
		}
		if err != nil {
			return nil, fmt.Errorf("%s node %q: %w", kind, name, err)
		}
		nodes = append(nodes, node)
		list(config["proxies"])[index] = Object{"name": name, "type": "socks5", "server": node.Host, "port": port, "udp": udp}
	}
	return nodes, nil
}
func nodeChecks(raw Object, kind, name string, config Object, testURL string) (Object, Object, error) {
	inherited, direct, err := groupChecks(config, name)
	if err != nil {
		return nil, nil, err
	}
	check := copyObject(object(raw["connectivity-check"]))
	urls, err := safeURLs(check["urls"])
	if err != nil {
		return nil, nil, err
	}
	if len(urls) == 0 {
		urls = inherited
	}
	if len(urls) == 0 && strings.TrimSpace(testURL) != "" {
		urls, err = safeURLs([]any{testURL})
		if err != nil {
			return nil, nil, err
		}
	}
	check["urls"] = urls
	if check["required"] == true && len(urls) == 0 {
		return nil, nil, errors.New("required connectivity check has no URLs")
	}
	if check["required"] == nil {
		check["required"] = false
	}
	startup := 30 * time.Second
	if kind == "stormdns" {
		startup = 2 * time.Minute
	}
	for key, spec := range map[string]struct{ fallback, max time.Duration }{"timeout": {5 * time.Second, time.Minute}, "startup-timeout": {startup, 5 * time.Minute}, "retry-interval": {time.Second, 5 * time.Minute}} {
		value, err := wholeSeconds(check[key], spec.fallback, spec.max, false)
		if err != nil {
			return nil, nil, fmt.Errorf("connectivity-check.%s: %w", key, err)
		}
		check[key] = value
	}
	for key, spec := range map[string][2]int{"requests": {1, 32}, "concurrency": {1, 16}} {
		value, err := bounded(check[key], spec[0], 1, spec[1])
		if err != nil {
			return nil, nil, err
		}
		check[key] = value
	}
	if ratio, ok := number(check["min-success-ratio"]); ok && (ratio <= 0 || ratio > 1) {
		return nil, nil, errors.New("connectivity success ratio must be within (0,1]")
	}
	if kind == "naiveproxy" || kind == "byedpi" {
		return check, nil, nil
	}
	activation := copyObject(object(raw["activation"]))
	mode := "auto"
	if value, ok := raw["activation"].(string); ok {
		mode = strings.ToLower(strings.TrimSpace(value))
	} else if value := text(activation["mode"]); value != "" {
		mode = value
	}
	activation["mode"] = mode
	wake := object(activation["wake"])
	wakeURLs, err := safeURLs(wake["urls"])
	if err != nil {
		return nil, nil, err
	}
	if len(wakeURLs) == 0 {
		wakeURLs = urls
	}
	wake["urls"] = wakeURLs
	if mode == "auto" && (len(direct) == 0 || len(wakeURLs) == 0) {
		return nil, nil, errors.New("automatic activation requires a direct containing group and wake URL")
	}
	for key, spec := range map[string]struct{ fallback, max time.Duration }{"interval": {30 * time.Second, time.Hour}, "retry-after": {5 * time.Minute, 24 * time.Hour}} {
		value, err := wholeSeconds(wake[key], spec.fallback, spec.max, false)
		if err != nil {
			return nil, nil, err
		}
		wake[key] = value
	}
	failures, err := bounded(wake["failures"], 2, 1, 10)
	if err != nil {
		return nil, nil, err
	}
	wake["failures"] = failures
	sleep := object(activation["sleep"])
	idle, err := wholeSeconds(sleep["idle"], 15*time.Minute, 24*time.Hour, true)
	if err != nil {
		return nil, nil, err
	}
	sleep["idle"] = idle
	activation["wake"] = wake
	activation["sleep"] = sleep
	activation["containing-groups"] = direct
	activation["watch-group"] = ""
	if len(direct) > 0 {
		activation["watch-group"] = direct[0]
	}
	return check, activation, nil
}
func groupChecks(config Object, name string) ([]string, []string, error) {
	groups := list(config["proxy-groups"])
	direct := []string{}
	for _, item := range groups {
		group := object(item)
		for _, member := range list(group["proxies"]) {
			if strings.TrimSpace(text(member)) == name && text(group["name"]) != "" {
				direct = append(direct, text(group["name"]))
				break
			}
		}
	}
	members := map[string]bool{name: true}
	visited := map[string]bool{}
	for len(members) > 0 {
		parents := map[string]bool{}
		for _, item := range groups {
			group := object(item)
			name := strings.TrimSpace(text(group["name"]))
			if name == "" || visited[name] {
				continue
			}
			found := false
			for _, entry := range list(group["proxies"]) {
				found = found || members[strings.TrimSpace(text(entry))]
			}
			if !found {
				continue
			}
			visited[name] = true
			if value := group["connectivity-check"]; value != nil {
				if _, ok := asObject(value); !ok {
					return nil, nil, errors.New("group connectivity-check must be a map")
				}
			}
			urls, err := safeURLs(object(group["connectivity-check"])["urls"])
			if err != nil {
				return nil, nil, err
			}
			if len(urls) > 0 {
				return urls, direct, nil
			}
			if address := strings.TrimSpace(text(group["url"])); address != "" {
				urls, err = safeURLs([]any{address})
				return urls, direct, err
			}
			parents[name] = true
		}
		members = parents
	}
	return nil, direct, nil
}
func wholeSeconds(value any, fallback, maximum time.Duration, zero bool) (int64, error) {
	duration, err := Duration(value, fallback, maximum, zero)
	if err != nil {
		return 0, err
	}
	if duration%time.Second != 0 {
		return 0, errors.New("duration requires whole seconds")
	}
	return int64(duration / time.Second), nil
}
func bounded(value any, fallback, minimum, maximum int) (int, error) {
	if value == nil {
		return fallback, nil
	}
	n, ok := number(value)
	if !ok || !matchesType(value, "integer") || n < float64(minimum) || n > float64(maximum) {
		return 0, errors.New("integer outside supported range")
	}
	return int(n), nil
}
func safeURLs(value any) ([]string, error) {
	if value == nil {
		return nil, nil
	}
	values, ok := value.([]any)
	if !ok || len(values) > 16 {
		return nil, errors.New("check URLs must be a list of at most 16 entries")
	}
	result := []string{}
	for _, value := range values {
		address := strings.TrimSpace(text(value))
		if err := netpolicy.ValidateURL(address); err != nil {
			return nil, err
		}
		u, _ := url.Parse(address)
		result = append(result, u.String())
	}
	return result, nil
}

func artifact(node *Node, name string, value any) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	node.Files["built-in-proxies/"+node.Type+"/"+node.ID+"/"+name] = string(raw)
	return nil
}
