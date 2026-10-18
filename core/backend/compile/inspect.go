package compile

import "context"

// Inspection prepares read-only editor information without loading an engine
// configuration, running scripts or creating an execution capability.
type Inspection struct {
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
	return Inspection{Config: config, AccessControl: access, Diagnostics: diagnostics}, ctx.Err()
}
