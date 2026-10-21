package profiles

import "encoding/json"

// Preserve legacy compatibility transformations formerly performed by the
// Flutter Config factory. Unknown fields remain intact in the Go catalogue.
func compatibleSettings(settings Object) {
	var oldAccess, vpn Object
	if json.Unmarshal(settings["accessControl"], &oldAccess) == nil && oldAccess != nil && json.Unmarshal(settings["vpnProps"], &vpn) == nil && vpn != nil {
		var enabled bool
		_ = json.Unmarshal(settings["isAccessControl"], &enabled)
		oldAccess["enable"] = mustJSON(enabled)
		vpn["accessControl"] = mustJSON(oldAccess)
		settings["vpnProps"] = mustJSON(vpn)
	}
	var style Object
	if json.Unmarshal(settings["proxiesStyle"], &style) == nil && style != nil {
		var icon string
		_ = json.Unmarshal(style["iconStyle"], &icon)
		if icon == "standard" {
			style["iconStyle"] = mustJSON("icon")
			settings["proxiesStyle"] = mustJSON(style)
		}
	}
}
