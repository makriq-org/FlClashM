package service

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestLinkSessionTokenOriginSingleUseAndClose(t *testing.T) {
	s := linkSession{token: "secret", url: "http://192.168.1.2:1234/secret", expires: time.Now().Add(time.Minute)}
	send := func(path, origin, body string) int {
		r := httptest.NewRequest(http.MethodPost, "http://192.168.1.2:1234"+path, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		r.Header.Set("Origin", origin)
		w := httptest.NewRecorder()
		s.receive(w, r, "secret")
		return w.Code
	}
	if send("/wrong", "", "link=https%3A%2F%2Fexample.org") != 404 {
		t.Fatal("wrong token accepted")
	}
	if send("/secret", "https://attacker.example", "link=https%3A%2F%2Fexample.org") != 403 {
		t.Fatal("cross-origin accepted")
	}
	if send("/secret", "", "link=file%3A%2F%2Fetc%2Fpasswd") != 400 {
		t.Fatal("local file accepted")
	}
	if send("/secret", "", "link=https%3A%2F%2Fexample.org") != 200 || s.state().Link != "https://example.org" {
		t.Fatal("valid link not received")
	}
	if send("/secret", "", "link=https%3A%2F%2Fsecond.example") != 409 {
		t.Fatal("pending link overwritten")
	}
	s.close()
	if s.state().URL != "" || send("/secret", "", "link=https%3A%2F%2Fexample.org") != 404 {
		t.Fatal("closed session remained usable")
	}
	s.token = "expired"
	s.expires = time.Now().Add(-time.Second)
	if s.state().URL != "" || s.token != "" {
		t.Fatal("expired capability retained")
	}
}

func TestLinkSessionListenerClosesAndOldIDCannotCloseReplacement(t *testing.T) {
	app := openTestApp(t, options(t, t.TempDir(), &testEngine{}, make(chan time.Time)))
	first, err := app.startLinkSession()
	if err != nil {
		t.Skipf("no private LAN interface available: %v", err)
	}
	client := &http.Client{Timeout: time.Second, Transport: &http.Transport{}}
	defer client.CloseIdleConnections()
	get := func(address string) error {
		response, err := client.Get(address)
		if err == nil {
			defer response.Body.Close()
			if response.StatusCode != http.StatusOK {
				return fmt.Errorf("HTTP %d", response.StatusCode)
			}
		}
		return err
	}
	if err = get(first.URL); err != nil {
		t.Fatal("listener not reachable", err)
	}
	second, err := app.startLinkSession()
	if err != nil {
		t.Fatal(err)
	}
	if err = get(first.URL); err == nil {
		t.Fatal("replacement left old listener open")
	}
	app.linkSession.closeID(first.SessionID)
	if err = get(second.URL); err != nil {
		t.Fatal("stale UI closed replacement", err)
	}
	app.linkSession.closeID(second.SessionID)
	if err = get(second.URL); err == nil {
		t.Fatal("closed listener remained reachable")
	}
}
