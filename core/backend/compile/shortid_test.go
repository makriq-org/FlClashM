package compile

import (
	"strconv"
	"strings"
	"testing"
)

// mihomo reads an unquoted short-id as a number, which turns 0123 into 123 and
// makes the proxy authenticate with the wrong id.
func TestRealityShortIDKeepsItsLiteralText(t *testing.T) {
	config, err := ParseProfile(`
x-reality: &reality {public-key: pk, short-id: 0123}
proxies:
  - {name: direct, type: vless, server: s, port: 443, reality-opts: {public-key: pk, short-id: 0123}}
  - {name: alias, type: vless, server: s, port: 443, reality-opts: *reality}
  - {name: list, type: vless, server: s, port: 443, reality-opts: {public-key: pk, short-id: &ids [0123, 00]}}
  - {name: quoted, type: vless, server: s, port: 443, reality-opts: {public-key: pk, short-id: "0123"}}
  - {name: number, type: vless, server: s, port: 443, port-range: 443}
`)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"direct": "0123",
		"alias":  "0123",
		"list":   []any{"0123", "00"},
		"quoted": "0123",
	}
	for _, entry := range list(config["proxies"]) {
		proxy := object(entry)
		name := text(proxy["name"])
		expected, checked := want[name]
		if !checked {
			continue
		}
		got := object(proxy["reality-opts"])["short-id"]
		if !equalValue(got, expected) {
			t.Errorf("%s short-id = %#v, want %#v", name, got, expected)
		}
	}
	// A number that is not a short-id keeps its numeric type.
	if port, ok := number(object(list(config["proxies"])[4])["port-range"]); !ok || port != 443 {
		t.Errorf("port-range = %#v", object(list(config["proxies"])[4])["port-range"])
	}
}

func equalValue(got, want any) bool {
	switch expected := want.(type) {
	case string:
		value, ok := got.(string)
		return ok && value == expected
	case []any:
		values, ok := got.([]any)
		if !ok || len(values) != len(expected) {
			return false
		}
		for i := range expected {
			if !equalValue(values[i], expected[i]) {
				return false
			}
		}
		return true
	}
	return false
}

// A document well inside the size limit can still name one big anchor from
// thousands of short-id fields, and each list field copies it. The budget has
// to stop that before the copies are made.
func TestRealityShortIDAliasesStayWithinBudget(t *testing.T) {
	var builder strings.Builder
	builder.WriteString("x-ids: &ids [")
	for i := 0; i < 2000; i++ {
		if i > 0 {
			builder.WriteString(", ")
		}
		builder.WriteString("00")
	}
	builder.WriteString("]\nproxies:\n")
	for i := 0; i < 2000; i++ {
		builder.WriteString("  - {name: p")
		builder.WriteString(strconv.Itoa(i))
		builder.WriteString(", type: vless, server: s, port: 443, reality-opts: {public-key: pk, short-id: *ids}}\n")
	}
	_, err := ParseProfile(builder.String())
	if err == nil {
		t.Fatal("an expanding short-id alias was accepted")
	}
	if !strings.Contains(err.Error(), "short-id") {
		t.Fatalf("err = %v", err)
	}
}

// A profile reusing one short-id anchor from a handful of fields stays valid.
func TestRealityShortIDSharedAnchorStillParses(t *testing.T) {
	var builder strings.Builder
	builder.WriteString("x-reality: &reality {public-key: pk, short-id: 0123}\nproxies:\n")
	for i := 0; i < 200; i++ {
		builder.WriteString("  - {name: p")
		builder.WriteString(strconv.Itoa(i))
		builder.WriteString(", type: vless, server: s, port: 443, reality-opts: *reality}\n")
	}
	config, err := ParseProfile(builder.String())
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range list(config["proxies"]) {
		if got := object(object(entry)["reality-opts"])["short-id"]; got != "0123" {
			t.Fatalf("short-id = %#v", got)
		}
	}
}
