package profilecodec

import "testing"

func TestCompileRulesPreservesFormatsAndRoundTripsMrs(t *testing.T) {
	for _, test := range []struct {
		name, source, behavior, format string
		binary                         bool
	}{
		{"domain yaml", "payload: ['+.example.com']", "domain", "yaml", true},
		{"IP text", "# test\n10.0.0.0/8\n2001:db8::/32", "ipcidr", "text", true},
		{"classical", "PROCESS-NAME,curl", "classical", "text", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			info, data, err := CompileRules([]byte(test.source), false)
			if err != nil || info.Behavior != test.behavior || info.Format != test.format {
				t.Fatalf("metadata: %+v %v", info, err)
			}
			if (data != nil) != test.binary {
				t.Fatalf("unexpected binary output: %v", data)
			}
			if data != nil {
				roundtrip, _, err := CompileRules(data, false)
				if err != nil || roundtrip.Format != "mrs" || roundtrip.Behavior != test.behavior {
					t.Fatalf("roundtrip: %+v %v", roundtrip, err)
				}
			}
		})
	}
}

func TestCompileRulesRejectsAmbiguousOrBrokenInput(t *testing.T) {
	for _, source := range []string{"", "example.com\n10.0.0.0/8", string(zstdMagic) + "broken", "bad/name"} {
		if _, _, err := CompileRules([]byte(source), false); err == nil {
			t.Fatalf("accepted %q", source)
		}
	}
	info, _, err := CompileRules(nil, true)
	if err != nil || info.Behavior != "classical" {
		t.Fatalf("new empty editor document: %+v %v", info, err)
	}
}
