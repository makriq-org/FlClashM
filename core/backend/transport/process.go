// Package transport implements external-process mechanisms for every supported
// host. Runtime policy and mutable business state remain in RuntimeCoordinator.
package transport

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"core/backend"
	"core/backend/compile"
)

type process struct {
	command  *exec.Cmd
	graceful bool
	done     chan struct{}
	exitErr  error // Written before closing done; readers synchronize on done.
}
type ProcessAdapter struct {
	epoch       uint64
	starting    map[string]bool
	versions    map[string]uint64
	Home        string
	ABI         string
	Executables map[string]string
	PhysicalDNS func(context.Context) ([]netip.Addr, error)
	// ProbeRequest is supplied by the host's HTTP/SOCKS mechanism.
	ProbeRequest func(context.Context, backend.NodeProbe) (bool, error)
	// Log is a trusted host sink. The host must redact output before persistence.
	// A bounded queue isolates process I/O and lifecycle from slow diagnostics.
	Log       func(kind, line string)
	mu        sync.Mutex
	processes map[string]*process
}

var nodeID = regexp.MustCompile(`^(naiveproxy|olcrtc|byedpi|stormdns)-[0-9a-f]{32}(?:-probe-[0-9a-f]{32})?$`)

func (a *ProcessAdapter) directory(node backend.NodePlan) (string, error) {
	if !nodeID.MatchString(node.ID) || !strings.HasPrefix(node.ID, node.Type+"-") {
		return "", errors.New("invalid node identity")
	}
	switch a.ABI {
	case "arm64-v8a", "armeabi-v7a", "x86_64", "x86", "host":
	default:
		return "", errors.New("unsupported host ABI")
	}
	if node.Host != "127.0.0.1" || node.Port < 1 || node.Port > 65535 {
		return "", errors.New("external listener must be loopback")
	}
	return filepath.Join(a.Home, "runtimes", node.Type, a.ABI, "nodes", node.ID), nil
}
func (a *ProcessAdapter) Prepare(ctx context.Context, node backend.NodePlan) error {
	directory, err := a.directory(node)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	prefix := "built-in-proxies/" + node.Type + "/" + node.ID + "/"
	allowed := map[string]bool{"config.json": true, "config.yaml": true, "client_config.toml": true, "client_resolvers.template": true}
	for key, body := range node.Files {
		if err = ctx.Err(); err != nil {
			return err
		}
		name, ok := strings.CutPrefix(key, prefix)
		if !ok || !allowed[name] || len(body) > 16<<20 {
			return errors.New("invalid compiler artifact path or size")
		}
		if err = writePrivate(filepath.Join(directory, name), []byte(body)); err != nil {
			return err
		}
	}

	return ctx.Err()
}
func (a *ProcessAdapter) renderDNS(ctx context.Context, node backend.NodePlan, directory string) error {
	var addresses []netip.Addr
	if a.PhysicalDNS != nil && node.Metadata["depends-on-system-dns"] == "true" {
		var err error
		addresses, err = a.PhysicalDNS(ctx)
		if err != nil {
			return err
		}
	}
	dns := []string{}
	seen := map[netip.Addr]bool{}
	for _, ip := range addresses {
		ip = ip.Unmap()
		if !ip.IsValid() || ip.Zone() != "" || ip.IsUnspecified() || ip.IsMulticast() || ip.IsLoopback() || seen[ip] {
			continue
		}
		seen[ip] = true
		dns = append(dns, ip.String())
		if len(dns) >= 16 {
			break
		}
	}
	if node.Type == "olcrtc" {
		name := filepath.Join(directory, "config.yaml")
		raw, err := os.ReadFile(name)
		if err != nil {
			return err
		}
		if !strings.Contains(string(raw), "@flclashm-system-dns@") {
			return nil
		}
		if len(dns) == 0 {
			return errors.New("physical DNS is unavailable")
		}
		native := map[string]any{}
		if json.Unmarshal(raw, &native) != nil {
			return errors.New("invalid olcrtc artifact")
		}
		network, ok := native["net"].(map[string]any)
		if !ok {
			return errors.New("missing olcrtc network configuration")
		}
		network["dns"] = net.JoinHostPort(dns[0], "53")
		rendered, err := json.Marshal(native)
		if err != nil {
			return err
		}
		return writePrivate(name, rendered)
	}
	template, err := os.ReadFile(filepath.Join(directory, "client_resolvers.template"))
	if err != nil {
		return err
	}
	lines := []string{}
	for _, line := range strings.Split(string(template), "\n") {
		if line == "# @flclashm:system-dns" {
			if len(dns) == 0 {
				return errors.New("physical DNS is unavailable")
			}
			lines = append(lines, dns...)
		} else if strings.TrimSpace(line) != "" {
			lines = append(lines, line)
		}
	}
	fingerprint := node.Metadata["cache-fingerprint"]
	if len(fingerprint) != 16 || strings.Trim(fingerprint, "0123456789abcdef") != "" {
		return errors.New("invalid StormDNS cache identity")
	}
	// Physical resolver changes invalidate the MTU cache as in the legacy host.
	digest := sha256.Sum256([]byte(strings.Join(lines, "\n")))
	digestText := hex.EncodeToString(digest[:])
	cacheDirectory := filepath.Join(directory, "cache", fingerprint)
	marker := filepath.Join(cacheDirectory, ".resolver-digest")
	old, readErr := os.ReadFile(marker)
	changed := readErr == nil && string(old) != digestText
	if os.IsNotExist(readErr) {
		legacy, _ := os.ReadFile(filepath.Join(directory, "client_resolvers.txt"))
		changed = len(legacy) > 0 && string(legacy) != strings.Join(lines, "\n")+"\n"
	}
	if changed {
		if err = os.RemoveAll(cacheDirectory); err != nil {
			return err
		}
	}
	if err = os.MkdirAll(cacheDirectory, 0700); err != nil {
		return err
	}

	if err = writePrivate(filepath.Join(directory, "client_resolvers.txt"), []byte(strings.Join(lines, "\n")+"\n")); err != nil {
		return err
	}
	return writePrivate(marker, []byte(digestText))
}
func (a *ProcessAdapter) Start(ctx context.Context, launch backend.NodeLaunch) error {
	node := launch.Node
	a.mu.Lock()
	epoch, version := a.epoch, a.versions[node.ID]
	if a.starting[node.ID] {
		a.mu.Unlock()
		return errors.New("node process start is already in progress")
	}
	if p := a.processes[node.ID]; p != nil {
		select {
		case <-p.done:
			delete(a.processes, node.ID)
		default:
			a.mu.Unlock()
			return errors.New("node process already exists")
		}
	}
	if a.starting == nil {
		a.starting = map[string]bool{}
	}
	a.starting[node.ID] = true
	a.mu.Unlock()
	defer func() { a.mu.Lock(); delete(a.starting, node.ID); a.mu.Unlock() }()
	directory, err := a.directory(node)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	executable := a.Executables[node.Type]
	if executable == "" || !filepath.IsAbs(executable) {
		return errors.New("trusted transport executable is unavailable")
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	port := node.Port
	if launch.Port != 0 {
		port = launch.Port
	}
	// Do not report readiness against a socket owned by another installation.
	// The actual transport binds after this probe; namespace allocation keeps
	// application variants apart and process observation still fences early exit.
	listener, err := net.Listen("tcp", net.JoinHostPort(node.Host, strconv.Itoa(port)))
	if err != nil {
		return fmt.Errorf("external listener port %d is unavailable: %w", port, err)
	}
	_ = listener.Close()
	if node.Type == "stormdns" || node.Type == "olcrtc" {
		if err = a.renderDNS(ctx, node, directory); err != nil {
			return err
		}
	}
	arguments := []string{}
	switch node.Type {
	case "naiveproxy":
		arguments = []string{filepath.Join(directory, "config.json")}
	case "olcrtc":
		arguments = []string{filepath.Join(directory, "config.yaml")}
	case "stormdns":
		arguments = []string{"-config", filepath.Join(directory, "client_config.toml"), "-resolvers", filepath.Join(directory, "client_resolvers.txt")}
	case "byedpi":
		port := node.Port
		if launch.Port != 0 {
			port = launch.Port
		}
		strategy := launch.Strategy
		if strategy == "" {
			var native struct {
				Args string `json:"args"`
			}
			raw, e := os.ReadFile(filepath.Join(directory, "config.json"))
			if e != nil {
				return e
			}
			if e = json.Unmarshal(raw, &native); e != nil {
				return e
			}
			strategy = native.Args
		}
		strategy = strings.ReplaceAll(strategy, "{sni}", launch.SNI)
		argv, e := compile.CLIArguments(strategy, "args")
		if e != nil {
			return e
		}
		arguments = append([]string{"--ip", "127.0.0.1", "--port", strconv.Itoa(port)}, argv...)
	default:
		return errors.New("unsupported transport")
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.epoch != epoch || a.versions[node.ID] != version {
		return errors.New("process start was fenced")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if p := a.processes[node.ID]; p != nil {
		select {
		case <-p.done:
			delete(a.processes, node.ID)
		default:
			return errors.New("node process already exists")
		}
	}
	command := exec.Command(executable, arguments...)
	command.Dir = directory
	command.Stdin = nil
	output := newProcessOutput(node.Type, a.Log)
	command.Stdout = output
	command.Stderr = output
	p := &process{command: command, graceful: node.Type == "olcrtc", done: make(chan struct{})}
	started := make(chan error, 1)
	pin := bindChildLifetime(command)
	go func() {
		if pin {
			runtime.LockOSThread()
			defer runtime.UnlockOSThread()
		}
		if err := command.Start(); err != nil {
			output.finish(err)
			started <- err
			close(p.done)
			return
		}
		started <- nil
		p.exitErr = command.Wait()
		output.finish(p.exitErr)
		close(p.done)
	}()
	if err = <-started; err != nil {
		return fmt.Errorf("start %s transport: %w", node.Type, err)
	}
	if a.processes == nil {
		a.processes = map[string]*process{}
	}
	a.processes[node.ID] = p

	if err = ctx.Err(); err != nil {
		_ = command.Process.Kill()
		<-p.done
		delete(a.processes, node.ID)
		return err
	}
	return nil
}
func (a *ProcessAdapter) Stop(ctx context.Context, id string) error {
	a.mu.Lock()
	if a.versions == nil {
		a.versions = map[string]uint64{}
	}
	a.versions[id]++
	p := a.processes[id]
	a.mu.Unlock()
	if p == nil {
		return nil
	}
	select {
	case <-p.done:
		a.forgetProcess(id, p)
		return nil
	default:
	}
	// OlcRTC must leave the provider room before a replacement joins it. Killing
	// it outright strands guest participants and stale media subscriptions.
	// Keep the fence bounded and still kill a child that cannot shut down.
	if p.graceful && p.command.Process.Signal(os.Interrupt) == nil {
		timer := time.NewTimer(2 * time.Second)
		defer timer.Stop()
		select {
		case <-p.done:
			a.forgetProcess(id, p)
			return nil
		case <-timer.C:
		case <-ctx.Done():
		}
	}
	err := p.command.Process.Kill()
	if err != nil && !errors.Is(err, os.ErrProcessDone) {
		return err
	}
	select {
	case <-p.done:
		a.forgetProcess(id, p)
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// forgetProcess must not remove a replacement started after the old child exited.
func (a *ProcessAdapter) forgetProcess(id string, p *process) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.processes[id] == p {
		delete(a.processes, id)
	}
}
func (a *ProcessAdapter) StopAll(ctx context.Context) error {
	a.mu.Lock()
	a.epoch++
	ids := make([]string, 0, len(a.processes))
	for id := range a.processes {
		ids = append(ids, id)
	}
	a.mu.Unlock()
	var result error
	for _, id := range ids {
		result = errors.Join(result, a.Stop(ctx, id))
	}
	return result
}
func (a *ProcessAdapter) Observe(ctx context.Context, id string) (backend.Observation, error) {
	if err := ctx.Err(); err != nil {
		return backend.Observation{}, err
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	p := a.processes[id]
	if p == nil {
		return backend.Observation{State: "stopped"}, nil
	}
	select {
	case <-p.done:
		message := "external process exited"
		if p.exitErr != nil {
			message += ": " + p.exitErr.Error()
		}
		return backend.Observation{State: "degraded", Message: message}, nil
	default:
		return backend.Observation{State: "running"}, nil
	}
}
func (a *ProcessAdapter) AllocatePort(ctx context.Context) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port, nil
}
func (a *ProcessAdapter) Probe(ctx context.Context, probe backend.NodeProbe) (bool, error) {
	if a.ProbeRequest == nil {
		return false, errors.New("host probe mechanism is unavailable")
	}
	return a.ProbeRequest(ctx, probe)
}
func writePrivate(name string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(name), ".backend-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	if err == nil {
		err = f.Close()
	}
	if err == nil {
		err = os.Rename(f.Name(), name)
	}
	return err
}

func (a *ProcessAdapter) Listening(ctx context.Context, node backend.NodePlan) (bool, error) {
	if node.Host != "127.0.0.1" || node.Port < 1 || node.Port > 65535 {
		return false, errors.New("invalid listener endpoint")
	}
	connection, err := (&net.Dialer{Timeout: 200 * time.Millisecond}).DialContext(ctx, "tcp", net.JoinHostPort(node.Host, strconv.Itoa(node.Port)))
	if err != nil {
		if ctx.Err() != nil {
			return false, ctx.Err()
		}
		return false, nil
	}
	_ = connection.Close()
	return true, nil
}
