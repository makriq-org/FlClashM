package compile

import (
	"bytes"
	_ "embed"
	"encoding/json"
)

// Defaults retain the existing settings format; they are filled by the backend
// rather than depending on a Flutter model constructor having run first.
//
//go:embed default_patch.json
var defaultPatch []byte

//go:embed bypass_routes.json
var privateRoutes []byte

func defaults() Object {
	var value Object
	decoder := json.NewDecoder(bytes.NewReader(defaultPatch))
	decoder.UseNumber()
	if err := decoder.Decode(&value); err != nil {
		panic(err)
	}
	return value
}
func bypassPrivateRoutes() []any {
	var value []any
	if err := json.Unmarshal(privateRoutes, &value); err != nil {
		panic(err)
	}
	return value
}
