package compile

import "go.yaml.in/yaml/v3"

// mihomo decodes an unquoted REALITY short-id as a YAML number, so 0123 is 83
// and 00 is 0. The scalar keeps its literal text, so retagging it to a string
// restores the id the profile wrote.
//
// The whole document is walked, not the merged result: a short-id inside a
// template that proxies reach through an alias lives in a section the merge
// drops, and retagging only the merged map would leave it numeric.
func retagShortIDs(node *yaml.Node) {
	if node == nil {
		return
	}
	if node.Kind == yaml.MappingNode {
		for i := 0; i+1 < len(node.Content); i += 2 {
			if node.Content[i].Value != "short-id" {
				continue
			}
			if retagged, ok := retagShortID(node.Content[i+1]); ok {
				node.Content[i+1] = retagged
			}
		}
	}
	for _, child := range node.Content {
		retagShortIDs(child)
	}
}

// A copy is retagged because an alias may be another key's value, such as a
// port, which must keep its number. Only one level is read: a short-id is an
// id or a flat list of them, and following nested aliases could recurse until
// the stack overflows on a self-referential document.
func retagShortID(node *yaml.Node) (*yaml.Node, bool) {
	target := resolveAlias(node)
	if target == nil {
		return node, false
	}
	if target.Kind != yaml.SequenceNode {
		return retagNumber(node)
	}
	changed := false
	items := make([]*yaml.Node, len(target.Content))
	for i, item := range target.Content {
		items[i], _ = retagNumber(item)
		changed = changed || items[i] != item
	}
	if !changed {
		return node, false
	}
	copied := *target
	copied.Anchor, copied.Content = "", items
	return &copied, true
}

func retagNumber(node *yaml.Node) (*yaml.Node, bool) {
	target := resolveAlias(node)
	if target == nil ||
		target.Kind != yaml.ScalarNode ||
		target.Style != 0 ||
		(target.Tag != "!!int" && target.Tag != "!!float") {
		return node, false
	}
	copied := *target
	copied.Anchor, copied.Tag = "", "!!str"
	// The materializer reads a plain scalar by its text, so the string tag has
	// to be explicit for the literal to survive.
	copied.Style |= yaml.TaggedStyle
	return &copied, true
}
