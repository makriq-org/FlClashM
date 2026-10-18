package service

import (
	"context"
	"encoding/base64"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const maxBlobBytes int64 = 128 << 20
const blobChunkBytes = 192 << 10

var blobToken = regexp.MustCompile(`^[0-9a-f]{32}$`)

type Blob struct {
	Token string `json:"token"`
	Size  int64  `json:"size"`
}

func (a *App) blobDirectory() string { return filepath.Join(a.directory, "transfers") }
func (a *App) blobPath(token string) (string, error) {
	if !blobToken.MatchString(token) {
		return "", errors.New("invalid transfer token")
	}
	return filepath.Join(a.blobDirectory(), token), nil
}
func (a *App) newBlob() (Blob, error) {
	a.transferMu.Lock()
	defer a.transferMu.Unlock()
	if err := os.MkdirAll(a.blobDirectory(), 0700); err != nil {
		return Blob{}, err
	}
	entries, err := os.ReadDir(a.blobDirectory())
	if err != nil {
		return Blob{}, err
	}
	active := 0
	var bytes int64
	for _, entry := range entries {
		if entry.IsDir() || !blobToken.MatchString(entry.Name()) {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return Blob{}, err
		}
		if time.Since(info.ModTime()) > 24*time.Hour {
			_ = os.Remove(filepath.Join(a.blobDirectory(), entry.Name()))
			continue
		}
		active++
		bytes += info.Size()
	}
	if active >= 32 || bytes >= 512<<20 {
		return Blob{}, errors.New("too many unfinished transfers")
	}
	token := strings.TrimPrefix(newID("blob"), "blob-")
	name, err := a.blobPath(token)
	if err != nil {
		return Blob{}, err
	}
	file, err := os.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return Blob{}, err
	}
	_ = file.Close()
	return Blob{Token: token}, nil
}
func (a *App) appendBlob(ctx context.Context, token string, offset int64, encoded string) (Blob, error) {
	if err := ctx.Err(); err != nil {
		return Blob{}, err
	}
	if len(encoded) > base64.StdEncoding.EncodedLen(blobChunkBytes) {
		return Blob{}, errors.New("transfer chunk exceeds limit")
	}
	data, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return Blob{}, err
	}
	if offset < 0 || offset > maxBlobBytes-int64(len(data)) {
		return Blob{}, errors.New("transfer exceeds limit")
	}
	name, err := a.blobPath(token)
	if err != nil {
		return Blob{}, err
	}
	a.transferMu.Lock()
	defer a.transferMu.Unlock()
	file, err := os.OpenFile(name, os.O_RDWR, 0600)
	if err != nil {
		return Blob{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return Blob{}, err
	}
	if info.Size() != offset {
		// A request may be retried after its acknowledgement was lost.
		if info.Size() == offset+int64(len(data)) {
			previous := make([]byte, len(data))
			_, _ = file.ReadAt(previous, offset)
			if string(previous) == string(data) {
				return Blob{token, info.Size()}, nil
			}
		}
		return Blob{}, errors.New("transfer offset changed")
	}
	if _, err = file.WriteAt(data, offset); err != nil {
		return Blob{}, err
	}
	if err = file.Sync(); err != nil {
		return Blob{}, err
	}
	return Blob{token, offset + int64(len(data))}, nil
}
func (a *App) readBlob(token string, offset int64, limit int) (any, error) {
	if offset < 0 || limit < 1 || limit > blobChunkBytes {
		return nil, errors.New("invalid transfer range")
	}
	name, err := a.blobPath(token)
	if err != nil {
		return nil, err
	}
	file, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || offset > info.Size() || info.Size() > maxBlobBytes {
		return nil, errors.New("invalid transfer size")
	}
	buffer := make([]byte, min(int64(limit), info.Size()-offset))
	n, err := file.ReadAt(buffer, offset)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	return struct {
		Blob
		Offset int64  `json:"offset"`
		Data   string `json:"data"`
		EOF    bool   `json:"eof"`
	}{Blob: Blob{token, info.Size()}, Offset: offset, Data: base64.StdEncoding.EncodeToString(buffer[:n]), EOF: offset+int64(n) == info.Size()}, nil
}
func (a *App) removeBlob(token string) error {
	name, err := a.blobPath(token)
	if err != nil {
		return err
	}
	err = os.Remove(name)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
