package main

import (
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/constant"
	"net"
	"testing"
)

func namedProxy(name string) constant.Proxy {
	return adapter.NewProxy(outbound.NewDirectWithOption(outbound.DirectOption{Name: name}))
}

func blackHoleServer(t *testing.T) net.Addr {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var connections []net.Conn
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			connections = append(connections, connection)
		}
	}()
	t.Cleanup(func() {
		_ = listener.Close()
		<-done
		for _, connection := range connections {
			_ = connection.Close()
		}
	})
	return listener.Addr()
}
