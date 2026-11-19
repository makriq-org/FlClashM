package compile

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/dlclark/regexp2/v2"

	"core/backend/authoring"
)

// proxyChain is one authoring declaration: the device connects to the first
// hop, traffic leaves from the last, and every hop after the first dials
// through the one before it.
type proxyChain struct {
	name string
	hops []string
}

var chainGroupTypes = map[string]bool{
	"select":       true,
	"url-test":     true,
	"fallback":     true,
	"load-balance": true,
}

// chainMembershipKeys never carry over from a source group: the chain group
// lists cloned proxies instead.
var chainMembershipKeys = map[string]bool{
	"name": true, "type": true, "proxies": true, "use": true,
	"include-all": true, "include-all-proxies": true, "include-all-providers": true,
	"filter": true, "exclude-filter": true, "exclude-type": true,
	"hidden": true, "default-selected": true,
}

var chainReservedNames = map[string]bool{
	"DIRECT": true, "REJECT": true, "REJECT-DROP": true, "COMPATIBLE": true,
	"PASS": true, "PASS-RULE": true, "GLOBAL": true, "MATCH": true,
}

// unchainedProxyTypes are the mihomo constructors that ignore dialer-proxy.
var unchainedProxyTypes = map[string]bool{
	"direct": true, "dns": true, "reject": true, "rematch": true,
}

func authoredProxyChains(collections authoring.Collections, profileID string) ([]proxyChain, error) {
	chains := []proxyChain{}
	for _, row := range authoring.Scoped(collections["proxyChains"], profileID) {
		var hops []string
		if raw := row["hops"]; len(raw) == 0 || string(raw) == "null" || json.Unmarshal(raw, &hops) != nil {
			return nil, errors.New("proxy chain hops must contain names")
		}
		if len(hops) < 2 || len(hops) > 3 {
			return nil, errors.New("proxy chain requires two or three hops")
		}
		enabled := true
		if raw, exists := row["enabled"]; exists && json.Unmarshal(raw, &enabled) != nil {
			return nil, errors.New("proxy chain enabled must be a boolean")
		}
		if !enabled {
			continue
		}
		name := authoring.String(row, "name")
		if strings.TrimSpace(name) == "" {
			return nil, errors.New("proxy chain name is required")
		}
		chains = append(chains, proxyChain{name: name, hops: hops})
	}
	return chains, nil
}

// applyAuthoredProxyChains adds one group per chain whose members are clones of
// the exit hop that dial through the hops before it (mihomo's dialer-proxy).
// Invalid chains fail the whole compile, so an applied runtime plan is never
// replaced by a partial or REJECT-substituted path.
func applyAuthoredProxyChains(config Object, chains []proxyChain) error {
	if len(chains) == 0 {
		return nil
	}
	builder := &chainBuilder{
		proxies:     []any{},
		groups:      list(config["proxy-groups"]),
		proxyByName: map[string]Object{},
		groupByName: map[string]Object{},
		providers:   map[string]bool{},
		taken:       map[string]bool{},
		chainNames:  map[string]bool{},
		leaves:      map[string][]string{},
	}
	originalProxies := []string{}
	for _, proxy := range list(config["proxies"]) {
		values := copyObject(object(proxy))
		name := text(values["name"])
		if name != "" {
			builder.proxies = append(builder.proxies, values)
			builder.proxyByName[name] = values
			originalProxies = append(originalProxies, name)
		}
	}
	originalGroups := []string{}
	hasGlobal := false
	for _, group := range builder.groups {
		values := object(group)
		if name := text(values["name"]); name != "" {
			builder.groupByName[name] = values
			originalGroups = append(originalGroups, name)
			hasGlobal = hasGlobal || name == "GLOBAL"
		}
	}
	for name := range object(config["proxy-providers"]) {
		builder.providers[name] = true
	}
	// Generated names must not shadow an existing outbound: mihomo rejects the
	// whole config on a duplicate proxy or group name.
	for name := range builder.proxyByName {
		builder.taken[name] = true
	}
	for name := range builder.groupByName {
		builder.taken[name] = true
	}
	for name := range builder.providers {
		builder.taken[name] = true
	}
	for name := range chainReservedNames {
		builder.taken[name] = true
	}
	for _, chain := range chains {
		if builder.reserved(chain.name) {
			return fmt.Errorf("proxy chain %s collides with an existing outbound", chain.name)
		}
		builder.chainNames[chain.name] = true
		builder.taken[chain.name] = true
	}
	pinned, err := builder.pin()
	if err != nil {
		return err
	}
	builder.groups = pinned
	builder.groupByName = map[string]Object{}
	for _, group := range pinned {
		values := object(group)
		if name := text(values["name"]); name != "" {
			builder.groupByName[name] = values
		}
	}
	for _, chain := range chains {
		seen := map[string]bool{}
		for index, hop := range chain.hops {
			if seen[hop] {
				return fmt.Errorf("proxy chain %s repeats hop %s", chain.name, hop)
			}
			seen[hop] = true
			if builder.chainNames[hop] {
				return fmt.Errorf("proxy chain %s references a proxy chain", chain.name)
			}
			if index == 0 {
				if err := builder.validateEntry(hop); err != nil {
					return fmt.Errorf("proxy chain %s: %w", chain.name, err)
				}
				continue
			}
			if err := builder.validateHop(hop); err != nil {
				return fmt.Errorf("proxy chain %s: %w", chain.name, err)
			}
		}
	}
	for _, chain := range chains {
		if err := builder.build(chain); err != nil {
			return err
		}
	}
	// mihomo builds GLOBAL from every configured proxy, so the generated hop
	// clones would appear in Global mode's list. An explicit selector keeps the
	// subscription's outbounds and the chain groups, but not the internals.
	if !hasGlobal {
		builder.groups = append(builder.groups, builder.globalGroup(originalProxies, originalGroups, chains))
	}
	config["proxies"] = builder.proxies
	config["proxy-groups"] = builder.groups
	return nil
}

