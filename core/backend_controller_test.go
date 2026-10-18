package main

import (
	"sync/atomic"
	"testing"

	controlhttp "github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/hub/route"
)

func TestBackendHostIdentity(t *testing.T) {
	for _, test := range []struct {
		home, packageName string
		allowed           bool
	}{
		{"/data/user/0/com.makriq.flclash/files", "com.makriq.flclash", true},
		{"/data/user/0/com.makriq.flclash.dev/files", "com.makriq.flclash.dev", true},
		{"relative/files", "com.makriq.flclash", false},
		{"", "com.makriq.flclash.dev", false},
		{"/private/files", "com.makriq.flclash.other", false},
		{"/private/files", "com.makriq.flclash.dev.dev", false},
	} {
		if got := validBackendHost(test.home, test.packageName); got != test.allowed {
			t.Errorf("host %q / %q: allowed=%t, want %t", test.home, test.packageName, got, test.allowed)
		}
	}
}

func TestControllerAuthenticatesBeforeCommandGate(t *testing.T) {
	var mutations atomic.Int32
	router := route.NewEmbeddedRouter(&route.Config{Secret: "private-token"}, func(next controlhttp.Handler) controlhttp.Handler {
		return controlhttp.HandlerFunc(func(w controlhttp.ResponseWriter, request *controlhttp.Request) {
			if request.Method == "DELETE" {
				mutations.Add(1)
				w.WriteHeader(204)
				return
			}
			next.ServeHTTP(w, request)
		})
	})
	for _, test := range []struct {
		method, path, token string
		status              int
	}{
		{"DELETE", "/connections", "", 401},
		{"DELETE", "/connections", "wrong", 401},
		{"GET", "/version", "", 401},
		{"GET", "/version", "private-token", 200},
		{"DELETE", "/connections", "private-token", 204},
	} {
		request := httptest.NewRequest(test.method, test.path, nil)
		if test.token != "" {
			request.Header.Set("Authorization", "Bearer "+test.token)
		}
		response := httptest.NewRecorder()
		router.ServeHTTP(response, request)
		if response.Code != test.status {
			t.Fatalf("%s %s: %d, want %d", test.method, test.path, response.Code, test.status)
		}
	}
	if mutations.Load() != 1 {
		t.Fatal("unauthenticated mutation reached backend")
	}
}
