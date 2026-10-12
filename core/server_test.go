//go:build !cgo

package main

import (
	"bufio"
	"encoding/json"
	"net"
	"strings"
	"testing"
)

func TestControlHandshakeRequiresGUIProofAndNeverSendsToken(t *testing.T) {
	for _, valid := range []bool{true, false} {
		server, client := net.Pipe()
		result := make(chan error, 1)
		token := strings.Repeat("a", 64)
		go func() { result <- authenticateControlConnection(server, bufio.NewReader(server), token) }()
		line, err := bufio.NewReader(client).ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(line, token) {
			t.Fatal("control token leaked through TCP")
		}
		var hello map[string]string
		if err := json.Unmarshal([]byte(line), &hello); err != nil {
			t.Fatal(err)
		}
		if hello["proof"] != controlProof(token, "core/v1", hello["nonce"]) {
			t.Fatal("invalid core proof")
		}
		proof := controlProof(token, "gui/v1", hello["nonce"])
		if !valid {
			proof = hello["proof"]
		}
		ack, _ := json.Marshal(map[string]string{"proof": proof})
		if _, err := client.Write(append(ack, '\n')); err != nil {
			t.Fatal(err)
		}
		if err := <-result; (err == nil) != valid {
			t.Fatalf("valid=%v: %v", valid, err)
		}
		_ = server.Close()
		_ = client.Close()
	}
}
