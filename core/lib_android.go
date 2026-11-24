//go:build android && cgo

package main

import "C"
import (
	"context"
	"core/isolation"
	"core/platform"
	"core/state"
	t "core/tun"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	M "github.com/metacubex/sing/common/metadata"
	"golang.org/x/sync/semaphore"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

type TunHandler struct {
	listener *sing_tun.Listener
	callback unsafe.Pointer

	limit  *semaphore.Weighted
	closed atomic.Bool
}

func (t *TunHandler) close() {
	t.closed.Store(true)
	activeTunHandler.CompareAndSwap(t, nil)
	// Bound the drain. handleProtect/handleResolveProcess hold this semaphore while
	// calling into the JVM (Binder), which can wedge under system pressure; close()
	// runs under tunLock, so an unbounded Acquire here would block stop AND the next
	// start/getRunTime forever. On timeout, skip releaseObject and leak the callback
	// global ref rather than risk a use-after-free on an in-flight Protect call.
	// Only Release what was actually acquired (a deferred Release after a failed
	// Acquire would drive the semaphore negative and panic).
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	drained := t.limit.Acquire(ctx, 4) == nil
	if drained {
		defer t.limit.Release(4)
	} else {
		log.Warnln("TunHandler.close: drain timed out, leaking callback global ref to avoid use-after-free")
	}
	// Capture and clear the listener BEFORE closing it. On the drain-timeout path
	// the handler is otherwise left intact, so without clearing here the next
	// handleStopTun would call Close() a second time on the same (already closed)
	// listener. In-flight Protect/ResolveProcess don't read t.listener after their
	// nil-guard, so clearing it now is safe for them.
	l := t.listener
	t.listener = nil
	if l != nil {
		_ = l.Close()
	}
	if drained {
		if t.callback != nil {
			releaseObject(t.callback)
		}
		t.callback = nil
	}
	// Timeout path: t.callback is intentionally left intact (and its global ref
	// leaked, not released). An in-flight Protect/ResolveProcess still holding a
	// permit is already past its t.listener nil-guard and may read t.callback;
	// writing nil here would race and could hand a null jobject to the JVM.
}

func (t *TunHandler) handleProtect(fd int) bool {
	_ = t.limit.Acquire(context.Background(), 1)
	defer t.limit.Release(1)

	if t.closed.Load() {
		return false
	}

	Protect(t.callback, fd)
	return true
}

func (t *TunHandler) handleResolveProcess(source, target net.Addr) string {
	_ = t.limit.Acquire(context.Background(), 1)
	defer t.limit.Release(1)

	if t.closed.Load() {
		return ""
	}
	var protocol int
	uid := -1
	switch source.Network() {
	case "udp", "udp4", "udp6":
		protocol = syscall.IPPROTO_UDP
	case "tcp", "tcp4", "tcp6":
		protocol = syscall.IPPROTO_TCP
	}
	if version.Load() < 29 {
		uid = platform.QuerySocketUidFromProcFs(source, target)
	}
	return ResolveProcess(t.callback, protocol, source.String(), target.String(), uid)
}

// ownerAnswer is the JSON contract of the Android connection-owner callback.
type ownerAnswer struct {
	UID      int      `json:"uid"`
	Packages []string `json:"packages"`
	Unknown  bool     `json:"unknown"`
	Error    string   `json:"error"`
}

// tunOwnerResolver attributes one flow through the same JNI callback the
// process-aware rules use, but returns the UID and every shared package instead
// of a display name.
type tunOwnerResolver struct{ handler *TunHandler }

func (r tunOwnerResolver) Resolve(protocol string, source, destination netip.AddrPort) (isolation.Owner, error) {
	handler := r.handler
	if handler == nil {
		return isolation.Owner{}, errors.New("tun owner resolver is not running")
	}
	return handler.resolveOwner(protocol, source, destination)
}

func (t *TunHandler) resolveOwner(protocol string, source, destination netip.AddrPort) (isolation.Owner, error) {
	_ = t.limit.Acquire(context.Background(), 1)
	defer t.limit.Release(1)
	if t.closed.Load() {
		return isolation.Owner{}, errors.New("tun is stopping")
	}
	ipProtocol := 0
	switch protocol {
	case "tcp":
		ipProtocol = syscall.IPPROTO_TCP
	case "udp":
		ipProtocol = syscall.IPPROTO_UDP
	default:
		// ICMP has no per-socket Android API; the guard treats it as unknown.
		return isolation.Owner{}, nil
	}
	uid := -1
	if version.Load() < 29 {
		uid = platform.QuerySocketUidFromProcFs(socketAddr(protocol, source), socketAddr(protocol, destination))
	}
	raw := ResolveOwner(t.callback, ipProtocol, source.String(), destination.String(), uid)
	if raw == "" {
		return isolation.Owner{}, errors.New("connection owner lookup is unavailable")
	}
	var answer ownerAnswer
	if err := json.Unmarshal([]byte(raw), &answer); err != nil {
		return isolation.Owner{}, fmt.Errorf("connection owner answer: %w", err)
	}
	if answer.Error != "" {
		return isolation.Owner{}, errors.New(answer.Error)
	}
	if answer.Unknown || answer.UID < 0 {
		return isolation.Owner{Known: false}, nil
	}
	return isolation.Owner{Known: true, UID: answer.UID, Packages: answer.Packages}, nil
}

func socketAddr(protocol string, address netip.AddrPort) net.Addr {
	ip := net.IP(address.Addr().AsSlice())
	if protocol == "tcp" {
		return &net.TCPAddr{IP: ip, Port: int(address.Port())}
	}
	return &net.UDPAddr{IP: ip, Port: int(address.Port())}
}

func isolationCapability() string {
	callbacksMu.RLock()
	available := globalCallbacks.resolveOwnerFunc != nil
	callbacksMu.RUnlock()
	if !available {
		return "none"
	}
	if version.Load() < 29 {
		return "procfs"
	}
	return "full"
}

// installIsolationGuard creates the policy for a new tunnel before the first
// packet is read. A failed start clears it again.
func installIsolationGuard(handler *TunHandler) {
	runLock.Lock()
	policy := isolationPolicy()
	runLock.Unlock()
	guard := isolation.NewGuard(policy, tunOwnerResolver{handler: handler})
	guard.SetCapability(isolationCapability())
	activeIsolationGuard.Store(guard)
}

func clearIsolationGuard() {
	activeIsolationGuard.Store(nil)
}

// checkIsolation is the single mihomo hook entry point. It reads the atomic
// guard so stopping a tunnel cannot race the packet path.
func checkIsolation(protocol string, source, destination M.Socksaddr) bool {
	guard := activeIsolationGuard.Load()
	if guard == nil {
		return true
	}
	return guard.Check(protocol, source.AddrPort(), destination.AddrPort())
}

var (
	activeTunHandler atomic.Pointer[TunHandler]
	installTunHooks  sync.Once
	tunLock          sync.Mutex
	runTime          *time.Time
	errBlocked       = errors.New("blocked")
	tunHandler       *TunHandler
)

func handleStopTun() {
	tunLock.Lock()
	defer tunLock.Unlock()
	runTime = nil
	tunUp.Store(false)
	clearIsolationGuard()
	if tunHandler != nil {
		tunHandler.close()
		tunHandler = nil
	}
}

func handleStartTun(fd int, callback unsafe.Pointer) bool {
	tunLock.Lock()
	defer tunLock.Unlock()
	runTime = nil
	tunUp.Store(false)
	previous := tunHandler
	tunHandler = nil
	if fd != 0 {
		tunHandler = &TunHandler{callback: callback, limit: semaphore.NewWeighted(4)}
		// Android routes already exist: publish protection before waiting for
		// config or draining the previous JNI callback generation.
		initTunHook()
	}
	if previous != nil {
		previous.close()
	}
	runLock.Lock()
	if currentConfig == nil {
		runLock.Unlock()
		// The Kotlin caller now only closes the fd when the core was never reached
		// (loader.start threw before handing it off). Once startTun is entered the
		// core owns it; the fd was never wrapped by sing-tun on this path, so close
		// it here to avoid leaking it.
		if fd != 0 {
			_ = syscall.Close(fd)
		}
		if tunHandler != nil {
			tunHandler.close()
			tunHandler = nil
		} else if callback != nil {
			releaseObject(callback)
		}
		return false
	}
	tunCfg := currentConfig.General.Tun
	runLock.Unlock()
	// Android 10 and earlier reject SO_BINDTODEVICE for an unprivileged app.
	// The system and mixed stacks require it to route TCP back into the TUN.
	if version.Load() <= 29 && (tunCfg.Stack == constant.TunSystem || tunCfg.Stack == constant.TunMixed) {
		log.Warnln("Android API %d requires gVisor TUN stack", version.Load())
		tunCfg.Stack = constant.TunGvisor
	}
	if fd != 0 {
		installIsolationGuard(tunHandler)
		tunListener, err := t.Start(fd, tunCfg, trafficTunnel)
		if err != nil {
			log.Errorln("handleStartTun: t.Start failed: %v", err)
			// fd ownership: the Kotlin caller no longer closes the fd on a false
			// return (it sets fdHandedToCore=true before Core.startTun). Once startTun
			// is entered the fd belongs to sing-tun, which closes it exactly once via
			// Listener.Close on a post-wrap failure (NewStack/tunStack.Start). Do NOT
			// add an unconditional syscall.Close(fd) here — that would double-close a
			// number sing-tun may have already closed/reused. (A rare pre-wrap sing-tun
			// failure would leak this one fd; accepted over a double-close.)
			removeTunHook()
			clearIsolationGuard()
			if tunHandler != nil {
				tunHandler.close()
				tunHandler = nil
			}
			return false
		}
		if tunListener != nil {
			log.Infoln("TUN address: %v", tunListener.Address())
			tunHandler.listener = tunListener
		} else {
			removeTunHook()
			clearIsolationGuard()
			if tunHandler != nil {
				tunHandler.close()
				tunHandler = nil
			}
			return false
		}
	} else if callback != nil {
		releaseObject(callback)
	}
	// The TUN is up. A headless tile/boot start reaches here without ever calling
	// startListener (so isRunning stays false); tunUp lets the connections "Journal"
	// forwarder run for this tunnel once the UI is foregrounded (see hub.go).
	now := time.Now()
	runTime = &now
	tunUp.Store(true)
	return true
}

func handleGetRunTime() string {
	tunLock.Lock()
	defer tunLock.Unlock()
	if runTime == nil {
		return ""
	}
	return strconv.FormatInt(runTime.UnixMilli(), 10)
}

// Hooks remain installed: mihomo may load a hook before stop and call it later.
func initTunHook() {
	installTunHooks.Do(func() {
		sing_tun.ConnectionGuard = checkIsolation
		dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
			if platform.ShouldBlockConnection() {
				return errBlocked
			}
			return conn.Control(func(fd uintptr) {
				for h := activeTunHandler.Load(); h != nil; {
					if h.handleProtect(int(fd)) {
						return
					}
					next := activeTunHandler.Load()
					if next == h {
						return
					}
					h = next
				}
			})
		}
		process.DefaultPackageNameResolver = func(metadata *constant.Metadata) (string, error) {
			src, dst := metadata.RawSrcAddr, metadata.RawDstAddr
			if src == nil || dst == nil {
				return "", process.ErrInvalidNetwork
			}
			if h := activeTunHandler.Load(); h != nil {
				return h.handleResolveProcess(src, dst), nil
			}
			return "", nil
		}
	})
	activeTunHandler.Store(tunHandler)
}

