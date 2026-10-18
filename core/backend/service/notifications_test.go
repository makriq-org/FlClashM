package service

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"
)

type notificationPlatform struct {
	testPlatform
	noticeMu sync.Mutex
	notices  []SubscriptionNotice
}

func (p *notificationPlatform) NotifySubscription(ctx context.Context, notice SubscriptionNotice) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	p.noticeMu.Lock()
	p.notices = append(p.notices, notice)
	p.noticeMu.Unlock()
	return true, nil
}
func (p *notificationPlatform) count() int {
	p.noticeMu.Lock()
	defer p.noticeMu.Unlock()
	return len(p.notices)
}
func TestSubscriptionNoticesSurviveUIDetachRenewalAndProcessReopen(t *testing.T) {
	now := time.Date(2026, 10, 18, 12, 0, 0, 0, time.UTC)
	expire := now.Add(3*24*time.Hour + time.Second).Unix()
	dir := t.TempDir()
	platform := &notificationPlatform{}
	opt := options(t, dir, &testEngine{}, make(chan time.Time))
	opt.Platform = platform
	opt.Now = func() time.Time { return now }
	legacy, _ := json.Marshal(map[string]any{"appSetting": map[string]any{"locale": "ru", "testUrl": ""}, "profiles": []any{map[string]any{"id": "one", "label": "Original", "subscriptionInfo": map[string]any{"expire": expire}, "providerHeaders": map[string]string{"flclashm-servicename": "U2VydmljZQ==", "support-url": "https://fixture.invalid/renew"}}}, "subscriptionNotifications": map[string]any{"subscription_notified_one_3d": expire}})
	opt.LegacySettings = legacy
	opt.ReadLegacySource = func(string) (string, error) { return "rules: ['MATCH,DIRECT']", nil }
	app, err := Open(opt)
	if err != nil {
		t.Fatal(err)
	}
	_, _, detach := app.Subscribe(1)
	detach()
	app.checkNotices(context.Background(), now)
	if platform.count() != 0 {
		t.Fatal("migration duplicated the already shown notice")
	}
	for _, days := range []int{2, 1, 0, -1} {
		at := now.Add(time.Duration(3-days) * 24 * time.Hour)
		app.checkNotices(context.Background(), at)
		app.checkNotices(context.Background(), at)
	}
	if platform.count() != 4 {
		t.Fatal("wrong threshold/deduplication behavior", platform.count())
	}
	platform.noticeMu.Lock()
	first := platform.notices[0]
	platform.noticeMu.Unlock()
	if first.Title != "Service" || first.Days != 2 || first.Locale != "ru" || first.SupportURL != "https://fixture.invalid/renew" {
		t.Fatal("presentation lost", first)
	}
	if err = app.Close(); err != nil {
		t.Fatal(err)
	}
	app, err = Open(opt)
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	app.checkNotices(context.Background(), now.Add(4*24*time.Hour))
	if platform.count() != 4 {
		t.Fatal("process reopen duplicated notice")
	}
	record, _ := app.profiles.Get("one")
	_, err = app.profiles.UpdateMetadata(context.Background(), "one", map[string]json.RawMessage{"subscriptionInfo": jsonValue(map[string]any{"expire": expire + int64(30*24*time.Hour/time.Second)})}, record.Revision)
	if err != nil {
		t.Fatal(err)
	}
	app.checkNotices(context.Background(), now.Add(31*24*time.Hour))
	if platform.count() != 5 {
		t.Fatal("renewed subscription did not notify")
	}
}
