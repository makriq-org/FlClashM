package compile

import (
	"errors"
	"fmt"
	"io"
	"strings"

	"go.yaml.in/yaml/v3"
)

type Object map[string]any

// ParseProfile preserves the legacy YAML merge order and materializes every
// nested map with string keys. Alias cycles and explosive expansion are bounded.
func ParseProfile(text string) (Object, error) {
	if len(text) > 16<<20 {
		return nil, errors.New("profile exceeds size limit")
	}
	var document yaml.Node
	decoder := yaml.NewDecoder(strings.NewReader(text))
	if err := decoder.Decode(&document); err != nil {
		return nil, err
	}
	var extra yaml.Node
	if err := decoder.Decode(&extra); err != io.EOF {
		return nil, errors.New("profile must contain a single YAML document")
	}
	if len(document.Content) != 1 || document.Content[0].Kind != yaml.MappingNode {
		return nil, errors.New("profile root must be a YAML map")
	}
	count := 0
	value, err := materialize(document.Content[0], map[*yaml.Node]bool{}, 0, &count)
	if err != nil {
		return nil, err
	}
	return value.(Object), nil
}
func materialize(node *yaml.Node, stack map[*yaml.Node]bool, depth int, count *int) (any, error) {
	*count++
	if depth > 128 || *count > 200000 {
		return nil, errors.New("profile structure exceeds limits")
	}
	if stack[node] {
		return nil, errors.New("cyclic YAML alias")
	}
	stack[node] = true
	defer delete(stack, node)
	switch node.Kind {
	case yaml.AliasNode:
		return materialize(node.Alias, stack, depth+1, count)
	case yaml.SequenceNode:
		if node.ShortTag() != "!!seq" {
			return nil, errors.New("unsupported profile YAML tag")
		}
		items := make([]any, 0, len(node.Content))
		for _, child := range node.Content {
			v, err := materialize(child, stack, depth+1, count)
			if err != nil {
				return nil, err
			}
			items = append(items, v)
		}
		return items, nil
	case yaml.MappingNode:
		if node.ShortTag() != "!!map" {
			return nil, errors.New("unsupported profile YAML tag")
		}
		result := Object{}
		explicit := map[string]bool{}
		for i := 0; i < len(node.Content); i += 2 {
			if node.Content[i].Value != "<<" {
				continue
			}
			merged, err := materialize(node.Content[i+1], stack, depth+1, count)
			if err != nil {
				return nil, err
			}
			merge := func(value any) error {
				m, ok := value.(Object)
				if !ok {
					return nil // Legacy materialization ignores non-map merge entries.
				}
				for k, v := range m {
					result[k] = v
				}
				return nil
			}
			if list, ok := merged.([]any); ok {
				for _, item := range list {
					if err = merge(item); err != nil {
						return nil, err
					}
				}
			} else if err = merge(merged); err != nil {
				return nil, err
			}
		}
		for i := 0; i < len(node.Content); i += 2 {
			keyNode := node.Content[i]
			if keyNode.Value == "<<" {
				continue
			}
			key, err := profileScalar(keyNode)
			if err != nil {
				return nil, err
			}
			name := fmt.Sprint(key)
			if key == nil {
				name = "null"
			}
			if explicit[name] {
				return nil, fmt.Errorf("duplicate profile key %q", name)
			}
			explicit[name] = true
			value, err := materialize(node.Content[i+1], stack, depth+1, count)
			if err != nil {
				return nil, err
			}
			result[name] = value
		}
		return result, nil
	case yaml.ScalarNode:
		return profileScalar(node)
	default:
		return nil, errors.New("unsupported YAML node")
	}
}
