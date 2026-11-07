package service

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

func TestCopyProxyDeduplicatesAndDropsExternalDialer(t *testing.T) {
	opts := options(t, t.TempDir(), &testEngine{}, make(chan time.Time))
	opts.ReadProxyDefinition = func(context.Context, string) (map[string]any, error) {
		return map[string]any{"name": "node", "type": "socks5", "server": "example.org", "port": 1080, "dialer-proxy": "external-group"}, nil
	}
	app := openTestApp(t, opts)
	first, err := app.copyProxy(context.Background(), []byte(`{"name":"node"}`))
	if err != nil {
		t.Fatal(err)
	}
	rows := app.profiles.AuthoringSnapshot().Collections["customProxies"]
	if len(rows) != 1 {
		t.Fatal("proxy not saved", rows)
	}
	var definition map[string]any
	if err := json.Unmarshal(rows[0]["definition"], &definition); err != nil {
		t.Fatal(err)
	}
	if definition["server"] != "example.org" || definition["dialer-proxy"] != nil {
		t.Fatal("definition was damaged or retained external reference", definition)
	}
	second, err := app.copyProxy(context.Background(), []byte(`{"name":"node"}`))
	if err != nil || second.Revision != first.Revision || len(app.profiles.AuthoringSnapshot().Collections["customProxies"]) != 1 {
		t.Fatal("duplicate copy changed catalog", second, err)
	}
}
