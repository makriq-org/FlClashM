package compile

import (
	"fmt"
	"strings"
)

// AppIsolationSettingKey mirrors the Dart owned-setting key. The engine never
// sees tun.app-isolation: the compiled mode belongs to the Android host, which
// enforces it inside the TUN reader.
const AppIsolationSettingKey = "clash.tun.app-isolation"

const appIsolationField = "app-isolation"

// AppIsolation modes accepted from a profile or the local setting.
const (
	AppIsolationOff      = "off"
	AppIsolationBalanced = "balanced"
	AppIsolationStrict   = "strict"
)

func validAppIsolation(value string) bool {
	switch value {
	case AppIsolationOff, AppIsolationBalanced, AppIsolationStrict:
		return true
	}
	return false
}

// parseAppIsolation validates one declared value. A non-string or unknown
// value is an error: silently disabling the guard is never acceptable.
func parseAppIsolation(value any, field string) (string, error) {
	text, ok := value.(string)
	if !ok {
		return "", fmt.Errorf("%s must be off, balanced or strict", field)
	}
	mode := strings.ToLower(strings.TrimSpace(text))
	if !validAppIsolation(mode) {
		return "", fmt.Errorf("%s must be off, balanced or strict, not %q", field, text)
	}
	return mode, nil
}

// resolveAppIsolation picks the mode handed to the Android host and removes the
// client-only key from both the engine config and the resolved patch.
//
// Precedence matches the other `clash.*` hints: a profile value applies while
// the user has neither taken the setting over nor asked local network settings
// to override the subscription. Otherwise the local setting wins, and without
// either the compatibility default is balanced.
func (c *Compiler) resolveAppIsolation(config, patch, settings Object, override bool) (Object, error) {
	android := c.Capabilities.Platform == "android"
	tun := object(config["tun"])
	rawProfile, profilePresent := tun[appIsolationField]
	delete(tun, appIsolationField)
	config["tun"] = tun
	patchTun := object(patch["tun"])
	rawLocal, localPresent := patchTun[appIsolationField]
	delete(patchTun, appIsolationField)
	patch["tun"] = patchTun

	profilesWins := profilePresent && !override && !ownsSetting(settings, AppIsolationSettingKey)
	mode, source := AppIsolationBalanced, "default"
	if profilesWins {
		profileMode, err := parseAppIsolation(rawProfile, "tun.app-isolation")
		if err != nil {
			if !android {
				// The key is an Android client extension; a desktop profile that
				// carries it stays loadable and the value is ignored.
				return Object{}, nil
			}
			return nil, err
		}
		mode, source = profileMode, "profile"
	} else if localPresent {
		localMode, err := parseAppIsolation(rawLocal, "tun.app-isolation")
		if err != nil {
			if !android {
				// The key only drives the Android guard; a desktop profile that
				// carries it stays loadable and the value is ignored.
				return Object{}, nil
			}
			return nil, err
		}
		mode, source = localMode, "user"
	}
	if !android {
		return Object{}, nil
	}
	return Object{"mode": mode, "source": source}, nil
}
