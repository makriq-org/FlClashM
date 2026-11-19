package authoring

import "testing"

func chainRow(values map[string]any) Object {
	out := Object{}
	for key, value := range values {
		out[key] = Value(value)
	}
	return out
}

func chainCollections(extra func(Collections)) (Collections, map[string]Object) {
	c := Empty()
	c["customProxies"] = []Object{
		chainRow(map[string]any{"id": 1, "definition": map[string]any{"name": "Entry", "type": "socks5", "server": "entry.test", "port": 1080}}),
		chainRow(map[string]any{"id": 2, "definition": map[string]any{"name": "Exit", "type": "socks5", "server": "exit.test", "port": 1080}}),
	}
	c["proxyChains"] = []Object{chainRow(map[string]any{"id": 3, "profileId": "p", "name": "Two", "enabled": true, "hops": []string{"Entry", "Exit"}})}
	if extra != nil {
		extra(c)
	}
	return c, map[string]Object{"p": chainRow(map[string]any{"type": "custom"})}
}

func TestValidateProxyChains(t *testing.T) {
	c, profiles := chainCollections(func(c Collections) {
		c["rules"] = []Object{chainRow(map[string]any{"id": 4, "profileId": "p", "ruleAction": "MATCH", "ruleTarget": "Two"})}
	})
	if err := Validate(c, profiles); err != nil {
		t.Fatalf("valid chain rejected: %v", err)
	}
	// Standard profiles do not know their subscription outbounds, so any hop
	// name is accepted here and resolved by the compiler.
	c, profiles = chainCollections(nil)
	profiles["p"] = chainRow(map[string]any{"type": "standard"})
	c["proxyChains"][0]["hops"] = Value([]string{"Some proxy", "Some group"})
	if err := Validate(c, profiles); err != nil {
		t.Fatalf("standard chain rejected: %v", err)
	}
}

func TestValidateProxyChainRejectsInvalidDeclarations(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(Collections)
	}{
		{"one hop", func(c Collections) { c["proxyChains"][0]["hops"] = Value([]string{"Entry"}) }},
		{"four hops", func(c Collections) { c["proxyChains"][0]["hops"] = Value([]string{"Entry", "Exit", "Entry", "Exit"}) }},
		{"repeated hop", func(c Collections) { c["proxyChains"][0]["hops"] = Value([]string{"Entry", "Entry"}) }},
		{"missing hop", func(c Collections) { c["proxyChains"][0]["hops"] = Value([]string{"Entry", "Ghost"}) }},
		{"reserved hop", func(c Collections) { c["proxyChains"][0]["hops"] = Value([]string{"Entry", "DIRECT"}) }},
		{"duplicate name", func(c Collections) {
			c["proxyChains"] = append(c["proxyChains"], chainRow(map[string]any{"id": 5, "profileId": "p", "name": "Two", "hops": []string{"Entry", "Exit"}}))
		}},
		{"proxy name collision", func(c Collections) { c["proxyChains"][0]["name"] = Value("Entry") }},
		{"chain cycle", func(c Collections) {
			c["proxyChains"] = append(c["proxyChains"], chainRow(map[string]any{"id": 5, "profileId": "p", "name": "Next", "hops": []string{"Entry", "Two"}}))
		}},
		{"non boolean enabled", func(c Collections) { c["proxyChains"][0]["enabled"] = Value("yes") }},
		{"missing profile", func(c Collections) { delete(c["proxyChains"][0], "profileId") }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			c, profiles := chainCollections(test.mutate)
			if err := Validate(c, profiles); err == nil {
				t.Fatal("invalid chain was accepted")
			}
		})
	}
}