// globalGroup mirrors the selector mihomo would create: DIRECT and REJECT,
// the profile's proxies, its groups and the chain groups.
func (b *chainBuilder) globalGroup(proxies, groups []string, chains []proxyChain) Object {
	members := []any{"DIRECT", "REJECT"}
	for _, name := range proxies {
		kind := strings.ToLower(text(b.proxyByName[name]["type"]))
		// mihomo leaves PASS out of the global selector.
		if kind == "pass" || kind == "pass-rule" {
			continue
		}
		members = append(members, name)
	}
	for _, name := range groups {
		members = append(members, name)
	}
	for _, chain := range chains {
		members = append(members, chain.name)
	}
	return Object{"name": "GLOBAL", "type": "select", "proxies": members}
}

type chainBuilder struct {
	proxies     []any
	groups      []any
	proxyByName map[string]Object
	groupByName map[string]Object
	providers   map[string]bool
	taken       map[string]bool
	chainNames  map[string]bool
	leaves      map[string][]string
}

func (b *chainBuilder) reserved(name string) bool {
	return name == "" ||
		chainReservedNames[name] ||
		b.proxyByName[name] != nil ||
		b.groupByName[name] != nil ||
		b.providers[name] ||
		b.chainNames[name]
}

func (b *chainBuilder) unique(base string) string {
	name := base
	for attempt := 2; b.taken[name]; attempt++ {
		name = base + " " + strconv.Itoa(attempt)
	}
	b.taken[name] = true
	return name
}

// validateEntry checks the first hop, which is only the target of
// dialer-proxy: a provider-backed group or a node with its own dialer-proxy is
// a valid starting point, because it is never cloned or rewritten.
func (b *chainBuilder) validateEntry(name string) error {
	if chainReservedNames[name] {
		return fmt.Errorf("hop %s is not a chainable proxy or group", name)
	}
	if b.proxyByName[name] == nil && b.groupByName[name] == nil {
		return fmt.Errorf("hop %s is missing", name)
	}
	return nil
}

func (b *chainBuilder) validateHop(name string) error {
	if chainReservedNames[name] {
		return fmt.Errorf("hop %s is not a chainable proxy or group", name)
	}
	leaves, err := b.leavesOf(name)
	if err != nil {
		return err
	}
	for _, leaf := range leaves {
		if err := b.chainableLeaf(leaf); err != nil {
			return err
		}
	}
	return nil
}

func (b *chainBuilder) chainableLeaf(name string) error {
	if chainReservedNames[name] {
		return fmt.Errorf("hop %s is not a chainable proxy or group", name)
	}
	proxy := b.proxyByName[name]
	if proxy == nil {
		return fmt.Errorf("hop %s is not an inline proxy", name)
	}
	if unchainedProxyTypes[strings.ToLower(text(proxy["type"]))] {
		return fmt.Errorf("hop %s has a type that ignores dialer-proxy", name)
	}
	if text(proxy["dialer-proxy"]) != "" {
		return fmt.Errorf("hop %s already uses a dialer-proxy", name)
	}
	return nil
}

