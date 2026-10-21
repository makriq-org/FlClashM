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

func defaultBypassDomains() []string {
	return []string{"*zhihu.com", "*zhimg.com", "*jd.com", "100ime-iat-api.xfyun.cn", "*360buyimg.com", "localhost", "*.local", "127.*", "10.*", "172.16.*", "172.17.*", "172.18.*", "172.19.*", "172.2*", "172.30.*", "172.31.*", "192.168.*"}
}
