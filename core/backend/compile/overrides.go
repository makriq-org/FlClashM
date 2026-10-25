package compile

import (
	"fmt"
	"strings"
)

var overridePaths = map[string]string{
	"dns":     "enable listen listen-routing-mark use-hosts use-system-hosts ipv6 ipv6-timeout respect-rules prefer-h3 cache-algorithm cache-max-size enhanced-mode fake-ip-range fake-ip-range6 fake-ip-filter fake-ip-filter-mode fake-ip-ttl default-nameserver nameserver-policy nameserver fallback fallback-lazy-query proxy-server-nameserver proxy-server-nameserver-policy direct-nameserver direct-nameserver-follow-policy fallback-filter.geoip fallback-filter.geoip-code fallback-filter.geosite fallback-filter.ipcidr fallback-filter.domain",
	"ntp":     "enable server port interval dialer-proxy write-to-system",
	"sniffer": "enable override-destination force-dns-mapping parse-pure-ip force-domain skip-domain skip-src-address skip-dst-address sniff.HTTP sniff.TLS sniff.QUIC",
	"tun":     "mtu congestion-controller strict-route route-address route-exclude-address dns-hijack udp-timeout disable-icmp-forwarding gso",
}
var overrideDefaults = Object{
	"dns":     Object{"enable": false, "listen": "", "listen-routing-mark": 0, "prefer-h3": false, "use-hosts": true, "use-system-hosts": true, "respect-rules": false, "ipv6": false, "ipv6-timeout": 100, "cache-algorithm": "lru", "cache-max-size": 4096, "default-nameserver": []any{"8.8.8.8", "1.1.1.1"}, "enhanced-mode": "redir-host", "fake-ip-range": "198.18.0.1/16", "fake-ip-range6": "", "fake-ip-filter": []any{"dns.msftnsci.com", "www.msftnsci.com", "www.msftconnecttest.com"}, "fake-ip-filter-mode": "blacklist", "fake-ip-ttl": 1, "nameserver-policy": Object{}, "nameserver": []any{"https://dns.google/dns-query", "https://cloudflare-dns.com/dns-query"}, "fallback": []any{}, "fallback-lazy-query": false, "proxy-server-nameserver": []any{}, "proxy-server-nameserver-policy": Object{}, "direct-nameserver": []any{}, "direct-nameserver-follow-policy": false, "fallback-filter": Object{"geoip": true, "geoip-code": "", "geosite": []any{}, "ipcidr": []any{}, "domain": []any{}}},
	"ntp":     Object{"enable": false, "server": "time.apple.com", "port": 123, "interval": 30, "dialer-proxy": "", "write-to-system": false},
	"sniffer": Object{"enable": false, "override-destination": true, "force-dns-mapping": true, "parse-pure-ip": true, "force-domain": []any{}, "skip-domain": []any{}, "skip-src-address": []any{}, "skip-dst-address": []any{}, "sniff": Object{"HTTP": Object{"ports": []any{}}, "TLS": Object{"ports": []any{}}, "QUIC": Object{"ports": []any{}}}},
}

