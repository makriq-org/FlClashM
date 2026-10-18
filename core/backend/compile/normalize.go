package compile

import (
	"errors"
	"fmt"
	"strings"
)

func normalizeKeys(input Object, path string) (Object, error) {
	output := Object{}
	for original, value := range input {
		key := strings.ReplaceAll(original, "_", "-")
		if _, ok := output[key]; ok {
			return nil, errors.New("conflicting canonical transport field")
		}
		if path == "proxy" && key == "headers" {
			output[key] = value
			continue
		}
		if child, ok := asObject(value); ok {
			normalized, err := normalizeKeys(child, path+"."+key)
			if err != nil {
				return nil, err
			}
			value = normalized
		} else if list, ok := value.([]any); ok {
			normalized := make([]any, len(list))
			for i, v := range list {
				if child, ok := asObject(v); ok {
					var err error
					normalized[i], err = normalizeKeys(child, path+"."+key)
					if err != nil {
						return nil, err
					}
				} else {
					normalized[i] = v
				}
			}
			value = normalized
		}
		output[key] = value
	}
	return output, nil
}
func move(node Object, old, new string) error {
	if value, ok := node[old]; ok {
		if _, conflict := node[new]; conflict {
			return errors.New("legacy transport field conflicts with canonical field")
		}
		node[new] = value
		delete(node, old)
	}
	return nil
}
func normalizeNode(input Object, kind string) (Object, error) {
	node, err := normalizeKeys(input, "proxy")
	if err != nil {
		return nil, err
	}
	if kind == "byedpi" {
		if err = move(node, "args", "strategy"); err != nil {
			return nil, err
		}
		mode := text(node["mode"])
		if _, ok := node["mode"]; !ok {
			mode = "auto"
			if _, ok := node["strategy"]; ok {
				mode = "manual"
			}
			node["mode"] = mode
		}
		if mode != "auto" {
			return node, nil
		}
		if value, ok := node["strategy-list"]; ok {
			if _, conflict := node["strategies"]; conflict {
				return nil, errors.New("strategy-list conflicts with strategies")
			}
			if strings.TrimSpace(text(value)) == "" {
				return nil, errors.New("invalid strategy-list")
			}
			node["strategies"] = []any{"builtin:" + strings.TrimSpace(text(value))}
			delete(node, "strategy-list")
		}
		if value, ok := asObject(node["strategy-test"]); ok {
			if err = move(value, "resolver", "dns-resolver"); err != nil {
				return nil, err
			}
			if err = move(value, "concurrency", "request-concurrency"); err != nil {
				return nil, err
			}
		}
		selection := object(node["strategy-selection"])
		if legacy, ok := asObject(node["selection"]); ok {
			if _, conflict := node["strategy-selection"]; conflict {
				return nil, errors.New("selection conflicts with strategy-selection")
			}
			for old, new := range map[string]string{"concurrency": "strategy-concurrency", "foreground-timeout": "startup-timeout", "background": "continue-in-background"} {
				if err = move(legacy, old, new); err != nil {
					return nil, err
				}
			}
			selection = legacy
			delete(node, "selection")
		}
		if value, ok := node["fallback-args"]; ok {
			if _, conflict := selection["fallback-strategy"]; conflict {
				return nil, errors.New("fallback-args conflicts with fallback-strategy")
			}
			selection["fallback-strategy"] = value
			delete(node, "fallback-args")
		}
		if cache, ok := asObject(node["cache"]); ok {
			if _, conflict := selection["cache"]; conflict {
				return nil, errors.New("legacy cache conflicts with canonical cache")
			}
			if retry, ok := cache["retry-after"]; ok {
				if _, conflict := selection["retry-after"]; conflict {
					return nil, errors.New("conflicting retry-after")
				}
				selection["retry-after"] = retry
				delete(cache, "retry-after")
			}
			selection["cache"] = cache
			delete(node, "cache")
		}
		if len(selection) > 0 {
			node["strategy-selection"] = selection
		}
	}
	if kind == "olcrtc" {
		for section, aliases := range map[string]map[string]string{
			"auth": {"provider": "provider", "token": "provider-token"}, "room": {"id": "room", "channel": "room-channel"}, "crypto": {"key": "encryption-key"}, "net": {"transport": "transport", "dns": "dns-server"}, "engine": {"name": "engine", "url": "engine-url", "token": "engine-token"},
		} {
			value, ok := node[section]
			if !ok || value == nil {
				continue
			}
			fields, ok := asObject(value)
			if !ok {
				if section == "room" || section == "engine" {
					continue
				}
				return nil, errors.New("legacy transport section must be a map")
			}
			delete(node, section)
			for key, value := range fields {
				target, ok := aliases[key]
				if !ok {
					return nil, errors.New("unsupported legacy olcrtc field")
				}
				if _, conflict := node[target]; conflict {
					return nil, errors.New("legacy olcrtc section conflicts with canonical field")
				}
				node[target] = value
			}
		}
		expected := map[string]string{"videochannel": "video", "vp8channel": "vp8", "seichannel": "sei"}[text(node["transport"])]
		for section, aliases := range map[string]map[string]string{
			"video": {"width": "width", "height": "height", "fps": "fps", "bitrate": "bitrate", "qr-size": "fragment-size", "qr-recovery": "qr-recovery", "codec": "codec", "tile-module": "tile-module", "tile-rs": "tile-rs"},
			"vp8":   {"fps": "fps", "batch-size": "batch-size"}, "sei": {"fps": "fps", "batch-size": "batch-size", "fragment-size": "fragment-size", "ack-timeout-ms": "ack-timeout"},
		} {
			value, ok := node[section]
			if !ok {
				continue
			}
			if section != expected {
				return nil, errors.New("legacy olcrtc section does not match transport")
			}
			if _, conflict := node["transport-options"]; conflict {
				return nil, errors.New("legacy section conflicts with transport-options")
			}
			fields, ok := asObject(value)
			if !ok {
				return nil, errors.New("legacy transport options must be a map")
			}
			options := Object{}
			for key, value := range fields {
				target, ok := aliases[key]
				if !ok {
					return nil, errors.New("unsupported legacy olcrtc option")
				}
				if section == "sei" && key == "ack-timeout-ms" {
					value = fmt.Sprint(value) + "ms"
				}
				options[target] = value
			}
			node["transport-options"] = options
			delete(node, section)
		}
		for section, keys := range map[string][]string{"liveness": {"interval", "timeout"}, "lifecycle": {"max-session-duration"}, "traffic": {"min-delay", "max-delay"}} {
			for _, key := range keys {
				fields := object(node[section])
				if value, ok := fields[key]; ok && matchesType(value, "integer") {
					fields[key] = fmt.Sprint(value) + "s"
				}
			}
		}
	}
	return node, nil
}
