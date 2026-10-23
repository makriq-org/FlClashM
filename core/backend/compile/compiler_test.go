package compile

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"core/backend"
)

func mustProfile(t *testing.T, source string) Object {
	t.Helper()
	value, err := ParseProfile(source)
	if err != nil {
		t.Fatal(err)
	}
	return value
}
func TestYAMLCompatibility(t *testing.T) {
	value := mustProfile(t, `a: &a {port: 80, keep: true}
b: &b {port: 81}
proxies:
 - <<: [*a, *b]
   port: 82
   name: "yes"
   10: ten
`)
	node := object(list(value["proxies"])[0])
	if node["port"] != int64(82) || node["keep"] != true || node["name"] != "yes" || node["10"] != "ten" {
		t.Fatalf("merge and scalar semantics: %#v", node)
	}
	if got := mustProfile(t, "a: &a {p: 1}\nb: &b {p: 2}\nnode: {<<: [*a, *b]}\n"); object(got["node"])["p"] != int64(2) {
		t.Fatalf("legacy last merge wins: %#v", got)
	}
	for _, source := range []string{"a: 1\na: 2", "a: &a [*a]", "[a,b]", "a: b\n---\nc: d"} {
		if _, err := ParseProfile(source); err == nil {
			t.Errorf("accepted malformed profile %q", source)
		}
	}
}
func prepared(t *testing.T, c Compiler, request Input) Prepared {
	t.Helper()
	raw, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := c.Compile(context.Background(), backend.Input(raw), 7)
	if err != nil {
		t.Fatal(err)
	}
	if plan.Generation() != 7 {
		t.Fatal("lost generation")
	}
	var p Prepared
	if err = json.Unmarshal(plan.Payload(), &p); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestExplicitEmptyTestURLDisablesInheritedConnectivityProbes(t *testing.T) {
	c := Compiler{Nodes: &ExternalCompiler{}, Validate: func(context.Context, Object) error { return nil }}
	request := Input{Version: 1, Profile: &RawProfile{ID: "manual", Text: "proxies: [{name: Bye, type: byedpi, mode: manual, args: '--disorder 1'}]"}, Settings: Object{"appSetting": Object{"testUrl": ""}}}
	result := prepared(t, c, request)
	if result.TestURL != "" || len(list(result.Nodes[0].Check["urls"])) != 0 {
		t.Fatalf("explicit empty URL introduced network work: %#v", result)
	}
	delete(object(request.Settings["appSetting"]), "testUrl")
	result = prepared(t, c, request)
	if result.TestURL != "https://www.gstatic.com/generate_204" || len(list(result.Nodes[0].Check["urls"])) != 1 {
		t.Fatal("missing setting did not retain legacy default")
	}
}
func TestProfileSettingsSecurityAndOverrides(t *testing.T) {
	c := Compiler{Capabilities: Capabilities{Platform: "android", HomeDir: "/home/test", ProfilesDir: "/home/test/profiles"}, Validate: func(ctx context.Context, value Object) error { return ctx.Err() }}
	request := Input{Version: 1, Profile: &RawProfile{ID: "profile-1", Text: `mixed-port: 9091
ipv6: false
find-process-mode: invalid
log-level: warning
tun: {enable: false, stack: system}
dns: {enable: false}
secret: '  token  '
external-ui: /private/path
proxy-groups: [{name: Auto, description: Description, type: url-test, lazy: false}]
proxy-providers: {one: {type: http, url: 'https://example.com/p.yaml', path: /unsafe}}
rules: [MATCH,DIRECT]
`, Metadata: Object{"providerHeaders": Object{"flclashm-androidsecure": "true"}, "selectedMap": Object{"Auto": "DIRECT"}}}, Settings: Object{"patchClashConfig": Object{"find-process-mode": "strict", "tun": Object{"enable": false}}, "vpnProps": Object{"accessControl": Object{"enable": true, "mode": "acceptSelected", "acceptList": []any{"com.makriq.flclash", "com.example.app"}}}}}
	result := prepared(t, c, request)
	if result.Config["mixed-port"] != float64(0) || result.Config["ipv6"] != false || result.Config["find-process-mode"] != "strict" || result.Config["secret"] != "token" {
		t.Fatalf("security and provider hints: %#v", result.Config)
	}
	tun := object(result.Config["tun"])
	if tun["enable"] != false || tun["stack"] != "system" {
		t.Fatalf("Tun enable changed by provider: %#v", tun)
	}
	if result.Config["external-ui"] != "/home/test/zashboard" || len(result.Diagnostics) != 1 {
		t.Fatal("local Android path policy")
	}
	path := object(object(result.Config["proxy-providers"])["one"])["path"]
	if path != "/home/test/profiles/providers/profile-1/proxies/"+md5Text("https://example.com/p.yaml") {
		t.Fatalf("provider path %v", path)
	}
	access := object(object(result.CoreState["vpn-props"])["accessControl"])
	if !reflect.DeepEqual(access["acceptList"], []any{"com.example.app"}) {
		t.Fatalf("self bypass: %#v", access)
	}
	if object(list(result.Config["proxy-groups"])[0])["lazy"] != true {
		t.Fatal("Android health check not deferred")
	}
	if !containsAny(list(object(result.Config["dns"])["nameserver"]), "system://") {
		t.Fatal("disabled profile DNS needs system fallback")
	}
	// UI override ignores advisory hints; security still applies to the result.
	request.Settings["appSetting"] = Object{"overrideNetworkSettings": true}
	result = prepared(t, c, request)
	if object(result.Config["tun"])["stack"] != "mixed" || result.Config["ipv6"] != true || result.Config["mixed-port"] != float64(0) {
		t.Fatal("override/security ordering")
	}
}
func containsAny(values []any, target any) bool {
	for _, v := range values {
		if reflect.DeepEqual(v, target) {
			return true
		}
	}
	return false
}
func TestScriptPreparationAndRuleOverride(t *testing.T) {
	c := Compiler{Scripts: JavaScript{}, Validate: func(context.Context, Object) error { return nil }}
	request := Input{Version: 1, Profile: &RawProfile{ID: "p", Text: "rules: [old]\n", Metadata: Object{"overrideData": Object{"enable": true, "rule": Object{"type": "added", "addedRules": []any{Object{"value": "new"}}}}}}, Settings: Object{}}
	result := prepared(t, c, request)
	if !reflect.DeepEqual(result.Config["rules"], []any{"new", "old"}) {
		t.Fatalf("rules %#v", result.Config["rules"])
	}
	request.Settings["scriptProps"] = Object{"currentId": "js", "scripts": []any{Object{"id": "js", "content": `async function main(config) { config.rules=['script']; delete config['proxy-providers']; return config; }`}}}
	result = prepared(t, c, request)
	if !reflect.DeepEqual(result.Config["rules"], []any{"script"}) {
		t.Fatalf("script not authoritative %#v", result.Config["rules"])
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := c.Scripts.Evaluate(ctx, `function main(c){while(true){}}`, Object{}); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel: %v", err)
	}
	_, err := JavaScript{Timeout: 20 * time.Millisecond}.Evaluate(context.Background(), `function main(c){while(true){}}`, Object{})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("unbounded script: %v", err)
	}
	if _, err = (JavaScript{}).Evaluate(context.Background(), `function main(c){return require('fs')}`, Object{}); err == nil {
		t.Fatal("host binding exposed")
	}
}
func TestPreparationDoesNotMutateInputsAndRequiresValidation(t *testing.T) {
	request := Input{Version: 1, Profile: &RawProfile{ID: "p", Text: "proxies: []\n"}, Settings: Object{"patchClashConfig": Object{"dns": Object{"enable": true}}}}
	before, _ := json.Marshal(request)
	c := Compiler{Validate: func(context.Context, Object) error { return errors.New("engine rejected plan") }}
	raw, _ := json.Marshal(request)
	if _, err := c.Compile(context.Background(), raw, 1); err == nil {
		t.Fatal("validator failure ignored")
	}
	c.Validate = func(context.Context, Object) error { return nil }
	prepared(t, c, request)
	after, _ := json.Marshal(request)
	if string(before) != string(after) {
		t.Fatal("input mutated")
	}
}
func TestExternalTransportCompilation(t *testing.T) {
	cases := []struct{ kind, source, file, expected string }{
		{"naiveproxy", `{name: Naive, type: naiveproxy, server: '[2001:4860:4860::8888]', port: 443, username: 'u@x', password: 'p:y', transport: https}`, "config.json", `https://u%40x:p%3Ay@[2001:4860:4860::8888]:443`},
		{"byedpi", `{name: Bye, type: byedpi, mode: manual, strategy: '-d1 -s2'}`, "config.json", `-d1 -s2`},
		{"olcrtc", `{name: Olc, type: olcrtc, provider: jitsi, room: room, encryption-key: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', dns-server: system, transport: datachannel, activation: always}`, "config.yaml", `@flclashm-system-dns@`},
		{"stormdns", `{name: Storm, type: stormdns, domains: ['V.EXAMPLE.COM.', 'example.com'], encryption: chacha20, encryption-key: key, activation: always, preset: bulk, arq: {initial-rto: 600ms, max-rto: 3s}}`, "client_config.toml", `ARQ_INITIAL_RTO_SECONDS = 0.6`},
	}
	for _, tt := range cases {
		t.Run(tt.kind, func(t *testing.T) {
			config := mustProfile(t, "proxies: ["+tt.source+"]")
			nodes, err := (&ExternalCompiler{}).Compile(context.Background(), config, defaults(), "https://example.com/check")
			if err != nil {
				t.Fatal(err)
			}
			if len(nodes) != 1 {
				t.Fatal("missing node")
			}
			node := nodes[0]
			proxy := object(list(config["proxies"])[0])
			if proxy["type"] != "socks5" || proxy["server"] != "127.0.0.1" || len(proxy) != 5 {
				t.Fatalf("unsafe engine node %#v", proxy)
			}
			key := "built-in-proxies/" + tt.kind + "/" + node.ID + "/" + tt.file
			artifact := node.Files[key]
			if !strings.Contains(artifact, tt.expected) {
				t.Fatalf("native configuration %s: %s", key, artifact)
			}
			if tt.kind == "stormdns" && !strings.Contains(artifact, "UPLOAD_COMPRESSION_TYPE = 1") {
				t.Fatal("preset not rendered")
			}
			again, err := (&ExternalCompiler{}).Compile(context.Background(), mustProfile(t, "proxies: ["+tt.source+"]"), defaults(), "https://example.com/check")
			if err != nil || again[0].Port != node.Port || again[0].ID != node.ID {
				t.Fatal("unstable listener identity")
			}
		})
	}
}
// TestGhostlaneProviders checks the provider/transport matrix and MAX credentials.
func TestGhostlaneProviders(t *testing.T) {
	for _, tc := range []struct{ provider, transport, room, token string }{
		{"salutejazz", "datachannel", "example:password", ""},
		{"vkcalls", "vp8channel", "https://vk.ru/call/join/example", ""},
		{"vkcalls", "videochannel", "https://vk.ru/call/join/example", ""},
		{"mtslink", "vp8channel", "https://my.mts-link.ru/j/owner/event", ""},
		{"max", "datachannel", "https://max.ru/joincall/example", "test-token"},
	} {
		t.Run(tc.provider+"/"+tc.transport, func(t *testing.T) {
			raw := Object{"name": "Olc", "type": "olcrtc", "provider": tc.provider, "room": tc.room,
				"provider-token": tc.token, "transport": tc.transport, "encryption-key": strings.Repeat("a", 64),
				"dns-server": "system", "activation": "always"}
			compile := func(raw Object) ([]Node, error) {
				return (&ExternalCompiler{}).Compile(context.Background(), Object{"proxies": []any{raw}}, defaults(), "")
			}
			nodes, err := compile(raw)
			if err != nil || len(nodes) != 1 {
				t.Fatalf("compile %s: nodes=%d error=%v", tc.provider, len(nodes), err)
			}
			var native Object
			for _, content := range nodes[0].Files {
				if err := json.Unmarshal([]byte(content), &native); err != nil {
					t.Fatal(err)
				}
			}
			if native["mode"] != "cnc" || object(native["auth"])["provider"] != tc.provider ||
				object(native["auth"])["token"] != tc.token || object(native["room"])["id"] != tc.room ||
				object(native["net"])["transport"] != tc.transport ||
				object(native["socks"])["host"] != "127.0.0.1" || native["udp"] != nil || native["route"] != nil {
				t.Fatalf("unexpected runtime config: %#v", native)
			}
			raw["transport"] = "seichannel"
			if _, err := compile(raw); err == nil {
				t.Fatal("accepted unsupported provider/transport pair")
			}
			raw["transport"] = tc.transport
			if tc.provider == "max" {
				delete(raw, "provider-token")
				if _, err := compile(raw); err == nil {
					t.Fatal("accepted MAX without a provider token")
				}
			}
		})
	}
}

