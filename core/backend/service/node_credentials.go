package service

import (
	"crypto/rand"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
)

var nodeServiceKeyMu sync.Mutex

func loadNodeServiceKey(directory string) ([32]byte, error) {
	// One backend process owns the installation directory. Serialize opens
	// within that process so they all use the same atomically published key.
	nodeServiceKeyMu.Lock()
	defer nodeServiceKeyMu.Unlock()
	path := filepath.Join(directory, "node-service.key")
	var key [32]byte
	file, err := os.Open(path)
	if err == nil {
		raw, readErr := io.ReadAll(io.LimitReader(file, int64(len(key)+1)))
		_ = file.Close()
		if readErr != nil {
			return key, readErr
		}
		if len(raw) == len(key) && [32]byte(raw) != key {
			return [32]byte(raw), nil
		}
		// A corrupt key cannot authenticate anything and can be regenerated
		// from scratch without changing profiles or settings.
	} else if !errors.Is(err, os.ErrNotExist) {
		return key, err
	}

	rand.Read(key[:])
	if err := writePrivateFileAtomically(path, key[:]); err != nil {
		return [32]byte{}, err
	}
	return key, nil
}