func removeTunHook() {
	activeTunHandler.CompareAndSwap(tunHandler, nil)
}

func handleGetAndroidVpnOptions() string {
	runLock.Lock()
	defer runLock.Unlock()
	if currentConfig == nil {
		return ""
	}
	mixedPort := currentConfig.General.MixedPort
	// With the HTTP/SOCKS inbound disabled there is no proxy endpoint to
	// advertise via VpnService.setHttpProxy — force it off so Android doesn't
	// end up with a ProxyInfo pointing at 127.0.0.1:0.
	systemProxy := state.CurrentState.VpnProps.SystemProxy && mixedPort != 0
	options := state.AndroidVpnOptions{
		Enable:           state.CurrentState.VpnProps.Enable,
		Port:             mixedPort,
		Ipv4Address:      state.DefaultIpv4Address,
		Ipv6Address:      state.GetIpv6Address(),
		AccessControl:    state.CurrentState.VpnProps.AccessControl,
		SystemProxy:      systemProxy,
		AllowBypass:      state.CurrentState.VpnProps.AllowBypass,
		RouteAddress:     currentConfig.General.Tun.RouteAddress,
		BypassDomain:     state.CurrentState.BypassDomain,
		DnsServerAddress: state.GetDnsServerAddress(),
		IncludePackage:   currentConfig.General.Tun.IncludePackage,
		ExcludePackage:   currentConfig.General.Tun.ExcludePackage,
		AppIsolation:     isolationOptions(isolationCapability()),
	}
	data, err := json.Marshal(options)
	if err != nil {
		log.Errorln("Error: %v", err)
		return ""
	}
	return string(data)
}

