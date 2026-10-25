package profiles

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestSubscriptionDeviceHeaderConsent(t *testing.T) {
	choices := []struct {
		name  string
		value *bool
	}{{"default", nil}, {"on", new(true)}, {"off", new(false)}}
	for _, host := range choices {
		for _, profile := range choices {
			for _, requested := range []bool{false, true} {
				t.Run(fmt.Sprintf("host-%s/profile-%s/request-%t", host.name, profile.name, requested), func(t *testing.T) {
					received := make(chan http.Header, 3)
					server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
						received <- r.Header.Clone()
						_, _ = w.Write([]byte("proxies: []\n"))
					}))
					defer server.Close()
					repository := openRepository(t)
					if host.value != nil {
						if err := repository.UpdateSettings(Object{"sendDeviceHeaders": mustJSON(*host.value)}, 0); err != nil {
							t.Fatal(err)
						}
					}
					meta := metadata("privacy", server.URL)
					if profile.value != nil {
						meta["sendDeviceHeaders"] = mustJSON(*profile.value)
					}
					now := time.Date(2026, 10, 25, 0, 0, 0, 0, time.UTC)
					calls := 0
					device := map[string]string{"x-hwid": "device", "x-device-os": "Android", "x-ver-os": "16", "x-device-model": "test"}
					subscriptions := Subscriptions{
						Repository: repository, Client: server.Client(), Now: func() time.Time { return now },
						DeviceHeaders: func(context.Context) (map[string]string, error) { calls++; return device, nil },
					}
					if _, err := subscriptions.Import(context.Background(), meta, requested); err != nil {
						t.Fatal(err)
					}
					if _, err := subscriptions.Update(context.Background(), "privacy", requested); err != nil {
						t.Fatal(err)
					}
					// Scheduler always requests headers; persisted opt-outs must still win.
					ticks := make(chan time.Time, 1)
					ticks <- now.Add(48 * time.Hour)
					close(ticks)
					subscriptions.Run(context.Background(), ticks, func(_ string, err error) { t.Fatal(err) })
					if len(received) != 3 {
						t.Fatalf("import/manual/headless requests: %d", len(received))
					}
					storedConsent := (host.value == nil || *host.value) && (profile.value == nil || *profile.value)
					wantCalls := 0
					for index := range 3 {
						allowed := storedConsent && (index == 2 || requested)
						if allowed {
							wantCalls++
						}
						headers := <-received
						for key, value := range device {
							want := ""
							if allowed {
								want = value
							}
							if got := headers.Get(key); got != want {
								t.Fatalf("request %d header %s: got %q, want %q", index, key, got, want)
							}
						}
					}
					if calls != wantCalls {
						t.Fatalf("device information read %d times, want %d", calls, wantCalls)
					}
				})
			}
		}
	}
}
