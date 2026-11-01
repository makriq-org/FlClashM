package service

import (
	"context"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type qualityHTTP struct{ calls int }

func (c *qualityHTTP) Do(r *http.Request) (*http.Response, error) {
	c.calls++
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"ip":"8.8.8.8","org":"AS15169 Google LLC"}`))}, nil
}
func TestQualityCacheExpiryRefreshAndMismatch(t *testing.T) {
	now := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	var clock atomic.Int64
	clock.Store(now.UnixNano())
	client := &qualityHTTP{}
	opts := options(t, t.TempDir(), &testEngine{}, make(chan time.Time))
	opts.HTTPClient = client
	opts.Now = func() time.Time { return time.Unix(0, clock.Load()) }
	app := openTestApp(t, opts)
	for i := 0; i < 2; i++ {
		record, err := app.ipQuality(context.Background(), "8.8.8.8", false)
		if err != nil || record.Quality["type"] != "hosting" {
			t.Fatal(record, err)
		}
	}
	if client.calls != 1 {
		t.Fatal("fresh cache made network request", client.calls)
	}
	if _, err := app.ipQuality(context.Background(), "8.8.8.8", true); err != nil || client.calls != 2 {
		t.Fatal("manual refresh did not query source", err, client.calls)
	}
	clock.Add(int64(qualityMaxAge))
	if _, err := app.ipQuality(context.Background(), "8.8.8.8", false); err != nil || client.calls != 3 {
		t.Fatal("expired cache reused", err, client.calls)
	}
	if _, err := app.ipQuality(context.Background(), "127.0.0.1", false); err == nil {
		t.Fatal("accepted local IP")
	}
	if _, err := parseIPQuality("8.8.8.8", map[string]any{"ip": "1.1.1.1"}); err == nil {
		t.Fatal("accepted mismatched IP")
	}
}
