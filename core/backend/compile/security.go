package compile

import (
	"encoding/json"

	"core/backend/profiles"
)

// SecurityPolicy is applied to prepared settings before engine validation and
// plan sealing. It is backend policy; platform adapters only enforce its result.
type SecurityPolicy struct{}

func (SecurityPolicy) ApplyPatch(patch Object, metadata Object, capabilities Capabilities) {
	raw, _ := json.Marshal(metadata["providerHeaders"])
	headers := map[string]string{}
	_ = json.Unmarshal(raw, &headers)
	if profiles.ProviderSpecial(headers, "noglobal") && patch["mode"] == "global" {
		patch["mode"] = "rule"
	}
	if capabilities.Platform != "android" {
		return
	}
	if profiles.ProviderSpecial(headers, "androidsecure") {
		patch["mixed-port"] = 0
	}
}
func (SecurityPolicy) AccessControl(access Object, capabilities Capabilities) Object {
	if capabilities.Platform == "android" {
		return selfBypass(access, capabilities.SelfPackages)
	}
	return copyObject(access)
}