func (b *chainBuilder) leavesOf(name string) ([]string, error) {
	if b.proxyByName[name] != nil {
		return []string{name}, nil
	}
	if b.groupByName[name] == nil {
		return nil, fmt.Errorf("hop %s is missing", name)
	}
	return b.groupLeaves(name, map[string]bool{})
}

func (b *chainBuilder) groupLeaves(name string, visiting map[string]bool) ([]string, error) {
	if cached, ok := b.leaves[name]; ok {
		return cached, nil
	}
	if visiting[name] {
		return nil, fmt.Errorf("hop group %s forms a cycle", name)
	}
	visiting[name] = true
	group := b.groupByName[name]
	if len(list(group["use"])) > 0 {
		return nil, fmt.Errorf("hop group %s uses providers", name)
	}
	includeAll := group["include-all"] == true
	if includeAll && len(b.providers) > 0 || group["include-all-providers"] == true {
		return nil, fmt.Errorf("hop group %s uses providers", name)
	}
	members := append([]any(nil), list(group["proxies"])...)
	if includeAll || group["include-all-proxies"] == true {
		if text(group["filter"]) != "" || text(group["exclude-filter"]) != "" || text(group["exclude-type"]) != "" {
			return nil, fmt.Errorf("hop group %s has filters", name)
		}
		members = append(members, b.proxyNames()...)
	}
	found := []string{}
	seen := map[string]bool{}
	for _, member := range members {
		memberName := text(member)
		if memberName == "" {
			continue
		}
		var leaves []string
		if b.proxyByName[memberName] != nil {
			leaves = []string{memberName}
		} else if b.groupByName[memberName] != nil {
			var err error
			leaves, err = b.groupLeaves(memberName, visiting)
			if err != nil {
				return nil, err
			}
		} else {
			return nil, fmt.Errorf("hop group %s references missing member %s", name, memberName)
		}
		for _, leaf := range leaves {
			if !seen[leaf] {
				seen[leaf] = true
				found = append(found, leaf)
			}
		}
	}
	delete(visiting, name)
	if len(found) == 0 {
		return nil, fmt.Errorf("hop group %s has no proxies", name)
	}
	b.leaves[name] = found
	return found, nil
}

func (b *chainBuilder) proxyNames() []any {
	names := make([]string, 0, len(b.proxyByName))
	for name := range b.proxyByName {
		names = append(names, name)
	}
	sort.Strings(names)
	out := make([]any, 0, len(names))
	for _, name := range names {
		out = append(out, name)
	}
	return out
}

func (b *chainBuilder) defaultLeafOf(name string, visiting map[string]bool) string {
	if b.proxyByName[name] != nil {
		return name
	}
	group := b.groupByName[name]
	if group == nil || visiting[name] {
		return ""
	}
	visiting[name] = true
	if pick := text(group["default-selected"]); pick != "" {
		return b.defaultLeafOf(pick, visiting)
	}
	for _, member := range list(group["proxies"]) {
		if leaf := b.defaultLeafOf(text(member), visiting); leaf != "" {
			return leaf
		}
	}
	return ""
}

func (b *chainBuilder) build(chain proxyChain) error {
	through := chain.hops[0]
	for index := 1; index < len(chain.hops); index++ {
		hop := chain.hops[index]
		leaves, err := b.leavesOf(hop)
		if err != nil {
			return err
		}
		isExit := index == len(chain.hops)-1
		cloneOf := map[string]string{}
		clones := make([]any, 0, len(leaves))
		for _, leaf := range leaves {
			base := leaf + " · " + chain.name
			if !isExit {
				base = leaf + " · " + chain.name + " " + strconv.Itoa(index)
			}
			name := b.unique(base)
			clone := copyObject(b.proxyByName[leaf])
			clone["name"] = name
			clone["dialer-proxy"] = through
			b.proxies = append(b.proxies, clone)
			cloneOf[leaf] = name
			clones = append(clones, name)
		}
		source := b.groupByName[hop]
		defaultLeaf := ""
		if source != nil {
			defaultLeaf = b.defaultLeafOf(hop, map[string]bool{})
		}
		if isExit {
			group := chainGroup(chain.name, source, clones, cloneOf[defaultLeaf])
			b.groups = append(b.groups, group)
			continue
		}
		if source == nil {
			// A proxy hop is its own clone; the next exit dials through it.
			through = cloneOf[hop]
			continue
		}
		name := b.unique(chain.name + " · " + strconv.Itoa(index))
		group := chainGroup(name, source, clones, cloneOf[defaultLeaf])
		group["hidden"] = true
		b.groups = append(b.groups, group)
		through = name
	}
	return nil
}

