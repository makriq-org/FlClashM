//go:build !cgo

package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strconv"
	"sync"
	"time"
)

var conn net.Conn
var connMu sync.Mutex

func (result ActionResult) send() {
	data, err := result.Json()
	if err != nil {
		return
	}
	send(data)
}

func sendMessage(message Message) {
	result := ActionResult{
		Method: messageMethod,
		Data:   message,
	}
	result.send()
}

func send(data []byte) {
	connMu.Lock()
	defer connMu.Unlock()
	if conn == nil {
		return
	}
	_, _ = conn.Write(append(data, []byte("\n")...))
}

func startServer(arg string) {

	_, numErr := strconv.Atoi(arg)

	var c net.Conn
	var err error
	if numErr != nil {
		c, err = net.Dial("unix", arg)
	} else {
		c, err = net.Dial("tcp", fmt.Sprintf("127.0.0.1:%s", arg))
	}
	if err != nil {
		fmt.Printf("startServer: connection failed: %v\n", err)
		return
	}

	reader := bufio.NewReader(c)
	if token := os.Getenv("FLCLASHM_CONTROL_TOKEN"); token != "" {
		if err := authenticateControlConnection(c, reader, token); err != nil {
			_ = c.Close()
			return
		}
	}
	connMu.Lock()
	conn = c
	connMu.Unlock()

	defer func() {
		handleShutdown()
		connMu.Lock()
		if conn != nil {
			_ = conn.Close()
			conn = nil
		}
		connMu.Unlock()
	}()

	for {
		data, err := reader.ReadString('\n')
		if err != nil {
			return
		}
		var action = &Action{}

		err = json.Unmarshal([]byte(data), action)

		if err != nil {
			fmt.Printf("startServer: invalid action json: %v\n", err)
			continue
		}

		result := ActionResult{
			Id:     action.Id,
			Method: action.Method,
		}

		go handleAction(action, result)
	}
}

func nextHandle(action *Action, result ActionResult) bool {
	return false
}

func controlProof(token, role, nonce string) string {
	mac := hmac.New(sha256.New, []byte(token))
	_, _ = mac.Write([]byte(role + ":" + nonce))
	return hex.EncodeToString(mac.Sum(nil))
}

func authenticateControlConnection(c net.Conn, reader *bufio.Reader, token string) error {
	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		return err
	}
	nonce := hex.EncodeToString(nonceBytes)
	hello, _ := json.Marshal(map[string]string{"nonce": nonce, "proof": controlProof(token, "core/v1", nonce)})
	if err := c.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		return err
	}
	defer c.SetDeadline(time.Time{})
	if _, err := c.Write(append(hello, '\n')); err != nil {
		return err
	}
	line, err := reader.ReadSlice('\n')
	if err != nil {
		return err
	}
	var ack struct {
		Proof string `json:"proof"`
	}
	if err := json.Unmarshal(line, &ack); err != nil {
		return err
	}
	actual, err := hex.DecodeString(ack.Proof)
	if err != nil {
		return err
	}
	expected, _ := hex.DecodeString(controlProof(token, "gui/v1", nonce))
	if !hmac.Equal(actual, expected) {
		return fmt.Errorf("GUI control proof is invalid")
	}
	return nil
}
