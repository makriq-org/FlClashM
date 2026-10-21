package compile

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"time"
)

var serverPattern = regexp.MustCompile(`[,/@?#\\\s]`)
var headerPattern = regexp.MustCompile("^[!#$%&'*+\\-.^_`|~0-9A-Za-z]+$")

func controls(value string) bool {
	for _, r := range value {
		if r < 32 || r == 127 {
			return true
		}
	}
	return false
}
func buildNaive(raw Object, node *Node) error {
	server := strings.TrimSpace(text(raw["server"]))
	if server == "" || serverPattern.MatchString(server) {
		return errors.New("server must be a host name or IP")
	}
	if strings.ContainsAny(server, "[]:") {
		address, err := netip.ParseAddr(strings.TrimSuffix(strings.TrimPrefix(server, "["), "]"))
		if err != nil || address.Zone() != "" {
			return errors.New("invalid server address")
		}
		server = address.String()
	}
	port, err := bounded(raw["port"], 0, 1, 65535)
	if err != nil {
		return err
	}
	user, password := text(raw["username"]), text(raw["password"])
	if strings.TrimSpace(user) == "" || strings.TrimSpace(password) == "" {
		return errors.New("credentials must be nonempty strings")
	}
	transport := text(raw["transport"])
	if transport == "" {
		transport = "https"
	}
	proxy := url.URL{Scheme: transport, User: url.UserPassword(user, password), Host: net.JoinHostPort(server, fmt.Sprint(port))}
	native := Object{"listen": fmt.Sprintf("socks://127.0.0.1:%d", node.Port), "proxy": proxy.String()}
	if value, ok := raw["insecure-concurrency"]; ok {
		native["insecure-concurrency"] = value
	}
	for _, key := range []string{"tunnel-timeout", "idle-timeout"} {
		if value, ok := raw[key]; ok {
			seconds, err := wholeSeconds(value, 0, 2147483647*time.Second, false)
			if err != nil {
				return err
			}
			native[key] = seconds
		}
	}
	if raw["post-quantum"] == false {
		native["no-post-quantum"] = true
	}
	if headers, ok := asObject(raw["headers"]); ok {
		names := make([]string, 0, len(headers))
		for name := range headers {
			names = append(names, name)
		}
		sort.Strings(names)
		lines := []string{}
		for _, name := range names {
			value, ok := headers[name].(string)
			if !headerPattern.MatchString(name) || !ok || controls(value) {
				return errors.New("invalid naiveproxy header")
			}
			lines = append(lines, name+": "+value)
		}
		if len(lines) > 0 {
			native["extra-headers"] = strings.Join(lines, "\r\n")
		}
	}
	if value, ok := raw["host-resolver-rules"]; ok {
		rules := strings.TrimSpace(text(value))
		if rules == "" || controls(rules) {
			return errors.New("host-resolver-rules must be a single line")
		}
		native["host-resolver-rules"] = rules
	}
	return artifact(node, "config.json", native)
}
