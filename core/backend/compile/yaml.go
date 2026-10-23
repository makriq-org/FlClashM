package compile

import (
	"errors"
	"fmt"
	"io"
	"strings"

	"go.yaml.in/yaml/v3"
)

type Object map[string]any

// maxAliasExpansion bounds values materialized through YAML aliases. Values
// written directly in the document are already bounded by the profile size;
// aliases are not, so a "billion laughs" document must fail before it exhausts
// memory, while a large profile reusing anchors (for example hundreds of
// groups merging one list of thousands of proxies) remains valid.
const maxAliasExpansion = 2_000_000

// maxYAMLDepth bounds nesting, including nesting reached through aliases.
const maxYAMLDepth = 128

// ParseProfile preserves the legacy YAML merge order and materializes every
// nested map with string keys. Alias cycles and explosive expansion are bounded.
func ParseProfile(text string) (Object, error) {
	value, _, err := parseProfile(text)
	return value, err
}

// parseProfile also reports the declaration order of dns.nameserver-policy,
// which the engine evaluates in order but a Go map cannot retain.
func parseProfile(text string) (Object, []string, error) {
	if len(text) > 16<<20 {
		return nil, nil, errors.New("profile exceeds size limit")
	}
	var document yaml.Node
	decoder := yaml.NewDecoder(strings.NewReader(text))
	if err := decoder.Decode(&document); err != nil {
		return nil, nil, err
	}
	var extra yaml.Node
	if err := decoder.Decode(&extra); err != io.EOF {
		return nil, nil, errors.New("profile must contain a single YAML document")
	}
	if len(document.Content) != 1 || document.Content[0].Kind != yaml.MappingNode {
		return nil, nil, errors.New("profile root must be a YAML map")
	}
	root := document.Content[0]
	m := materializer{stack: map[*yaml.Node]bool{}}
	value, err := m.materialize(root, 0, false)
	if err != nil {
		return nil, nil, err
	}
	order := mappingKeyOrder(mappingValue(mappingValue(root, "dns"), "nameserver-policy"), 0)
	return value.(Object), order, nil
}

type materializer struct {
	stack    map[*yaml.Node]bool
	expanded int
}

func (m *materializer) materialize(node *yaml.Node, depth int, aliased bool) (any, error) {
	if aliased {
		m.expanded++
	}
	if depth > maxYAMLDepth || m.expanded > maxAliasExpansion {
		return nil, errors.New("profile structure exceeds limits")
	}
	if m.stack[node] {
		return nil, errors.New("cyclic YAML alias")
	}
	m.stack[node] = true
	defer delete(m.stack, node)
	switch node.Kind {
	case yaml.AliasNode:
		return m.materialize(node.Alias, depth+1, true)
	case yaml.SequenceNode:
		if node.ShortTag() != "!!seq" {
			return nil, errors.New("unsupported profile YAML tag")
		}
		items := make([]any, 0, len(node.Content))
		for _, child := range node.Content {
			v, err := m.materialize(child, depth+1, aliased)
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
			merged, err := m.materialize(node.Content[i+1], depth+1, aliased)
			if err != nil {
				return nil, err
			}
			merge := func(value any) {
				values, ok := value.(Object)
				if !ok {
					return // Legacy materialization ignores non-map merge entries.
				}
				for k, v := range values {
					result[k] = v
				}
			}
			if list, ok := merged.([]any); ok {
				for _, item := range list {
					merge(item)
				}
			} else {
				merge(merged)
			}
		}
		for i := 0; i < len(node.Content); i += 2 {
			keyNode := node.Content[i]
			if keyNode.Value == "<<" {
				continue
			}
			name, err := profileKey(keyNode)
			if err != nil {
				return nil, err
			}
			if explicit[name] {
				return nil, fmt.Errorf("duplicate profile key %q", name)
			}
			explicit[name] = true
			value, err := m.materialize(node.Content[i+1], depth+1, aliased)
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

func profileKey(node *yaml.Node) (string, error) {
	key, err := profileScalar(node)
	if err != nil {
		return "", err
	}
	if key == nil {
		return "null", nil
	}
	return fmt.Sprint(key), nil
}

func resolveAlias(node *yaml.Node) *yaml.Node {
	for depth := 0; node != nil && node.Kind == yaml.AliasNode && depth <= maxYAMLDepth; depth++ {
		node = node.Alias
	}
	return node
}

// mappingValue returns the explicit value of key in a (possibly aliased) map.
func mappingValue(node *yaml.Node, key string) *yaml.Node {
	node = resolveAlias(node)
	if node == nil || node.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		if node.Content[i].Value == "<<" {
			continue
		}
		if name, err := profileKey(node.Content[i]); err == nil && name == key {
			return resolveAlias(node.Content[i+1])
		}
	}
	return nil
}

// mappingKeyOrder lists the keys of a map in declaration order; merged keys
// appear at the position of their merge entry.
func mappingKeyOrder(node *yaml.Node, depth int) []string {
	node = resolveAlias(node)
	if node == nil || node.Kind != yaml.MappingNode || depth > maxYAMLDepth {
		return nil
	}
	keys := []string{}
	seen := map[string]bool{}
	add := func(names []string) {
		for _, name := range names {
			if !seen[name] {
				seen[name] = true
				keys = append(keys, name)
			}
		}
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		if node.Content[i].Value == "<<" {
			merged := resolveAlias(node.Content[i+1])
			if merged != nil && merged.Kind == yaml.SequenceNode {
				for _, item := range merged.Content {
					add(mappingKeyOrder(item, depth+1))
				}
			} else {
				add(mappingKeyOrder(merged, depth+1))
			}
			continue
		}
		if name, err := profileKey(node.Content[i]); err == nil {
			add([]string{name})
		}
	}
	return keys
}
