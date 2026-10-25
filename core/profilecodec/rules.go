// Package profilecodec contains pure import/export operations shared by the
// application backend and the engine bridge. It owns no files or runtime state.
package profilecodec

import (
	"bytes"
	"errors"
	"github.com/metacubex/mihomo/common/yaml"
	cp "github.com/metacubex/mihomo/constant/provider"
	rp "github.com/metacubex/mihomo/rules/provider"
	"io"
	"net/netip"
	"slices"
	"strings"
)

type RuleSetInfo struct {
	Behavior string `json:"behavior"`
	Format   string `json:"format"`
}

var (
	errRuleSetEmpty   = errors.New("rule set has no usable entries")
	errRuleSetMixed   = errors.New("rule set mixes domains and IP ranges")
	errRuleSetInvalid = errors.New("rule set is not a readable mrs file")
)
var zstdMagic = []byte{0x28, 0xB5, 0x2F, 0xFD}

func CompileRules(buf []byte, allowEmpty bool) (*RuleSetInfo, []byte, error) {
	if bytes.HasPrefix(buf, zstdMagic) {
		for _, behavior := range []cp.RuleBehavior{cp.Domain, cp.IPCIDR} {
			if rp.ConvertToMrs(buf, behavior, cp.MrsRule, io.Discard) == nil {
				return ruleSetInfo(cp.MrsRule, behavior), nil, nil
			}
		}
		return nil, nil, errRuleSetInvalid
	}
	format, entries := ruleSetEntries(buf)
	if len(entries) == 0 && allowEmpty {
		return ruleSetInfo(format, cp.Classical), nil, nil
	}
	behavior, keys, err := classifyRuleSet(entries)
	if err != nil {
		return nil, nil, err
	}
	info := ruleSetInfo(format, behavior)
	if behavior == cp.Classical {
		return info, nil, nil
	}
	var mrs bytes.Buffer
	// With an in-memory writer the only failure left is that no key parsed.
	if err := rp.ConvertToMrs([]byte(strings.Join(keys, "\n")), behavior, cp.TextRule, &mrs); err != nil {
		return nil, nil, errRuleSetEmpty
	}
	return info, mrs.Bytes(), nil
}

func ruleSetInfo(format cp.RuleFormat, behavior cp.RuleBehavior) *RuleSetInfo {
	formats := map[cp.RuleFormat]string{cp.YamlRule: "yaml", cp.TextRule: "text", cp.MrsRule: "mrs"}
	return &RuleSetInfo{Behavior: strings.ToLower(behavior.String()), Format: formats[format]}
}

func ruleSetEntries(buf []byte) (cp.RuleFormat, []string) {
	var schema struct {
		Payload *[]string `yaml:"payload"`
		Rules   *[]string `yaml:"rules"`
	}
	if yaml.Unmarshal(buf, &schema) == nil && (schema.Payload != nil || schema.Rules != nil) {
		var entries []string
		for _, list := range []*[]string{schema.Payload, schema.Rules} {
			if list == nil {
				continue
			}
			for _, entry := range *list {
				if entry = strings.TrimSpace(entry); entry != "" {
					entries = append(entries, entry)
				}
			}
		}
		return cp.YamlRule, entries
	}
	var entries []string
	for _, line := range strings.Split(string(buf), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || line[0] == '#' || strings.HasPrefix(line, "//") {
			continue
		}
		entries = append(entries, line)
	}
	return cp.TextRule, entries
}

func classifyRuleSet(entries []string) (cp.RuleBehavior, []string, error) {
	if len(entries) == 0 {
		return cp.Classical, nil, errRuleSetEmpty
	}
	if slices.ContainsFunc(entries, func(entry string) bool { return strings.Contains(entry, ",") }) {
		behavior, keys := classifyClassical(entries)
		return behavior, keys, nil
	}
	cidrs := make([]string, 0, len(entries))
	for _, entry := range entries {
		if cidr, ok := parseCIDR(entry); ok {
			cidrs = append(cidrs, cidr)
		}
	}
	switch len(cidrs) {
	case 0:
		return cp.Domain, entries, nil
	case len(entries):
		return cp.IPCIDR, cidrs, nil
	}
	return cp.Classical, nil, errRuleSetMixed
}

func classifyClassical(entries []string) (cp.RuleBehavior, []string) {
	domains := make([]string, 0, len(entries))
	cidrs := make([]string, 0, len(entries))
	for _, entry := range entries {
		ruleType, value, ok := strings.Cut(entry, ",")
		if !ok || strings.Contains(value, ",") {
			return cp.Classical, nil
		}
		value = strings.TrimSpace(value)
		switch strings.ToUpper(strings.TrimSpace(ruleType)) {
		case "DOMAIN":
			if !plainDomain(value) {
				return cp.Classical, nil
			}
			domains = append(domains, value)
		case "DOMAIN-SUFFIX":
			if !plainDomain(value) {
				return cp.Classical, nil
			}
			domains = append(domains, "+."+value)
		case "IP-CIDR", "IP-CIDR6":
			if _, err := netip.ParsePrefix(value); err != nil {
				return cp.Classical, nil
			}
			cidrs = append(cidrs, value)
		default:
			return cp.Classical, nil
		}
	}
	switch {
	case len(cidrs) == 0:
		return cp.Domain, domains
	case len(domains) == 0:
		return cp.IPCIDR, cidrs
	}
	return cp.Classical, nil
}

// A domain set reads a leading dot, "+" and "*" as wildcards.
func plainDomain(value string) bool {
	return value != "" && value[0] != '.' && !strings.ContainsAny(value, "+*/")
}

func parseCIDR(entry string) (string, bool) {
	if _, err := netip.ParsePrefix(entry); err == nil {
		return entry, true
	}
	if addr, err := netip.ParseAddr(entry); err == nil {
		addr = addr.WithZone("")
		return netip.PrefixFrom(addr, addr.BitLen()).String(), true
	}
	return "", false
}
