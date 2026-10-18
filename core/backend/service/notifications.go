package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"maps"
	"strconv"
	"strings"
	"time"

	"core/backend/profiles"
)

type SubscriptionNotice struct {
	Title      string `json:"title"`
	Days       int    `json:"days"`
	SupportURL string `json:"supportUrl"`
	Locale     string `json:"locale"`
}

// The platform localizes and displays a semantic notice; scheduling and durable
// deduplication belong to the backend and continue after UI detaches.
type SubscriptionNotifier interface {
	NotifySubscription(context.Context, SubscriptionNotice) (bool, error)
}

func (a *App) migrateNotices(legacy []byte) error {
	a.operations.mu.Lock()
	defer a.operations.mu.Unlock()
	if a.operations.document.NoticesMigrated {
		return nil
	}
	var input struct {
		Notices map[string]int64 `json:"subscriptionNotifications"`
	}
	_ = json.Unmarshal(legacy, &input)
	next := a.operations.document
	next.NoticesMigrated = true
	next.SubscriptionNotices = map[string]int64{}
	for key, expire := range input.Notices {
		if strings.HasPrefix(key, "subscription_notified_") && len(key) < 512 && expire > 0 {
			next.SubscriptionNotices[key] = expire
		}
	}
	return a.operations.saveLocked(next)
}
func (a *App) checkNotices(ctx context.Context, now time.Time) {
	notifier, ok := a.platform.(SubscriptionNotifier)
	if !ok {
		return
	}
	a.noticeMu.Lock()
	defer a.noticeMu.Unlock()
	catalog := a.profiles.Snapshot()
	var app struct {
		Locale string `json:"locale"`
	}
	_ = json.Unmarshal(catalog.Settings["appSetting"], &app)
	for _, record := range catalog.Profiles {
		if ctx.Err() != nil || a.resetting.Load() {
			return
		}
		var info struct {
			Expire int64 `json:"expire"`
		}
		_ = json.Unmarshal(record.Metadata["subscriptionInfo"], &info)
		if info.Expire <= 0 {
			continue
		}
		expiry := time.Unix(info.Expire, 0)
		days := int(expiry.Sub(now) / (24 * time.Hour))
		if expiry.Before(now) {
			days = -1
		}
		if days > 3 {
			continue
		}
		var id, label string
		_ = json.Unmarshal(record.Metadata["id"], &id)
		_ = json.Unmarshal(record.Metadata["label"], &label)
		if label == "" {
			label = id
		}
		key := "subscription_notified_" + id + "_" + strconv.Itoa(days) + "d"
		a.operations.mu.Lock()
		sent := a.operations.document.SubscriptionNotices[key] == info.Expire
		a.operations.mu.Unlock()
		if sent {
			continue
		}
		var headers map[string]string
		_ = json.Unmarshal(record.Metadata["providerHeaders"], &headers)
		if service, err := base64.StdEncoding.DecodeString(profiles.ProviderHeader(headers, "servicename")); err == nil && len(service) > 0 {
			label = strings.TrimSpace(string(service))
		}
		noticeContext, cancel := context.WithTimeout(ctx, 15*time.Second)
		displayed, err := notifier.NotifySubscription(noticeContext, SubscriptionNotice{Title: label, Days: days, SupportURL: strings.TrimSpace(headers["support-url"]), Locale: app.Locale})
		cancel()
		if err != nil || !displayed {
			continue
		}
		a.operations.mu.Lock()
		next := a.operations.document
		next.SubscriptionNotices = maps.Clone(next.SubscriptionNotices)
		if next.SubscriptionNotices == nil {
			next.SubscriptionNotices = map[string]int64{}
		}
		next.SubscriptionNotices[key] = info.Expire
		// Bound obsolete profile receipts, including repeated imports/deletions.
		if len(next.SubscriptionNotices) > max(128, len(catalog.Profiles)*5) {
			keep := map[string]int64{}
			for _, p := range catalog.Profiles {
				var profileID string
				_ = json.Unmarshal(p.Metadata["id"], &profileID)
				for _, threshold := range []int{-1, 0, 1, 2, 3} {
					k := "subscription_notified_" + profileID + "_" + strconv.Itoa(threshold) + "d"
					if value, exists := next.SubscriptionNotices[k]; exists {
						keep[k] = value
					}
				}
			}
			next.SubscriptionNotices = keep
		}
		_ = a.operations.saveLocked(next)
		a.operations.mu.Unlock()
	}
}
