package main

import (
	"io"
	"net"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func TestStoppingClosesTheConnectionsAlreadyOpen(t *testing.T) {
	local, remote := net.Pipe()
	t.Cleanup(func() { _ = remote.Close() })
	go func() { _, _ = io.Copy(io.Discard, remote) }()
	direct := outbound.NewDirectWithOption(outbound.DirectOption{Name: "DIRECT"})
	tracker := statistic.NewTCPTracker(
		outbound.NewConn(local, direct),
		statistic.DefaultManager,
		&constant.Metadata{},
		nil,
		0,
		0,
		true,
	)
	id := tracker.ID()
	if statistic.DefaultManager.Get(id) == nil {
		t.Fatal("the connection was not tracked")
	}

	handleStopListener()

	if statistic.DefaultManager.Get(id) != nil {
		t.Error("the connection outlived the stop")
	}
	if _, err := local.Write([]byte("x")); err == nil {
		t.Error("the connection still carries traffic after the stop")
	}
}

type dialingTunnel struct {
	constant.Tunnel
	entered chan struct{}
}

// Stands in for a connection whose upstream dial is still out: it holds the
// client's side until something closes it.
func (t dialingTunnel) HandleTCPConn(conn net.Conn, _ *constant.Metadata) {
	close(t.entered)
	_, _ = io.Copy(io.Discard, conn)
}

func TestStoppingClosesAConnectionStillDialingOut(t *testing.T) {
	isRunning = true
	listenersAccepting.Store(true)
	local, remote := net.Pipe()
	t.Cleanup(func() { _ = remote.Close() })
	dialing := dialingTunnel{entered: make(chan struct{})}
	handled := make(chan struct{})
	go func() {
		accountingTunnel{dialing}.HandleTCPConn(local, &constant.Metadata{})
		close(handled)
	}()
	<-dialing.entered

	handleStopListener()

	select {
	case <-handled:
	case <-time.After(5 * time.Second):
		t.Fatal("a connection accepted before the stop is still open")
	}
}

func TestAConnectionArrivingAfterTheStopIsTurnedAway(t *testing.T) {
	handleStopListener()
	local, remote := net.Pipe()
	t.Cleanup(func() { _ = remote.Close() })
	dialing := dialingTunnel{entered: make(chan struct{})}
	returned := make(chan struct{})
	go func() {
		accountingTunnel{dialing}.HandleTCPConn(local, &constant.Metadata{Type: constant.SOCKS5})
		close(returned)
	}()

	select {
	case <-returned:
	case <-dialing.entered:
		t.Fatal("a connection reached the tunnel after the stop")
	case <-time.After(5 * time.Second):
		t.Fatal("handling a connection after the stop never returned")
	}
	if _, err := local.Write([]byte("x")); err == nil {
		t.Error("a connection turned away after the stop is still open")
	}
}
