package authoring

import (
	"errors"
	"strings"
)

var ruleActions = strings.Fields("DOMAIN DOMAIN-SUFFIX DOMAIN-KEYWORD DOMAIN-REGEX DOMAIN-WILDCARD GEOSITE IP-CIDR IP-CIDR6 IP-SUFFIX IP-ASN GEOIP SRC-GEOIP SRC-IP-ASN SRC-IP-CIDR SRC-IP-SUFFIX DST-PORT SRC-PORT IN-PORT IN-TYPE IN-USER IN-NAME REMATCH-NAME PROCESS-PATH PROCESS-PATH-REGEX PROCESS-PATH-WILDCARD PROCESS-NAME PROCESS-NAME-REGEX PROCESS-NAME-WILDCARD UID NETWORK DSCP RULE-SET AND OR NOT SUB-RULE MATCH")

func Action(row Object) string {
	return strings.ReplaceAll(strings.ToUpper(String(row, "ruleAction")), "_", "-")
}
func RuleLine(row Object) (string, error) {
	action := Action(row)
	known := false
	for _, a := range ruleActions {
		known = known || a == action
	}
	if !known {
		return "", errors.New("unsupported rule action")
	}
	payload, target := String(row, "content"), String(row, "ruleTarget")
	if action == "RULE-SET" {
		payload = String(row, "ruleProvider")
	}
	if action == "SUB-RULE" {
		target = String(row, "subRule")
	}
	if target == "" || strings.ContainsAny(target, ",\r\n\x00") {
		return "", errors.New("rule target is required")
	}
	fields := []string{action}
	if action != "MATCH" {
		if payload == "" || strings.ContainsAny(payload, "\r\n\x00") {
			return "", errors.New("rule payload is required")
		}
		fields = append(fields, payload)
	}
	fields = append(fields, target)
	if action == "GEOIP" || action == "IP-ASN" || action == "IP-CIDR" || action == "IP-CIDR6" || action == "IP-SUFFIX" || action == "RULE-SET" {
		if string(row["src"]) == "true" {
			fields = append(fields, "src")
		}
		if string(row["noResolve"]) == "true" {
			fields = append(fields, "no-resolve")
		}
	}
	return strings.Join(fields, ","), nil
}

// ParseRule keeps comma-bearing logical and regular expression payloads intact.
func ParseRule(line string) (Object, error) {
	fields := strings.Split(line, ",")
	for i := range fields {
		fields[i] = strings.TrimSpace(fields[i])
	}
	action := strings.ToUpper(fields[0])
	row := Object{"ruleAction": Value(strings.ReplaceAll(action, "-", "_"))}
	rest := fields[1:]
	if action == "MATCH" {
		if len(rest) == 1 {
			row["ruleTarget"] = Value(rest[0])
		}
	} else if action == "AND" || action == "OR" || action == "NOT" || action == "SUB-RULE" || strings.HasSuffix(action, "REGEX") {
		if len(rest) > 1 {
			row["content"] = Value(strings.Join(rest[:len(rest)-1], ","))
			key := "ruleTarget"
			if action == "SUB-RULE" {
				key = "subRule"
			}
			row[key] = Value(rest[len(rest)-1])
		}
	} else if len(rest) >= 2 {
		key := "content"
		if action == "RULE-SET" {
			key = "ruleProvider"
		}
		row[key] = Value(rest[0])
		row["ruleTarget"] = Value(rest[1])
		for _, param := range rest[2:] {
			switch param {
			case "src":
				row["src"] = Value(true)
			case "no-resolve":
				row["noResolve"] = Value(true)
			default:
				return nil, errors.New("unsupported rule parameter")
			}
		}
	}
	_, err := RuleLine(row)
	return row, err
}
