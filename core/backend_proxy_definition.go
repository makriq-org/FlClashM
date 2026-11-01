package main

import (
	"context"
	"encoding/json"
	"errors"

	prepare "core/backend/compile"
	"core/profilecodec"
)

// Definitions come only from the applied private config or a trusted engine
// provider cache; the UI supplies a name, never a file path or a URL to fetch.
func readBackendProxyDefinition(ctx context.Context, name string) (map[string]any, error) {
	runLock.Lock()
	proxy := proxiesWithProviders()[name]
	if proxy == nil {
		runLock.Unlock()
		return nil, errors.New("proxy not found")
	}
	provider := proxy.ProxyInfo().ProviderName
	encoded, err := json.Marshal(currentRuntimeRawConfig)
	runLock.Unlock()
	if err != nil {
		return nil, err
	}
	var config map[string]any
	if err = json.Unmarshal(encoded, &config); err != nil {
		return nil, err
	}
	definitions, _ := config["proxies"].([]any)
	override := map[string]any{}
	if provider != "" {
		providers, _ := config["proxy-providers"].(map[string]any)
		mapping, _ := providers[provider].(map[string]any)
		if mapping == nil {
			return nil, errors.New("provider definition unavailable")
		}
		if value, ok := mapping["override"].(map[string]any); ok {
			override = value
		}
		if override["proxy-name"] != nil || override["override-expr"] != nil {
			return nil, errors.New("provider name rewrite cannot be exported")
		}
		if mapping["type"] == "inline" {
			definitions, _ = mapping["payload"].([]any)
		} else {
			data, err := readBackendProviderResource(ctx, provider, "proxy")
			if err != nil {
				return nil, err
			}
			parsed, err := prepare.ParseProfile(string(data))
			if err != nil {
				var values []any
				for _, group := range profilecodec.DecodeLinks([]string{string(data)}) {
					for _, item := range group {
						values = append(values, item)
					}
				}
				definitions = values
			} else {
				definitions, _ = parsed["proxies"].([]any)
			}
		}
	}
	prefix, _ := override["additional-prefix"].(string)
	suffix, _ := override["additional-suffix"].(string)
	for _, value := range definitions {
		definition, ok := value.(map[string]any)
		if !ok {
			if obj, yes := value.(prepare.Object); yes {
				definition = map[string]any(obj)
			}
		}
		rawName, _ := definition["name"].(string)
		if prefix+rawName+suffix != name {
			continue
		}
		for _, key := range []string{"tfo", "mptcp", "udp", "udp-over-tcp", "up", "down", "dialer-proxy", "skip-cert-verify", "name-cert-verify", "interface-name", "routing-mark", "ip-version"} {
			if value, ok := override[key]; ok {
				definition[key] = value
			}
		}
		definition["name"] = name
		return definition, nil
	}
	return nil, errors.New("proxy definition unavailable")
}
