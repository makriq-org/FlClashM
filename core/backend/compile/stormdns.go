package compile

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

//go:embed storm_schema.json
var stormSchemaJSON []byte
var stormSchema = func() struct {
	Aliases map[string]struct {
		Key      string
		Duration bool
	}
	Durations map[string][2]string
} {
	var schema struct {
		Aliases map[string]struct {
			Key      string
			Duration bool
		}
		Durations map[string][2]string
	}
	if err := json.Unmarshal(stormSchemaJSON, &schema); err != nil {
		panic(err)
	}
	return schema
}()
var stormDurationPart = regexp.MustCompile(`(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h|d)`)
var stormDomain = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*$`)

// StormDNS accepts compound, fractional durations. The persisted contract is
// rounded to microseconds, as in the original profile compiler.
func stormDuration(value string) (time.Duration, error) {
	value = strings.TrimSpace(value)
	parts := stormDurationPart.FindAllStringSubmatchIndex(value, -1)
	offset := 0
	seconds := 0.0
	units := map[string]float64{"ns": 1e-9, "us": 1e-6, "µs": 1e-6, "ms": .001, "s": 1, "m": 60, "h": 3600, "d": 86400}
	for _, p := range parts {
		if p[0] != offset {
			return 0, errors.New("invalid StormDNS duration")
		}
		n, err := strconv.ParseFloat(value[p[2]:p[3]], 64)
		if err != nil {
			return 0, err
		}
		seconds += n * units[value[p[4]:p[5]]]
		offset = p[1]
	}
	micros := math.Round(seconds * 1e6)
	if offset != len(value) || len(parts) == 0 || math.IsInf(micros, 0) || math.IsNaN(micros) || micros > float64(math.MaxInt64/int64(time.Microsecond)) {
		return 0, errors.New("invalid StormDNS duration")
	}
	return time.Duration(micros) * time.Microsecond, nil
}
func stormFieldDuration(path string, value any, fallback time.Duration) (time.Duration, error) {
	if value == nil {
		return fallback, nil
	}
	s, ok := value.(string)
	if !ok {
		return 0, fmt.Errorf("%s requires a duration string", path)
	}
	d, err := stormDuration(s)
	if err != nil {
		return 0, err
	}
	if bounds, ok := stormSchema.Durations[path]; ok {
		min, _ := stormDuration(bounds[0])
		max, _ := stormDuration(bounds[1])
		if d < min || d > max {
			return 0, fmt.Errorf("%s must be within %s..%s", path, bounds[0], bounds[1])
		}
	}
	return d, nil
}
func (e *ExternalCompiler) buildStormDNS(ctx context.Context, raw Object, node *Node) error {
	domains := []string{}
	seen := map[string]bool{}
	for _, v := range list(raw["domains"]) {
		s := strings.TrimRight(strings.ToLower(strings.TrimSpace(text(v))), ".")
		if !stormDomain.MatchString(s) {
			return errors.New("invalid StormDNS domain")
		}
		if !seen[s] {
			seen[s] = true
			domains = append(domains, s)
		}
	}
	if len(domains) == 0 {
		return errors.New("StormDNS domains are required")
	}
	sort.Slice(domains, func(i, j int) bool {
		if len(domains[i]) != len(domains[j]) {
			return len(domains[i]) > len(domains[j])
		}
		return domains[i] < domains[j]
	})
	encryption := strings.TrimSpace(text(raw["encryption"]))
	code, ok := map[string]int{"none": 0, "xor": 1, "chacha20": 2, "aes-128-gcm": 3, "aes-192-gcm": 4, "aes-256-gcm": 5}[encryption]
	if !ok {
		return errors.New("invalid StormDNS encryption")
	}
	key := strings.TrimSpace(text(raw["encryption-key"]))
	if key == "" {
		return errors.New("StormDNS encryption-key is required")
	}
	presets := map[string][4]int{"messenger": {1, 7, 3, 8}, "balanced": {2, 5, 3, 6}, "bulk": {3, 3, 4, 4}}
	preset := text(raw["preset"])
	if preset == "" {
		preset = "messenger"
	}
	dup, ok := presets[preset]
	if !ok {
		return errors.New("invalid StormDNS preset")
	}
	for i, k := range []string{"upload", "download", "upload-setup", "download-setup"} {
		if v := object(raw["duplication"])[k]; v != nil {
			n, _ := number(v)
			dup[i] = int(n)
		}
	}
	if dup[2] < dup[0] || dup[3] < dup[1] {
		return errors.New("setup duplication must not be lower than data duplication")
	}
	policy := object(raw["resolver-policy"])
	refresh, err := stormFieldDuration("resolver-policy.refresh", policy["refresh"], 24*time.Hour)
	if err != nil {
		return err
	}
	lines, err := e.stormResolverLines(ctx, raw["resolvers"], refresh)
	if err != nil {
		return err
	}
	// Cached MTUs are negotiated for a specific wire format and server key.
	// Reusing XOR-era or larger MTUs after changing encryption/limits can make
	// a cached startup silently drop traffic until the cache is removed.
	keyDigest := sha256.Sum256([]byte(key))
	fingerprintData := struct {
		Runtime    string   `json:"runtime"`
		Domains    []string `json:"domains"`
		Resolvers  []string `json:"resolvers"`
		Encryption int      `json:"encryption"`
		KeyDigest  string   `json:"keyDigest"`
		MTU        Object   `json:"mtu"`
		BaseEncode bool     `json:"baseEncode"`
	}{"git-ca2eb481fddd4a80d26b3a1a7c714b5aecacecfc", domains, lines, code, hex.EncodeToString(keyDigest[:]), object(raw["mtu"]), object(raw["runtime"])["base-encode"] == true}
	var canonical bytes.Buffer
	encoder := json.NewEncoder(&canonical)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(fingerprintData); err != nil {
		return err
	}
	sum := sha256.Sum256(bytes.TrimSuffix(canonical.Bytes(), []byte{'\n'}))
	fingerprint := hex.EncodeToString(sum[:])[:16]
	node.Metadata["cache-fingerprint"] = fingerprint
	node.Metadata["depends-on-system-dns"] = strconv.FormatBool(contains(lines, stormSystemDNS))
	node.Files["built-in-proxies/stormdns/"+node.ID+"/client_resolvers.template"] = strings.Join(lines, "\n") + "\n"
	toml := []string{"# Generated by FlClashM. Do not edit: the profile is the source of truth.", `PROTOCOL_TYPE = "SOCKS5"`, `LISTEN_IP = "127.0.0.1"`, fmt.Sprintf("LISTEN_PORT = %d", node.Port), "SOCKS5_AUTH = false"}
	add := func(k string, v any) {
		var s string
		switch x := v.(type) {
		case string:
			s = tomlString(x)
		case []string:
			values := make([]string, len(x))
			for i, v := range x {
				values[i] = tomlString(v)
			}
			s = "[" + strings.Join(values, ", ") + "]"
		default:
			s = fmt.Sprint(x)
		}
		toml = append(toml, k+" = "+s)
	}
	add("DOMAINS", domains)
	add("DATA_ENCRYPTION_METHOD", code)
	add("ENCRYPTION_KEY", key)
	add("LOCAL_DNS_ENABLED", false)
	strategy := text(policy["strategy"])
	if strategy == "" {
		strategy = "least-loss"
	}
	strategyCode, ok := map[string]int{"random": 1, "round-robin": 2, "least-loss": 3, "lowest-latency": 4}[strategy]
	if !ok {
		return errors.New("invalid resolver strategy")
	}
	add("RESOLVER_BALANCING_STRATEGY", strategyCode)
	for _, pair := range [][2]string{{"recheck", "RECHECK_INACTIVE_SERVERS_ENABLED"}, {"auto-disable", "AUTO_DISABLE_TIMEOUT_SERVERS"}} {
		field, native := pair[0], pair[1]
		value := true
		if v, ok := policy[field]; ok {
			value = v == true
		}
		add(native, value)
	}
	for i, k := range []string{"UPLOAD_PACKET_DUPLICATION_COUNT", "DOWNLOAD_PACKET_DUPLICATION_COUNT", "UPLOAD_SETUP_PACKET_DUPLICATION_COUNT", "DOWNLOAD_SETUP_PACKET_DUPLICATION_COUNT"} {
		add(k, dup[i])
	}
	compression := object(raw["compression"])
	fallback := "lz4"
	if preset == "bulk" {
		fallback = "zstd"
	}
	for _, direction := range []string{"upload", "download"} {
		value := text(compression[direction])
		if value == "" {
			value = fallback
		}
		n, ok := map[string]int{"none": 0, "zstd": 1, "lz4": 2, "zlib": 3}[value]
		if !ok {
			return errors.New("invalid compression")
		}
		add(strings.ToUpper(direction)+"_COMPRESSION_TYPE", n)
	}
	if v := compression["min-size"]; v != nil {
		add("COMPRESSION_MIN_SIZE", v)
	}
	for _, direction := range []string{"upload", "download"} {
		mtu := object(object(raw["mtu"])[direction])
		minimum, maximum := 100.0, 200.0
		if direction == "download" {
			minimum, maximum = 1000, 4000
		}
		if v, ok := number(mtu["min"]); ok {
			minimum = v
		}
		if v, ok := number(mtu["max"]); ok {
			maximum = v
		}
		if maximum > 0 && minimum > maximum {
			return errors.New("MTU minimum exceeds maximum")
		}
		for _, bound := range []string{"min", "max"} {
			if v := mtu[bound]; v != nil {
				add(strings.ToUpper(bound+"_"+direction)+"_MTU", v)
			}
		}
	}
	startup := object(raw["startup"])
	mode := text(startup["mode"])
	if mode == "" {
		mode = "cached"
	}
	if mode != "scan" && mode != "cached" && mode != "verified" {
		return errors.New("invalid noninteractive startup mode")
	}
	maxAge, err := stormFieldDuration("startup.max-age", startup["max-age"], 30*24*time.Hour)
	if err != nil {
		return err
	}
	if maxAge%(24*time.Hour) != 0 {
		return errors.New("startup.max-age must be whole days")
	}
	add("LOG_TO_FILE", true)
	add("LOG_DIR", "cache/"+fingerprint+"/logs")
	nativeMode := "logs"
	if mode == "scan" {
		nativeMode = "resolvers"
	}
	add("STARTUP_MODE", nativeMode)
	add("LOG_BASED_MTU_VERIFY", mode == "verified")
	add("LOG_SCAN_MAX_DAYS", int(maxAge/(24*time.Hour)))
	effective := map[string]float64{}
	optional := []string{}
	for _, block := range []string{"arq", "ping", "runtime"} {
		for k, v := range object(raw[block]) {
			path := block + "." + k
			if path == "runtime.base-encode" {
				add("BASE_ENCODE_DATA", v)
				continue
			}
			alias, ok := stormSchema.Aliases[path]
			if !ok {
				return fmt.Errorf("unsupported field %s", path)
			}
			if alias.Duration {
				duration, err := stormFieldDuration(path, v, 0)
				if err != nil {
					return err
				}
				effective[path] = duration.Seconds()
				s := strings.TrimRight(strconv.FormatFloat(duration.Seconds(), 'f', 6, 64), "0")
				if strings.HasSuffix(s, ".") {
					s += "0"
				}
				optional = append(optional, alias.Key+" = "+s)
			} else {
				n, _ := number(v)
				effective[path] = n
				optional = append(optional, alias.Key+" = "+fmt.Sprint(v))
			}
		}
	}
	get := func(path string, fallback float64) float64 {
		if v, ok := effective[path]; ok {
			return v
		}
		return fallback
	}
	for _, pair := range []struct {
		lower, upper string
		low, high    float64
	}{{"arq.initial-rto", "arq.max-rto", .6, 3}, {"arq.control-initial-rto", "arq.control-max-rto", .5, 2}, {"ping.aggressive-interval", "ping.lazy-interval", .2, .75}, {"ping.lazy-interval", "ping.cooldown-interval", .75, 2}, {"ping.cooldown-interval", "ping.cold-interval", 2, 15}, {"ping.warm-threshold", "ping.cool-threshold", 5, 15}, {"ping.cool-threshold", "ping.cold-threshold", 15, 30}, {"runtime.session-retry-base", "runtime.session-retry-max", 1, 60}, {"runtime.workers", "runtime.process-workers", 4, 4}} {
		if get(pair.lower, pair.low) > get(pair.upper, pair.high) {
			return fmt.Errorf("%s must not exceed %s", pair.lower, pair.upper)
		}
	}
	if gap, ok := effective["arq.nack-max-gap"]; ok && gap > math.Floor(get("arq.window", 1000)/4) {
		return errors.New("NACK gap exceeds quarter window")
	}
	sort.Strings(optional)
	toml = append(toml, optional...)
	node.Files["built-in-proxies/stormdns/"+node.ID+"/client_config.toml"] = strings.Join(toml, "\n") + "\n"
	return nil
}
func tomlString(value string) string {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	_ = e.Encode(value)
	return strings.TrimSuffix(b.String(), "\n")
}
