package compile

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"core/backend"
	"core/backend/authoring"
)

func row(value any) authoring.Object { return authoring.Object(toRaw(object(value))) }
func customRequest(t *testing.T) (Compiler, Input) {
	t.Helper()
	root := t.TempDir()
	c := Compiler{Capabilities: Capabilities{Platform: "android", HomeDir: root, ProfilesDir: filepath.Join(root, "profiles")}, Nodes: &ExternalCompiler{}, Validate: func(ctx context.Context, _ Object) error { return ctx.Err() }}
	data := authoring.Empty()
	data["customProxies"] = []authoring.Object{row(Object{"id": 1, "definition": Object{"name": "Server", "type": "socks5", "server": "example.com", "port": 443}}), row(Object{"id": 2, "definition": Object{"name": "Unused", "type": "socks5", "server": "unused.test", "port": 1}})}
	data["proxyGroups"] = []authoring.Object{row(Object{"id": 3, "profileId": "custom-id", "name": "Proxy", "type": "select", "proxies": []any{"Server"}, "use": []any{"Subscription"}, "memberLayout": []any{"ignored"}, "order": "a0"})}
	data["rules"] = []authoring.Object{row(Object{"id": 4, "profileId": "custom-id", "ruleAction": "RULE_SET", "ruleProvider": "Domains", "ruleTarget": "Proxy"}), row(Object{"id": 5, "profileId": "custom-id", "ruleAction": "MATCH", "ruleTarget": "Proxy"})}
	data["clashProviders"] = []authoring.Object{row(Object{"id": 6, "label": "Domains", "format": "yaml", "behavior": "domain", "contentBase64": base64.StdEncoding.EncodeToString([]byte("payload: ['+.example.com']"))})}
	return c, Input{Version: 1, Profile: &RawProfile{ID: "custom-id", SourceMissing: true, Metadata: Object{"type": "custom", "label": "Custom", "providerHeaders": Object{"flclashm-androidsecure": "true"}}}, Settings: Object{}, Authoring: data, Profiles: map[string]RawProfile{"provider-id": {ID: "provider-id", Text: "proxies: [{name: DPI, type: byedpi, mode: manual, args: '--disorder 1'}]", Metadata: Object{"label": "Subscription"}}}}
}
func TestCustomCompileKeepsRuleAndFallbackProxyDependencies(t *testing.T) {
	for _, mode := range []string{"rule", "empty-fallback"} {
		t.Run(mode, func(t *testing.T) {
			c, request := customRequest(t)
			request.Authoring["customProxies"] = append(request.Authoring["customProxies"],
				row(Object{"id": 7, "definition": Object{"name": "Hop", "type": "socks5", "server": "hop.test", "port": 1080}}))
			request.Authoring["proxyDialers"] = []authoring.Object{row(Object{"profileId": "custom-id", "proxyId": 2, "target": "Hop"})}
			request.Authoring["rules"] = []authoring.Object{row(Object{"id": 4, "profileId": "custom-id", "ruleAction": "MATCH", "ruleTarget": "Unused"})}
			request.Authoring["proxyGroups"] = nil
			if mode == "empty-fallback" {
				request.Authoring["proxyGroups"] = []authoring.Object{row(Object{"id": 3, "profileId": "custom-id", "name": "Proxy", "type": "select", "proxies": []any{"DIRECT"}, "empty-fallback": "Unused"})}
				request.Authoring["rules"][0]["ruleTarget"] = authoring.Value("Proxy")
			}
			// A different profile must not pull its dependencies into this one.
			request.Authoring["rules"] = append(request.Authoring["rules"], row(Object{"id": 8, "profileId": "other", "ruleAction": "MATCH", "ruleTarget": "Server"}))
			result := prepared(t, c, request)
			var names []string
			for _, proxy := range list(result.Config["proxies"]) {
				names = append(names, text(object(proxy)["name"]))
			}
			if !reflect.DeepEqual(names, []string{"Unused", "Hop"}) {
				t.Fatalf("referenced proxies and dialer dependencies must survive, unrelated proxies must not: %v", names)
			}
		})
	}
}
func TestCustomCompileUsesValidatorSecurityAndExternalProviderNodes(t *testing.T) {
	c, request := customRequest(t)
	calls := 0
	c.Validate = func(_ context.Context, config Object) error {
		calls++
		if object(list(object(object(config["proxy-providers"])["Subscription"])["payload"])[0])["type"] != "socks5" {
			t.Error("external provider proxy escaped node compilation")
		}
		return nil
	}
	result := prepared(t, c, request)
	if calls != 1 || len(result.Nodes) != 1 || result.Nodes[0].Type != "byedpi" || len(list(result.Config["proxies"])) != 1 {
		t.Fatal("custom profile did not use full backend pipeline", result)
	}
	if result.Config["mixed-port"] != float64(0) {
		t.Fatal("SecurityPolicy skipped custom profile")
	}
	group := object(list(result.Config["proxy-groups"])[0])
	if group["memberLayout"] != nil || group["profileId"] != nil || group["id"] != nil {
		t.Fatal("UI bookkeeping leaked into config", group)
	}
	if !reflect.DeepEqual(list(result.Config["rules"]), []any{"RULE-SET,Domains,Proxy", "MATCH,Proxy"}) {
		t.Fatal("rules changed", result.Config["rules"])
	}
	provider := object(object(result.Config["rule-providers"])["Domains"])
	path := text(provider["path"])
	if provider["format"] != "mrs" || provider["type"] != "file" || !strings.HasPrefix(path, c.Capabilities.ProfilesDir+string(filepath.Separator)) {
		t.Fatal("resource was not privately materialized", provider)
	}
	original, err := os.ReadFile(path)
	if err != nil || len(original) == 0 {
		t.Fatal("missing resource bytes", err)
	}
	request.Authoring["clashProviders"][0]["contentBase64"] = authoring.Value(base64.StdEncoding.EncodeToString([]byte("payload: ['+.new.example']")))
	newer := prepared(t, c, request)
	newPath := text(object(object(newer.Config["rule-providers"])["Domains"])["path"])
	if newPath == path {
		t.Fatal("changed resource reused active file")
	}
	after, _ := os.ReadFile(path)
	if !reflect.DeepEqual(original, after) {
		t.Fatal("active generation resource mutated")
	}
}
func TestPerKeyOverridesPreserveUnselectedAndLegacySections(t *testing.T) {
	c := Compiler{Capabilities: Capabilities{Platform: "android"}, Validate: func(context.Context, Object) error { return nil }}
	request := Input{Version: 1, Profile: &RawProfile{ID: "p", Text: `dns: {enable: true, nameserver: [https://old.example/dns-query], fallback: [tls://old.example], fallback-filter: {geoip: false, domain: [old.test]}}
ntp: {enable: true, server: old.time, interval: 60, write-to-system: true}
sniffer: {enable: true, sniff: {http: {ports: [80]}, TLS: {ports: [443]}}, skip-domain: [old.test]}
rules: ['MATCH,DIRECT']`, Metadata: Object{"overrides": Object{"dns": Object{"nameserver": []any{"https://new.example/dns-query"}, "fallback-filter": Object{"domain": []any{"new.test"}}}, "dns-override-keys": []any{"nameserver", "fallback-filter.domain"}, "ntp": Object{"server": "new.time"}, "ntp-override-keys": []any{"server"}, "sniffer": Object{"sniff": Object{"HTTP": Object{"ports": []any{8080}}}}, "sniffer-override-keys": []any{"sniff.HTTP"}}}}, Settings: Object{"patchClashConfig": Object{"dns": Object{"ipv6": false}, "dns-override-keys": []any{"ipv6"}}}}
	result := prepared(t, c, request)
	dns := object(result.Config["dns"])
	if dns["ipv6"] != false || object(dns["fallback-filter"])["geoip"] != false || list(dns["fallback"])[0] != "tls://old.example" || list(dns["nameserver"])[0] != "https://new.example/dns-query" {
		t.Fatal("key overrides replaced unselected DNS", dns)
	}
	ntp := object(result.Config["ntp"])
	if ntp["server"] != "new.time" || ntp["interval"] != float64(60) || ntp["write-to-system"] != false {
		t.Fatal("NTP or Android policy changed", ntp)
	}
	sniff := object(object(result.Config["sniffer"])["sniff"])
	if sniff["http"] != nil || len(sniff) != 2 || list(object(sniff["HTTP"])["ports"])[0] != "8080" {
		t.Fatal("sniffer protocol merge changed", sniff)
	}
	// No new key sets: preserve the existing whole-section switch exactly.
	request.Profile.Metadata = Object{}
	request.Settings = Object{"overrideDns": true, "patchClashConfig": Object{"dns": Object{"nameserver": []any{"https://legacy.example/dns-query"}}}}
	legacy := prepared(t, c, request)
	if list(object(legacy.Config["dns"])["nameserver"])[0] != "https://legacy.example/dns-query" {
		t.Fatal("legacy overrideDns stopped working")
	}
}
func TestAuthoringRulesAndScriptsPreserveLegacyBehavior(t *testing.T) {
	c := Compiler{Scripts: JavaScript{}, Validate: func(context.Context, Object) error { return nil }}
	data := authoring.Empty()
	data["rules"] = []authoring.Object{row(Object{"id": 1, "ruleAction": "DOMAIN", "content": "global.test", "ruleTarget": "DIRECT"}), row(Object{"id": 2, "profileId": "p", "ruleAction": "DOMAIN_SUFFIX", "content": "own.test", "ruleTarget": "MATCH"})}
	data["disabledRules"] = []authoring.Object{row(Object{"profileId": "p", "ruleId": 1})}
	request := Input{Version: 1, Profile: &RawProfile{ID: "p", Text: "rules: ['MATCH,REJECT']", Metadata: Object{"extendType": "standard", "overrideData": Object{"enable": true, "rule": Object{"addedRules": []any{Object{"value": "DOMAIN,legacy.test,DIRECT"}}}}}}, Settings: Object{}, Authoring: data}
	result := prepared(t, c, request)
	if !reflect.DeepEqual(list(result.Config["rules"]), []any{"DOMAIN,legacy.test,DIRECT", "DOMAIN-SUFFIX,own.test,REJECT", "MATCH,REJECT"}) {
		t.Fatal("rules order, disabled or legacy rules changed", result.Config["rules"])
	}
	data["scripts"] = []authoring.Object{row(Object{"id": int64(9007199254740993), "label": "New", "content": "function main(c){c.rules=['MATCH,DIRECT'];return c;}"})}
	request.Profile.Metadata = Object{"extendType": "script", "scriptId": json.Number("9007199254740993")}
	result = prepared(t, c, request)
	if !reflect.DeepEqual(list(result.Config["rules"]), []any{"MATCH,DIRECT"}) {
		t.Fatal("declaration script did not run", result.Config)
	}
	request.Profile.Metadata = Object{}
	request.Settings = Object{"scriptProps": Object{"currentId": "legacy", "scripts": []any{Object{"id": "legacy", "content": "function main(c){c.rules=['MATCH,PASS'];return c;}"}}}}
	result = prepared(t, c, request)
	if list(result.Config["rules"])[0] != "MATCH,PASS" {
		t.Fatal("legacy scripts lost")
	}
}
func TestCustomSelectionCannotReuseStaleAuthoring(t *testing.T) {
	c, request := customRequest(t)
	initial, _ := json.Marshal(request)
	plan, err := c.Compile(context.Background(), backend.Input(initial), 1)
	if err != nil {
		t.Fatal(err)
	}
	request.Authoring["rules"][1]["ruleTarget"] = authoring.Value("DIRECT")
	changed, _ := json.Marshal(request)
	reused, err := c.CompileSelection(context.Background(), changed, initial, plan, 2)
	if err != nil || reused != nil {
		t.Fatal("authoring edit reused old plan", err)
	}
}