// TestVKCallsRejectsProviderToken protects VK Calls' guest-only login contract.
func TestVKCallsRejectsProviderToken(t *testing.T) {
	for _, transport := range []string{"vp8channel", "videochannel"} {
		for _, field := range []string{"provider-token", "auth"} {
			t.Run(transport+"/"+field, func(t *testing.T) {
				for _, token := range []string{"test-token", " "} {
					config := mustProfile(t, `proxies: [{name: VK, type: olcrtc, provider: vkcalls,
room: 'https://vk.ru/call/join/example', encryption-key: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
dns-server: system, activation: always}]`)
					raw := object(list(config["proxies"])[0])
					raw["transport"] = transport
					if field == "auth" {
						raw[field] = Object{"token": token}
					} else {
						raw[field] = token
					}
					_, err := (&ExternalCompiler{}).Compile(context.Background(), config, defaults(), "")
					if err == nil || !strings.Contains(err.Error(), "provider-token") {
						t.Fatalf("expected provider-token rejection, got %v", err)
					}
				}
			})
		}
	}
}

func TestExternalSecurityAndRelationalValidation(t *testing.T) {
	base := `name: Storm, type: stormdns, domains: [example.com], encryption: none, encryption-key: k, activation: always`
	for _, extra := range []string{", listen-port: 1", ", arq: {initial-rto: 4s, max-rto: 3s}", ", arq: {nack-max-gap: 251}", ", startup: {max-age: 36h}", ", runtime: {workers: 5}", ", mtu: {upload: {min: 201}}", ", resolvers: [10.0.0.0/8]", ", ping: {cold-interval: 1s}"} {
		config := mustProfile(t, "proxies: [{"+base+extra+"}]")
		if _, err := (&ExternalCompiler{}).Compile(context.Background(), config, defaults(), ""); err == nil {
			t.Errorf("accepted %s", extra)
		}
	}
	for _, address := range []string{"https://127.0.0.1/a", "https://[::1]/a", "http://example.com/list", "https://u:p@example.com/list", "https://example.com/a#b", "https://192.0.2.1/a"} {
		if err := publicListURL(address); err == nil {
			t.Errorf("unsafe list accepted %s", address)
		}
	}
	for _, strategy := range []string{"--ip 0.0.0.0 -d1", "-p1234 -d1", "-l/tmp/log -d1", "-d1 --unknown", "-d1; touch /tmp/pwned"} {
		if _, err := CLIArguments(strategy, "args"); err == nil {
			t.Errorf("unsafe argv accepted %s", strategy)
		}
	}
	if _, err := CLIArguments(ByeDPIFallback, "fallbackArgs"); err != nil {
		t.Fatalf("bundled fallback rejected %v", err)
	}
}
func TestResolverExpansionAndOrdering(t *testing.T) {
	config := mustProfile(t, "proxies: [{name: Storm, type: stormdns, domains: [example.com], encryption: none, encryption-key: k, activation: always, resolvers: ['system', '1.1.1.0/30', '1.1.1.1:5353', '[2001:4860::1]:5353']}]\n")
	nodes, err := (&ExternalCompiler{}).Compile(context.Background(), config, defaults(), "")
	if err != nil {
		t.Fatal(err)
	}
	body := nodes[0].Files["built-in-proxies/stormdns/"+nodes[0].ID+"/client_resolvers.template"]
	if body != "# @flclashm:system-dns\n1.1.1.1\n1.1.1.2\n[2001:4860::1]:5353\n" {
		t.Fatalf("dedup/order: %s", body)
	}
	for _, tc := range []struct {
		literal string
		count   int
	}{{"10.0.0.0/16", 65534}, {"2001:4860::/112", 65535}, {"1.1.1.0/31", 2}, {"::/128", 1}} {
		entries, err := expandResolverLiteral(tc.literal)
		if err != nil || len(entries) != tc.count {
			t.Errorf("%s: %d %v", tc.literal, len(entries), err)
		}
	}
}

