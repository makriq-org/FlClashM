package compile

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

//go:embed cli_schema.json
var cliJSON []byte

type cliOption struct {
	Short, Long, Kind, Scope string
	Repeatable               bool
	Contexts                 []string
	Forbidden                *string
}

var cliOptions = func() []cliOption {
	var options []cliOption
	if err := json.Unmarshal(cliJSON, &options); err != nil {
		panic(err)
	}
	return options
}()

// CLIArguments tokenizes the documented option language and validates it before
// passing argv directly to exec.Command. No shell evaluates profile contents.
func CLIArguments(source, context string) ([]string, error) {
	arguments, err := splitArguments(source)
	if err != nil {
		return nil, err
	}
	if len(arguments) == 0 {
		return nil, errors.New("ByeDPI strategy requires at least one option")
	}
	byLong, byShort := map[string]cliOption{}, map[string]cliOption{}
	for _, option := range cliOptions {
		byLong[option.Long] = option
		byShort[option.Short] = option
	}
	seen := map[string]bool{}
	group := 0
	record := func(option cliOption, value string) error {
		if option.Forbidden != nil {
			return errors.New("ByeDPI option is forbidden: " + option.Long)
		}
		if !contains(option.Contexts, context) {
			return errors.New("ByeDPI option unavailable in this context: " + option.Long)
		}
		if option.Kind != "none" && !validCLIValue(option.Kind, value) {
			return errors.New("invalid value for ByeDPI option: " + option.Long)
		}
		scope := fmt.Sprint(group)
		if option.Scope == "process" {
			scope = "process"
		}
		key := scope + ":" + option.Long
		if seen[key] && !option.Repeatable {
			return errors.New("repeated ByeDPI option: " + option.Long)
		}
		seen[key] = true
		if option.Scope == "groupSeparator" {
			group++
		}
		return nil
	}
	for i := 0; i < len(arguments); i++ {
		argument := arguments[i]
		if strings.HasPrefix(argument, "--") {
			name, value, hasValue := strings.Cut(argument[2:], "=")
			option, ok := byLong[name]
			if !ok {
				return nil, errors.New("unknown ByeDPI option: " + name)
			}
			if option.Kind != "none" {
				if !hasValue {
					i++
					if i >= len(arguments) {
						return nil, errors.New("ByeDPI option requires a value")
					}
					value = arguments[i]
				}
			} else if hasValue {
				return nil, errors.New("ByeDPI flag does not take a value")
			}
			if err = record(option, value); err != nil {
				return nil, err
			}
			continue
		}
		if !strings.HasPrefix(argument, "-") || len(argument) == 1 {
			return nil, errors.New("unexpected ByeDPI positional argument")
		}
		for offset := 1; offset < len(argument); {
			option, ok := byShort[argument[offset:offset+1]]
			if !ok {
				return nil, errors.New("unknown ByeDPI short option")
			}
			value := ""
			if option.Kind != "none" {
				if offset+1 < len(argument) {
					value = argument[offset+1:]
				} else {
					i++
					if i >= len(arguments) {
						return nil, errors.New("ByeDPI option requires a value")
					}
					value = arguments[i]
				}
				offset = len(argument)
			} else {
				offset++
			}
			if err = record(option, value); err != nil {
				return nil, err
			}
		}
	}
	return arguments, nil
}
func splitArguments(source string) ([]string, error) {
	args := []string{}
	var buffer strings.Builder
	var quote rune
	escape := false
	flush := func() {
		if buffer.Len() > 0 {
			args = append(args, buffer.String())
			buffer.Reset()
		}
	}
	for _, r := range source {
		if escape {
			buffer.WriteRune(r)
			escape = false
		} else if r == '\\' {
			escape = true
		} else if quote != 0 {
			if r == quote {
				quote = 0
			} else {
				buffer.WriteRune(r)
			}
		} else if r == '\'' || r == '"' {
			quote = r
		} else if unicode.IsSpace(r) {
			flush()
		} else {
			buffer.WriteRune(r)
		}
	}
	if quote != 0 || escape {
		return nil, errors.New("incomplete ByeDPI quote or escape")
	}
	flush()
	return args, nil
}

