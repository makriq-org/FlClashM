package service

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

func (a *App) clearProfileArtifacts() error {
	if lists, ok := a.compiler.Lists.(interface{ Reset() }); ok {
		lists.Reset()
	}
	home := filepath.Clean(a.compiler.Capabilities.HomeDir)
	if !filepath.IsAbs(home) || home == string(filepath.Separator) {
		return errors.New("invalid private application directory")
	}
	profiles := filepath.Clean(a.compiler.Capabilities.ProfilesDir)
	if !strings.HasPrefix(profiles, home+string(filepath.Separator)) {
		return errors.New("profile directory is outside application storage")
	}
	a.transferMu.Lock()
	defer a.transferMu.Unlock()
	for _, directory := range []string{profiles, filepath.Join(home, "runtimes"), a.blobDirectory(), filepath.Join(a.directory, "validation")} {
		if err := os.RemoveAll(directory); err != nil {
			return err
		}
	}
	return os.MkdirAll(profiles, 0700)
}