func TestLegacyYAMLScalarRules(t *testing.T) {
	cases := []struct {
		source   string
		expected any
	}{{"0443", int64(443)}, {"0o443", int64(291)}, {"0x1bb", int64(443)}, {"2026-10-18", "2026-10-18"}, {"1_000", "1_000"}, {"0b10", "0b10"}, {"on", "on"}, {"yes", "yes"}, {"1e3", float64(1000)}, {"!!str 0443", "0443"}, {"!!int 0443", int64(443)}}
	for _, tt := range cases {
		got := mustProfile(t, "value: "+tt.source)["value"]
		if !reflect.DeepEqual(got, tt.expected) {
			t.Errorf("%s -> %T %v, expected %T %v", tt.source, got, got, tt.expected, tt.expected)
		}
	}
	if _, err := ParseProfile("value: !!timestamp 2026-10-18"); err == nil {
		t.Fatal("undefined legacy tag accepted")
	}
}

func TestLegacyOlcRTCModeCNCIsAcceptedAndRemoved(t *testing.T) {
	node := `name: Olc, type: olcrtc, provider: jitsi, room: room, encryption-key: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', dns-server: system, transport: datachannel, activation: always`
	nodes, err := (&ExternalCompiler{}).Compile(context.Background(), mustProfile(t, "proxies: [{"+node+", mode: ' cnc '}]"), defaults(), "")
	if err != nil {
		t.Fatal("legacy olcrtc mode cnc rejected:", err)
	}
	artifact := nodes[0].Files["built-in-proxies/olcrtc/"+nodes[0].ID+"/config.yaml"]
	if !strings.Contains(artifact, "@flclashm-system-dns@") {
		t.Fatalf("legacy mode changed native configuration: %s", artifact)
	}
	for _, mode := range []string{"p2p", "''", "1"} {
		if _, err := (&ExternalCompiler{}).Compile(context.Background(), mustProfile(t, "proxies: [{"+node+", mode: "+mode+"}]"), defaults(), ""); err == nil {
			t.Errorf("accepted unsupported olcrtc mode %s", mode)
		}
	}
}

