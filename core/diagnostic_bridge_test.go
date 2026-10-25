package main

import (
	"encoding/json"
	"math"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

func TestLegacyDelayPayloadMeasuresTheRequestedNode(t *testing.T) {
	server := probeServer(t, func(w http.ResponseWriter, _ *http.Request) {
		// URLTest reports milliseconds; make a successful result nonzero.
		time.Sleep(5 * time.Millisecond)
		w.WriteHeader(http.StatusNoContent)
	})
	withProbeProxies(t, "node-a")
	params, err := json.Marshal(TestDelayParams{ProxyName: "node-a", TestUrl: server.URL, Timeout: 2000})
	if err != nil {
		t.Fatal(err)
	}
	result := make(chan string, 1)
	handleAsyncTestDelay(string(params), func(value string) { result <- value })
	select {
	case raw := <-result:
		var delay Delay
		if err := json.Unmarshal([]byte(raw), &delay); err != nil {
			t.Fatal(err)
		}
		if delay.Name != "node-a" || delay.Url != server.URL || delay.Value <= 0 {
			t.Fatalf("incorrect delay result: %+v", delay)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("delay callback did not complete")
	}
}

func TestProxyDiagnosticsHideOnlySyntheticGlobalAndKeepProfileOrder(t *testing.T) {
	for _, providerName := range []string{provider.ReservedName, "configured-global"} {
		t.Run(providerName, func(t *testing.T) {
			members := []constant.Proxy{namedProxy("DIRECT")}
			pd, err := provider.NewCompatibleProvider(providerName, members, provider.NewHealthCheck(members, "", 0, 0, true, nil))
			if err != nil {
				t.Fatal(err)
			}
			selector, err := outboundgroup.NewSelector(outboundgroup.GroupCommonOption{Name: "GLOBAL"}, outboundgroup.SelectorOption{}, namedProxy("COMPATIBLE"), []cp.ProxyProvider{pd})
			if err != nil {
				t.Fatal(err)
			}
			proxies := map[string]constant.Proxy{"GLOBAL": adapter.NewProxy(selector), "DIRECT": members[0]}
			for _, name := range []string{"z-group", "a-group"} {
				group, err := outboundgroup.NewSelector(outboundgroup.GroupCommonOption{Name: name}, outboundgroup.SelectorOption{}, namedProxy("COMPATIBLE"), []cp.ProxyProvider{pd})
				if err != nil {
					t.Fatal(err)
				}
				proxies[name] = adapter.NewProxy(group)
			}
			previousConfig := currentRuntimeRawConfig
			previousProxies, previousProviders := tunnel.Proxies(), tunnel.Providers()
			t.Cleanup(func() {
				currentRuntimeRawConfig = previousConfig
				tunnel.UpdateProxies(previousProxies, previousProviders)
			})
			currentRuntimeRawConfig = map[string]any{"proxy-groups": []any{map[string]any{"name": "z-group"}, map[string]any{"name": "a-group"}}}
			tunnel.UpdateProxies(proxies, nil)
			value, err, handled := diagnosticAction(&Action{Method: "getProxiesData"})
			if !handled || err != nil {
				t.Fatalf("diagnostic request rejected: %v", err)
			}
			view := value.(ProxiesData)
			if strings.Join(view.All, ",") != "z-group,a-group,GLOBAL" {
				t.Fatalf("profile group order lost: %v", view.All)
			}
			global := view.Proxies["GLOBAL"].(map[string]any)
			if got := global["hidden"] == true; got != (providerName == provider.ReservedName) {
				t.Fatalf("GLOBAL hidden=%v for provider %q", global["hidden"], providerName)
			}
		})
	}
}

func TestDiagnosticBridgeAcceptsBothNativeArgumentEnvelopes(t *testing.T) {
	for _, data := range []any{[]string{"vless://id@example.com:443#test"}, `["vless://id@example.com:443#test"]`} {
		value, err, handled := diagnosticAction(&Action{Method: "decodeShareLinks", Data: data})
		if !handled || err != nil {
			t.Fatalf("request rejected: %v %v", handled, err)
		}
		rows, ok := value.([][]map[string]any)
		if !ok || len(rows) != 1 || len(rows[0]) != 1 || rows[0][0]["server"] != "example.com" {
			t.Fatalf("decoded links: %#v", value)
		}
	}
}

func TestDiagnosticBridgeRejectsBadShapesAndOversizedInput(t *testing.T) {
	for _, request := range []Action{
		{Method: "probe", Data: map[string]any{"url": "https://example.com", "unexpected": true}},
		{Method: "decodeShareLinks", Data: `{}`},
		{Method: "validateFilters", Data: strings.Repeat("x", maxDiagnosticBytes+1)},
		{Method: "watchRoute", Data: "true false"},
	} {
		if _, err, handled := diagnosticAction(&request); !handled || err == nil {
			t.Fatalf("accepted invalid request: %s", request.Method)
		}
	}
	if _, _, handled := diagnosticAction(&Action{Method: "runtime.stop"}); handled {
		t.Fatal("diagnostic path captured runtime mutation")
	}
}

func TestNativeArrivalOrderPreventsLateWatchReactivation(t *testing.T) {
	var older, newer Action
	if err := json.Unmarshal([]byte(`{"id":"a","method":"watchRoute","data":true}`), &older); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(`{"id":"b","method":"watchRoute","data":false}`), &newer); err != nil {
		t.Fatal(err)
	}
	if older.callSeq >= newer.callSeq {
		t.Fatal("arrival order was lost")
	}
	defer stopRouteWatch()
	diagnosticAction(&newer)
	diagnosticAction(&older)
	currentRoute.mu.Lock()
	watching := currentRoute.watched
	currentRoute.mu.Unlock()
	if watching {
		t.Fatal("older delayed UI request reactivated route polling")
	}
}

func TestProbeTimeoutCannotOverflowOrExceedItsBudget(t *testing.T) {
	if got := timeoutFromMillis(math.MaxInt64, time.Second); got != 2*time.Minute {
		t.Fatalf("unbounded timeout: %v", got)
	}
	if got := timeoutFromMillis(0, time.Second); got != time.Second {
		t.Fatalf("fallback timeout: %v", got)
	}
}
