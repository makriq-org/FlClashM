package compile

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"core/backend"
	"core/backend/authoring"
)

const chainProfileSource = `proxies:
  - {name: Entry, type: socks5, server: entry.test, port: 1080}
  - {name: Middle, type: socks5, server: middle.test, port: 1080}
  - {name: Exit, type: socks5, server: exit.test, port: 1080}
proxy-groups:
  - {name: Auto, type: url-test, proxies: [Exit], url: 'http://test'}
  - {name: All, type: select, include-all: true, proxies: [Auto]}
rules: ['DOMAIN,keep.test,DIRECT', 'MATCH,All']`

func chainRequest(source string) (Compiler, Input) {
	data := authoring.Empty()
	data["proxyChains"] = []authoring.Object{
		row(Object{"id": 1, "profileId": "p", "name": "Two", "enabled": true, "hops": []any{"Entry", "Exit"}}),
		row(Object{"id": 2, "profileId": "p", "name": "Three", "hops": []any{"Entry", "Auto", "Exit"}}),
		row(Object{"id": 3, "profileId": "p", "name": "GroupExit", "hops": []any{"Entry", "Exit", "Auto"}}),
		row(Object{"id": 4, "profileId": "p", "name": "SelectExit", "hops": []any{"Entry", "Exit", "All"}}),
	}
	c := Compiler{Validate: func(context.Context, Object) error { return nil }}
	return c, Input{Version: 1, Profile: &RawProfile{ID: "p", Text: source, Metadata: Object{"extendType": "standard"}}, Settings: Object{}, Authoring: data}
}

func configEntry(t *testing.T, result Prepared, section, name string) Object {
	t.Helper()
	for _, item := range list(result.Config[section]) {
		value := object(item)
		if text(value["name"]) == name {
			return value
		}
	}
	t.Fatalf("%s %s is missing: %v", section, name, result.Config[section])
	return nil
}

func TestProxyChainsCloneExitThroughHops(t *testing.T) {
	c, request := chainRequest(chainProfileSource)
	result := prepared(t, c, request)

	two := configEntry(t, result, "proxy-groups", "Two")
	if two["type"] != "select" || !reflect.DeepEqual(list(two["proxies"]), []any{"Exit · Two"}) {
		t.Fatalf("two-hop chain group is wrong: %v", two)
	}
	clone := configEntry(t, result, "proxies", "Exit · Two")
	if clone["dialer-proxy"] != "Entry" || clone["server"] != "exit.test" {
		t.Fatalf("exit clone must dial through the entry hop: %v", clone)
	}

	middle := configEntry(t, result, "proxy-groups", "Three · 1")
	if middle["hidden"] != true || middle["type"] != "url-test" || !reflect.DeepEqual(list(middle["proxies"]), []any{"Exit · Three 1"}) {
		t.Fatalf("hidden middle group is wrong: %v", middle)
	}
	if configEntry(t, result, "proxies", "Exit · Three 1")["dialer-proxy"] != "Entry" {
		t.Fatal("middle clone must dial through the entry hop")
	}
	three := configEntry(t, result, "proxy-groups", "Three")
	if three["type"] != "select" || three["default-selected"] != nil {
		t.Fatalf("proxy exit group must stay a plain selector: %v", three)
	}
	if configEntry(t, result, "proxies", "Exit · Three")["dialer-proxy"] != "Three · 1" {
		t.Fatal("exit clone must dial through the hidden middle group")
	}

	// A group exit keeps the source type; only selectors take a default pick.
	groupExit := configEntry(t, result, "proxy-groups", "GroupExit")
	if groupExit["type"] != "url-test" || groupExit["url"] != "http://test" || groupExit["default-selected"] != nil {
		t.Fatalf("group exit must keep the source type: %v", groupExit)
	}
	if configEntry(t, result, "proxies", "Exit · GroupExit")["dialer-proxy"] != "Exit · GroupExit 1" {
		t.Fatal("group exit clone must dial through the middle proxy clone")
	}
	selectExit := configEntry(t, result, "proxy-groups", "SelectExit")
	if selectExit["type"] != "select" || selectExit["default-selected"] != "Exit · SelectExit" {
		t.Fatalf("selector exit must map its default pick to a clone: %v", selectExit)
	}

	// include-all is pinned before clones exist, so the subscription group never
	// picks up generated proxies.
	all := configEntry(t, result, "proxy-groups", "All")
	if all["include-all"] != nil || all["include-all-proxies"] != nil {
		t.Fatalf("include-all was not pinned: %v", all)
	}
	if !reflect.DeepEqual(list(all["proxies"]), []any{"Auto", "Entry", "Exit", "Middle"}) {
		t.Fatalf("pinned membership changed: %v", all["proxies"])
	}
	if !reflect.DeepEqual(list(result.Config["rules"]), []any{"DOMAIN,keep.test,DIRECT", "MATCH,All"}) {
		t.Fatalf("rules changed: %v", result.Config["rules"])
	}
}

