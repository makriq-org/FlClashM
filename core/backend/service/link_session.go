package service

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"sync"
	"time"
)

// This is an explicit, two-minute authoring capability, independent of runtime.
// Receiving never imports anything. The TV must confirm through the regular API.
type linkSession struct {
	mu      sync.Mutex
	server  *http.Server
	token   string
	url     string
	pending string
	expires time.Time
	timer   *time.Timer
}

type linkSessionState struct {
	SessionID string    `json:"sessionId"`
	URL       string    `json:"url"`
	Link      string    `json:"link,omitempty"`
	ExpiresAt time.Time `json:"expiresAt"`
}

func (s *linkSession) closeLocked() {
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
	if s.server != nil {
		_ = s.server.Close()
		s.server = nil
	}
	s.token = ""
	s.url = ""
	s.pending = ""
}
func (s *linkSession) close() { s.mu.Lock(); defer s.mu.Unlock(); s.closeLocked() }

func (a *App) startLinkSession() (linkSessionState, error) {
	s := &a.linkSession
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := a.ctx.Err(); err != nil {
		return linkSessionState{}, err
	}
	s.closeLocked()
	interfaces, err := net.Interfaces()
	if err != nil {
		return linkSessionState{}, err
	}
	host := ""
	for _, network := range interfaces {
		if network.Flags&net.FlagUp == 0 || network.Flags&(net.FlagLoopback|net.FlagPointToPoint) != 0 || strings.HasPrefix(network.Name, "tun") || strings.HasPrefix(network.Name, "wg") || strings.HasPrefix(network.Name, "rmnet") {
			continue
		}
		addresses, err := network.Addrs()
		if err != nil {
			continue
		}
		for _, address := range addresses {
			prefix, err := netip.ParsePrefix(address.String())
			if err == nil && prefix.Addr().Is4() && prefix.Addr().IsPrivate() {
				host = prefix.Addr().String()
				break
			}
		}
		if host != "" {
			break
		}
	}
	if host == "" {
		return linkSessionState{}, errors.New("local network unavailable")
	}
	listener, err := net.Listen("tcp4", net.JoinHostPort(host, "0"))
	if err != nil {
		return linkSessionState{}, err
	}
	var random [32]byte
	if _, err = rand.Read(random[:]); err != nil {
		_ = listener.Close()
		return linkSessionState{}, err
	}
	s.token = hex.EncodeToString(random[:])
	s.expires = time.Now().Add(2 * time.Minute)
	s.url = "http://" + listener.Addr().String() + "/" + s.token
	token := s.token
	server := &http.Server{ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 5 * time.Second, MaxHeaderBytes: 4096}
	server.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { s.receive(w, r, token) })
	s.server = server
	s.timer = time.AfterFunc(2*time.Minute, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.token == token {
			s.closeLocked()
		}
	})
	go func() { _ = server.Serve(listener) }()
	return linkSessionState{URL: s.url, SessionID: s.token, ExpiresAt: s.expires}, nil
}
func (s *linkSession) state() linkSessionState {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !time.Now().Before(s.expires) {
		s.closeLocked()
	}
	return linkSessionState{URL: s.url, SessionID: s.token, Link: s.pending, ExpiresAt: s.expires}
}
func (s *linkSession) receive(w http.ResponseWriter, r *http.Request, token string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; form-action 'self'; frame-ancestors 'none'")
	if s.token == "" || subtle.ConstantTimeCompare([]byte(s.token), []byte(token)) != 1 || r.URL.Path != "/"+token || !time.Now().Before(s.expires) {
		http.NotFound(w, r)
		return
	}
	if r.Host != strings.TrimPrefix(strings.Split(s.url, "/")[2], "http://") {
		http.Error(w, "Invalid host", 400)
		return
	}
	if origin := r.Header.Get("Origin"); origin != "" && origin != "http://"+r.Host {
		http.Error(w, "Invalid origin", 403)
		return
	}
	switch r.Method {
	case http.MethodGet:
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = io.WriteString(w, `<!doctype html><meta name="viewport" content="width=device-width"><title>FlClashM</title><h1>FlClashM</h1><form method="post"><label>Subscription or proxy link <input name="link" type="text" maxlength="16384" required></label><button>Send</button></form>`)
	case http.MethodPost:
		if s.pending != "" {
			http.Error(w, "Already received", 409)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 20<<10)
		if err := r.ParseForm(); err != nil {
			http.Error(w, "Invalid request", 400)
			return
		}
		link := strings.TrimSpace(r.PostForm.Get("link"))
		parsed, err := url.Parse(link)
		if err != nil || len(link) > 16384 || strings.ContainsAny(link, "\r\n\x00") || parsed.Scheme == "" {
			http.Error(w, "Invalid link", 400)
			return
		}
		switch strings.ToLower(parsed.Scheme) {
		case "http", "https", "ss", "ssr", "vmess", "vless", "trojan", "hysteria", "hysteria2", "hy2", "tuic", "socks", "socks5", "wireguard":
		default:
			http.Error(w, "Unsupported link", 400)
			return
		}
		// Publish only after the phone's acknowledgement has been flushed;
		// polling on the TV can immediately close the listener.
		if _, err := io.WriteString(w, "Received. Confirm import on the TV."); err != nil {
			return
		}
		if err := http.NewResponseController(w).Flush(); err != nil {
			return
		}
		s.pending = link
	default:
		w.Header().Set("Allow", "GET, POST")
		http.Error(w, "Method not allowed", 405)
	}
}

func (s *linkSession) closeID(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if id != "" && s.token == id {
		s.closeLocked()
	}
}
func (s *linkSession) stateID(id string) (linkSessionState, error) {
	value := s.state()
	if id == "" || value.SessionID != id {
		return linkSessionState{}, errors.New("link session expired")
	}
	return value, nil
}
