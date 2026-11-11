package compile

import (
	"bytes"
	"context"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

func byeDPITestStrategies() []string {
	strategies := []string{ByeDPIFallback}
	for _, line := range strings.Split(bundledStrategies, "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") {
			strategies = append(strategies, strings.ReplaceAll(line, "{sni}", "example.com"))
		}
	}
	return strategies
}

func TestByeDPIBundledStrategies(t *testing.T) {
	for i, strategy := range byeDPITestStrategies() {
		for _, context := range []string{"args", "strategy", "fallbackArgs"} {
			if _, err := CLIArguments(strategy, context); err != nil {
				t.Errorf("strategy %d (%s): %v", i, context, err)
			}
		}
	}
}

func TestByeDPIUpdatedControlOptionsRemainForbidden(t *testing.T) {
	for _, arg := range []string{"--tcp-timeout 1:2", "-T1", "--tls-timeout 1:2:3", "-W1", "--await-int 10", "-z10", "--rst", "-0"} {
		for _, context := range []string{"args", "strategy", "fallbackArgs"} {
			if _, err := CLIArguments(arg, context); err == nil || !strings.Contains(err.Error(), "forbidden") {
				t.Errorf("%s (%s): expected policy rejection, got %v", arg, context, err)
			}
		}
	}
	if _, err := CLIArguments("--timeout 1", "args"); err == nil {
		t.Fatal("removed timeout alias accepted")
	}
}

// tool/check_byedpi.sh supplies the exact pinned upstream source and host binary.
func TestByeDPIPinnedOptionContract(t *testing.T) {
	source := os.Getenv("BYEDPI_TEST_SOURCE")
	if source == "" {
		t.Skip("run tool/check_byedpi.sh for the pinned runtime contract")
	}
	body, err := os.ReadFile(filepath.Join(source, "main.c"))
	if err != nil {
		t.Fatal(err)
	}
	table := regexp.MustCompile(`(?s)const struct option options\[\] = \{(.*?)\n\};`).FindSubmatch(body)
	if len(table) != 2 {
		t.Fatal("upstream option table not found")
	}
	entries := regexp.MustCompile(`\{"([a-z0-9-]+)",\s*([01]),\s*0,\s*'(.)'\}`).FindAllSubmatch(table[1], -1)
	options := map[string]cliOption{}
	for _, option := range cliOptions {
		options[option.Long] = option
	}
	for _, entry := range entries {
		name := string(entry[1])
		option, ok := options[name]
		if !ok {
			t.Errorf("upstream option missing from policy: %s", name)
			continue
		}
		if option.Short != string(entry[3]) || (option.Kind != "none") != (string(entry[2]) == "1") {
			t.Errorf("option contract differs: %s", name)
		}
		delete(options, name)
	}
	for name := range options {
		t.Errorf("policy option absent upstream: %s", name)
	}
}

func TestByeDPIPinnedRuntimeStrategies(t *testing.T) {
	binary := os.Getenv("BYEDPI_TEST_BINARY")
	if binary == "" {
		t.Skip("run tool/check_byedpi.sh for real runtime strategy checks")
	}
	for i, strategy := range byeDPITestStrategies() {
		args, err := CLIArguments(strategy, "strategy")
		if err != nil {
			t.Fatal(err)
		}
		listener, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		address := listener.Addr().String()
		_, port, _ := net.SplitHostPort(address)
		listener.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		cmd := exec.CommandContext(ctx, binary, append([]string{"--ip", "127.0.0.1", "--port", port}, args...)...)
		var output bytes.Buffer
		cmd.Stdout = &output
		cmd.Stderr = &output
		if err := cmd.Start(); err != nil {
			cancel()
			t.Fatal(err)
		}
		var conn net.Conn
		for ctx.Err() == nil {
			conn, err = net.DialTimeout("tcp4", address, 50*time.Millisecond)
			if err == nil {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		if err == nil {
			conn.SetDeadline(time.Now().Add(time.Second))
			_, err = conn.Write([]byte{5, 1, 0})
			if err == nil {
				response := make([]byte, 2)
				_, err = io.ReadFull(conn, response)
				if err == nil && !bytes.Equal(response, []byte{5, 0}) {
					t.Errorf("strategy %d: bad SOCKS response %v", i, response)
				}
			}
			conn.Close()
		}
		cancel()
		cmd.Wait()
		if err != nil {
			t.Fatalf("strategy %d: %v\n%s", i, err, output.String())
		}
	}
}
