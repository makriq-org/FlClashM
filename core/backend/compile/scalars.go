package compile

import (
	"errors"
	"math"
	"strconv"
	"strings"

	"go.yaml.in/yaml/v3"
)

// YAML v3's implicit resolver includes YAML 1.1 octal and timestamps. Profiles
// historically use Dart yaml's 1.2 scalar rules; apply those to parsed nodes.
func profileScalar(node *yaml.Node) (any, error) {
	value := node.Value
	explicit := node.Style&yaml.TaggedStyle != 0
	if explicit {
		switch node.ShortTag() {
		case "!!str":
			return value, nil
		case "!!null":
			if v, ok := nullScalar(value); ok {
				return v, nil
			}
		case "!!bool":
			if v, ok := boolScalar(value); ok {
				return v, nil
			}
		case "!!int":
			if v, ok := numericScalar(value, true, false); ok {
				return v, nil
			}
		case "!!float":
			if v, ok := numericScalar(value, false, true); ok {
				return v, nil
			}
		default:
			return nil, errors.New("unsupported profile YAML tag")
		}
		return nil, errors.New("invalid explicitly tagged YAML scalar")
	}
	if node.Style&(yaml.DoubleQuotedStyle|yaml.SingleQuotedStyle|yaml.LiteralStyle|yaml.FoldedStyle) != 0 {
		return value, nil
	}
	if v, ok := nullScalar(value); ok {
		return v, nil
	}
	if v, ok := boolScalar(value); ok {
		return v, nil
	}
	if v, ok := numericScalar(value, true, true); ok {
		return v, nil
	}
	return value, nil
}
func nullScalar(value string) (any, bool) {
	switch value {
	case "", "null", "Null", "NULL", "~":
		return nil, true
	}
	return nil, false
}
func boolScalar(value string) (bool, bool) {
	switch value {
	case "true", "True", "TRUE":
		return true, true
	case "false", "False", "FALSE":
		return false, true
	}
	return false, false
}
func numericScalar(value string, allowInt, allowFloat bool) (any, bool) {
	if value == "" || strings.Contains(value, "_") {
		return nil, false
	}
	if allowInt && strings.HasPrefix(value, "0x") {
		if n, err := strconv.ParseUint(value[2:], 16, 64); err == nil {
			return int64(n), true
		}
		return nil, false
	}
	if allowInt && strings.HasPrefix(value, "0o") {
		n, err := strconv.ParseInt(value[2:], 8, 64)
		return n, err == nil
	}
	startsDigit := value[0] >= '0' && value[0] <= '9'
	signedDigit := len(value) > 1 && (value[0] == '+' || value[0] == '-') && value[1] >= '0' && value[1] <= '9'
	if startsDigit || signedDigit {
		if allowInt {
			if n, err := strconv.ParseInt(value, 10, 64); err == nil {
				return n, true
			}
		}
		if allowFloat && !strings.ContainsAny(value, "xXpP") {
			if n, err := strconv.ParseFloat(value, 64); err == nil || errors.Is(err, strconv.ErrRange) {
				return n, true
			}
		}
		return nil, false
	}
	if !allowFloat {
		return nil, false
	}
	switch value {
	case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF":
		return math.Inf(1), true
	case "-.inf", "-.Inf", "-.INF":
		return math.Inf(-1), true
	case ".nan", ".NaN", ".NAN":
		return math.NaN(), true
	}
	if value[0] == '.' || len(value) > 1 && (value[0] == '+' || value[0] == '-') && value[1] == '.' {
		n, err := strconv.ParseFloat(value, 64)
		return n, err == nil || errors.Is(err, strconv.ErrRange)
	}
	return nil, false
}
