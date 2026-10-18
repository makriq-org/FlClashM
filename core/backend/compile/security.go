package compile

import "strings"

// SecurityPolicy is applied to prepared settings before engine validation and
// plan sealing. It is backend policy; platform adapters only enforce its result.
type SecurityPolicy struct{}

func (SecurityPolicy) ApplyPatch(patch Object, metadata Object, capabilities Capabilities) {
	headers := object(metadata["providerHeaders"])
	globalMode, present := headers["flclashm-globalmode"]
	if !present {
		globalMode = headers["flclashx-globalmode"]
	}
	if strings.EqualFold(strings.TrimSpace(text(globalMode)), "false") && patch["mode"] == "global" {
		patch["mode"] = "rule"
	}
	if capabilities.Platform != "android" {
		return
	}
	value, ok := headers["flclashm-androidsecure"]
	if !ok {
		value = headers["flclashx-androidsecure"]
	}
	if strings.EqualFold(strings.TrimSpace(text(value)), "true") {
		patch["mixed-port"] = 0
	}
}
func (SecurityPolicy) AccessControl(access Object, capabilities Capabilities) Object {
	if capabilities.Platform == "android" {
		return selfBypass(access, capabilities.SelfPackages)
	}
	return copyObject(access)
}
