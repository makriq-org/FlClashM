package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/listener/inner"
	"github.com/metacubex/mihomo/tunnel"
)

const (
	defaultTunnelHTTPTimeout = 60 * time.Second
	maxTunnelHTTPResponseLen = 16 << 20
)

var tunnelHTTPRequests sync.Map // map[string]context.CancelFunc

// handleTunnelHTTPRequest performs a client-owned HTTP request without
// creating or using an inbound listener. DialContext hands the connection to
// mihomo's internal inbound, so normal rules, DNS and selected proxies apply.
func handleTunnelHTTPRequest(paramsString string) (*TunnelHTTPResponse, error) {
	var params TunnelHTTPRequest
	if err := json.Unmarshal([]byte(paramsString), &params); err != nil {
		return nil, fmt.Errorf("invalid tunnel HTTP request: %w", err)
	}
	if strings.TrimSpace(params.URL) == "" {
		return nil, errors.New("tunnel HTTP request URL is empty")
	}

	timeout := defaultTunnelHTTPTimeout
	if params.TimeoutMillis > 0 {
		timeout = time.Duration(params.TimeoutMillis) * time.Millisecond
	}
	maxLen := int64(maxTunnelHTTPResponseLen)
	if params.MaxResponseLen > 0 && params.MaxResponseLen < maxLen {
		maxLen = params.MaxResponseLen
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	if params.RequestID != "" {
		tunnelHTTPRequests.Store(params.RequestID, cancel)
		defer tunnelHTTPRequests.Delete(params.RequestID)
	}
	method := params.Method
	if method == "" {
		method = http.MethodGet
	}
	req, err := http.NewRequestWithContext(ctx, method, params.URL, strings.NewReader(params.Body))
	if err != nil {
		return nil, err
	}
	for name, value := range params.Headers {
		req.Header.Set(name, value)
	}

	transport := &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			if network != "tcp" && network != "tcp4" && network != "tcp6" {
				return nil, fmt.Errorf("unsupported network %q", network)
			}
			return inner.HandleTcp(tunnel.Tunnel, address, "")
		},
		ForceAttemptHTTP2: false,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport: transport,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return errors.New("too many redirects")
			}
			return nil
		},
	}

	response, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.ContentLength > maxLen {
		return nil, fmt.Errorf("response exceeds %d byte limit", maxLen)
	}
	var body []byte
	var writtenLen int64
	if params.TargetPath != "" {
		file, err := os.Create(params.TargetPath)
		if err != nil {
			return nil, fmt.Errorf("create response file: %w", err)
		}
		writtenLen, err = io.Copy(file, io.LimitReader(response.Body, maxLen+1))
		closeErr := file.Close()
		if err != nil {
			_ = os.Remove(params.TargetPath)
			return nil, err
		}
		if closeErr != nil {
			_ = os.Remove(params.TargetPath)
			return nil, closeErr
		}
		if writtenLen > maxLen {
			_ = os.Remove(params.TargetPath)
			return nil, fmt.Errorf("response exceeds %d byte limit", maxLen)
		}
	} else {
		body, err = io.ReadAll(io.LimitReader(response.Body, maxLen+1))
		if err != nil {
			return nil, err
		}
		if int64(len(body)) > maxLen {
			return nil, fmt.Errorf("response exceeds %d byte limit", maxLen)
		}
		body = bytes.Clone(body)
	}

	return &TunnelHTTPResponse{
		StatusCode: response.StatusCode,
		Headers:    response.Header.Clone(),
		Body:       body,
		FinalURL:   response.Request.URL.String(),
		WrittenLen: writtenLen,
	}, nil
}

func cancelTunnelHTTPRequest(requestID string) bool {
	if requestID == "" {
		return false
	}
	value, ok := tunnelHTTPRequests.Load(requestID)
	if !ok {
		return false
	}
	value.(context.CancelFunc)()
	return true
}