func TestProxyChainCanBeMatchTargetAndRuleTarget(t *testing.T) {
	c, request := chainRequest("proxies: [{name: Entry, type: socks5, server: entry.test, port: 1080}, {name: Exit, type: socks5, server: exit.test, port: 1080}]\nrules: ['MATCH,REJECT']")
	request.Profile.Metadata = Object{"extendType": "standard", "matchTarget": "Two"}
	request.Authoring["proxyChains"] = []authoring.Object{row(Object{"id": 1, "profileId": "p", "name": "Two", "hops": []any{"Entry", "Exit"}})}
	request.Authoring["rules"] = []authoring.Object{row(Object{"id": 9, "profileId": "p", "ruleAction": "DOMAIN", "content": "chain.test", "ruleTarget": "Two"})}
	result := prepared(t, c, request)
	if !reflect.DeepEqual(list(result.Config["rules"]), []any{"DOMAIN,chain.test,Two", "MATCH,Two"}) {
		t.Fatalf("chain targets were not kept: %v", result.Config["rules"])
	}
	configEntry(t, result, "proxy-groups", "Two")
}

func TestProxyChainEntryMayUseAProviderOrItsOwnDialer(t *testing.T) {
	source := `proxies:
  - {name: Entry, type: socks5, server: entry.test, port: 1080}
  - {name: Exit, type: socks5, server: exit.test, port: 1080}
proxy-providers:
  remote: {type: http, url: 'https://example.test/nodes.yaml', path: nodes.yaml}
proxy-groups:
  - {name: Remote, type: select, use: [remote]}
rules: ['MATCH,DIRECT']`
	c, request := chainRequest(source)
	request.Authoring["proxyChains"] = []authoring.Object{
		row(Object{"id": 1, "profileId": "p", "name": "FromProvider", "hops": []any{"Remote", "Exit"}}),
	}
	result := prepared(t, c, request)
	if got := configEntry(t, result, "proxies", "Exit · FromProvider")["dialer-proxy"]; got != "Remote" {
		t.Fatalf("provider-backed entry must stay the dialer target: %v", got)
	}

	source = `proxies:
  - {name: Entry, type: socks5, server: entry.test, port: 1080, dialer-proxy: DIRECT}
  - {name: Exit, type: socks5, server: exit.test, port: 1080}
rules: ['MATCH,DIRECT']`
	c, request = chainRequest(source)
	request.Authoring["proxyChains"] = []authoring.Object{
		row(Object{"id": 1, "profileId": "p", "name": "OnTop", "hops": []any{"Entry", "Exit"}}),
	}
	result = prepared(t, c, request)
	if got := configEntry(t, result, "proxies", "Exit · OnTop")["dialer-proxy"]; got != "Entry" {
		t.Fatalf("an entry with its own dialer-proxy must remain usable: %v", got)
	}
	if got := configEntry(t, result, "proxies", "Entry")["dialer-proxy"]; got != "DIRECT" {
		t.Fatalf("the entry hop must not be rewritten: %v", got)
	}
}

func TestDisabledProxyChainIsNotApplied(t *testing.T) {
	c, request := chainRequest(chainProfileSource)
	request.Authoring["proxyChains"] = []authoring.Object{row(Object{"id": 1, "profileId": "p", "name": "Two", "enabled": false, "hops": []any{"Entry", "Exit"}})}
	result := prepared(t, c, request)
	if len(list(result.Config["proxy-groups"])) != 2 || configEntry(t, result, "proxy-groups", "All")["include-all"] != true {
		t.Fatal("disabled chain changed the config")
	}
}

func TestProxyChainErrorsKeepRuntimeUntouched(t *testing.T) {
	source := chainProfileSource
	cases := []struct {
		name  string
		chain authoring.Object
		src   string
		want  string
	}{
		{"missing hop", row(Object{"id": 1, "profileId": "p", "name": "Two", "hops": []any{"Entry", "Ghost"}}), source, "missing"},
		{"name collision", row(Object{"id": 1, "profileId": "p", "name": "Auto", "hops": []any{"Entry", "Exit"}}), source, "collides"},
		{"chain cycle", row(Object{"id": 1, "profileId": "p", "name": "Two", "hops": []any{"Entry", "Two"}}), source, "proxy chain"},
		{"existing dialer", row(Object{"id": 1, "profileId": "p", "name": "Two", "hops": []any{"Entry", "Exit"}}), "proxies: [{name: Entry, type: socks5, server: entry.test, port: 1080}, {name: Exit, type: socks5, server: exit.test, port: 1080, dialer-proxy: Entry}]\nrules: ['MATCH,DIRECT']", "dialer-proxy"},
		{"unreadable filter", row(Object{"id": 1, "profileId": "p", "name": "Two", "hops": []any{"Entry", "Exit"}}), "proxies: [{name: Entry, type: socks5, server: entry.test, port: 1080}, {name: Exit, type: socks5, server: exit.test, port: 1080}]\nproxy-groups: [{name: All, type: select, include-all: true, filter: '(?<=x)y'}]\nrules: ['MATCH,DIRECT']", "filter"},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			c, request := chainRequest(test.src)
			request.Authoring["proxyChains"] = []authoring.Object{test.chain}
			raw, err := json.Marshal(request)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = c.Compile(context.Background(), backend.Input(raw), 3); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("chain error %q does not mention %q", err, test.want)
			}
		})
	}
}
