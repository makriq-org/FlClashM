package service

import (
	"archive/zip"
	"context"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"

	"core/backend"
	"core/backend/profiles"
)

func (a *App) exportBackup(ctx context.Context) (Blob, error) {
	// Capture a consistent source/catalog view; retries account for a simultaneous
	// subscription commit without retaining every original profile in memory.
	for range 4 {
		catalog := a.profiles.Snapshot()
		settings, err := a.profiles.ExportLegacy()
		if err != nil {
			return Blob{}, err
		}
		blob, err := a.newBlob()
		if err != nil {
			return Blob{}, err
		}
		name, _ := a.blobPath(blob.Token)
		file, err := os.OpenFile(name, os.O_WRONLY|os.O_TRUNC, 0600)
		if err != nil {
			return Blob{}, err
		}
		writer := zip.NewWriter(file)
		write := func(name string, reader io.Reader) error {
			if err := ctx.Err(); err != nil {
				return err
			}
			entry, err := writer.Create(name)
			if err != nil {
				return err
			}
			_, err = io.Copy(entry, reader)
			return err
		}
		err = write("config.json", strings.NewReader(string(settings)))
		for _, record := range catalog.Profiles {
			if err != nil {
				break
			}
			var id string
			_ = json.Unmarshal(record.Metadata["id"], &id)
			profile, readErr := a.profiles.Get(id)
			if readErr != nil {
				err = readErr
				break
			}
			err = write(path.Join("profiles", id+".yaml"), strings.NewReader(profile.Source))
		}
		cacheRoot := filepath.Join(a.compiler.Capabilities.ProfilesDir, "providers")
		if err == nil {
			err = filepath.WalkDir(cacheRoot, func(name string, entry fs.DirEntry, walkErr error) error {
				if os.IsNotExist(walkErr) {
					return nil
				}
				if walkErr != nil {
					return walkErr
				}
				if entry.IsDir() {
					return nil
				}
				info, e := entry.Info()
				if e != nil {
					return e
				}
				if !info.Mode().IsRegular() {
					return nil
				}
				relative, e := filepath.Rel(a.compiler.Capabilities.ProfilesDir, name)
				if e != nil {
					return e
				}
				source, e := os.Open(name)
				if e != nil {
					return e
				}
				defer source.Close()
				return write(path.Join("profiles", filepath.ToSlash(relative)), io.LimitReader(source, maxBlobBytes+1))
			})
		}
		closeErr := writer.Close()
		if err == nil {
			err = closeErr
		}
		if err == nil {
			err = file.Sync()
		}
		info, statErr := file.Stat()
		if err == nil {
			err = statErr
		}
		_ = file.Close()
		if err != nil {
			_ = a.removeBlob(blob.Token)
			return Blob{}, err
		}
		if info.Size() > maxBlobBytes {
			_ = a.removeBlob(blob.Token)
			return Blob{}, errors.New("backup exceeds transfer limit")
		}
		if a.profiles.Snapshot().Revision != catalog.Revision {
			_ = a.removeBlob(blob.Token)
			continue
		}
		blob.Size = info.Size()
		return blob, nil
	}
	return Blob{}, profiles.ErrConflict
}
func safeArchiveName(name string) bool {
	return name != "" && !strings.ContainsAny(name, "\\\x00") && !strings.HasPrefix(name, "/") && path.Clean(name) == strings.TrimSuffix(name, "/") && name != ".." && !strings.HasPrefix(name, "../")
}
func (a *App) restoreBackup(ctx context.Context, token string, onlyProfiles, replace bool) (string, error) {
	name, err := a.blobPath(token)
	if err != nil {
		return "", err
	}
	archive, err := zip.OpenReader(name)
	if err != nil {
		return "", err
	}
	defer archive.Close()
	entries := map[string]*zip.File{}
	var total uint64
	for _, entry := range archive.File {
		if !safeArchiveName(entry.Name) {
			return "", errors.New("unsafe backup entry path")
		}
		if entry.FileInfo().Mode()&os.ModeSymlink != 0 {
			return "", errors.New("backup links are unsupported")
		}
		if _, duplicate := entries[entry.Name]; duplicate {
			return "", errors.New("duplicate backup entry")
		}
		total += entry.UncompressedSize64
		if total > 512<<20 || entry.UncompressedSize64 > uint64(maxBlobBytes) {
			return "", errors.New("backup expands past size limit")
		}
		entries[entry.Name] = entry
	}
	read := func(entry *zip.File, limit int64) ([]byte, error) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if entry.UncompressedSize64 > uint64(limit) {
			return nil, errors.New("backup entry exceeds limit")
		}
		reader, err := entry.Open()
		if err != nil {
			return nil, err
		}
		defer reader.Close()
		raw, err := io.ReadAll(io.LimitReader(reader, limit+1))
		if err != nil {
			return nil, err
		}
		if len(raw) > int(limit) {
			return nil, errors.New("backup entry exceeds limit")
		}
		return raw, nil
	}
	config := entries["config.json"]
	if config == nil {
		return "", errors.New("backup config.json is missing")
	}
	rawSettings, err := read(config, profiles.MaxDocumentBytes)
	if err != nil {
		return "", err
	}
	if legacy := entries["clashConfig.json"]; legacy != nil {
		clash, err := read(legacy, profiles.MaxDocumentBytes)
		if err != nil {
			return "", err
		}
		var settings profiles.Object
		if json.Unmarshal(rawSettings, &settings) != nil {
			return "", errors.New("invalid backup settings")
		}
		settings["patchClashConfig"] = clash
		rawSettings, _ = json.Marshal(settings)
	}
	err = a.profiles.Restore(ctx, rawSettings, func(id string) (string, error) {
		entry := entries[path.Join("profiles", id+".yaml")]
		if entry == nil {
			return "", os.ErrNotExist
		}
		raw, err := read(entry, profiles.MaxProfileBytes)
		return string(raw), err
	}, onlyProfiles, replace)
	if err != nil {
		return "", err
	}
	for entryName, entry := range entries {
		relative, ok := strings.CutPrefix(entryName, "profiles/providers/")
		if !ok || entry.FileInfo().IsDir() {
			continue
		}
		if err := ctx.Err(); err != nil {
			return "", err
		}
		raw, err := read(entry, maxBlobBytes)
		if err != nil {
			return "", err
		}
		target := filepath.Join(a.compiler.Capabilities.ProfilesDir, "providers", filepath.FromSlash(relative))
		if err = os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			return "", err
		}
		if err = os.WriteFile(target, raw, 0600); err != nil {
			return "", err
		}
	}
	input, err := a.captureInput()
	if err != nil {
		return "", err
	}
	operationID := newID("restore")
	_, err = a.runtime.Submit(backend.Request{APIVersion: backend.APIVersion, OperationID: operationID, Method: "restart", Input: input})
	return operationID, err
}
