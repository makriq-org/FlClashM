package compile

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"
	"strings"
)

// Inspection prepares read-only editor information without loading an engine
// configuration, running scripts or creating an execution capability.
type Inspection struct {
	Base          Object   `json:"base"`
	Outbounds     Object   `json:"outbounds"`
	Config        Object   `json:"config"`
	AccessControl Object   `json:"accessControl,omitempty"`
	Diagnostics   []string `json:"diagnostics"`
}

func (c *Compiler) Inspect(ctx context.Context, source, profileID string) (Inspection, error) {
	config, err := ParseProfile(source)
	if err != nil {
		return Inspection{}, err
	}
	diagnostics := []string{}
	var access Object
	if c.Capabilities.Platform == "android" {
		access, err = c.splitPackages(ctx, copyObject(config), profileID, &diagnostics)
		if err != nil {
			return Inspection{}, err
		}
		if access != nil {
			access = c.Policy.AccessControl(access, c.Capabilities)
		}
	}
	result := Inspection{Config: config, AccessControl: access, Diagnostics: diagnostics}
	fillInspection(&result, source)
	return result, ctx.Err()
}

// InspectProfile uses repository-captured inputs for custom profiles; ordinary
// files are returned exactly as parsed, with no script or runtime execution.
func (c *Compiler) InspectProfile(ctx context.Context, input []byte) (Inspection, error) {
	var request Input
	dec := json.NewDecoder(bytes.NewReader(input))
	dec.UseNumber()
	if err := dec.Decode(&request); err != nil {
		return Inspection{}, err
	}
	if request.Profile == nil {
		return Inspection{}, errors.New("profile not found")
	}
	var result Inspection
	var err error
	if request.Profile.Metadata["type"] == "custom" {
		result.Config, err = c.customConfig(ctx, request)
		if err == nil {
			_, err = c.applyKeyOverrides(result.Config, request.Settings, request.Profile.Metadata)
		}
		result.Diagnostics = []string{}
		if err == nil && c.Capabilities.Platform == "android" {
			result.AccessControl, err = c.splitPackages(ctx, copyObject(result.Config), request.Profile.ID, &result.Diagnostics)
			if err == nil && result.AccessControl != nil {
				result.AccessControl = c.Policy.AccessControl(result.AccessControl, c.Capabilities)
			}
		}
	} else {
		result, err = c.Inspect(ctx, request.Profile.Text, request.Profile.ID)
	}
	if err == nil {
		source := request.Profile.Text
		if request.Profile.Metadata["type"] == "custom" {
			raw, _ := json.Marshal(result.Config)
			source = string(raw)
		}
		fillInspection(&result, source)
	}
	return result, err
}

func fillInspection(result *Inspection, source string) {
	config := result.Config
	result.Outbounds = Object{"proxies": list(config["proxies"]), "proxy-groups": list(config["proxy-groups"]), "proxy-providers": object(config["proxy-providers"])}
	base := copyObject(config)
	for _, key := range []string{"proxies", "proxy-groups", "rules", "sub-rules"} {
		delete(base, key)
	}
	present := []string{}
	for key := range config {
		present = append(present, key)
	}
	for key := range object(config["tun"]) {
		present = append(present, "tun."+key)
	}
	sort.Strings(present)
	matches := []string{}
	for _, entry := range list(config["rules"]) {
		rule := text(entry)
		kind, _, _ := strings.Cut(rule, ",")
		if strings.EqualFold(strings.TrimSpace(kind), "MATCH") {
			matches = append(matches, rule)
		}
	}
	digest := sha256.Sum256([]byte(source))
	result.Base = Object{"config": base, "digest": hex.EncodeToString(digest[:]), "present": present, "proxies": len(list(config["proxies"])), "proxy-groups": len(list(config["proxy-groups"])), "rules": len(list(config["rules"])), "match-rules": matches}
}
