package compile

import (
	"errors"
	"net"
	"net/netip"
	"strconv"
	"strings"
)

// buildQwdtt компилирует публичный контракт qWDTT в приватный JSON.
//
// Секреты (пароль подключения и пароль локального SOCKS5) попадают только в
// файл, который host пишет с правами 0600; в argv процесса их нет.
func buildQwdtt(raw Object, node *Node, serviceUser, servicePassword string) error {
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
	password := text(raw["password"])
	if strings.TrimSpace(password) == "" || controls(password) || strings.Contains(password, "|") || password != strings.TrimSpace(password) {
		return errors.New("password must be a nonempty single-line string without | or edge spaces")
	}

	hashes, err := qwdttHashes(raw["vk-hashes"])
	if err != nil {
		return err
	}
	workers, err := bounded(raw["workers"], 9, 1, maxQwdttWorkers)
	if err != nil {
		return err
	}
	if limit := 27 * len(hashes); workers > limit {
		return errors.New("workers exceed 27 per VK hash")
	}

	tunnel := strings.ToLower(strings.TrimSpace(text(raw["tunnel"])))
	if tunnel == "" {
		tunnel = "wireguard"
	}
	if !contains([]string{"wireguard", "wireguard-direct", "raw-ip"}, tunnel) {
		return errors.New("tunnel must be wireguard, wireguard-direct or raw-ip")
	}
	obfs := strings.ToLower(strings.TrimSpace(text(raw["obfs"])))
	if obfs == "" {
		obfs = "audio"
	}
	if obfs != "audio" && obfs != "video" {
		return errors.New("obfs must be audio or video")
	}
	udp := true
	if value, ok := raw["udp"]; ok {
		udp = value == true
	}
	transport := strings.ToLower(strings.TrimSpace(text(raw["turn-transport"])))
	if transport == "" {
		transport = "udp"
	}
	if transport != "udp" && transport != "tcp" {
		return errors.New("turn-transport must be udp or tcp")
	}

	turnServers := []string{}
	if value, ok := raw["turn-servers"]; ok {
		entries, ok := value.([]any)
		if !ok || len(entries) > 64 {
			return errors.New("turn-servers must be a list of at most 64 addresses")
		}
		for _, entry := range entries {
			address := strings.TrimSpace(text(entry))
			if _, _, err := qwdttTurnAddress(address); err != nil {
				return err
			}
			turnServers = append(turnServers, address)
		}
	}
	turnPort, err := bounded(raw["turn-port"], 0, 1, 65535)
	if err != nil {
		return err
	}

	dns := strings.TrimSpace(text(raw["dns-server"]))
	if dns == "" {
		dns = "system"
	}
	if dns != "system" {
		host, portText, err := net.SplitHostPort(dns)
		number, _ := strconv.Atoi(portText)
		if err != nil || host == "" || number < 1 || number > 65535 || strings.ContainsAny(host, "/@?# ") || controls(host) || strings.IndexByte(host, 92) >= 0 {
			return errors.New("dns-server must be host:port or system")
		}
		address, parseErr := netip.ParseAddr(strings.Trim(host, "[]"))
		if parseErr != nil || address.Zone() != "" {
			return errors.New("dns-server host must be an IP address")
		}
	}

	native := Object{
		"mode":           "socks",
		"peer":           net.JoinHostPort(server, strconv.Itoa(port)),
		"password":       password,
		"vk-hashes":      hashes,
		"workers":        workers,
		"tunnel":         tunnel,
		"obfs":           obfs,
		"udp":            udp,
		"turn-transport": transport,
		"dns-server":     dns,
		"socks": Object{
			"listen":    net.JoinHostPort(node.Host, strconv.Itoa(node.Port)),
			"username":  serviceUser,
			"password":  servicePassword,
			"auth":      true,
			"udp":       udp,
			"udp-token": udp,
		},
		"device-id":    node.ID,
		"captcha-mode": "native",
		"vk-auth":      "anonymous",
		"vk-anon-path": "vkcalls",
	}
	if len(turnServers) > 0 {
		native["turn-servers"] = turnServers
	}
	if turnPort > 0 {
		native["turn-port"] = turnPort
	}
	return artifact(node, "config.json", native)
}

const maxQwdttWorkers = 162

func qwdttHashes(value any) ([]string, error) {
	entries, ok := value.([]any)
	if !ok || len(entries) < 1 || len(entries) > 6 {
		return nil, errors.New("vk-hashes must contain 1 to 6 hashes")
	}
	hashes := make([]string, 0, len(entries))
	seen := map[string]bool{}
	for _, entry := range entries {
		hash := strings.TrimSpace(text(entry))
		if hash == "" || controls(hash) {
			return nil, errors.New("vk-hashes entries must be nonempty single-line strings")
		}
		if seen[hash] {
			return nil, errors.New("vk-hashes entries must be unique")
		}
		seen[hash] = true
		hashes = append(hashes, hash)
	}
	return hashes, nil
}

// qwdttTurnAddress проверяет адрес TURN-сервера и возвращает host и port
// (пустой порт означает «взять из turn-port или из ответа VK»).
func qwdttTurnAddress(value string) (string, string, error) {
	if value == "" || serverPattern.MatchString(value) {
		return "", "", errors.New("turn-servers entries must be host or host:port")
	}
	host, port, err := net.SplitHostPort(value)
	if err != nil {
		host, port = value, ""
		if strings.HasPrefix(value, "[") && strings.HasSuffix(value, "]") {
			host = value[1 : len(value)-1]
		}
	}
	host = strings.TrimSpace(host)
	if host == "" || strings.ContainsAny(host, "[]/") {
		return "", "", errors.New("turn-servers entries must be host or host:port")
	}
	if strings.Contains(host, ":") {
		if address, err := netip.ParseAddr(host); err != nil || address.Zone() != "" {
			return "", "", errors.New("invalid turn server address")
		}
	}
	if port != "" {
		n, err := strconv.Atoi(port)
		if err != nil || n < 1 || n > 65535 {
			return "", "", errors.New("turn server port must be within 1..65535")
		}
	}
	return host, port, nil
}
