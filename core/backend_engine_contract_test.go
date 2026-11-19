package main

import (
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"

	"core/backend"
	"core/backend/compile"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/listener"
)

func TestCompiledRulesReachMihomoLoader(t *testing.T) {
	for _, test := range []struct {
		name, source string
		valid        bool
	}{
		{"route to reject", "rules: ['MATCH,REJECT']", true},
		{"reject missing outbound", "rules: ['MATCH,missing-outbound']", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			compiler := compile.Compiler{Validate: func(_ context.Context, value compile.Object) error {
				payload, err := json.Marshal(value)
				if err != nil {
					return err
				}
				raw, err := config.UnmarshalRawConfig(payload)
				if err != nil {
					return err
				}
				if len(raw.Rule) != 1 {
					t.Fatalf("engine silently lost compiled rules: %v", raw.Rule)
				}
				_, err = config.ParseRawConfig(raw)
				return err
			}}
			input, _ := json.Marshal(compile.Input{Version: 1, Profile: &compile.RawProfile{ID: "fixture", Text: "dns: {enable: true, nameserver: ['127.0.0.1']}\n" + test.source}, Settings: compile.Object{}})
			_, err := compiler.Compile(context.Background(), input, 1)
			if (err == nil) != test.valid {
				t.Fatalf("validation error = %v, valid = %v", err, test.valid)
			}
		})
	}
}

func TestRollbackOfLegacyPlanPreservesRoutingRules(t *testing.T) {
	for _, payload := range []string{
		`{"rule":["MATCH,REJECT"]}`,
		`{"rules":["MATCH,REJECT"],"rule":["MATCH,DIRECT"]}`,
	} {
		raw, err := unmarshalBackendEngineConfig(json.RawMessage(payload))
		if err != nil || len(raw.Rule) != 1 || raw.Rule[0] != "MATCH,REJECT" {
			t.Fatal("rollback lost or replaced routing rules", raw, err)
		}
	}
}

func TestEmbeddedUIWithoutDownloadURLPreservesServingPath(t *testing.T) {
	controller := &config.Controller{ExternalUI: "/private/zashboard", ExternalUIName: "local", ExternalController: "127.0.0.1:9090", Secret: "private"}
	original := &config.Config{Controller: controller}
	prepared := embeddedExecutorConfig(original, true)
	if prepared.Controller.ExternalUI != "" || prepared.Controller.ExternalUIName != "" {
		t.Fatal("empty URL still triggers automatic UI download")
	}
	if controller.ExternalUI != "/private/zashboard" || controller.ExternalUIName != "local" || prepared.Controller.ExternalController != controller.ExternalController || prepared.Controller.Secret != controller.Secret {
		t.Fatal("serving path or controller settings changed")
	}
	controller.ExternalUIURL = "https://example.com/ui.zip"
	if embeddedExecutorConfig(original, true) != original {
		t.Fatal("explicit UI download was disabled")
	}
}

func TestStoppedBackendStagesMixedPort(t *testing.T) {
	reservation, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := reservation.Addr().String()
	port := reservation.Addr().(*net.TCPAddr).Port
	_ = reservation.Close()

	wasManaged := backendManaged.Swap(true)
	t.Cleanup(func() {
		handleShutdown()
		backendManaged.Store(wasManaged)
	})
	engine := backendEngine{}
	ctx := context.Background()
	if err := engine.Stop(ctx); err != nil {
		t.Fatal(err)
	}
	plan := func(generation uint64, mixedPort int) *backend.RuntimePlan {
		t.Helper()
		plan, err := backend.NewRuntimePlan(generation, map[string]any{
			"config": map[string]any{
				"mixed-port": mixedPort,
				"tun":        map[string]bool{"enable": false},
				"dns":        map[string]bool{"enable": false},
			},
			"coreState": map[string]any{},
		})
		if err != nil {
			t.Fatal(err)
		}
		return plan
	}
	assertListening := func(want bool) {
		t.Helper()
		conn, err := net.DialTimeout("tcp4", address, time.Second)
		if conn != nil {
			_ = conn.Close()
		}
		if listening := err == nil; listening != want {
			t.Fatalf("mixed port listening = %t, want %t: %v", listening, want, err)
		}
	}
	enabled, disabled := plan(1, port), plan(2, 0)
	if err := engine.Apply(ctx, enabled); err != nil {
		t.Fatal(err)
	}
	assertListening(false)
	if err := engine.Start(ctx); err != nil {
		t.Fatal(err)
	}
	assertListening(true)
	if err := engine.Stop(ctx); err != nil {
		t.Fatal(err)
	}
	assertListening(false)

	// A stopped engine can hold a listener bound by an earlier preparation.
	listener.ReCreateMixed(port, trafficTunnel)
	assertListening(true)
	if err := engine.ApplyLiveSettings(ctx, enabled, disabled); err != nil {
		t.Fatal(err)
	}
	assertListening(false)
}
