package compile

import "testing"

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
