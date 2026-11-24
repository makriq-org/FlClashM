package compile

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"
)

func compileQwdtt(t *testing.T, node string) (Object, Node, error) {
	t.Helper()
	config := mustProfile(t, "proxies: ["+node+"]")
	nodes, err := (&ExternalCompiler{}).Compile(context.Background(), config, defaults(), "https://example.com/check")
	if err != nil {
		return nil, Node{}, err
	}
	if len(nodes) != 1 {
		t.Fatal("missing qwdtt node")
	}
	raw := nodes[0].Files["built-in-proxies/qwdtt/"+nodes[0].ID+"/config.json"]
	native := Object{}
	if raw == "" {
		t.Fatal("missing qwdtt config.json")
	}
	if err := json.Unmarshal([]byte(raw), &native); err != nil {
		t.Fatal(err)
	}
	return native, nodes[0], nil
}

func TestQwdttDefaults(t *testing.T) {
	native, node, err := compileQwdtt(t, `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: secret, vk-hashes: [h1, h2], activation: always}`)
	if err != nil {
		t.Fatal(err)
	}
	if native["tunnel"] != "wireguard" || native["obfs"] != "audio" || native["turn-transport"] != "udp" {
		t.Fatalf("defaults: %v", native)
	}
	if native["workers"] != float64(9) || native["udp"] != true || native["dns-server"] != "system" {
		t.Fatalf("defaults: %v", native)
	}
	socks := object(native["socks"])
	if socks["listen"] != "127.0.0.1:"+strconv.Itoa(node.Port) || socks["auth"] != true || socks["udp-token"] != true {
		t.Fatalf("socks: %v", socks)
	}
	if node.Metadata["depends-on-system-dns"] != "" || node.UDP != true || node.Activation == nil {
		t.Fatalf("node metadata: %+v", node)
	}
}

func TestQwdttExplicitFields(t *testing.T) {
	native, _, err := compileQwdtt(t, `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: secret, vk-hashes: [h1, h2, h3], tunnel: wireguard-direct, workers: 27, obfs: video, udp: false, turn-transport: tcp, turn-servers: ['192.0.2.10', '192.0.2.20:443', '[2001:db8::1]', '[2001:db8::2]:443'], turn-port: 3478, dns-server: '1.1.1.1:5353', activation: always}`)
	if err != nil {
		t.Fatal(err)
	}
	if native["tunnel"] != "wireguard-direct" || native["workers"] != float64(27) || native["obfs"] != "video" || native["turn-transport"] != "tcp" {
		t.Fatalf("native: %v", native)
	}
	if native["turn-port"] != float64(3478) || native["dns-server"] != "1.1.1.1:5353" {
		t.Fatalf("native: %v", native)
	}
	if native["udp"] != false {
		t.Fatalf("udp must be disabled: %v", native)
	}
	if object(native["socks"])["udp-token"] != false {
		t.Fatal("udp token must be disabled together with UDP")
	}
	servers := list(native["turn-servers"])
	if len(servers) != 4 || text(servers[1]) != "192.0.2.20:443" || text(servers[2]) != "[2001:db8::1]" {
		t.Fatalf("turn-servers: %v", native["turn-servers"])
	}
}

func TestQwdttValidation(t *testing.T) {
	cases := map[string]string{
		"workers above hashes": `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: secret, vk-hashes: [h1], workers: 28, activation: always}`,
		"workers zero":         `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: secret, vk-hashes: [h1], workers: 0, activation: always}`,
		"duplicate hashes":     `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: secret, vk-hashes: [h1, h1], activation: always}`,
		"too many hashes":      `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: secret, vk-hashes: [h1, h2, h3, h4, h5, h6, h7], activation: always}`,
		"empty hash":           `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: secret, vk-hashes: [''], activation: always}`,
		"bad tunnel":           `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: secret, vk-hashes: [h1], tunnel: udp, activation: always}`,
		"bad obfs":             `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: secret, vk-hashes: [h1], obfs: text, activation: always}`,
		"bad turn transport":   `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: secret, vk-hashes: [h1], turn-transport: quic, activation: always}`,
		"bad turn port":        `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: secret, vk-hashes: [h1], turn-port: 0, activation: always}`,
		"bad turn server":      `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: secret, vk-hashes: [h1], turn-servers: ['host:0'], activation: always}`,
		"bad dns":              `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: secret, vk-hashes: [h1], dns-server: dns.example.com, activation: always}`,
		"empty password":       `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: '', vk-hashes: [h1], activation: always}`,
		"owned listener":       `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: secret, vk-hashes: [h1], socks: '127.0.0.1:1', activation: always}`,
		"unknown field":        `{name: Qw, type: qwdtt, server: vpn.example.com, port: 56003, password: secret, vk-hashes: [h1], fld: 1, activation: always}`,
	}
	for name, source := range cases {
		t.Run(name, func(t *testing.T) {
			if _, _, err := compileQwdtt(t, source); err == nil {
				t.Fatal("invalid node accepted")
			}
		})
	}
}