func overrideKeys(source Object, section string) ([]string, bool, error) {
	value, exists := source[section+"-override-keys"]
	if !exists {
		return nil, false, nil
	}
	rows, ok := value.([]any)
	if !ok {
		return nil, true, fmt.Errorf("%s override keys must be an array", section)
	}
	paths := strings.Fields(overridePaths[section])
	keys := []string{}
	for _, entry := range rows {
		path, ok := entry.(string)
		if !ok || !contains(paths, path) {
			return nil, true, fmt.Errorf("unsupported %s override key", section)
		}
		keys = append(keys, path)
	}
	return keys, true, nil
}
func selectedOverrides(source Object, section string, custom bool) (Object, bool, error) {
	keys, exists, err := overrideKeys(source, section)
	if err != nil || !exists {
		return nil, exists, err
	}
	values := copyObject(object(overrideDefaults[section]))

	storage := section
	if section == "tun" && source["tun-override"] != nil {
		storage = "tun-override"
	}
	mergePatch(values, object(source[storage]), "")
	if section == "sniffer" {
		if supplied, ok := asObject(object(source[storage])["sniff"]); ok {
			for key, entry := range supplied {
				object(values["sniff"])[strings.ToUpper(key)] = entry
			}
		}
	}
	out := Object{}
	for _, path := range keys {
		parent, field, nested := strings.Cut(path, ".")
		value := values[parent]
		if nested {
			value = object(values[parent])[field]
		}
		if value == nil {
			continue
		}
		// Custom profiles skip blank DNS form entries; normal profiles can clear a
		// selected field. An empty nameserver is invalid in mihomo in either mode.
		empty := false
		switch v := value.(type) {
		case string:
			empty = v == ""
		case []any:
			empty = len(v) == 0
		case Object:
			empty = len(v) == 0
		case map[string]any:
			empty = len(v) == 0
		}
		if empty && (section != "dns" || custom || path == "nameserver") {
			continue
		}
		if nested {
			child := object(out[parent])
			child[field] = value
			out[parent] = child
		} else {
			out[parent] = value
		}
	}
	for _, key := range []string{"nameserver-policy", "proxy-server-nameserver-policy"} {
		if policy, ok := asObject(out[key]); ok {
			for name, value := range policy {
				if s, ok := value.(string); ok {
					policy[name] = splitValues(s)
				}
			}
		}
	}
	return out, true, nil
}
func mergeSection(raw, patch Object, section string) Object {
	result := copyObject(raw)
	for key, value := range patch {
		if section == "dns" && key == "fallback-filter" {
			nested := object(result[key])
			for k, v := range object(value) {
				nested[k] = v
			}
			result[key] = nested
		} else if section == "sniffer" && key == "sniff" {
			sniff := object(result[key])
			if len(sniff) == 0 {
				sniff = Object{}
				for _, name := range list(raw["sniffing"]) {
					def := Object{}
					if raw["port-whitelist"] != nil {
						def["ports"] = raw["port-whitelist"]
					}
					sniff[strings.ToUpper(text(name))] = def
				}
			}
			for name, entry := range object(value) {
				for old := range sniff {
					if strings.EqualFold(old, name) {
						delete(sniff, old)
					}
				}
				sniff[strings.ToUpper(name)] = entry
			}
			result[key] = sniff
		} else {
			result[key] = value
		}
	}
	return result
}

// applyKeyOverrides leaves every unselected section key byte-semantically
// intact. Profile keys take precedence over shared keys when both are selected.
func (c *Compiler) applyKeyOverrides(config, settings, metadata Object) (bool, error) {
	patch := object(settings["patchClashConfig"])
	local := object(metadata["overrides"])
	custom := metadata["type"] == "custom"
	policyChanged := false
	for _, source := range []Object{patch, local} {
		for _, section := range []string{"dns", "ntp", "sniffer"} {
			fragment, exists, err := selectedOverrides(source, section, custom)
			if err != nil {
				return false, err
			}
			if !exists {
				continue
			}
			if fragment["nameserver-policy"] != nil {
				policyChanged = true
			}
			config[section] = mergeSection(object(config[section]), fragment, section)
		}
	}
	if c.Capabilities.Platform == "android" {
		if ntp, ok := asObject(config["ntp"]); ok {
			ntp["write-to-system"] = false
		}
	}
	return policyChanged, nil
}

// ImportOverrideKeys keeps the selected key paths of an imported section.
func ImportOverrideKeys(section string, value Object) []any {
	out := []any{}
	for _, path := range strings.Fields(overridePaths[section]) {
		parent, field, nested := strings.Cut(path, ".")
		if !nested {
			if _, ok := value[parent]; ok {
				out = append(out, path)
			}
		} else {
			for key := range object(value[parent]) {
				if strings.EqualFold(key, field) {
					out = append(out, path)
					break
				}
			}
		}
	}
	return out
}
