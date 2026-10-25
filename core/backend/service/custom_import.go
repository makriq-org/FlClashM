package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync/atomic"
	"time"

	"core/backend/authoring"
	"core/backend/compile"
	"core/backend/profiles"
)

func declarationValue(v any) authoring.Object {
	raw, _ := json.Marshal(v)
	var out authoring.Object
	_ = json.Unmarshal(raw, &out)
	return out
}
func mapValue(v any) compile.Object {
	switch x := v.(type) {
	case compile.Object:
		return x
	case map[string]any:
		return compile.Object(x)
	}
	return compile.Object{}
}
func listValue(v any) []any          { x, _ := v.([]any); return x }
func textValue(v any) string         { x, _ := v.(string); return x }
func copyValue(v any) compile.Object { return mapValue(authoring.Decode(declarationValue(v))) }
func freeName(name string, taken map[string]bool) string {
	if strings.TrimSpace(name) == "" {
		name = "Imported"
	}
	candidate := name
	for i := 1; taken[candidate]; i++ {
		candidate = fmt.Sprintf("%s(%d)", name, i)
	}
	taken[candidate] = true
	return candidate
}

var declarationSequence atomic.Int64

func newDeclarationID() int64 {
	for {
		previous := declarationSequence.Load()
		next := time.Now().UnixNano()
		if next <= previous {
			next = previous + 1
		}
		if declarationSequence.CompareAndSwap(previous, next) {
			return next
		}
	}
}
func proxyComparable(value compile.Object) string {
	value = copyValue(value)
	delete(value, "name")
	delete(value, "dialer-proxy")
	var normalize func(any) any
	normalize = func(v any) any {
		switch x := v.(type) {
		case json.Number:
			return x.String()
		case float64:
			return fmt.Sprint(x)
		case int64:
			return fmt.Sprint(x)
		case int:
			return fmt.Sprint(x)
		case compile.Object:
			out := compile.Object{}
			for k, v := range x {
				out[k] = normalize(v)
			}
			return out
		case map[string]any:
			return normalize(compile.Object(x))
		case []any:
			out := make([]any, len(x))
			for i, v := range x {
				out[i] = normalize(v)
			}
			return out
		}
		return v
	}
	raw, _ := json.Marshal(normalize(value))
	return string(raw)
}

