package compile

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/dlclark/regexp2"
	"go.yaml.in/yaml/v3"
)

type selector struct {
	raw, pattern          string
	include, scan, inline bool
	regex                 *regexp2.Regexp
}

func parseSelector(value string, inline bool) (selector, error) {
	s := selector{raw: strings.TrimSpace(value), include: true, inline: inline}
	s.pattern = s.raw
	if strings.HasPrefix(s.pattern, "!") {
		s.include = false
		s.pattern = strings.TrimSpace(s.pattern[1:])
	}
	if s.pattern == "" {
		return s, errors.New("empty Android package selector")
	}
	expression := ""
	for _, prefix := range []string{"re:", "regex:", "regexp:"} {
		if strings.HasPrefix(s.pattern, prefix) {
			s.scan = true
			expression = strings.TrimPrefix(s.pattern, prefix)
			break
		}
	}
	if !s.scan && strings.Contains(s.pattern, "*") {
		s.scan = true
		expression = "^" + strings.ReplaceAll(regexp.QuoteMeta(s.pattern), `\*`, ".*") + "$"
	}
	if s.scan {
		var err error
		s.regex, err = regexp2.Compile(expression, regexp2.ECMAScript)
		if err != nil {
			return s, errors.New("invalid Android package regular expression")
		}
		s.regex.MatchTimeout = 100 * time.Millisecond
	}
	return s, nil
}
func selectors(value any, inline bool) ([]selector, error) {
	values := []any{}
	if value == nil {
		return nil, nil
	}
	if text, ok := value.(string); ok {
		values = []any{text}
	} else {
		var ok bool
		values, ok = value.([]any)
		if !ok {
			return nil, errors.New("package selectors must be a list or string")
		}
	}
	result := []selector{}
	for _, value := range values {
		text := strings.TrimSpace(fmt.Sprint(value))
		if text == "" {
			continue
		}
		s, err := parseSelector(text, inline)
		if err != nil {
			return nil, err
		}
		result = append(result, s)
	}
	return result, nil
}
func packageURLs(value any, preferURL bool, field string, diagnostics *[]string) ([]string, error) {
	if value == nil {
		return nil, nil
	}
	values, ok := value.([]any)
	if !ok {
		values = []any{value}
	}
	urls := []string{}
	seen := map[string]bool{}
	ignored := false
	for _, value := range values {
		address, local := "", ""
		if v, ok := value.(string); ok {
			v = strings.TrimSpace(v)
			if isHTTPURL(v) {
				address = v
			} else if preferURL && v != "" {
				return nil, errors.New("package source must be an HTTP(S) URL")
			} else {
				local = v
			}
		} else if descriptor, ok := asObject(value); ok {
			if descriptor["path"] != nil {
				local = strings.TrimSpace(fmt.Sprint(descriptor["path"]))
			}
			if descriptor["url"] != nil {
				address = strings.TrimSpace(fmt.Sprint(descriptor["url"]))
			}
			if preferURL && address == "" {
				if isHTTPURL(local) {
					address = local
					local = ""
				} else if local != "" {
					return nil, errors.New("package source must be an HTTP(S) URL")
				}
			}
			if address != "" && !isHTTPURL(address) {
				return nil, errors.New("invalid package source URL")
			}
		} else {
			return nil, errors.New("package source must be a string or map")
		}
		ignored = ignored || local != ""
		if address != "" && !seen[address] {
			seen[address] = true
			urls = append(urls, address)
		}
	}
	if ignored {
		*diagnostics = append(*diagnostics, "Android ignored unsupported local profile path `"+field+"`.")
	}
	return urls, nil
}
func isHTTPURL(value string) bool {
	u, err := url.Parse(value)
	return err == nil && u.Hostname() != "" && (u.Scheme == "http" || u.Scheme == "https")
}
func parsePackageBody(body string) ([]selector, error) {
	// YAML reads an exclusion item such as `- !com.example` as a local tag
	// with an empty value. The legacy parser rejected undefined tags and used
	// line parsing instead, which keeps the exclusion.
	var document yaml.Node
	if yaml.Unmarshal([]byte(body), &document) == nil && len(document.Content) == 1 {
		if root := document.Content[0]; root.Kind == yaml.SequenceNode && !hasCustomYAMLTag(root) {
			var value any
			if root.Decode(&value) == nil {
				if _, ok := value.([]any); ok {
					return selectors(value, false)
				}
			}
		}
	}
	values := []any{}
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimSpace(strings.TrimPrefix(line, "-"))
		if before, _, ok := strings.Cut(line, " #"); ok {
			line = strings.TrimSpace(before)
		}
		if line != "" && !strings.HasPrefix(line, "#") {
			values = append(values, line)
		}
	}
	return selectors(values, false)
}
func hasCustomYAMLTag(node *yaml.Node) bool {
	if tag := node.ShortTag(); strings.HasPrefix(tag, "!") && !strings.HasPrefix(tag, "!!") {
		return true
	}
	for _, child := range node.Content {
		if hasCustomYAMLTag(child) {
			return true
		}
	}
	return false
}
func (c *Compiler) splitPackages(ctx context.Context, config Object, profileID string, diagnostics *[]string) (Object, error) {
	tun := object(config["tun"])
	groups := make([][]selector, 2)
	hasSource := false
	needInventory := false
	for index, mode := range []string{"include", "exclude"} {
		field := "tun." + mode + "-package"
		inline, err := selectors(tun[mode+"-package"], true)
		if err != nil {
			return nil, err
		}
		groups[index] = inline
		for _, s := range inline {
			needInventory = needInventory || s.scan
		}
		urls := []string{}
		for _, kind := range []string{"file", "url"} {
			raw := tun[mode+"-package-"+kind]
			needInventory = needInventory || raw != nil
			sources, err := packageURLs(raw, kind == "url", field+"-"+kind, diagnostics)
			if err != nil {
				return nil, err
			}
			urls = append(urls, sources...)
		}
		hasSource = hasSource || len(urls) > 0
		if len(urls) > 0 && c.Lists == nil {
			return nil, errors.New("package list store is required")
		}
		// Results are consumed in declaration order regardless of completion order.
		for offset := 0; offset < len(urls); offset += 4 {
			end := offset + 4
			if end > len(urls) {
				end = len(urls)
			}
			type result struct {
				selectors []selector
				err       error
			}
			done := make([]chan result, end-offset)
			for i, address := range urls[offset:end] {
				done[i] = make(chan result, 1)
				go func(i int, address string) {
					body, err := c.Lists.Read(ctx, profileID, address)
					var parsed []selector
					if err == nil {
						parsed, err = parsePackageBody(body)
					}
					done[i] <- result{parsed, err}
				}(i, address)
			}
			for _, ready := range done {
				select {
				case <-ctx.Done():
					return nil, ctx.Err()
				case result := <-ready:
					if result.err != nil {
						return nil, result.err
					}
					groups[index] = append(groups[index], result.selectors...)
				}
			}
		}
	}
	if len(groups[0]) > 0 && len(groups[1]) > 0 {
		return nil, errors.New("Android profile split tunneling requires either include or exclude selectors")
	}
	inventory := []string{}
	if needInventory && (hasSource || len(groups[0]) > 0 || len(groups[1]) > 0) {
		if c.Capabilities.InstalledPackages == nil {
			return nil, errors.New("installed package inventory is unavailable")
		}
		var err error
		inventory, err = c.Capabilities.InstalledPackages(ctx)
		if err != nil {
			return nil, err
		}
		if len(inventory) == 0 {
			return nil, errors.New("installed package inventory is empty; check installed applications permission")
		}
	}
	for i, p := range inventory {
		inventory[i] = strings.TrimSpace(p)
	}
	access := Object(nil)
	for index, mode := range []string{"include", "exclude"} {
		if len(groups[index]) == 0 {
			if hasSource {
				delete(tun, mode+"-package")
			}
			continue
		}
		resolved := []any{}
		exists := map[string]bool{}
		apply := func(name string, include bool) {
			if include {
				if !exists[name] {
					exists[name] = true
					resolved = append(resolved, name)
				}
			} else if exists[name] {
				delete(exists, name)
				for i, v := range resolved {
					if v == name {
						resolved = append(resolved[:i], resolved[i+1:]...)
						break
					}
				}
			}
		}
		for _, s := range groups[index] {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			if len(inventory) == 0 {
				if !s.scan && s.inline {
					apply(s.pattern, s.include)
				}
				continue
			}
			for _, name := range inventory {
				if name == "" {
					continue
				}
				match := name == s.pattern
				if s.scan {
					var err error
					match, err = s.regex.MatchString(name)
					if err != nil {
						return nil, errors.New("package regular expression exceeded limits")
					}
				}
				if match {
					apply(name, s.include)
				}
			}
		}
		tun[mode+"-package"] = resolved
		if index == 0 {
			access = Object{"enable": true, "mode": "acceptSelected", "acceptList": resolved, "rejectList": []any{}}
		} else {
			access = Object{"enable": true, "mode": "rejectSelected", "acceptList": []any{}, "rejectList": resolved}
		}
	}
	for _, key := range []string{"include-package-file", "include-package-url", "exclude-package-file", "exclude-package-url"} {
		delete(tun, key)
	}
	if len(tun) > 0 {
		config["tun"] = tun
	}
	return access, nil
}