var timeoutPattern = regexp.MustCompile(`^\d+(?:\.\d+)?(?::\d+(?:\.\d+)?(?::\d+(?:\.\d+)?(?::\d+(?:\.\d+)?)?)?)?$`)
var rangePattern = regexp.MustCompile(`^(\d+)(?:-(\d+))?$`)
var positionPattern = regexp.MustCompile(`^-?(?:0[xX][0-9a-fA-F]+|0[0-7]+|\d+)(?::[1-9]\d*(?::\d+)?)?(?:\+[shn][shemrn]{0,2})?$`)
var fakeTLSPattern = regexp.MustCompile(`^(?:m|msize)=\d+$`)
var escapedPattern = regexp.MustCompile(`^\\(?:[rntrfbva\\]|x[0-9a-fA-F]{2}|[0-7]{1,3})$`)

func intRange(value string, min, max int64) bool {
	n, err := strconv.ParseInt(value, 10, 64)
	return err == nil && n >= min && n <= max
}
func cliRange(value string, min, max int64) bool {
	parts := rangePattern.FindStringSubmatch(value)
	if parts == nil {
		return false
	}
	first, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return false
	}
	last := first
	if parts[2] != "" {
		last, err = strconv.ParseInt(parts[2], 10, 64)
	}
	return err == nil && first >= min && last >= first && last <= max
}
func enumCLI(value string, allowed []string, priority bool) bool {
	for _, part := range strings.Split(value, ",") {
		if contains(allowed, part) {
			continue
		}
		if priority && strings.HasPrefix(part, "p=") {
			if _, err := strconv.ParseFloat(strings.TrimPrefix(part, "p="), 64); err == nil {
				continue
			}
		}
		return false
	}
	return value != ""
}
func validCLIValue(kind, value string) bool {
	if value == "" {
		return false
	}
	switch kind {
	case "none":
		return true
	case "text":
		return !controls(value)
	case "address":
		u, err := url.Parse("socket://" + value)
		return err == nil && u.Hostname() != "" && u.Port() == ""
	case "bufferSize":
		return intRange(value, 1, 536870911)
	case "connectionLimit":
		return intRange(value, 1, 32766)
	case "debugLevel":
		return intRange(value, 0, 2)
	case "positiveInteger":
		return intRange(value, 1, 2147483647)
	case "nonNegativeInteger":
		return intRange(value, 0, 2147483647)
	case "uint8":
		return intRange(value, 1, 255)
	case "timeout":
		return timeoutPattern.MatchString(value)
	case "autoDetect":
		return enumCLI(value, []string{"t", "r", "s", "n", "c", "torst", "redirect", "ssl_err", "none", "conn"}, true)
	case "autoMode":
		return enumCLI(value, []string{"s", "o", "n", "swop", "onreconn", "noreconn"}, false)
	case "inlineData":
		return strings.HasPrefix(value, ":") && len(value) > 1
	case "protocolList":
		return enumCLI(value, []string{"t", "h", "u", "i", "tls", "http", "udp", "ipv4"}, false)
	case "portRange":
		return cliRange(value, 1, 65535)
	case "positiveRange":
		return cliRange(value, 1, 2147483647)
	case "position":
		return positionPattern.MatchString(value)
	case "tlsRecordPosition":
		if !positionPattern.MatchString(value) {
			return false
		}
		raw := strings.Split(strings.Split(value, ":")[0], "+")[0]
		base := 10
		unsigned := strings.TrimPrefix(raw, "-")
		if strings.HasPrefix(strings.ToLower(unsigned), "0x") {
			base = 16
			unsigned = unsigned[2:]
		} else if len(unsigned) > 1 && strings.HasPrefix(unsigned, "0") {
			base = 8
		}
		n, err := strconv.ParseInt(unsigned, base, 64)
		if strings.HasPrefix(raw, "-") {
			n = -n
		}
		return err == nil && n <= 65535
	case "fakeTlsModifiers":
		for _, part := range strings.Split(value, ",") {
			if !contains([]string{"r", "o", "rand", "orig"}, part) && !fakeTLSPattern.MatchString(part) {
				return false
			}
		}
		return true
	case "escapedCharacter":
		return utf8.RuneCountInString(value) == 1 || escapedPattern.MatchString(value)
	case "httpModifiers":
		return enumCLI(value, []string{"h", "d", "r", "hcsmix", "dcsmix", "rmspace"}, false)
	}
	return false
}