func chainGroup(name string, source Object, clones []any, defaultSelected string) Object {
	group := Object{}
	groupType := "select"
	if source != nil {
		for key, value := range source {
			if chainMembershipKeys[key] {
				continue
			}
			group[key] = value
		}
		if candidate := text(source["type"]); chainGroupTypes[candidate] {
			groupType = candidate
		}
	}
	group["name"] = name
	group["type"] = groupType
	group["proxies"] = clones
	if groupType == "select" && defaultSelected != "" {
		group["default-selected"] = defaultSelected
	}
	return group
}

// pin replaces include-all membership with explicit proxies before clones are
// added, so generated clones are never picked up by the subscription's own
// groups. Exclusions stay applied as mihomo would apply them.
func (b *chainBuilder) pin() ([]any, error) {
	pinned := make([]any, 0, len(b.groups))
	for _, entry := range b.groups {
		group := object(entry)
		includeAll := group["include-all"] == true
		includesProxies := includeAll || group["include-all-proxies"] == true
		if !includesProxies {
			pinned = append(pinned, group)
			continue
		}
		filters, err := chainPatterns(group["filter"])
		if err != nil {
			return nil, fmt.Errorf("group %s filter: %w", text(group["name"]), err)
		}
		excluded, err := chainPatterns(group["exclude-filter"])
		if err != nil {
			return nil, fmt.Errorf("group %s exclude-filter: %w", text(group["name"]), err)
		}
		excludedTypes := map[string]bool{}
		for _, kind := range strings.Split(text(group["exclude-type"]), "|") {
			if kind = strings.TrimSpace(kind); kind != "" {
				excludedTypes[strings.ToLower(kind)] = true
			}
		}
		next := Object{}
		for key, value := range group {
			if key != "include-all" && key != "include-all-proxies" {
				next[key] = value
			}
		}
		members := []any{}
		seen := map[string]bool{}
		add := func(name string) {
			if name == "" || seen[name] || chainExcluded(name, b, excluded, excludedTypes) {
				return
			}
			seen[name] = true
			members = append(members, name)
		}
		for _, member := range list(group["proxies"]) {
			add(text(member))
		}
		for _, name := range b.proxyNames() {
			if len(filters) == 0 || chainMatches(filters, text(name)) {
				add(text(name))
			}
		}
		if includeAll && len(b.providers) > 0 {
			next["include-all-providers"] = true
		}
		if len(members) == 0 && next["include-all-providers"] != true {
			fallback := text(group["empty-fallback"])
			if fallback == "" {
				fallback = "COMPATIBLE"
			}
			members = append(members, fallback)
		}
		next["proxies"] = members
		pinned = append(pinned, next)
	}
	return pinned, nil
}

func chainExcluded(name string, b *chainBuilder, excluded []*regexp2.Regexp, types map[string]bool) bool {
	if b.proxyByName[name] == nil {
		return false
	}
	if chainMatches(excluded, name) {
		return true
	}
	if len(types) == 0 {
		return false
	}
	kind := strings.ToLower(strings.ReplaceAll(text(b.proxyByName[name]["type"]), "-", ""))
	switch kind {
	case "ss":
		kind = "shadowsocks"
	case "ssr":
		kind = "shadowsocksr"
	}
	return types[strings.ToLower(strings.ReplaceAll(kind, "-", ""))]
}

func chainMatches(patterns []*regexp2.Regexp, name string) bool {
	for _, pattern := range patterns {
		// mihomo's regexp2 match errors are not membership decisions either.
		if matched, _ := pattern.MatchString(name); matched {
			return true
		}
	}
	return false
}

// chainPatterns reads mihomo's backtick-separated filter syntax with the same
// regexp2 dialect mihomo uses, so a filter that the engine accepts is never
// called unreadable here. An invalid pattern still fails the chain compile
// instead of silently changing membership.
func chainPatterns(value any) ([]*regexp2.Regexp, error) {
	source := text(value)
	if source == "" {
		return nil, nil
	}
	patterns := []*regexp2.Regexp{}
	for _, pattern := range strings.Split(source, "`") {
		compiled, err := regexp2.Compile(pattern, regexp2.None)
		if err != nil {
			return nil, errors.New("unsupported regular expression")
		}
		patterns = append(patterns, compiled)
	}
	return patterns, nil
}