func TestSelectedDNSPoliciesRetainWireOrderAndEmptyValues(t *testing.T) {
	c := Compiler{Validate: func(context.Context, Object) error { return nil }}
	raw := backend.Input(`{"version":1,"profile":{"id":"p","text":"dns: {enable: true, nameserver: [https://old.example/dns-query], fallback: [tls://old.example], nameserver-policy: {old: old.resolver}}\nrules: ['MATCH,DIRECT']","metadata":{"overrides":{"dns-override-keys":["fallback","nameserver-policy"],"dns":{"fallback":[],"nameserver-policy":{"geosite:z":"9.9.9.9","+.a.example":"1.1.1.1"}}}}},"settings":{}}`)
	plan, err := c.Compile(context.Background(), raw, 1)
	if err != nil {
		t.Fatal(err)
	}
	payload := string(plan.Payload())
	if strings.Index(payload, `"geosite:z"`) > strings.Index(payload, `"+.a.example"`) {
		t.Fatal("selected DNS policy order was sorted", payload)
	}
	var result Prepared
	_ = json.Unmarshal(plan.Payload(), &result)
	if len(list(object(result.Config["dns"])["fallback"])) != 0 {
		t.Fatal("normal profile could not clear an overridden field")
	}
}
func TestScriptSandboxHasNoHostBindingsAndIsInterrupted(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := (JavaScript{}).Evaluate(ctx, "function main(c){while(true){}}", Object{}); err == nil {
		t.Fatal("unbounded script returned success")
	}
	for _, binding := range []string{"require('fs')", "fetch('https://example.com')", "process.exit()"} {
		if _, err := (JavaScript{}).Evaluate(context.Background(), "function main(c){"+binding+";return c;}", Object{}); err == nil {
			t.Fatal("sandbox exposed host binding", binding)
		}
	}
}
