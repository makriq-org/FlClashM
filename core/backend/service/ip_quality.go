package service

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const qualityMaxAge = 72 * time.Hour

type qualityRecord struct {
	Quality   map[string]any `json:"quality"`
	CheckedAt time.Time      `json:"checkedAt"`
}

var hostingNames = regexp.MustCompile(`(?i)host|cloud|server|data ?cent|vps|colo|cdn|amazon|aws|azure|microsoft|google|digitalocean|linode|akamai|vultr|hetzner|ovh|contabo|scaleway|selectel|timeweb|leaseweb|oracle|alibaba|tencent|netcup|ionos|hostinger|cloudflare`)
var mobileNames = regexp.MustCompile(`(?i)mobile|cellular|wireless|\bmts\b|megafon|beeline|tele2|vodafone|t-mobile|telefonica|yota|kyivstar|lifecell|\blte\b|\b[345]g\b`)
var asnNumber = regexp.MustCompile(`\d+`)
var orgPrefix = regexp.MustCompile(`^AS\d+\s+`)

// Lookup and freshness are backend policy. There is no second persistent UI cache.
func (a *App) ipQuality(ctx context.Context, ip string, refresh bool) (qualityRecord, error) {
	addr, err := netip.ParseAddr(ip)
	if err != nil || !addr.IsGlobalUnicast() || addr.IsPrivate() || addr.IsLoopback() || addr.IsLinkLocalUnicast() {
		return qualityRecord{}, errors.New("public IP required")
	}
	ip = addr.String()
	a.qualityMu.Lock()
	defer a.qualityMu.Unlock()
	if err := ctx.Err(); err != nil {
		return qualityRecord{}, err
	}
	path := filepath.Join(a.directory, "ip-quality.json")
	records := map[string]qualityRecord{}
	if f, err := os.Open(path); err == nil {
		_ = json.NewDecoder(io.LimitReader(f, 1<<20)).Decode(&records)
		_ = f.Close()
	}
	if records == nil {
		records = map[string]qualityRecord{}
	}
	now := a.now()
	for key, record := range records {
		if record.CheckedAt.After(now) || now.Sub(record.CheckedAt) >= qualityMaxAge {
			delete(records, key)
		}
	}
	if record, ok := records[ip]; ok && !refresh {
		return record, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://ipinfo.io/"+ip+"/json", nil)
	if err != nil {
		return qualityRecord{}, err
	}
	response, err := a.subscriptions.Client.Do(req)
	if err != nil {
		return qualityRecord{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return qualityRecord{}, errors.New("IP quality source unavailable")
	}
	var data map[string]any
	if err := json.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(&data); err != nil {
		return qualityRecord{}, err
	}
	quality, err := parseIPQuality(ip, data)
	if err != nil {
		return qualityRecord{}, err
	}
	record := qualityRecord{Quality: quality, CheckedAt: a.now()}
	// Bound retained records as well as the source response and on-disk decoder.
	for len(records) >= 128 {
		oldest := ""
		for key, value := range records {
			if oldest == "" || value.CheckedAt.Before(records[oldest].CheckedAt) {
				oldest = key
			}
		}
		delete(records, oldest)
	}
	records[ip] = record
	encoded, _ := json.Marshal(records)
	if err := os.WriteFile(path+".tmp", encoded, 0600); err == nil {
		_ = os.Rename(path+".tmp", path)
	}
	return record, nil
}

func parseIPQuality(ip string, data map[string]any) (map[string]any, error) {
	if data["ip"] != ip || data["bogon"] == true {
		return nil, errors.New("IP quality source returned a different IP")
	}
	object := func(value any) map[string]any { result, _ := value.(map[string]any); return result }
	text := func(value any) string { result, _ := value.(string); return result }
	privacy, company, asn := object(data["privacy"]), object(data["company"]), object(data["asn"])
	org := text(company["name"])
	if org == "" {
		org = text(asn["name"])
	}
	if org == "" {
		org = orgPrefix.ReplaceAllString(text(data["org"]), "")
	}
	kind := ""
	for _, declared := range []string{text(company["type"]), text(asn["type"])} {
		switch declared {
		case "isp":
			kind = "residential"
		case "business", "education", "government", "banking":
			kind = "business"
		case "hosting":
			kind = "hosting"
		}
		if kind != "" {
			break
		}
	}
	if privacy["hosting"] == true {
		kind = "hosting"
	}
	if kind == "" {
		names := org + " " + text(data["hostname"])
		switch {
		case hostingNames.MatchString(names):
			kind = "hosting"
		case mobileNames.MatchString(names):
			kind = "mobile"
		default:
			kind = "residential"
		}
	}
	result := map[string]any{"ip": ip, "source": "ipInfo", "type": kind, "isProxy": privacy["proxy"] == true, "isVpn": privacy["vpn"] == true || privacy["relay"] == true, "isTor": privacy["tor"] == true, "isAbuser": false}
	if org != "" {
		result["organization"] = org
	}
	number := asnNumber.FindString(text(asn["asn"]))
	if number == "" {
		number = asnNumber.FindString(text(data["org"]))
	}
	if value, err := strconv.Atoi(strings.TrimSpace(number)); err == nil && value > 0 {
		result["asn"] = value
	}
	return result, nil
}
