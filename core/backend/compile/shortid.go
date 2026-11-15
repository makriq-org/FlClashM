package compile

import (
	"errors"

	"go.yaml.in/yaml/v3"
)

// maxShortIDNodes bounds the work and the copies retagging makes. One anchor
// may be reused by many short-id fields, and a field holding a list needs its
// own copy of that list, so a document well inside the size limit could still
// ask for millions of nodes. The budget is spent before anything is allocated,
// so the profile fails instead of exhausting memory.
const maxShortIDNodes = 500_000

// shortIDBudget counts the nodes retagging has walked and copied.
type shortIDBudget struct{ nodes int }

func (b *shortIDBudget) spend(count int) error {
	b.nodes += count
	if b.nodes > maxShortIDNodes {
		return errors.New("profile short-id aliases exceed limits")
	}
	return nil
}

// mihomo decodes an unquoted REALITY short-id as a YAML number, so 0123 is 83
// and 00 is 0. The scalar keeps its literal text, so retagging it to a string
// restores the id the profile wrote.
//
// The whole document is walked, not the merged result: a short-id inside a
// template that proxies reach through an alias lives in a section the merge
// drops, and retagging only the merged map would leave it numeric.
func retagShortIDs(node *yaml.Node) error {
	budget := &shortIDBudget{}
	return retagShortIDsWithin(node, budget)
}

func retagShortIDsWithin(node *yaml.Node, budget *shortIDBudget) error {
	if node == nil {
		return nil
	}
	if err := budget.spend(1); err != nil {
		return err
	}
	if node.Kind == yaml.MappingNode {
		for i := 0; i+1 < len(node.Content); i += 2 {
			if node.Content[i].Value != "short-id" {
				continue
			}
			retagged, ok, err := retagShortID(node.Content[i+1], budget)
			if err != nil {
				return err
			}
			if ok {
				node.Content[i+1] = retagged
			}
		}
	}
	for _, child := range node.Content {
		if err := retagShortIDsWithin(child, budget); err != nil {
			return err
		}
	}
	return nil
}

// A copy is retagged because an alias may be another key's value, such as a
// port, which must keep its number. Only one level is read: a short-id is an
// id or a flat list of them, and following nested aliases could recurse until
// the stack overflows on a self-referential document.
func retagShortID(node *yaml.Node, budget *shortIDBudget) (*yaml.Node, bool, error) {
	target := resolveAlias(node)
	if target == nil {
		return node, false, nil
	}
	if target.Kind != yaml.SequenceNode {
		retagged, ok := retagNumber(node)
		return retagged, ok, nil
	}
	// Charge the copy before making it: the list is duplicated for every field
	// that names it.
	if err := budget.spend(len(target.Content) + 1); err != nil {
		return node, false, err
	}
	changed := false
	items := make([]*yaml.Node, len(target.Content))
	for i, item := range target.Content {
		items[i], _ = retagNumber(item)
		changed = changed || items[i] != item
	}
	if !changed {
		return node, false, nil
	}
	copied := *target
	copied.Anchor, copied.Content = "", items
	return &copied, true, nil
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
