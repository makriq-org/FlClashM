package compile

import (
	"context"
	"errors"
	"net/url"
	"strings"
	"time"
)

const ByeDPIFallback = "-n google.com -Qr -f-204 -s1:5+sm -a1 -As -d1 -s3+s -s5+s -q7 -a1 -As -o2 -f-43 -a1 -As -r5 -Mh -s1:5+s -s3:7+sm -a1"

func (e *ExternalCompiler) buildByeDPI(ctx context.Context, raw Object, node *Node) error {
	mode := text(raw["mode"])
	native := Object{"mode": mode, "listenHost": node.Host, "listenPort": node.Port}
	if mode == "manual" {
		strategy, err := required(raw, "strategy")
		if err != nil {
			return err
		}
		if _, err = CLIArguments(strategy, "args"); err != nil {
			return err
		}
		native["args"] = strategy
		return artifact(node, "config.json", native)
	}
	if _, ok := raw["strategy"]; ok {
		return errors.New("manual strategy is unavailable in auto mode")
	}
	sources, ok := raw["strategies"]
	if !ok {
		sources = []any{"builtin:byebyeedpi"}
	}
	values, ok := sources.([]any)
	if !ok {
		return errors.New("strategies must be a list")
	}
	strategies := []string{}
	seen := map[string]bool{}
	appendStrategy := func(value string) error {
		if _, err := CLIArguments(value, "strategy"); err != nil {
			return err
		}
		if !seen[value] && len(strategies) < 4096 {
			seen[value] = true
			strategies = append(strategies, value)
		}
		return nil
	}
	for _, entry := range values {
		value := text(entry)
		if value == "" || value != strings.TrimSpace(value) {
			return errors.New("strategy source must be a nonempty trimmed string")
		}
		if strings.HasPrefix(value, "builtin:") {
			if value != "builtin:byebyeedpi" {
				return errors.New("unknown bundled strategy list")
			}
			if len(e.BuiltinStrategies) == 0 {
				return errors.New("bundled strategy list is unavailable")
			}
			for _, strategy := range e.BuiltinStrategies {
				if err := appendStrategy(strategy); err != nil {
					return err
				}
			}
		} else if strings.HasPrefix(strings.ToLower(value), "https://") {
			if err := publicListURL(value); err != nil {
				return err
			}
			if e.Lists == nil {
				continue
			}
			body, err := e.Lists.Read(ctx, "byedpi", value)
			if err != nil {
				if ctx.Err() != nil {
					return ctx.Err()
				}
				continue
			}
			parsed := []string{}
			for _, line := range strings.Split(body, "\n") {
				line = strings.TrimSpace(line)
				if line == "" || strings.HasPrefix(line, "#") {
					continue
				}
				if _, err := CLIArguments(line, "strategy"); err != nil {
					return err
				}
				parsed = append(parsed, line)
				if len(parsed) >= 4096 {
					break
				}
			}
			for _, strategy := range parsed {
				if err := appendStrategy(strategy); err != nil {
					return err
				}
			}
		} else {
			if err := appendStrategy(value); err != nil {
				return err
			}
		}
	}
	if len(strategies) == 0 {
		return errors.New("auto node resolved an empty strategy list")
	}
	native["strategies"] = strategies
	test := copyObject(object(raw["strategy-test"]))
	urls, err := safeURLs(test["urls"])
	if err != nil {
		return err
	}
	if len(urls) == 0 {
		urls = []string{"https://youtube.com/generate_204"}
	}
	test["urls"] = urls
	sni := text(test["sni"])
	if sni == "" {
		sni = "google.com"
	}
	if strings.ContainsAny(sni, "/@:") {
		return errors.New("strategy-test SNI must be a hostname")
	}
	test["sni"] = sni
	resolver := text(test["dns-resolver"])
	delete(test, "dns-resolver")
	if resolver == "" {
		resolver = "https://1.1.1.1/dns-query"
	}
	if !strings.EqualFold(resolver, "system") {
		if err = publicListURL(resolver); err != nil {
			return err
		}
	}
	test["resolver"] = resolver
	timeout, err := wholeSeconds(test["timeout"], 5*time.Second, time.Minute, false)
	if err != nil {
		return err
	}
	test["timeout"] = timeout
	requests, err := bounded(test["requests"], 1, 1, 32)
	if err != nil {
		return err
	}
	test["requests"] = requests
	concurrency, err := bounded(test["request-concurrency"], 4, 1, 16)
	if err != nil {
		return err
	}
	delete(test, "request-concurrency")
	test["concurrency"] = concurrency
	ratio := 1.0
	if value, ok := number(test["min-success-ratio"]); ok {
		ratio = value
	}
	if ratio <= 0 || ratio > 1 {
		return errors.New("strategy-test ratio must be within (0,1]")
	}
	test["min-success-ratio"] = ratio
	selection := object(raw["strategy-selection"])
	cache := object(selection["cache"])
	ttl, err := wholeSeconds(cache["ttl"], 7*24*time.Hour, 365*24*time.Hour, false)
	if err != nil {
		return err
	}
	recheck, err := wholeSeconds(cache["recheck-after"], 24*time.Hour, 365*24*time.Hour, false)
	if err != nil || recheck > ttl {
		return errors.New("cache recheck-after must not exceed TTL")
	}
	failures, err := bounded(cache["failure-threshold"], 2, 1, 32)
	if err != nil {
		return err
	}
	retry, err := wholeSeconds(selection["retry-after"], 5*time.Minute, 365*24*time.Hour, false)
	if err != nil {
		return err
	}
	selectionConcurrency, err := bounded(selection["strategy-concurrency"], 4, 1, 16)
	if err != nil {
		return err
	}
	foreground, err := wholeSeconds(selection["startup-timeout"], 0, time.Minute, true)
	if err != nil {
		return err
	}
	background := true
	if value, ok := selection["continue-in-background"]; ok {
		background = value == true
	}
	// Synchronous-only selection still needs a useful budget when omitted.
	if !background && selection["startup-timeout"] == nil {
		foreground = 15
	}
	fallback := ByeDPIFallback
	if value, ok := selection["fallback-strategy"]; ok {
		fallback = text(value)
		if fallback == "" || fallback != strings.TrimSpace(fallback) {
			return errors.New("fallback strategy must be a nonempty trimmed string")
		}
	}
	if _, err = CLIArguments(fallback, "fallbackArgs"); err != nil {
		return err
	}
	native["strategyTest"] = test
	native["selection"] = Object{"concurrency": selectionConcurrency, "foreground-timeout": foreground, "background": background}
	native["cache"] = Object{"ttl": ttl, "recheck-after": recheck, "failure-threshold": failures, "retry-after": retry}
	native["fallbackArgs"] = fallback
	return artifact(node, "config.json", native)
}
func publicListURL(value string) error {
	u, err := url.Parse(value)
	if err != nil || u.Scheme != "https" {
		return errors.New("remote list requires public HTTPS")
	}
	if _, err = safeURLs([]any{value}); err != nil {
		return err
	}
	return nil
}