// importAuthoring imports a config or share links as a single catalog commit.
// Named file providers can be supplied only as blob tokens; local paths in the
// imported YAML are never opened. Existing declarations keep their identities.
func (a *App) importAuthoring(ctx context.Context, params json.RawMessage) (Receipt, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	var p struct {
		sourceParams
		ProfileID        string            `json:"profileId"`
		Metadata         profiles.Object   `json:"metadata"`
		ExpectedRevision *uint64           `json:"expectedRevision"`
		Select           bool              `json:"select"`
		Replace          bool              `json:"replace"`
		Links            bool              `json:"links"`
		ProviderSources  map[string]string `json:"providerSources"`
	}
	if err := decodeParams(params, &p); err != nil {
		return Receipt{}, err
	}
	if p.ExpectedRevision == nil {
		return Receipt{}, errors.New("expectedRevision is required")
	}
	snapshot := a.profiles.Snapshot()
	if snapshot.Revision != *p.ExpectedRevision {
		return Receipt{}, profiles.ErrConflict
	}
	source, err := a.readSource(ctx, p.sourceParams)
	if err != nil {
		return Receipt{}, err
	}
	config := compile.Object{}
	if p.Links {
		var proxies []compile.Object
		proxies, err = a.compiler.ParseLinks(ctx, source)
		if err != nil {
			return Receipt{}, err
		}
		values := []any{}
		names := []any{}
		for _, proxy := range proxies {
			values = append(values, proxy)
			names = append(names, proxy["name"])
		}
		config = compile.Object{"proxies": values, "proxy-groups": []any{compile.Object{"name": "Proxy", "type": "select", "proxies": names}}, "rules": []any{"MATCH,Proxy"}}
	} else {
		config, err = compile.ParseProfile(source)
		if err != nil {
			return Receipt{}, err
		}
	}
	recognized := false
	for _, key := range []string{"proxies", "proxy-groups", "rules", "proxy-providers", "rule-providers", "dns", "ntp", "sniffer"} {
		_, exists := config[key]
		recognized = recognized || exists
	}
	if !recognized {
		return Receipt{}, errors.New("source contains no custom profile sections")
	}
	collections := authoring.Normalize(snapshot.Authoring)
	// Clone because snapshots must never be edited through nested shared maps.
	raw, _ := json.Marshal(collections)
	_ = json.Unmarshal(raw, &collections)
	id := p.ProfileID
	if id == "" {
		id = newID("profile")
	}
	metadata := profiles.Object{}
	exists := false
	for _, record := range snapshot.Profiles {
		if string(record.Metadata["id"]) == string(jsonValue(id)) {
			metadata = record.Metadata
			exists = true
			break
		}
	}
	for key, value := range p.Metadata {
		if key == "id" && string(value) != string(jsonValue(id)) {
			return Receipt{}, errors.New("profile id is immutable")
		}
		metadata[key] = value
	}
	metadata["id"] = jsonValue(id)
	metadata["type"] = jsonValue("custom")
	metadata["autoUpdate"] = jsonValue(false)
	if _, ok := metadata["label"]; !ok {
		metadata["label"] = jsonValue("Imported")
	}
	defaultProfileMetadata(metadata)
	if p.Replace && exists {
		authoring.PruneProfile(collections, id)
	}
	records := []profiles.Record{}
	profileLabels := map[string]bool{}
	providerByURL := map[string]string{}
	ruleLabels := map[string]bool{}
	ruleByURL := map[string]string{}
	for _, record := range snapshot.Profiles {
		label := authoring.String(authoring.Object(record.Metadata), "label")
		if label == "" {
			label = authoring.String(authoring.Object(record.Metadata), "id")
		}
		profileLabels[label] = true
		if authoring.String(authoring.Object(record.Metadata), "type") != "custom" {
			address := authoring.String(authoring.Object(record.Metadata), "url")
			if address != "" {
				providerByURL[address] = label
			}
		}
	}
	for _, row := range collections["clashProviders"] {
		label := authoring.String(row, "label")
		ruleLabels[label] = true
		if address := authoring.String(row, "url"); address != "" {
			ruleByURL[address] = label
		}
	}
	if exists {
		for _, record := range snapshot.Profiles {
			if authoring.String(authoring.Object(record.Metadata), "id") == id {
				label := authoring.String(authoring.Object(record.Metadata), "label")
				if label == "" {
					label = id
				}
				delete(profileLabels, label)
			}
		}
	}
	metadata["label"] = jsonValue(freeName(authoring.String(authoring.Object(metadata), "label"), profileLabels))
	// New provider definitions are data, never arbitrary file capabilities.
	providerNames, ruleNames := map[string]string{}, map[string]string{}
	providerOptions := compile.Object{}
	for _, section := range []string{"proxy-providers", "rule-providers"} {
		values := mapValue(config[section])
		names := sortedKeys(values)
		for _, name := range names {
			definition := mapValue(values[name])
			address := textValue(definition["url"])
			remote := definition["type"] == "http" && address != ""
			byURL, taken, mapping := providerByURL, profileLabels, providerNames
			if section == "rule-providers" {
				byURL, taken, mapping = ruleByURL, ruleLabels, ruleNames
			}
			label := ""
			if remote {
				label = byURL[address]
			}
			if label != "" {
				mapping[name] = label
				continue
			}
			label = freeName(name, taken)
			mapping[name] = label
			if remote {
				byURL[address] = label
			}
			var data []byte
			if token := p.ProviderSources[name]; token != "" {
				path, err := a.blobPath(token)
				if err != nil {
					return Receipt{}, err
				}
				data, err = readBounded(path, profiles.MaxProfileBytes)
				if err != nil {
					return Receipt{}, err
				}
			} else if remote {
				request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
				if err != nil {
					return Receipt{}, err
				}
				request.Header.Set("User-Agent", a.subscriptions.UserAgent)
				response, err := a.subscriptions.Client.Do(request)
				if err != nil {
					return Receipt{}, err
				}
				if response == nil || response.Body == nil {
					return Receipt{}, errors.New("provider transport returned no body")
				}
				data, err = func() ([]byte, error) {
					defer response.Body.Close()
					if response.StatusCode < 200 || response.StatusCode >= 300 {
						return nil, fmt.Errorf("provider HTTP status %d", response.StatusCode)
					}
					return io.ReadAll(io.LimitReader(response.Body, profiles.MaxProfileBytes+1))
				}()
				if err != nil {
					return Receipt{}, err
				}
			} else if definition["type"] == "inline" {
				payload, ok := definition["payload"].([]any)
				if !ok {
					return Receipt{}, errors.New("inline provider requires payload")
				}
				key := "payload"
				if section == "proxy-providers" {
					key = "proxies"
				}
				data, _ = json.Marshal(compile.Object{key: payload})
			} else {
				return Receipt{}, fmt.Errorf("provider %s requires an explicit blob source", name)
			}
			if len(data) > profiles.MaxProfileBytes {
				return Receipt{}, errors.New("provider exceeds size limit")
			}
			if section == "proxy-providers" {
				decoded, err := a.readSource(ctx, sourceParams{Source: string(data), AgeSecretKey: textValue(definition["age-secret-key"])})
				if err != nil {
					return Receipt{}, err
				}
				if err = a.validateSource(ctx, decoded); err != nil {
					return Receipt{}, err
				}
				pid := newID("provider")
				kind := "file"
				if remote {
					kind = "url"
				}
				m := profiles.Object{"id": jsonValue(pid), "label": jsonValue(label), "type": jsonValue(kind), "url": jsonValue(address), "ageSecretKey": jsonValue(textValue(definition["age-secret-key"]))}
				defaultProfileMetadata(m)
				records = append(records, profiles.Record{Metadata: m, Source: decoded})
			} else {
				info, err := a.compiler.CompileResource(ctx, data)
				if err != nil {
					return Receipt{}, err
				}
				collections["clashProviders"] = append(collections["clashProviders"], authoring.Object{"id": jsonValue(newDeclarationID()), "label": jsonValue(label), "url": jsonValue(address), "contentBase64": jsonValue(base64.StdEncoding.EncodeToString(data)), "behavior": jsonValue(info.Behavior), "format": jsonValue(info.Format)})
			}
		}
		if section == "proxy-providers" {
			for name, value := range values {
				opts := compile.Object{}
				for _, key := range []string{"health-check", "filter", "exclude-filter", "override"} {
					if v := mapValue(value)[key]; v != nil {
						opts[key] = v
					}
				}
				if len(opts) > 0 {
					providerOptions[providerNames[name]] = opts
				}
			}
		}
	}
	taken := map[string]bool{}
	for name := range authoring.Builtins {
		taken[name] = true
	}
	taken["GLOBAL"] = true
	held := map[string]string{}
	proxyIDs := map[string]json.RawMessage{}
	for _, row := range collections["customProxies"] {
		def := mapValue(authoring.Decode(row)["definition"])
		name := textValue(def["name"])
		taken[name] = true
		held[proxyComparable(def)] = name
		proxyIDs[name] = row["id"]
	}
	for _, row := range collections["proxyGroups"] {
		taken[authoring.String(row, "name")] = true
	}
	mapping := map[string]string{}
	importedNames := []string{}
	groups := listValue(config["proxy-groups"])
	for _, value := range listValue(config["proxies"]) {
		def := copyValue(value)
		name := textValue(def["name"])
		if name == "" {
			return Receipt{}, errors.New("imported proxy name is required")
		}
		comparable := proxyComparable(def)
		actual := held[comparable]
		if actual == "" {
			actual = freeName(name, taken)
			def["name"] = actual
			delete(def, "dialer-proxy")
			row := authoring.Object{"id": jsonValue(newDeclarationID()), "definition": jsonValue(def)}
			collections["customProxies"] = append(collections["customProxies"], row)
			held[comparable] = actual
			proxyIDs[actual] = row["id"]
		}
		if mapping[name] == "" {
			mapping[name] = actual
		}
		importedNames = append(importedNames, actual)
	}
	groupNames := []string{}
	for _, value := range groups {
		name := textValue(mapValue(value)["name"])
		actual := freeName(name, taken)
		if mapping[name] == "" {
			mapping[name] = actual
		}
		groupNames = append(groupNames, actual)
	}
	rename := func(name string) string {
		if mapped := mapping[name]; mapped != "" {
			return mapped
		}
		return name
	}
	renameList := func(value any, names map[string]string) []any {
		out := []any{}
		seen := map[string]bool{}
		for _, v := range listValue(value) {
			name := textValue(v)
			if mapped := names[name]; mapped != "" {
				name = mapped
			}
			if !seen[name] {
				out = append(out, name)
				seen[name] = true
			}
		}
		return out
	}
	dialerRows := []authoring.Object{}
	for i, value := range listValue(config["proxies"]) {
		if target := textValue(mapValue(value)["dialer-proxy"]); target != "" {
			dialerRows = append(dialerRows, authoring.Object{"profileId": jsonValue(id), "proxyId": proxyIDs[importedNames[i]], "target": jsonValue(rename(target))})
		}
	}
	collections = authoring.Merge(collections, authoring.Collections{"proxyDialers": dialerRows})
	for i, value := range groups {
		group := copyValue(value)
		group["name"] = groupNames[i]
		group["id"] = newDeclarationID()
		group["profileId"] = id
		group["proxies"] = renameList(group["proxies"], mapping)
		group["use"] = renameList(group["use"], providerNames)
		for _, key := range []string{"default-selected", "empty-fallback"} {
			if v := textValue(group[key]); v != "" {
				group[key] = rename(v)
			}
		}
		positions := compile.Object{}
		for name, pos := range mapValue(group["use-position"]) {
			if mapped := providerNames[name]; mapped != "" {
				name = mapped
			}
			positions[name] = pos
		}
		if len(positions) > 0 {
			group["use-position"] = positions
		}
		collections["proxyGroups"] = append(collections["proxyGroups"], declarationValue(group))
	}
	for _, value := range listValue(config["rules"]) {
		row, err := authoring.ParseRule(textValue(value))
		if err != nil {
			return Receipt{}, err
		}
		row["id"] = jsonValue(newDeclarationID())
		row["profileId"] = jsonValue(id)
		if target := authoring.String(row, "ruleTarget"); target != "" {
			row["ruleTarget"] = jsonValue(rename(target))
		}
		if provider := authoring.String(row, "ruleProvider"); provider != "" && ruleNames[provider] != "" {
			row["ruleProvider"] = jsonValue(ruleNames[provider])
		}
		collections["rules"] = append(collections["rules"], row)
	}
	overrides := compile.Object{"proxy-providers": providerOptions}
	for _, section := range []string{"dns", "ntp", "sniffer"} {
		if value, ok := config[section]; ok {
			overrides[section] = value
			overrides[section+"-override-keys"] = compile.ImportOverrideKeys(section, mapValue(value))
		}
	}
	// Imported references in DNS/NTP follow renamed groups and rule sets too.
	var renameReferences func(any) any
	renameReferences = func(value any) any {
		switch v := value.(type) {
		case string:
			if out := mapping[v]; out != "" {
				return out
			}
			for old, name := range mapping {
				v = strings.ReplaceAll(v, "#"+old, "#"+name)
			}
			for old, name := range ruleNames {
				v = strings.ReplaceAll(v, "rule-set:"+old, "rule-set:"+name)
			}
			return v
		case compile.Object:
			out := compile.Object{}
			for k, entry := range v {
				key := textValue(renameReferences(k))
				out[key] = renameReferences(entry)
			}
			return out
		case map[string]any:
			return renameReferences(compile.Object(v))
		case []any:
			for i, entry := range v {
				v[i] = renameReferences(entry)
			}
			return v
		}
		return value
	}
	overrides = mapValue(renameReferences(overrides))
	metadata["overrides"] = jsonValue(overrides)
	for _, key := range []string{"proxies", "proxy-groups", "proxy-providers", "rule-providers", "rules", "dns", "ntp", "sniffer"} {
		delete(config, key)
	}
	metadata["customConfig"] = jsonValue(config)
	records = append(records, profiles.Record{Metadata: metadata, Source: "{}"})
	selected := ""
	if p.Select {
		selected = id
	}
	if err = a.profiles.ImportAuthoring(ctx, records, collections, snapshot.Revision, selected); err != nil {
		return Receipt{}, err
	}
	return Receipt{ProfileID: id, Revision: snapshot.Revision + 1}, nil
}
func sortedKeys(value compile.Object) []string {
	keys := []string{}
	for key := range value {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
