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
	"core/backend/compile"
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
		size, writeErr := a.writeBlob(ctx, blob.Token, func(output io.Writer) error {
			writer := zip.NewWriter(output)
			var uncompressed int64
			write := func(name string, reader io.Reader) error {
				if err := ctx.Err(); err != nil {
					return err
				}
				entry, err := writer.Create(name)
				if err != nil {
					return err
				}
				n, copyErr := io.Copy(entry, io.LimitReader(reader, min(maxBlobBytes, 512<<20-uncompressed)+1))
				uncompressed += n
				if n > maxBlobBytes || uncompressed > 512<<20 {
					return errors.New("backup exceeds uncompressed limit")
				}
				return copyErr
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
				// Missing legacy/restored sources remain absent in the compatible
				// archive. An empty file is a real source, not a download marker.
				if profile.SourceMissing {
					continue
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
			return err
		})
		if writeErr != nil {
			_ = a.removeBlob(blob.Token)
			return Blob{}, writeErr
		}
		if a.profiles.Snapshot().Revision != catalog.Revision {
			_ = a.removeBlob(blob.Token)
			continue
		}
		blob.Size = size
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
	legacy := entries["clashConfig.json"]
	if legacy != nil || !onlyProfiles {
		var settings profiles.Object
		if json.Unmarshal(rawSettings, &settings) != nil || settings == nil {
			return "", errors.New("invalid backup settings")
		}
		if legacy != nil {
			clash, err := read(legacy, profiles.MaxDocumentBytes)
			if err != nil {
				return "", err
			}
			settings["patchClashConfig"] = clash
		}
		if !onlyProfiles {
			preserveHostOnlySettings(settings, a.profiles.Snapshot().Settings)
		}
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
		if err = atomicCacheFile(target, raw); err != nil {
			return "", err
		}
	}
	a.runtimeMu.Lock()
	defer a.runtimeMu.Unlock()
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if a.resetting.Load() {
		return "", errors.New("data reset in progress")
	}
	generation := a.runtime.Snapshot().Generation
	input, err := a.captureInput()
	if err != nil {
		return "", err
	}
	method := "restart"
	var captured compile.Input
	_ = json.Unmarshal(input, &captured)
	if captured.Profile == nil {
		if err = a.operations.disableBootstrap(); err != nil {
			return "", err
		}
		method = "stop"
		input = nil
	}
	operationID := newID("restore")
	_, err = a.runtime.SubmitAtGeneration(backend.Request{APIVersion: backend.APIVersion, OperationID: operationID, Method: method, Input: input}, generation)
	return operationID, err
}

// hostOnlySettings were separate SharedPreferences before the Go catalogue
// owned them, so legacy config.json backups never contain them. Restoring such
// a backup must not silently reset them to their defaults (sendDeviceHeaders
// defaults to enabled, which would re-enable device identification).
var hostOnlySettings = []string{"sendDeviceHeaders"}

func preserveHostOnlySettings(restored, current profiles.Object) {
	for _, key := range hostOnlySettings {
		if _, present := restored[key]; present {
			continue
		}
		if value, ok := current[key]; ok {
			restored[key] = append(json.RawMessage(nil), value...)
		}
	}
}

func atomicCacheFile(target string, data []byte) error {
	file, err := os.CreateTemp(filepath.Dir(target), ".restore-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if err = file.Chmod(0600); err == nil {
		_, err = file.Write(data)
	}
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Rename(file.Name(), target); err != nil {
		return err
	}
	directory, err := os.Open(filepath.Dir(target))
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
