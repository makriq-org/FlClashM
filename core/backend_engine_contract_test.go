package main

import (
	"context"
	"encoding/json"
	"testing"

	"core/backend/compile"
	"github.com/metacubex/mihomo/config"
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
	prepared := embeddedExecutorConfig(original)
	if prepared.Controller.ExternalUI != "" || prepared.Controller.ExternalUIName != "" {
		t.Fatal("empty URL still triggers automatic UI download")
	}
	if controller.ExternalUI != "/private/zashboard" || controller.ExternalUIName != "local" || prepared.Controller.ExternalController != controller.ExternalController || prepared.Controller.Secret != controller.Secret {
		t.Fatal("serving path or controller settings changed")
	}
	controller.ExternalUIURL = "https://example.com/ui.zip"
	if embeddedExecutorConfig(original) != original {
		t.Fatal("explicit UI download was disabled")
	}
}