func policyOrder(t *testing.T, c Compiler, input string) []string {
	t.Helper()
	result, err := c.prepare(context.Background(), backend.Input(input))
	if err != nil {
		t.Fatal(err)
	}
	// The payload encoding is what the engine reads in declaration order.
	raw, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	return jsonKeyOrder(raw, "config", "dns", "nameserver-policy")
}

func TestSavedNameserverPolicyReplacesDefaultEntries(t *testing.T) {
	c := Compiler{Validate: func(context.Context, Object) error { return nil }}
	// The user deleted every default entry except one and added a new one.
	settings := `{"overrideDns":true,"patchClashConfig":{"dns":{"nameserver-policy":{"www.baidu.com":"114.114.114.114","+.corp.example":"10.0.0.1"},"ipv6":false}}}`
	got := policyOrder(t, c, `{"version":1,"profile":{"id":"p","text":"proxies: []\n"},"settings":`+settings+`}`)
	if !reflect.DeepEqual(got, []string{"www.baidu.com", "+.corp.example"}) {
		t.Fatal("deleted default nameserver-policy entries returned", got)
	}
	result, err := c.prepare(context.Background(), backend.Input(`{"version":1,"profile":{"id":"p","text":"proxies: []\n"},"settings":`+settings+`}`))
	if err != nil {
		t.Fatal(err)
	}
	dns := object(result.Config["dns"])
	// Structured sections still keep defaults for fields the user did not save.
	if dns["ipv6"] != false || dns["listen"] != "0.0.0.0:1053" {
		t.Fatal("dns defaults were not filled field by field", dns)
	}
	// Without a saved dictionary the defaults remain, in their declared order.
	got = policyOrder(t, c, `{"version":1,"profile":{"id":"p","text":"proxies: []\n"},"settings":{"overrideDns":true}}`)
	if !reflect.DeepEqual(got, []string{"www.baidu.com", "+.internal.crop.com", "geosite:cn"}) {
		t.Fatal("default nameserver-policy changed", got)
	}
}

