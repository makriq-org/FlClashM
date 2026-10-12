package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestServiceSetupStagesBytesAndRemovesController(t *testing.T) {
	home := t.TempDir()
	t.Setenv("FLCLASHM_SERVICE_HOME", home)
	data := []byte(`{"config":{"external-controller":"0.0.0.0:9090","tun":{"enable":true,"device":"Other"},"proxy-providers":{"../escaped":{"type":"file","path":"C:\\Windows\\secret"}},"_flclashm-provider-files":{"proxy-providers/../escaped":"` + base64.StdEncoding.EncodeToString([]byte("proxies: []")) + `"}}}`)
	secured, err := secureServiceSetup(data)
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := json.Unmarshal(secured, &result); err != nil {
		t.Fatal(err)
	}
	conf := result["config"].(map[string]any)
	if conf["external-controller"] != "" || conf["tun"].(map[string]any)["device"] != "FlClashM" {
		t.Fatal("service policy was not enforced")
	}
	if _, exists := conf["_flclashm-provider-files"]; exists {
		t.Fatal("staging metadata reached mihomo")
	}
	provider := conf["proxy-providers"].(map[string]any)["../escaped"].(map[string]any)
	path := provider["path"].(string)
	if !strings.HasPrefix(path, filepath.Join(home, "providers")+string(filepath.Separator)) {
		t.Fatalf("escaped: %s", path)
	}
	content, err := os.ReadFile(path)
	if err != nil || string(content) != "proxies: []" {
		t.Fatalf("staging failed: %v", err)
	}
}

func TestServiceSetupRejectsPrivilegedFileReads(t *testing.T) {
	t.Setenv("FLCLASHM_SERVICE_HOME", t.TempDir())
	for _, config := range []string{
		`{"proxies":[{"type":"ssh","private-key":"C:\\Windows\\secret"}]}`,
		`{"listeners":[{"path":"/outside/socket"}]}`,
		`{"rule-providers":{"local":{"type":"file","path":"../outside"}}}`,
	} {
		if _, err := secureServiceSetup([]byte(`{"config":` + config + `}`)); err == nil {
			t.Fatalf("accepted privileged path: %s", config)
		}
	}
}

func TestServiceDownloadCannotWriteArbitraryPath(t *testing.T) {
	t.Setenv("FLCLASHM_SERVICE_HOME", t.TempDir())
	_, err := handleTunnelHTTPRequest(`{"url":"http://127.0.0.1:1","target-path":"C:\\Windows\\secret"}`)
	if err == nil || !strings.Contains(err.Error(), "saved by the GUI") {
		t.Fatalf("unexpected result: %v", err)
	}
}

func TestNonServiceSetupIsUnchanged(t *testing.T) {
	t.Setenv("FLCLASHM_SERVICE_HOME", "")
	input := []byte(`{"config":{"external-ui":"/user/ui"}}`)
	output, err := secureServiceSetup(input)
	if err != nil || string(output) != string(input) {
		t.Fatalf("ordinary core changed: %v", err)
	}
}
