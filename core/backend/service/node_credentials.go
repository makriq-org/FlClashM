package service

import (
	"crypto/rand"
	"errors"
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
	raw, err := readBounded(path, int64(len(key)))
	if err == nil {
		if len(raw) != len(key) || [32]byte(raw) == ([32]byte{}) {
			return key, errors.New("invalid node service key")
		}
		return [32]byte(raw), nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return key, err
	}

	rand.Read(key[:])
	if err := writePrivateFileAtomically(path, key[:]); err != nil {
		return [32]byte{}, err
	}
	return key, nil
}