func TestNameserverPolicyKeepsDeclarationOrder(t *testing.T) {
	c := Compiler{Validate: func(context.Context, Object) error { return nil }}
	profile := "dns:\n  enable: true\n  nameserver-policy:\n    'z.example': 10.0.0.2\n    '+.a.example': [10.0.0.1, 10.0.0.3]\n    'geosite:cn': system\n    'm.example': 10.0.0.4\nproxies: []\n"
	input, _ := json.Marshal(Input{Version: 1, Profile: &RawProfile{ID: "p", Text: profile}, Settings: Object{}})
	if got := policyOrder(t, c, string(input)); !reflect.DeepEqual(got, []string{"z.example", "+.a.example", "geosite:cn", "m.example"}) {
		t.Fatal("profile nameserver-policy order lost", got)
	}
	settings := `{"overrideDns":true,"patchClashConfig":{"dns":{"nameserver-policy":{"z.example":"10.0.0.2","geosite:cn":"system","a.example":"10.0.0.1, 10.0.0.3"}}}}`
	if got := policyOrder(t, c, `{"version":1,"profile":{"id":"p","text":"proxies: []\n"},"settings":`+settings+`}`); !reflect.DeepEqual(got, []string{"z.example", "geosite:cn", "a.example"}) {
		t.Fatal("saved nameserver-policy order lost", got)
	}
}