func handleUpdateDns(value string) {
	var dnsServers []string
	if err := json.Unmarshal([]byte(value), &dnsServers); err != nil {
		// Fallback to comma-split for backward compatibility
		dnsServers = strings.Split(value, ",")
	}
	dnsServers = normalizeSystemDNSServers(dnsServers)
	go func() {
		log.Infoln("[DNS] updateDns %s", value)
		dns.UpdateSystemDNS(dnsServers)
		dns.FlushCacheWithDefaultResolver()
	}()
}

func normalizeSystemDNSServers(dnsServers []string) []string {
	normalized := make([]string, 0, len(dnsServers))
	for _, server := range dnsServers {
		server = strings.TrimSpace(server)
		if server == "" {
			continue
		}
		if _, _, err := net.SplitHostPort(server); err == nil {
			normalized = append(normalized, server)
			continue
		}
		normalized = append(normalized, net.JoinHostPort(server, "53"))
	}
	return normalized
}

func handleGetCurrentProfileName() string {
	runLock.Lock()
	defer runLock.Unlock()
	if state.CurrentState == nil {
		return ""
	}
	return state.CurrentState.CurrentProfileName
}

func nextHandle(action *Action, result ActionResult) bool {
	switch action.Method {
	case getAndroidVpnOptionsMethod:
		result.success(handleGetAndroidVpnOptions())
		return true
	case updateDnsMethod:
		data, ok := action.Data.(string)
		if !ok {
			result.error("invalid data type")
			return true
		}
		handleUpdateDns(data)
		result.success(true)
		return true
	case getRunTimeMethod:
		result.success(handleGetRunTime())
		return true
	case getCurrentProfileNameMethod:
		result.success(handleGetCurrentProfileName())
		return true
	}
	return false
}

