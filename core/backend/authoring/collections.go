// Package authoring describes portable editor declarations. It has no engine,
// SQL, UI, or runtime dependencies. Profile references are always strings;
// declaration IDs retain JSON integers verbatim (including 64-bit snowflakes).
package authoring

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
)

type Object map[string]json.RawMessage
type Collections map[string][]Object
type Snapshot struct {
	Profiles    []Object    `json:"profiles"`
	Revision    uint64      `json:"revision"`
	Collections Collections `json:"collections"`
}

var Names = []string{"scripts", "rules", "disabledRules", "proxyGroups", "clashProviders", "customProxies", "proxyDialers", "iconRecords", "iconSets"}

func Empty() Collections {
	out := Collections{}
	for _, key := range Names {
		out[key] = []Object{}
	}
	return out
}
func Normalize(in Collections) Collections {
	out := Empty()
	for key, rows := range in {
		if rows != nil {
			out[key] = rows
		}
	}
	return out
}
func String(o Object, key string) string { var s string; _ = json.Unmarshal(o[key], &s); return s }
func ID(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var n json.Number
	if json.Unmarshal(raw, &n) == nil {
		if _, e := n.Int64(); e == nil {
			return n.String()
		}
	}
	return ""
}
func Value(v any) json.RawMessage { raw, _ := json.Marshal(v); return raw }
func Decode(o Object) map[string]any {
	raw, _ := json.Marshal(o)
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var result map[string]any
	_ = dec.Decode(&result)
	return result
}
func Ordered(rows []Object) []Object {
	out := append([]Object(nil), rows...)
	sort.SliceStable(out, func(i, j int) bool {
		a, b := String(out[i], "order"), String(out[j], "order")
		if a == b {
			return false
		}
		if a == "" {
			return false
		}
		if b == "" {
			return true
		}
		return a < b
	})
	return out
}
func Key(collection string, o Object) string {
	switch collection {
	case "disabledRules":
		return String(o, "profileId") + "\x00" + ID(o["ruleId"])
	case "proxyDialers":
		return String(o, "profileId") + "\x00" + ID(o["proxyId"])
	case "iconRecords":
		return String(o, "url")
	default:
		return ID(o["id"])
	}
}
func Scoped(rows []Object, profileID string) []Object {
	out := []Object{}
	for _, row := range Ordered(rows) {
		if String(row, "profileId") == profileID {
			out = append(out, row)
		}
	}
	return out
}

// PruneProfile mirrors upstream's foreign-key cascades and removes disabled
// references to rules belonging to the deleted profile in the same transaction.
func PruneProfile(c Collections, profileID string) {
	if c == nil {
		return
	}
	removedRules := map[string]bool{}
	for _, row := range c["rules"] {
		if String(row, "profileId") == profileID {
			removedRules[ID(row["id"])] = true
		}
	}
	for _, key := range []string{"rules", "disabledRules", "proxyGroups", "proxyDialers"} {
		out := []Object{}
		for _, row := range c[key] {
			if String(row, "profileId") == profileID || key == "disabledRules" && removedRules[ID(row["ruleId"])] {
				continue
			}
			out = append(out, row)
		}
		c[key] = out
	}
}
func Merge(previous, incoming Collections) Collections {
	out := Normalize(previous)
	for key, rows := range incoming {
		positions := map[string]int{}
		for i, row := range out[key] {
			positions[Key(key, row)] = i
		}
		for _, row := range rows {
			if i, exists := positions[Key(key, row)]; exists {
				out[key][i] = row
			} else {
				positions[Key(key, row)] = len(out[key])
				out[key] = append(out[key], row)
			}
		}
	}
	return out
}

var Builtins = map[string]bool{"DIRECT": true, "REJECT": true, "REJECT-DROP": true, "PASS": true, "COMPATIBLE": true}

func validName(name string) bool {
	return strings.TrimSpace(name) != "" && !strings.ContainsAny(name, "\x00\r\n") && len(name) <= 1024
}

