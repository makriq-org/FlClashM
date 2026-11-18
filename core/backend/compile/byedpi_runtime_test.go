package compile

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
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

func TestByeDPIPinnedRuntimeSOCKSAuthentication(t *testing.T) {
	binary := os.Getenv("BYEDPI_TEST_BINARY")
	if binary == "" {
		t.Skip("run tool/check_byedpi.sh for the pinned runtime contract")
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()

	credentials := filepath.Join(t.TempDir(), "auth.txt")
	username, password := strings.Repeat("u", 255), strings.Repeat("p", 255)
	if err = os.WriteFile(credentials, []byte(username+"\n"+password+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	cmd := exec.CommandContext(ctx, binary, "--ip", "127.0.0.1", "--port", strconv.Itoa(port), "--auth-file", credentials)
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		cancel()
		_ = cmd.Wait()
		if t.Failed() {
			t.Log(output.String())
		}
	}()

	var conn net.Conn
	for ctx.Err() == nil {
		conn, err = net.DialTimeout("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 50*time.Millisecond)
		if err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if conn == nil {
		t.Fatalf("listener did not start: %v", errors.Join(err, ctx.Err()))
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(time.Second))
	unauthenticated, err := net.DialTimeout("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	_ = unauthenticated.SetDeadline(time.Now().Add(time.Second))
	if _, err = unauthenticated.Write([]byte{5, 1, 0}); err != nil {
		unauthenticated.Close()
		t.Fatal(err)
	}
	unauthenticatedResponse := make([]byte, 2)
	if _, err = io.ReadFull(unauthenticated, unauthenticatedResponse); err != nil || !bytes.Equal(unauthenticatedResponse, []byte{5, 255}) {
		unauthenticated.Close()
		t.Fatalf("unauthenticated SOCKS5 was accepted: response=%v err=%v", unauthenticatedResponse, err)
	}
	_ = unauthenticated.Close()
	writePartial := func(part []byte) {
		t.Helper()
		if _, err := conn.Write(part); err != nil {
			t.Fatal(err)
		}
		if err := conn.SetReadDeadline(time.Now().Add(50 * time.Millisecond)); err != nil {
			t.Fatal(err)
		}
		var b [1]byte
		if _, err := conn.Read(b[:]); !errors.Is(err, os.ErrDeadlineExceeded) {
			t.Fatalf("incomplete negotiation should wait for more data, got %v", err)
		}
		if err := conn.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	writePartial([]byte{5})
	writePartial([]byte{1})
	if _, err = conn.Write([]byte{2}); err != nil {
		t.Fatal(err)
	}
	response := make([]byte, 2)
	if _, err = io.ReadFull(conn, response); err != nil || !bytes.Equal(response, []byte{5, 2}) {
		t.Fatalf("SOCKS5 auth method response %v: %v", response, err)
	}
	request := append([]byte{1, byte(len(username))}, username...)
	request = append(request, byte(len(password)))
	request = append(request, password...)
	writePartial(request[:2])
	writePartial(request[2:4])
	writePartial(request[4 : len(request)-2])
	if _, err = conn.Write(request[len(request)-2:]); err != nil {
		t.Fatal(err)
	}
	if _, err = io.ReadFull(conn, response); err != nil || !bytes.Equal(response, []byte{1, 0}) {
		t.Fatalf("RFC 1929 response %v: %v", response, err)
	}
	if _, err = conn.Write([]byte{5, 3, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil {
		t.Fatal(err)
	}
	udpResponse := make([]byte, 10)
	if _, err = io.ReadFull(conn, udpResponse); err != nil || udpResponse[0] != 5 || udpResponse[1] == 0 {
		t.Fatalf("UDP ASSOCIATE was not rejected: response=%v err=%v", udpResponse, err)
	}
}
