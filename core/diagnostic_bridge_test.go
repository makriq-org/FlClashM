package main

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
	"time"
)

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
