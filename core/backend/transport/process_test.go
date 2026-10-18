package transport

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"core/backend"
	"core/backend/compile"
)

func TestMain(m *testing.M) {
	if os.Getenv("FLCLASHM_TRANSPORT_HELPER") == "1" {
		if len(os.Args) > 3 && os.Args[1] == "--backend-parent" {
			executable, _ := os.Executable()
			port, _ := strconv.Atoi(os.Args[3])
			node := backend.NodePlan{ID: "byedpi-" + strings.Repeat("c", 32), Type: "byedpi", Host: "127.0.0.1", Port: port}
			adapter := &ProcessAdapter{Home: os.Args[2], ABI: "host", Executables: map[string]string{"byedpi": executable}}
			if err := adapter.Start(context.Background(), backend.NodeLaunch{Node: node, Strategy: "-d1"}); err != nil {
				os.Exit(5)
			}
			_, _ = fmt.Fprintln(os.Stdout, "started")
			_, _ = os.Stdin.Read(make([]byte, 1))
			os.Exit(0)
		}

		raw, _ := json.Marshal(os.Args[1:])
		_ = os.WriteFile(".argv.json", raw, 0600)
		port := ""
		for i, arg := range os.Args {
			if arg == "--port" && i+1 < len(os.Args) {
				port = os.Args[i+1]
			}
		}
		if port == "" {
			os.Exit(4)
		}
		listener, err := net.Listen("tcp", "127.0.0.1:"+port)
		if err != nil {
			os.Exit(2)
		}
		for {
			connection, err := listener.Accept()
			if err != nil {
				os.Exit(3)
			}
			_ = connection.Close()
		}
	}
	os.Exit(m.Run())
}
func testNode(t *testing.T, kind string, port int) backend.NodePlan {
	t.Helper()
	id := kind + "-" + strings.Repeat("a", 32)
	name := "config.json"
	switch kind {
	case "olcrtc":
		name = "config.yaml"
	case "stormdns":
		name = "client_config.toml"
	}
	return backend.NodePlan{ID: id, Type: kind, Host: "127.0.0.1", Port: port, Files: map[string]string{"built-in-proxies/" + kind + "/" + id + "/" + name: `{"args":"-d1 -s2"}`}, Metadata: map[string]string{}}
}
func waitListener(t *testing.T, port int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		connection, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 30*time.Millisecond)
		if err == nil {
			_ = connection.Close()
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("helper listener never became ready")
}
func TestProcessLifetimeAndStopFence(t *testing.T) {
	t.Setenv("FLCLASHM_TRANSPORT_HELPER", "1")
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	adapter := &ProcessAdapter{Home: t.TempDir(), ABI: "host", Executables: map[string]string{"byedpi": executable}}
	defer adapter.StopAll(context.Background())
	port, err := adapter.AllocatePort(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	node := testNode(t, "byedpi", port)
	if err = adapter.Prepare(context.Background(), node); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	if err = adapter.Start(ctx, backend.NodeLaunch{Node: node}); err != nil {
		t.Fatal(err)
	}
	cancel()
	waitListener(t, port)
	observation, err := adapter.Observe(context.Background(), node.ID)
	if err != nil || observation.State != "running" {
		t.Fatal("request detached process", observation, err)
	}
	directory, _ := adapter.directory(node)
	raw, err := os.ReadFile(filepath.Join(directory, ".argv.json"))
	if err != nil {
		t.Fatal(err)
	}
	var args []string
	if json.Unmarshal(raw, &args) != nil || strings.Join(args, " ") != "--ip 127.0.0.1 --port "+strconv.Itoa(port)+" -d1 -s2" {
		t.Fatalf("argv %s", raw)
	}
	if err = adapter.Stop(context.Background(), node.ID); err != nil {
		t.Fatal(err)
	}
	connection, err := net.DialTimeout("tcp", net.JoinHostPort(node.Host, strconv.Itoa(port)), 50*time.Millisecond)
	if err == nil {
		connection.Close()
		t.Fatal("successful stop left process listener alive")
	}
	observation, _ = adapter.Observe(context.Background(), node.ID)
	if observation.State != "stopped" {
		t.Fatal(observation)
	}
	if err = adapter.Start(context.Background(), backend.NodeLaunch{Node: node, Strategy: "--ip 0.0.0.0 -d1"}); err == nil {
		t.Fatal("runtime host accepted forbidden listener arguments")
	}
}
func TestArtifactsDNSAndCacheInvalidation(t *testing.T) {
	compiler := compile.ExternalCompiler{}
	config, err := compile.ParseProfile(`proxies: [{name: storm, type: stormdns, activation: always, domains: [example.com], encryption: none, encryption-key: key, resolvers: [system, '1.1.1.1']}]`)
	if err != nil {
		t.Fatal(err)
	}
	plans, err := compiler.Compile(context.Background(), config, compile.Object{}, "")
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(plans[0])
	var node backend.NodePlan
	_ = json.Unmarshal(raw, &node)
	physical := []netip.Addr{netip.MustParseAddr("9.9.9.9"), netip.MustParseAddr("9.9.9.9")}
	adapter := &ProcessAdapter{Home: t.TempDir(), ABI: "host", PhysicalDNS: func(context.Context) ([]netip.Addr, error) { return physical, nil }}
	if err = adapter.Prepare(context.Background(), node); err != nil {
		t.Fatal(err)
	}
	directory, _ := adapter.directory(node)
	if err = adapter.renderDNS(context.Background(), node, directory); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(filepath.Join(directory, "client_resolvers.txt"))
	if err != nil || string(body) != "9.9.9.9\n1.1.1.1\n" {
		t.Fatalf("rendered DNS %q %v", body, err)
	}
	cache := filepath.Join(directory, "cache", node.Metadata["cache-fingerprint"], "logs")
	if err = os.MkdirAll(cache, 0700); err != nil {
		t.Fatal(err)
	}
	sentinel := filepath.Join(cache, "mtu.log")
	if err = os.WriteFile(sentinel, []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	if err = adapter.Prepare(context.Background(), node); err != nil {
		t.Fatal(err)
	}
	if err = adapter.renderDNS(context.Background(), node, directory); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(sentinel); err != nil {
		t.Fatal("unchanged physical DNS destroyed cache")
	}
	physical = []netip.Addr{netip.MustParseAddr("8.8.8.8")}
	if err = adapter.Prepare(context.Background(), node); err != nil {
		t.Fatal(err)
	}
	if err = adapter.renderDNS(context.Background(), node, directory); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(sentinel); !os.IsNotExist(err) {
		t.Fatal("physical DNS change retained MTU cache", err)
	}
	node.Files = map[string]string{"../../outside": "secret"}
	if err = adapter.Prepare(context.Background(), node); err == nil {
		t.Fatal("artifact escaped node directory")
	}
}

func TestProcessDiesWithServiceHost(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "android" {
		t.Skip("Linux/Android parent-death mechanism")
	}
	t.Setenv("FLCLASHM_TRANSPORT_HELPER", "1")
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	adapter := &ProcessAdapter{}
	port, err := adapter.AllocatePort(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	parent := exec.Command(executable, "--backend-parent", t.TempDir(), strconv.Itoa(port))
	input, err := parent.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = parent.Start(); err != nil {
		t.Fatal(err)
	}
	defer parent.Process.Kill()
	waitListener(t, port)
	if err = input.Close(); err != nil {
		t.Fatal(err)
	}
	if err = parent.Wait(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		connection, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 30*time.Millisecond)
		if err != nil {
			return
		}
		connection.Close()
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("transport survived its service host")
}
