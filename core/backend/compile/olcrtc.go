package compile

import (
	"errors"
	"net"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var keyPattern = regexp.MustCompile(`^[0-9a-fA-F]{64}$`)

func required(raw Object, key string) (string, error) {
	value := text(raw[key])
	if value == "" || value != strings.TrimSpace(value) {
		return "", errors.New(key + " must be a nonempty trimmed string")
	}
	return value, nil
}
func buildOlcRTC(raw Object, node *Node) error {
	provider, err := required(raw, "provider")
	if err != nil {
		return err
	}
	if provider == "none" {
		for _, key := range []string{"engine", "engine-url", "engine-token"} {
			if _, err = required(raw, key); err != nil {
				return err
			}
		}
	} else {
		if _, err = required(raw, "room"); err != nil {
			return err
		}
		for _, key := range []string{"engine", "engine-url", "engine-token"} {
			if text(raw[key]) != "" {
				return errors.New("direct engine fields require provider none")
			}
		}
	}
	key, err := required(raw, "encryption-key")
	if err != nil || !keyPattern.MatchString(key) {
		return errors.New("encryption-key requires 64 hexadecimal characters")
	}
	dns, err := required(raw, "dns-server")
	if err != nil {
		return err
	}
	if dns != "system" {
		host, port, err := net.SplitHostPort(dns)
		n, _ := strconv.Atoi(port)
		if err != nil || host == "" || n < 1 || n > 65535 || strings.ContainsAny(host, "/@?# ") || controls(host) || strings.IndexByte(host, 92) >= 0 {
			return errors.New("dns-server must be host:port or system")
		}
	}
	transport := text(raw["transport"])
	options := copyObject(object(raw["transport-options"]))
	allowed := map[string][]string{"vp8channel": {"fps", "batch-size"}, "seichannel": {"fps", "batch-size", "fragment-size", "ack-timeout"}, "videochannel": {"codec", "width", "height", "fps", "bitrate", "fragment-size", "qr-recovery", "tile-module", "tile-rs"}}
	if transport == "datachannel" {
		if _, ok := raw["transport-options"]; ok {
			return errors.New("datachannel does not accept transport-options")
		}
	} else {
		for key := range options {
			if !contains(allowed[transport], key) {
				return errors.New("option is incompatible with the selected olcrtc transport")
			}
		}
	}
	if transport == "videochannel" {
		codec := text(options["codec"])
		if codec == "" {
			codec = "qrcode"
		}
		if codec == "tile" {
			if _, ok := options["fragment-size"]; ok {
				return errors.New("tile codec does not accept QR options")
			}
			if _, ok := options["qr-recovery"]; ok {
				return errors.New("tile codec does not accept QR options")
			}
			for _, dimension := range []string{"width", "height"} {
				if n, ok := number(options[dimension]); ok && n != 1080 {
					return errors.New("tile codec requires 1080 by 1080")
				}
			}
		} else {
			for _, key := range []string{"tile-module", "tile-rs"} {
				if _, ok := options[key]; ok {
					return errors.New("QR codec does not accept tile options")
				}
			}
		}
		delete(options, "bitrate")
	}
	if transport == "seichannel" {
		if n, ok := number(options["fragment-size"]); ok && (n < 1 || n > 60000) {
			return errors.New("SEI fragment size is outside supported range")
		}
	}
	auth := Object{"provider": provider}
	if value, ok := raw["provider-token"]; ok {
		auth["token"] = value
	}
	native := Object{"mode": "cnc", "auth": auth, "crypto": Object{"key": key}, "net": Object{"transport": transport, "dns": dns}, "socks": Object{"host": "127.0.0.1", "port": node.Port}}
	if dns == "system" {
		object(native["net"])["dns"] = "@flclashm-system-dns@"
		node.Metadata["depends-on-system-dns"] = "true"
	}
	if room, channel := raw["room"], raw["room-channel"]; room != nil || channel != nil {
		value := Object{}
		if room != nil {
			value["id"] = room
		}
		if channel != nil {
			value["channel"] = channel
		}
		native["room"] = value
	}
	if raw["engine"] != nil {
		native["engine"] = Object{"name": raw["engine"], "url": raw["engine-url"], "token": raw["engine-token"]}
	}
	section := map[string]string{"videochannel": "video", "vp8channel": "vp8", "seichannel": "sei"}[transport]
	if section != "" {
		nativeOptions := Object{}
		aliases := map[string]string{"batch-size": "batch_size", "fragment-size": "fragment_size"}
		if section == "video" {
			aliases = map[string]string{"fragment-size": "qr_size", "qr-recovery": "qr_recovery", "tile-module": "tile_module", "tile-rs": "tile_rs"}
		}
		for key, value := range options {
			target := key
			if alias, ok := aliases[key]; ok {
				target = alias
			}
			nativeOptions[target] = value
		}
		if section == "sei" {
			duration, err := Duration(options["ack-timeout"], 2*time.Second, 24*time.Hour, false)
			if err != nil {
				return err
			}
			delete(nativeOptions, "ack-timeout")
			nativeOptions["ack_timeout_ms"] = duration.Milliseconds()
		}
		native[section] = nativeOptions
	}
	for section, keys := range map[string][]string{"liveness": {"interval", "timeout"}, "lifecycle": {"max-session-duration"}, "traffic": {"min-delay", "max-delay"}} {
		fields, ok := asObject(raw[section])
		if !ok {
			continue
		}
		converted := Object{}
		for key, value := range fields {
			converted[strings.ReplaceAll(key, "-", "_")] = value
		}
		for _, key := range keys {
			if value, ok := fields[key]; ok {
				maximum := 24 * time.Hour
				if section == "lifecycle" {
					maximum = 365 * 24 * time.Hour
				}
				duration, err := Duration(value, 0, maximum, section == "traffic")
				if err != nil {
					return err
				}
				converted[strings.ReplaceAll(key, "-", "_")] = duration.String()
			}
		}
		native[section] = converted
	}
	traffic := object(raw["traffic"])
	min, err := Duration(traffic["min-delay"], 0, 24*time.Hour, true)
	if err != nil {
		return err
	}
	max, err := Duration(traffic["max-delay"], 0, 24*time.Hour, true)
	if err != nil {
		return err
	}
	if max > 0 && max < min {
		return errors.New("traffic max-delay is below min-delay")
	}
	if n, ok := number(traffic["max-payload-size"]); ok && n != 0 && n < 53 {
		return errors.New("traffic payload size must be zero or at least 53")
	}
	if value, ok := raw["debug"]; ok {
		native["debug"] = value
	}
	return artifact(node, "config.yaml", native)
}
