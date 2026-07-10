//go:build android && cgo

package main

import "C"
import (
	"context"
	"core/platform"
	"core/state"
	t "core/tun"
	"encoding/json"
	"errors"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"golang.org/x/sync/semaphore"
	"net"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

type TunHandler struct {
	listener *sing_tun.Listener
	callback unsafe.Pointer

	limit *semaphore.Weighted
}

func (t *TunHandler) close() {
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
	removeTunHook()
	if t.listener != nil {
		_ = t.listener.Close()
	}
	if drained {
		if t.callback != nil {
			releaseObject(t.callback)
		}
		t.callback = nil
		t.listener = nil
	}
	// Timeout path: intentionally leave t.callback/t.listener intact. An in-flight
	// Protect/ResolveProcess (still holding a permit, already past its nil-guard) may
	// read t.callback; writing nil here would race and could hand a null jobject to
	// the JVM. The global ref is deliberately leaked (not released) so it stays valid.
}

func (t *TunHandler) handleProtect(fd int) {
	_ = t.limit.Acquire(context.Background(), 1)
	defer t.limit.Release(1)

	if t.listener == nil {
		return
	}

	Protect(t.callback, fd)
}

func (t *TunHandler) handleResolveProcess(source, target net.Addr) string {
	_ = t.limit.Acquire(context.Background(), 1)
	defer t.limit.Release(1)

	if t.listener == nil {
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
	if version < 29 {
		uid = platform.QuerySocketUidFromProcFs(source, target)
	}
	return ResolveProcess(t.callback, protocol, source.String(), target.String(), uid)
}

var (
	tunLock    sync.Mutex
	runTime    *time.Time
	errBlocked = errors.New("blocked")
	tunHandler *TunHandler
)

func handleStopTun() {
	tunLock.Lock()
	defer tunLock.Unlock()
	runTime = nil
	if tunHandler != nil {
		tunHandler.close()
	}
}

func handleStartTun(fd int, callback unsafe.Pointer) bool {
	handleStopTun()
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
		if callback != nil {
			releaseObject(callback)
		}
		return false
	}
	tunCfg := currentConfig.General.Tun
	runLock.Unlock()
	tunLock.Lock()
	defer tunLock.Unlock()
	now := time.Now()
	runTime = &now
	if fd != 0 {
		tunHandler = &TunHandler{
			callback: callback,
			limit:    semaphore.NewWeighted(4),
		}
		initTunHook()
		tunListener, err := t.Start(fd, tunCfg)
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
			if tunHandler != nil {
				releaseObject(tunHandler.callback)
				tunHandler = nil
			}
			return false
		}
		if tunListener != nil {
			log.Infoln("TUN address: %v", tunListener.Address())
			tunHandler.listener = tunListener
		} else {
			removeTunHook()
			if tunHandler != nil {
				releaseObject(tunHandler.callback)
				tunHandler = nil
			}
			return false
		}
	} else if callback != nil {
		releaseObject(callback)
	}
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

func initTunHook() {
	dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
		if platform.ShouldBlockConnection() {
			return errBlocked
		}
		return conn.Control(func(fd uintptr) {
			tunHandler.handleProtect(int(fd))
		})
	}
	process.DefaultPackageNameResolver = func(metadata *constant.Metadata) (string, error) {
		src, dst := metadata.RawSrcAddr, metadata.RawDstAddr
		if src == nil || dst == nil {
			return "", process.ErrInvalidNetwork
		}
		return tunHandler.handleResolveProcess(src, dst), nil
	}
}

func removeTunHook() {
	dialer.DefaultSocketHook = nil
	process.DefaultPackageNameResolver = nil
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
		runLock.Lock()
		defer runLock.Unlock()
		resolver.ResetConnection()
		closeConnections()
		log.Infoln("[Network] connections reset after network change")
	}()
}
