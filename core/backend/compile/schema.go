package compile

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"time"
)

//go:embed node_schema.json
var schemaJSON []byte

type Field struct {
	Path             string   `json:"path"`
	Type             string   `json:"type"`
	Additional       []string `json:"additionalTypes"`
	Required         bool     `json:"required"`
	Modes            []string `json:"modes"`
	Allowed          []any    `json:"allowedValues"`
	HasDefault       bool     `json:"hasDefault"`
	Default          any      `json:"default"`
	Minimum          *float64 `json:"minimum"`
	Maximum          *float64 `json:"maximum"`
	ExclusiveMinimum bool     `json:"exclusiveMinimum"`
	Forbidden        *string  `json:"forbidden"`
}

var schemas = func() map[string][]Field {
	var data map[string][]Field
	if err := json.Unmarshal(schemaJSON, &data); err != nil {
		panic(err)
	}
	return data
}()

func ValidateNode(node Object, nodeType, mode string) error {
	fields, ok := schemas[nodeType]
	if !ok {
		return errors.New("unknown external transport")
	}
	byPath := map[string]Field{}
	for _, field := range fields {
		byPath[field.Path] = field
	}
	return validateObject(node, nodeType, mode, fields, byPath)
}
func validateObject(node Object, parent, mode string, fields []Field, byPath map[string]Field) error {
	direct := map[string]Field{}
	for _, field := range fields {
		key, ok := strings.CutPrefix(field.Path, parent+".")
		if ok && !strings.Contains(key, ".") && !strings.HasSuffix(key, "[]") {
			direct[key] = field
		}
	}
	for key, value := range node {
		field, ok := direct[key]
		if !ok {
			return fmt.Errorf("%s.%s is unknown", parent, key)
		}
		if field.Forbidden != nil {
			return fmt.Errorf("%s is forbidden", field.Path)
		}
		if len(field.Modes) > 0 && !contains(field.Modes, mode) {
			return fmt.Errorf("%s is unavailable in mode %s", field.Path, mode)
		}
		if err := validateValue(value, field); err != nil {
			return err
		}
		if object, ok := asObject(value); ok {
			hasChildren := false
			for _, candidate := range fields {
				if strings.HasPrefix(candidate.Path, field.Path+".") {
					hasChildren = true
					break
				}
			}
			if hasChildren {
				if err := validateObject(object, field.Path, mode, fields, byPath); err != nil {
					return err
				}
			}
		} else if list, ok := value.([]any); ok {
			if item, exists := byPath[field.Path+"[]"]; exists {
				for _, value := range list {
					if err := validateValue(value, item); err != nil {
						return err
					}
					if object, ok := asObject(value); ok {
						if err := validateObject(object, item.Path, mode, fields, byPath); err != nil {
							return err
						}
					}
				}
			}
		}
	}
	for key, field := range direct {
		if field.Required && field.Forbidden == nil && (len(field.Modes) == 0 || contains(field.Modes, mode)) {
			if _, ok := node[key]; !ok {
				return fmt.Errorf("%s is required", field.Path)
			}
		}
	}
	return nil
}
func validateValue(value any, field Field) error {
	matches := matchesType(value, field.Type)
	if !matches {
		for _, t := range field.Additional {
			matches = matches || matchesType(value, t)
		}
	}
	if !matches {
		return fmt.Errorf("%s must be %s", field.Path, field.Type)
	}
	if len(field.Allowed) > 0 && matchesType(value, field.Type) {
		found := false
		for _, allowed := range field.Allowed {
			if reflect.DeepEqual(value, allowed) {
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("%s has an unsupported value", field.Path)
		}
	}
	if n, ok := number(value); ok {
		if math.IsNaN(n) || math.IsInf(n, 0) || (field.Minimum != nil && (n < *field.Minimum || (field.ExclusiveMinimum && n == *field.Minimum))) || (field.Maximum != nil && n > *field.Maximum) {
			return fmt.Errorf("%s is outside its supported range", field.Path)
		}
	}
	return nil
}
func matchesType(value any, kind string) bool {
	switch kind {
	case "string":
		_, ok := value.(string)
		return ok
	case "boolean":
		_, ok := value.(bool)
		return ok
	case "object":
		_, ok := asObject(value)
		return ok
	case "list":
		_, ok := value.([]any)
		return ok
	case "integer":
		switch n := value.(type) {
		case int, int64, uint64:
			return true
		case json.Number:
			_, err := n.Int64()
			return err == nil
		}
	case "number":
		n, ok := number(value)
		return ok && !math.IsNaN(n) && !math.IsInf(n, 0)
	}
	return false
}
func asObject(value any) (Object, bool) {
	switch v := value.(type) {
	case Object:
		return v, true
	case map[string]any:
		return Object(v), true
	}
	return nil, false
}
func object(value any) Object {
	if v, ok := asObject(value); ok {
		return v
	}
	return Object{}
}
func number(value any) (float64, bool) {
	switch n := value.(type) {
	case float64:
		return n, true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	case uint64:
		return float64(n), true
	case json.Number:
		v, err := n.Float64()
		return v, err == nil
	}
	return 0, false
}
func contains(list []string, value string) bool {
	for _, v := range list {
		if v == value {
			return true
		}
	}
	return false
}

var durationPattern = regexp.MustCompile(`^(\d+)(ms|s|m|h|d)$`)

func Duration(value any, fallback, maximum time.Duration, zero bool) (time.Duration, error) {
	if value == nil {
		return fallback, nil
	}
	var result time.Duration
	if text, ok := value.(string); ok {
		parts := durationPattern.FindStringSubmatch(text)
		if parts == nil {
			return 0, errors.New("duration requires an explicit unit")
		}
		n, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return 0, errors.New("duration exceeds limit")
		}
		unit := map[string]time.Duration{"ms": time.Millisecond, "s": time.Second, "m": time.Minute, "h": time.Hour, "d": 24 * time.Hour}[parts[2]]
		if n > uint64(maximum/unit) {
			return 0, errors.New("duration exceeds limit")
		}
		result = time.Duration(n) * unit
	} else {
		n, ok := number(value)
		if !ok || !matchesType(value, "integer") || n < 0 || n > maximum.Seconds() {
			return 0, errors.New("invalid duration")
		}
		result = time.Duration(n) * time.Second
	}
	if result < 0 || (!zero && result == 0) || result > maximum {
		return 0, errors.New("duration outside supported limits")
	}
	return result, nil
}