// Validate checks editor relationships without loading mihomo. Unsupported
// protocol options remain lossless and are checked by the isolated validator
// when the backend compiles an immutable plan.
func Validate(c Collections, profiles map[string]Object) error {
	known := map[string]bool{}
	for _, name := range Names {
		known[name] = true
	}
	ids := map[string]map[string]Object{}
	for key, rows := range c {
		if !known[key] {
			return fmt.Errorf("unknown authoring collection %s", key)
		}
		ids[key] = map[string]Object{}
		for _, row := range rows {
			if row == nil {
				return errors.New("authoring declaration must be an object")
			}
			id := Key(key, row)
			if id == "" || strings.HasPrefix(id, "\x00") || strings.HasSuffix(id, "\x00") {
				return fmt.Errorf("%s declaration requires an id", key)
			}
			if _, exists := ids[key][id]; exists {
				return fmt.Errorf("duplicate %s id", key)
			}
			ids[key][id] = row
			if raw, exists := row["profileId"]; exists && string(raw) != "null" {
				var pid string
				if json.Unmarshal(raw, &pid) != nil || pid == "" || profiles[pid] == nil {
					return fmt.Errorf("%s profileId must reference an existing string id", key)
				}
			} else if key == "proxyGroups" || key == "disabledRules" || key == "proxyDialers" {
				return fmt.Errorf("%s requires profileId", key)
			}
			for field, raw := range row {
				if !json.Valid(raw) {
					return fmt.Errorf("invalid %s.%s JSON", key, field)
				}
			}
		}
	}
	proxies := map[string]bool{}
	proxyIDs := map[string]string{}
	for _, row := range c["customProxies"] {
		var def Object
		if json.Unmarshal(row["definition"], &def) != nil || def == nil {
			return errors.New("custom proxy definition is required")
		}
		name := String(def, "name")
		if !validName(name) || Builtins[name] || name == "GLOBAL" || proxies[name] {
			return errors.New("custom proxy name is empty, reserved or duplicated")
		}
		if String(def, "type") == "" {
			return errors.New("custom proxy type is required")
		}
		proxies[name] = true
		proxyIDs[ID(row["id"])] = name
	}
	providers := map[string]bool{}
	ruleProviders := map[string]bool{}
	for _, profile := range profiles {
		if String(profile, "type") != "custom" {
			label := String(profile, "label")
			if label != "" {
				providers[label] = true
			}
		}
	}
	for _, key := range []string{"scripts", "clashProviders", "iconSets"} {
		seen := map[string]bool{}
		for _, row := range c[key] {
			field := "label"
			if key == "iconSets" {
				field = "name"
			}
			name := String(row, field)
			if !validName(name) || seen[name] {
				return fmt.Errorf("%s name is empty or duplicated", key)
			}
			seen[name] = true
			if key == "clashProviders" {
				ruleProviders[name] = true
			}
		}
	}
	groups := map[string]map[string]Object{}
	for _, row := range c["proxyGroups"] {
		pid, name := String(row, "profileId"), String(row, "name")
		if String(profiles[pid], "type") != "custom" {
			return errors.New("proxy groups require a custom profile")
		}
		if groups[pid] == nil {
			groups[pid] = map[string]Object{}
		}
		if !validName(name) || Builtins[name] || name == "GLOBAL" || proxies[name] || groups[pid][name] != nil {
			return errors.New("group name is empty, reserved or duplicated")
		}
		switch String(row, "type") {
		case "select", "url-test", "fallback", "load-balance", "relay":
		default:
			return errors.New("unsupported proxy group type")
		}
		groups[pid][name] = row
	}
	validTarget := func(pid, name string) bool {
		return Builtins[name] || name == "GLOBAL" || proxies[name] || groups[pid][name] != nil
	}
	edges := map[string]map[string][]string{}
	for pid, named := range groups {
		edges[pid] = map[string][]string{}
		for name, row := range named {
			var members, use []string
			if raw := row["proxies"]; len(raw) > 0 && string(raw) != "null" && json.Unmarshal(raw, &members) != nil {
				return errors.New("group proxies must contain names")
			}
			if raw := row["use"]; len(raw) > 0 && string(raw) != "null" && json.Unmarshal(raw, &use) != nil {
				return errors.New("group use must contain provider names")
			}
			for _, member := range members {
				if !validTarget(pid, member) {
					return fmt.Errorf("group %s references missing proxy %s", name, member)
				}
				edges[pid][name] = append(edges[pid][name], member)
			}
			for _, provider := range use {
				if !providers[provider] {
					return fmt.Errorf("group %s references missing provider %s", name, provider)
				}
			}
			for _, key := range []string{"default-selected", "empty-fallback"} {
				if target := String(row, key); target != "" && !validTarget(pid, target) {
					return fmt.Errorf("invalid group %s", key)
				}
			}
		}
	}
	for _, row := range c["proxyDialers"] {
		pid := String(row, "profileId")
		proxy := proxyIDs[ID(row["proxyId"])]
		target := String(row, "target")
		if proxy == "" || !validTarget(pid, target) {
			return errors.New("dialer references missing proxy or target")
		}
		if edges[pid] == nil {
			edges[pid] = map[string][]string{}
		}
		edges[pid][proxy] = append(edges[pid][proxy], target)
	}
	for _, graph := range edges {
		visiting, done := map[string]bool{}, map[string]bool{}
		var walk func(string) error
		walk = func(name string) error {
			if visiting[name] {
				return errors.New("cyclic proxy group or dialer chain")
			}
			if done[name] {
				return nil
			}
			visiting[name] = true
			for _, child := range graph[name] {
				if err := walk(child); err != nil {
					return err
				}
			}
			delete(visiting, name)
			done[name] = true
			return nil
		}
		for name := range graph {
			if err := walk(name); err != nil {
				return err
			}
		}
	}
	for _, row := range c["disabledRules"] {
		rule := ids["rules"][ID(row["ruleId"])]
		if rule == nil || String(rule, "profileId") != "" && String(rule, "profileId") != String(row, "profileId") {
			return errors.New("disabled rule references missing or foreign rule")
		}
	}
	for _, row := range c["rules"] {
		if _, err := RuleLine(row); err != nil {
			return err
		}
		pid := String(row, "profileId")
		if pid != "" && String(profiles[pid], "type") == "custom" {
			if target := String(row, "ruleTarget"); target != "" && !validTarget(pid, target) {
				return fmt.Errorf("rule references missing target %s", target)
			}
			if provider := String(row, "ruleProvider"); provider != "" && !ruleProviders[provider] {
				return fmt.Errorf("rule references missing rule provider %s", provider)
			}
		}
	}
	return nil
}