func TestNameserverPolicyOrderThroughYAMLMerge(t *testing.T) {
	c := Compiler{Validate: func(context.Context, Object) error { return nil }}
	for name, profile := range map[string]string{
		"inherited dns":        "<<: &base\n  dns:\n    enable: true\n    nameserver-policy: {z.example: 1.1.1.1, a.example: 8.8.8.8}\nproxies: []\n",
		"inherited policy":     "dns:\n  <<: &base\n    enable: true\n    nameserver-policy: {z.example: 1.1.1.1, a.example: 8.8.8.8}\nproxies: []\n",
		"last merge wins":      "dns:\n  enable: true\n  <<: [{nameserver-policy: {old.example: 9.9.9.9}}, {nameserver-policy: {z.example: 1.1.1.1, a.example: 8.8.8.8}}]\nproxies: []\n",
		"explicit policy wins": "dns:\n  enable: true\n  nameserver-policy: {z.example: 1.1.1.1, a.example: 8.8.8.8}\n  <<: {nameserver-policy: {old.example: 9.9.9.9}}\nproxies: []\n",
	} {
		t.Run(name, func(t *testing.T) {
			input, _ := json.Marshal(Input{Version: 1, Profile: &RawProfile{ID: "p", Text: profile}, Settings: Object{}})
			if got := policyOrder(t, c, string(input)); !reflect.DeepEqual(got, []string{"z.example", "a.example"}) {
				t.Fatal("YAML merge lost effective policy order", got)
			}
		})
	}
}

func TestLargeAnchorProfileIsAcceptedAndAliasBombRejected(t *testing.T) {
	var source strings.Builder
	source.WriteString("base: &all\n  type: select\n  proxies:\n")
	for i := range 2000 {
		fmt.Fprintf(&source, "    - proxy-%d\n", i)
	}
	source.WriteString("proxy-groups:\n")
	for i := range 100 {
		fmt.Fprintf(&source, "  - {<<: *all, name: group-%d}\n", i)
	}
	value, err := ParseProfile(source.String())
	if err != nil {
		t.Fatal("realistic anchor profile rejected:", err)
	}
	groups := list(value["proxy-groups"])
	if len(groups) != 100 || len(list(object(groups[99])["proxies"])) != 2000 || object(groups[99])["name"] != "group-99" {
		t.Fatal("anchor profile materialized incorrectly")
	}
	// Merged values are independent copies: compilation mutates them in place.
	object(groups[0])["lazy"] = true
	if _, shared := object(groups[1])["lazy"]; shared {
		t.Fatal("aliased values share storage")
	}
	bomb := "a: &a [x, x, x, x, x, x, x, x, x, x]\n"
	previous := "a"
	for _, name := range []string{"b", "c", "d", "e", "f", "g", "h", "i"} {
		bomb += name + ": &" + name + " [" + strings.TrimSuffix(strings.Repeat("*"+previous+", ", 10), ", ") + "]\n"
		previous = name
	}
	if _, err = ParseProfile(bomb); err == nil {
		t.Fatal("billion laughs profile accepted")
	}
}
