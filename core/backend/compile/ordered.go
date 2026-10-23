package compile

import (
	"bytes"
	"encoding/json"
	"sort"
)

// orderedObject is a JSON object that keeps its member order. Go maps encode
// with sorted keys, but the engine evaluates some dictionaries, such as
// dns.nameserver-policy, in declaration order.
type orderedObject struct {
	keys   []string
	values Object
}

// newOrderedObject lists the preferred keys that exist in values first, in
// the given order, followed by any remaining keys in sorted order.
func newOrderedObject(values Object, preferred []string) orderedObject {
	keys := make([]string, 0, len(values))
	seen := make(map[string]bool, len(values))
	for _, key := range preferred {
		if _, ok := values[key]; ok && !seen[key] {
			seen[key] = true
			keys = append(keys, key)
		}
	}
	rest := make([]string, 0, len(values)-len(keys))
	for key := range values {
		if !seen[key] {
			rest = append(rest, key)
		}
	}
	sort.Strings(rest)
	return orderedObject{keys: append(keys, rest...), values: values}
}

func (o orderedObject) MarshalJSON() ([]byte, error) {
	var buffer bytes.Buffer
	buffer.WriteByte('{')
	for i, key := range o.keys {
		if i > 0 {
			buffer.WriteByte(',')
		}
		name, err := json.Marshal(key)
		if err != nil {
			return nil, err
		}
		value, err := json.Marshal(o.values[key])
		if err != nil {
			return nil, err
		}
		buffer.Write(name)
		buffer.WriteByte(':')
		buffer.Write(value)
	}
	buffer.WriteByte('}')
	return buffer.Bytes(), nil
}

// jsonKeyOrder returns the member names of the JSON object at path in
// declaration order, or nil when the path does not lead to an object.
func jsonKeyOrder(raw []byte, path ...string) []string {
	for _, name := range path {
		var members map[string]json.RawMessage
		if json.Unmarshal(raw, &members) != nil {
			return nil
		}
		raw = members[name]
	}
	if len(raw) == 0 {
		return nil
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	if token, err := decoder.Token(); err != nil || token != json.Delim('{') {
		return nil
	}
	keys := []string{}
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil
		}
		key, ok := token.(string)
		if !ok {
			return nil
		}
		keys = append(keys, key)
		var skip json.RawMessage
		if decoder.Decode(&skip) != nil {
			return nil
		}
	}
	return keys
}
