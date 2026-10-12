package main

// Elevated cores never open user supplied paths. The GUI stages file contents
// into the protected home selected by the service, not by profile metadata.
import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func serviceHome() string { return os.Getenv("FLCLASHM_SERVICE_HOME") }

func secureServiceSetup(data []byte) ([]byte, error) {
	home := serviceHome()
	if home == "" {
		return data, nil
	}
	var setup map[string]any
	if err := json.Unmarshal(data, &setup); err != nil {
		return nil, err
	}
	conf, ok := setup["config"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("service setup has no config")
	}
	files, _ := conf["_flclashm-provider-files"].(map[string]any)
	delete(conf, "_flclashm-provider-files")
	for _, key := range []string{"external-controller", "external-controller-tls", "external-controller-unix", "external-controller-pipe", "external-ui", "external-ui-url"} {
		conf[key] = ""
	}
	if tun, ok := conf["tun"].(map[string]any); ok {
		tun["device"] = "FlClashM"
	}
	var stagedBytes int
	for _, section := range []string{"proxy-providers", "rule-providers"} {
		providers, _ := conf[section].(map[string]any)
		for name, value := range providers {
			provider, ok := value.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("invalid provider %s", name)
			}
			hash := sha256.Sum256([]byte(section + "/" + name))
			dest := filepath.Join(home, "providers", fmt.Sprintf("%x", hash))
			provider["path"] = dest
			if provider["type"] == "file" {
				encoded, ok := files[section+"/"+name].(string)
				if !ok {
					return nil, fmt.Errorf("file provider %s must be staged by the GUI", name)
				}
				if len(encoded) > 24<<20 {
					return nil, fmt.Errorf("staged provider is too large")
				}
				content, err := base64.StdEncoding.DecodeString(encoded)
				if err != nil {
					return nil, err
				}
				contentHash := sha256.Sum256(content)
				dest += fmt.Sprintf("-%x", contentHash)
				provider["path"] = dest
				stagedBytes += len(content)
				if len(content) > 16<<20 || stagedBytes > 32<<20 {
					return nil, fmt.Errorf("staged providers exceed 32 MB")
				}
				if err := os.MkdirAll(filepath.Dir(dest), 0700); err != nil {
					return nil, err
				}
				if err := os.WriteFile(dest+".tmp", content, 0600); err != nil {
					return nil, err
				}
				if err := os.Rename(dest+".tmp", dest); err != nil {
					return nil, err
				}
			}
		}
	}
	if err := validateServiceFileFields(conf, home); err != nil {
		return nil, err
	}
	return json.Marshal(setup)
}

func validateServiceFileFields(value any, home string) error {
	switch node := value.(type) {
	case map[string]any:
		for key, child := range node {
			key = strings.ToLower(key)
			if key == "path" {
				if name, ok := child.(string); ok && name != "" {
					rel, err := filepath.Rel(home, name)
					if err != nil || filepath.IsAbs(rel) || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
						return fmt.Errorf("service config cannot open a path outside its protected home")
					}
				}
			}
			if key == "certificate" || key == "private-key" || key == "client-auth-cert" {
				if text, ok := child.(string); ok && text != "" && !strings.Contains(text, "-----BEGIN ") {
					return fmt.Errorf("service TLS credentials must contain inline PEM data")
				}
			}
			if err := validateServiceFileFields(child, home); err != nil {
				return err
			}
		}
	case []any:
		for _, child := range node {
			if err := validateServiceFileFields(child, home); err != nil {
				return err
			}
		}
	}
	return nil
}