//export quickStart
func quickStart(initParamsChar *C.char, paramsChar *C.char, stateParamsChar *C.char, callback unsafe.Pointer) {
	paramsString := C.GoString(initParamsChar)
	bytes := []byte(C.GoString(paramsChar))
	stateParams := C.GoString(stateParamsChar)
	go func() {
		// Callback lifetime is managed on the JVM side: invoke_callback_impl deletes
		// the global ref after delivering onResult. Every path below fires the
		// callback exactly once.
		if !handleInitClash(paramsString) {
			invokeCallback(callback, "init error")
			return
		}
		handleSetState(stateParams)
		invokeCallback(callback, handleSetupConfig(bytes))
	}()
}

//export startTUN
func startTUN(fd C.int, callback unsafe.Pointer) bool {
	return handleStartTun(int(fd), callback)
}

//export getRunTime
func getRunTime() *C.char {
	return C.CString(handleGetRunTime())
}

//export stopTun
func stopTun() {
	handleStopTun()
}

//export getCurrentProfileName
func getCurrentProfileName() *C.char {
	return C.CString(handleGetCurrentProfileName())
}

//export getAndroidVpnOptions
func getAndroidVpnOptions() *C.char {
	return C.CString(handleGetAndroidVpnOptions())
}

//export setState
func setState(s *C.char) {
	paramsString := C.GoString(s)
	handleSetState(paramsString)
}

//export updateDns
func updateDns(s *C.char) {
	dnsList := C.GoString(s)
	handleUpdateDns(dnsList)
}

//export resetConnections
func resetConnections() {
	go func() {
		handleResetConnections()
		handleCloseConnections()
		log.Infoln("[Network] connections reset after network change")
	}()
}
