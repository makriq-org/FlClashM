package service

import (
	"crypto/rand"
	"errors"
	"os"
	"path/filepath"
)

func loadNodeServiceKey(directory string) ([32]byte, error) {
	const fileName = "node-service.key"
	path := filepath.Join(directory, fileName)
	var key [32]byte
	read := func() ([32]byte, error) {
		raw, err := readBounded(path, int64(len(key)))
		if err != nil {
			return [32]byte{}, err
		}
		if len(raw) != len(key) || [32]byte(raw) == ([32]byte{}) {
			return [32]byte{}, errors.New("invalid node service key")
		}
		return [32]byte(raw), nil
	}
	if existing, err := read(); !errors.Is(err, os.ErrNotExist) {
		return existing, err
	}

	rand.Read(key[:])
	file, err := os.CreateTemp(directory, ".node-service-*")
	if err != nil {
		return [32]byte{}, err
	}
	defer os.Remove(file.Name())
	if _, err = file.Write(key[:]); err != nil {
		_ = file.Close()
		return [32]byte{}, err
	}
	err = file.Sync()
	closeErr := file.Close()
	if err = errors.Join(err, closeErr); err != nil {
		return [32]byte{}, err
	}
	// Publish the complete private file without replacing a concurrent winner.
	if err = os.Link(file.Name(), path); errors.Is(err, os.ErrExist) {
		return read()
	}
	if err != nil {
		return [32]byte{}, err
	}
	if dir, err := os.Open(directory); err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}
	return key, nil
}
