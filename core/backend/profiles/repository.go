// Package profiles owns original profile text and the compatible settings
// document. UI models are projections of this state, not its durable owner.
package profiles

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"unicode/utf8"

	"core/backend/authoring"
)

const Version = 1
const MaxDocumentBytes = 32 << 20
const MaxProfileBytes = 16 << 20

var ErrConflict = errors.New("profile revision changed")
var ErrNotFound = errors.New("profile not found")

type Object map[string]json.RawMessage

type Record struct {
	SourceMissing bool   `json:"sourceMissing,omitempty"`
	Metadata      Object `json:"metadata"`
	Source        string `json:"-"`
	Revision      uint64 `json:"revision"`
	Digest        string `json:"digest"`
}
type Document struct {
	Authoring authoring.Collections `json:"authoring,omitempty"`
	Version   int                   `json:"version"`
	Revision  uint64                `json:"revision"`
	Migrated  bool                  `json:"migrated"`
	Settings  Object                `json:"settings"`
	Profiles  []Record              `json:"profiles"`
}
type Validator func(context.Context, string) error

type Repository struct {
	mu            sync.Mutex
	path          string
	state         Document
	validate      Validator
	validated     map[string]string // source digests validated by this process
	syncDirectory func(string) error
}

func Open(directory string, validate Validator) (*Repository, error) {
	if validate == nil {
		return nil, errors.New("profile validator is required")
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	r := &Repository{path: filepath.Join(directory, "profiles.json"), validate: validate, syncDirectory: syncProfileDirectory,
		state: Document{Version: Version, Settings: Object{}, Profiles: []Record{}}}
	raw, err := readStore(r.path)
	if errors.Is(err, os.ErrNotExist) {
		return r, nil
	}
	if err != nil {
		return nil, err
	}
	if len(raw) > MaxDocumentBytes {
		return nil, errors.New("profile store exceeds size limit")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&r.state); err != nil || !json.Valid(raw) {
		return nil, errors.New("invalid profile store")
	}
	if r.state.Version != Version {
		return nil, fmt.Errorf("unsupported profile store version %d", r.state.Version)
	}
	seen := map[string]bool{}
	for _, p := range r.state.Profiles {
		id, err := profileID(p.Metadata)
		if err != nil {
			return nil, err
		}
		if seen[id] {
			return nil, errors.New("duplicate stored profile")
		}
		seen[id] = true
		if p.Revision > r.state.Revision || len(p.Digest) != 64 {
			return nil, errors.New("inconsistent profile revision")
		}
	}
	return r, nil
}
func clone[T any](v T) T {
	raw, _ := json.Marshal(v)
	var out T
	_ = json.Unmarshal(raw, &out)
	return out
}
func digest(source string) string {
	h := sha256.Sum256([]byte(source))
	return hex.EncodeToString(h[:])
}
func profileID(metadata Object) (string, error) {
	var id string
	if json.Unmarshal(metadata["id"], &id) != nil || id == "" || len(id) > 250 || id == "." || id == ".." || strings.ContainsAny(id, "/\\\x00\r\n") {
		return "", errors.New("invalid profile id")
	}
	return id, nil
}

// Older Flutter versions derived the profile type from the URL and did not
// persist a type field. Project it for both newly migrated and existing stores
// without rewriting legacy metadata or overriding an explicit modern type.
func projectLegacyProfileType(p *Record) {
	if raw, ok := p.Metadata["type"]; ok && string(raw) != "null" {
		return
	}
	var address string
	if json.Unmarshal(p.Metadata["url"], &address) == nil && address != "" {
		p.Metadata["type"] = json.RawMessage(`"url"`)
	}
}

func (r *Repository) Snapshot() Document {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := clone(r.state)
	for i := range out.Profiles {
		projectLegacyProfileType(&out.Profiles[i])
	}
	return out
}
func (r *Repository) Get(id string) (Record, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, p := range r.state.Profiles {
		key, _ := profileID(p.Metadata)
		if key == id {
			source, err := r.readSource(p.Digest)
			if err != nil {
				return Record{}, err
			}
			p.Source = source
			return cloneRecord(p), nil
		}
	}
	return Record{}, ErrNotFound
}
func (r *Repository) metadata(id string) (Record, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, p := range r.state.Profiles {
		key, _ := profileID(p.Metadata)
		if key == id {
			return cloneRecord(p), nil
		}
	}
	return Record{}, ErrNotFound
}
func cloneRecord(p Record) Record {
	out := clone(p)
	out.Source = p.Source
	projectLegacyProfileType(&out)
	return out
}
func (r *Repository) persist(next Document) error {
	existing, readErr := readStore(r.path)
	if readErr == nil {
		var header Document
		decoder := json.NewDecoder(bytes.NewReader(existing))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&header) != nil || !json.Valid(existing) || header.Version != Version {
			return errors.New("profile store schema changed")
		}
		if header.Revision != r.state.Revision {
			return ErrConflict
		}
	} else if !errors.Is(readErr, os.ErrNotExist) {
		return readErr
	}

	next.Version = Version
	next.Revision = r.state.Revision + 1
	raw, err := json.Marshal(next)
	if err != nil {
		return err
	}
	if len(raw) > MaxDocumentBytes {
		return errors.New("profile store exceeds size limit")
	}
	f, err := os.CreateTemp(filepath.Dir(r.path), ".profiles-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(raw)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Rename(f.Name(), r.path); err != nil {
		return err
	}
	// Rename has committed the visible generation. A failed directory flush
	// cannot reject that write: memory must match the revision already on disk,
	// just as it does for the runtime and operation stores.
	_ = r.syncDirectory(filepath.Dir(r.path))
	r.state = clone(next)
	r.pruneSources()
	return nil
}

func syncProfileDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

// Migrate imports the complete legacy settings object and original sources in
// one durable generation. Sources are read-only; repeating migration is a no-op.
func (r *Repository) Migrate(ctx context.Context, rawSettings []byte, readSource func(string) (string, error)) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.state.Migrated {
		return nil
	}
	if len(r.state.Profiles) > 0 {
		return errors.New("cannot migrate into a nonempty store")
	}
	// The Flutter preferences loader discarded an undecodable config and started
	// fresh. Mirror that instead of failing every backend start forever.
	var settings Object
	if !json.Valid(rawSettings) || json.Unmarshal(rawSettings, &settings) != nil || settings == nil {
		settings = Object{}
	}
	compatibleSettings(settings)
	metadata := legacyProfileMetadata(settings["profiles"])
	next := clone(r.state)
	next.Settings = settings
	delete(next.Settings, "profiles")
	if raw := next.Settings["authoring"]; len(raw) > 0 {
		if err := json.Unmarshal(raw, &next.Authoring); err != nil {
			return err
		}
		delete(next.Settings, "authoring")
	}
	next.Migrated = true
	seen := map[string]bool{}
	for _, m := range metadata {
		if err := ctx.Err(); err != nil {
			return err
		}
		// A record without a safe, unique id cannot be addressed or stored; skip
		// only that record so the remaining profiles still migrate.
		id, err := profileID(m)
		if err != nil || seen[id] {
			continue
		}
		seen[id] = true
		source, err := readSource(id)
		// Only known permanent source failures become missing sources. Unknown
		// or repairable read failures abort without committing the migration,
		// so a later start can recover the original content. Missing, oversized
		// or invalid file paths keep their metadata and cannot block startup.
		if retryableLegacyReadError(err) {
			return fmt.Errorf("read legacy profile %s: %w", id, err)
		}
		missing := err != nil || len(source) > MaxProfileBytes
		if missing {
			source = ""
		}
		// Migration preserves even an invalid legacy source: the compiler validates
		// it before execution. Rejecting one offline/broken profile must not lose all.
		if err = r.writeSource(source); err != nil {
			return err
		}
		next.Profiles = append(next.Profiles, Record{SourceMissing: missing, Metadata: m, Source: source, Revision: r.state.Revision + 1, Digest: digest(source)})
	}
	return r.persist(next)
}

// legacyProfileMetadata keeps every decodable profile object of the legacy
// list. A malformed entry or a non-list value drops only the affected data.
func legacyProfileMetadata(raw json.RawMessage) []Object {
	var entries []json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &entries) != nil {
		return nil
	}
	metadata := make([]Object, 0, len(entries))
	for _, entry := range entries {
		var m Object
		if json.Unmarshal(entry, &m) == nil && m != nil {
			metadata = append(metadata, m)
		}
	}
	return metadata
}

// Put uses optimistic revision checking so a late subscription response cannot
// overwrite an editor save, deletion, or a newer response for the same profile.
// expected==0 creates a record; every update must name its observed revision.
func (r *Repository) Put(ctx context.Context, metadata Object, source string, expected uint64) (Record, error) {
	id, err := profileID(metadata)
	if err != nil {
		return Record{}, err
	}
	if !utf8.ValidString(source) {
		return Record{}, errors.New("profile must be UTF-8")
	}
	if len(source) > MaxProfileBytes {
		return Record{}, errors.New("profile exceeds size limit")
	}
	metadata = clone(metadata)
	// Subscription headers and timestamps often change while the source stays
	// byte-for-byte identical. Its committed revision was already validated;
	// do not reopen the isolated parser or fetch its dependencies again.
	previous, readErr := r.metadata(id)
	sourceDigest := digest(source)
	r.mu.Lock()
	validated := r.validated[id] == sourceDigest
	r.mu.Unlock()
	unchanged := validated && readErr == nil && expected != 0 && previous.Revision == expected && !previous.SourceMissing && previous.Digest == sourceDigest
	if !unchanged {
		if err = r.validate(ctx, source); err != nil {
			return Record{}, err
		}
	}
	if err = ctx.Err(); err != nil {
		return Record{}, err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if err = ctx.Err(); err != nil {
		return Record{}, err
	}
	index := -1
	for i, p := range r.state.Profiles {
		key, _ := profileID(p.Metadata)
		if key == id {
			index = i
			break
		}
	}
	if (index < 0 && expected != 0) || (index >= 0 && r.state.Profiles[index].Revision != expected) {
		return Record{}, ErrConflict
	}
	if err = r.writeSource(source); err != nil {
		return Record{}, err
	}
	next := clone(r.state)
	record := Record{Metadata: metadata, Source: source, Revision: r.state.Revision + 1, Digest: digest(source)}
	if index < 0 {
		next.Profiles = append(next.Profiles, record)
	} else {
		record.Metadata = mergeObjects(next.Profiles[index].Metadata, record.Metadata)
		next.Profiles[index] = record
	}
	record.Metadata = uniqueLabel(record.Metadata, id, r.state.Profiles)
	if index < 0 {
		next.Profiles[len(next.Profiles)-1] = record
	} else {
		next.Profiles[index] = record
	}
	if index >= 0 {
		renameProvider(&next, r.state.Profiles[index].Metadata, record.Metadata)
	}
	if err = r.persist(next); err != nil {
		return Record{}, err
	}
	if r.validated == nil {
		r.validated = map[string]string{}
	}
	r.validated[id] = sourceDigest
	return cloneRecord(record), nil
}
func (r *Repository) Delete(id string, expected uint64) error {
	_, err := r.DeleteWithSelection(id, expected, nil)
	return err
}

// DeleteWithSelection commits removal and its replacement selection together.
// beforeLast must durably stop runtime before the last recoverable source is
// removed. It runs under the catalog lock and must not read the repository.
func (r *Repository) DeleteWithSelection(id string, expected uint64, beforeLast func() error) (bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	next := clone(r.state)
	for i, p := range next.Profiles {
		key, _ := profileID(p.Metadata)
		if key != id {
			continue
		}
		if p.Revision != expected {
			return false, ErrConflict
		}
		next.Profiles = append(next.Profiles[:i], next.Profiles[i+1:]...)
		authoring.PruneProfile(next.Authoring, id)
		renameProvider(&next, p.Metadata, nil)
		var current string
		_ = json.Unmarshal(next.Settings["currentProfileId"], &current)
		changed := current == id
		if changed {
			next.Settings["currentProfileId"] = json.RawMessage("null")
			if len(next.Profiles) > 0 {
				next.Settings["currentProfileId"] = bytes.Clone(next.Profiles[0].Metadata["id"])
			}
		}
		if len(next.Profiles) == 0 && beforeLast != nil {
			if err := beforeLast(); err != nil {
				return false, err
			}
		}
		return changed, r.persist(next)
	}
	return false, ErrNotFound
}
func (r *Repository) UpdateSettings(settings Object, expected uint64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if expected != r.state.Revision {
		return ErrConflict
	}
	if _, ok := settings["authoring"]; ok {
		return errors.New("authoring must be changed through authoring.replace")
	}
	if _, ok := settings["profiles"]; ok {
		return errors.New("profiles must be changed through the repository")
	}
	next := clone(r.state)
	next.Settings = mergeObjects(next.Settings, settings)
	return r.persist(next)
}
func (r *Repository) ExportLegacy() ([]byte, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	settings := clone(r.state.Settings)
	if settings == nil {
		settings = Object{}
	}
	metadata := make([]Object, 0, len(r.state.Profiles))
	for _, p := range r.state.Profiles {
		metadata = append(metadata, p.Metadata)
	}
	raw, err := json.Marshal(metadata)
	if err != nil {
		return nil, err
	}
	settings["profiles"] = raw
	if len(r.state.Authoring) > 0 {
		settings["authoring"] = mustJSON(authoring.Normalize(r.state.Authoring))
	}
	return json.Marshal(settings)
}
func ReadLegacySource(directory, id string) (string, error) {
	if _, err := profileID(Object{"id": mustJSON(id)}); err != nil {
		return "", err
	}
	f, err := os.Open(filepath.Join(directory, id+".yaml"))
	if err != nil {
		return "", err
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, MaxProfileBytes+1))
	if err != nil {
		return "", err
	}
	if len(raw) > MaxProfileBytes {
		return "", errLegacySourceTooLarge
	}
	return string(raw), nil
}

var errLegacySourceTooLarge = errors.New("profile exceeds size limit")

func retryableLegacyReadError(err error) bool {
	if err == nil || errors.Is(err, os.ErrNotExist) || errors.Is(err, errLegacySourceTooLarge) {
		return false
	}
	for _, errno := range []syscall.Errno{syscall.EISDIR, syscall.ENOTDIR, syscall.ELOOP, syscall.ENAMETOOLONG} {
		if errors.Is(err, errno) {
			return false
		}
	}
	// Permission, timeout and unknown I/O failures do not prove that the source
	// is permanently unavailable. Keep migration retryable until it can be read.
	return true
}

func mustJSON(v any) json.RawMessage { raw, _ := json.Marshal(v); return raw }

// Patch compatible objects recursively so a UI projection cannot erase fields
// it does not understand. Explicit null and array replacement remain explicit.
func mergeObjects(previous, patch Object) Object {
	result := clone(previous)
	if result == nil {
		result = Object{}
	}
	for key, raw := range patch {
		var nested Object
		var old Object
		if structuredObject(key) && json.Unmarshal(raw, &nested) == nil && nested != nil && json.Unmarshal(result[key], &old) == nil {
			result[key] = mustJSON(mergeObjects(old, nested))
		} else {
			result[key] = append(json.RawMessage(nil), raw...)
		}
	}
	return result
}

func structuredObject(key string) bool {
	switch key {
	case "appSetting", "patchClashConfig", "networkProps", "vpnProps", "themeProps", "proxiesStyle", "windowProps", "scriptProps", "textScale", "tun", "dns", "geox-url", "accessControl", "overrideData", "rule", "overrides", "ntp", "sniffer", "sniff", "fallback-filter", "tun-override":
		return true
	}
	return false
}

func readStore(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, MaxDocumentBytes+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > MaxDocumentBytes {
		return nil, errors.New("profile store exceeds size limit")
	}
	return raw, nil
}

func (r *Repository) sourcePath(hash string) string {
	return filepath.Join(filepath.Dir(r.path), "sources", hash+".yaml")
}
func (r *Repository) readSource(hash string) (string, error) {
	if len(hash) != 64 {
		return "", errors.New("invalid source digest")
	}
	if _, err := hex.DecodeString(hash); err != nil {
		return "", errors.New("invalid source digest")
	}
	f, err := os.Open(r.sourcePath(hash))
	if err != nil {
		return "", err
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, MaxProfileBytes+1))
	if err != nil {
		return "", err
	}
	if len(raw) > MaxProfileBytes || digest(string(raw)) != hash {
		return "", errors.New("stored profile source integrity check failed")
	}
	return string(raw), nil
}
func (r *Repository) writeSource(source string) error {
	hash := digest(source)
	if existing, err := r.readSource(hash); err == nil && existing == source {
		return nil
	}
	directory := filepath.Dir(r.sourcePath(hash))
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(directory, ".source-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(0600); err == nil {
		_, err = f.WriteString(source)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Rename(f.Name(), r.sourcePath(hash)); err != nil {
		return err
	}
	dir, err := os.Open(directory)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
func (r *Repository) pruneSources() { _ = r.collectSources() }
func (r *Repository) collectSources() error {
	keep := map[string]bool{}
	for _, p := range r.state.Profiles {
		keep[p.Digest+".yaml"] = true
	}
	directory := filepath.Join(filepath.Dir(r.path), "sources")
	files, err := os.ReadDir(directory)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, f := range files {
		if !f.Type().IsRegular() || keep[f.Name()] || len(f.Name()) != 69 || !strings.HasSuffix(f.Name(), ".yaml") {
			continue
		}
		if _, err := hex.DecodeString(strings.TrimSuffix(f.Name(), ".yaml")); err == nil {
			if err = os.Remove(filepath.Join(directory, f.Name())); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
		}
	}
	return nil
}

func (r *Repository) Reorder(ctx context.Context, ids []string, expected uint64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if expected != r.state.Revision || len(ids) != len(r.state.Profiles) {
		return ErrConflict
	}
	byID := map[string]Record{}
	for _, record := range r.state.Profiles {
		id, _ := profileID(record.Metadata)
		byID[id] = record
	}
	next := clone(r.state)
	next.Profiles = make([]Record, 0, len(ids))
	for _, id := range ids {
		record, ok := byID[id]
		if !ok {
			return errors.New("profile ordering must be a permutation")
		}
		delete(byID, id)
		next.Profiles = append(next.Profiles, record)
	}
	return r.persist(next)
}

// UpdateMetadata preserves the source blob and permits editing an offline or
// invalid legacy profile without implicitly replacing its original text.
func (r *Repository) UpdateMetadata(ctx context.Context, id string, patch Object, expected uint64) (Record, error) {
	if err := ctx.Err(); err != nil {
		return Record{}, err
	}
	if value, ok := patch["id"]; ok {
		var supplied string
		if json.Unmarshal(value, &supplied) != nil || supplied != id {
			return Record{}, errors.New("profile id is immutable")
		}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return Record{}, err
	}
	next := clone(r.state)
	for i, record := range next.Profiles {
		key, _ := profileID(record.Metadata)
		if key != id {
			continue
		}
		if record.Revision != expected {
			return Record{}, ErrConflict
		}
		record.Metadata = mergeObjects(record.Metadata, patch)
		if _, changed := patch["label"]; changed {
			record.Metadata = uniqueLabel(record.Metadata, id, r.state.Profiles)
		}
		record.Revision = r.state.Revision + 1
		next.Profiles[i] = record
		renameProvider(&next, r.state.Profiles[i].Metadata, record.Metadata)
		if err := r.persist(next); err != nil {
			return Record{}, err
		}
		return clone(record), nil
	}
	return Record{}, ErrNotFound
}

var labelSuffix = regexp.MustCompile(`\((\d+)\)$`)

func uniqueLabel(metadata Object, id string, records []Record) Object {
	var label *string
	_ = json.Unmarshal(metadata["label"], &label)
	candidate := id
	if label != nil {
		candidate = *label
	}
	original := candidate
	for range len(records) + 1 {
		duplicate := false
		for _, record := range records {
			key, _ := profileID(record.Metadata)
			if key == id {
				continue
			}
			var existing *string
			_ = json.Unmarshal(record.Metadata["label"], &existing)
			if existing != nil && *existing == candidate {
				duplicate = true
				break
			}
		}
		if !duplicate {
			if candidate != original {
				metadata["label"] = mustJSON(candidate)
			}
			return metadata
		}
		parts := labelSuffix.FindStringSubmatchIndex(candidate)
		if parts != nil {
			number, err := strconv.ParseUint(candidate[parts[2]:parts[3]], 10, 64)
			if err == nil && number < ^uint64(0) {
				candidate = candidate[:parts[0]] + "(" + strconv.FormatUint(number+1, 10) + ")"
				continue
			}
		}
		candidate += "(1)"
	}
	return metadata
}

// Restore imports a compatible backup as one catalog generation. The original
// source bytes are staged before the pointer commit, including broken legacy
// profiles. Runtime adoption is a separate coordinator operation.
func (r *Repository) Restore(ctx context.Context, rawSettings []byte, readSource func(string) (string, error), onlyProfiles, replace bool) error {
	var settings Object
	if !json.Valid(rawSettings) || json.Unmarshal(rawSettings, &settings) != nil || settings == nil {
		return errors.New("invalid backup settings")
	}
	compatibleSettings(settings)
	var incoming authoring.Collections
	hasAuthoring := len(settings["authoring"]) > 0
	if hasAuthoring {
		if err := json.Unmarshal(settings["authoring"], &incoming); err != nil {
			return err
		}
		delete(settings, "authoring")
	}
	var metadata []Object
	if raw := settings["profiles"]; len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &metadata); err != nil {
			return err
		}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	next := clone(r.state)
	if !onlyProfiles {
		delete(settings, "profiles")
		next.Settings = settings
	}
	if replace {
		next.Profiles = []Record{}
	}
	seen := map[string]bool{}
	for _, m := range metadata {
		if err := ctx.Err(); err != nil {
			return err
		}
		id, err := profileID(m)
		if err != nil {
			return err
		}
		if seen[id] {
			return errors.New("duplicate backup profile id")
		}
		seen[id] = true
		source, err := readSource(id)
		missing := errors.Is(err, os.ErrNotExist)
		if err != nil {
			if !errors.Is(err, os.ErrNotExist) {
				return err
			}
			source = ""
		}
		if len(source) > MaxProfileBytes {
			return errors.New("backup profile exceeds limit")
		}
		if err = r.writeSource(source); err != nil {
			return err
		}
		record := Record{SourceMissing: missing, Metadata: m, Digest: digest(source), Revision: r.state.Revision + 1}
		index := -1
		for i, old := range next.Profiles {
			key, _ := profileID(old.Metadata)
			if key == id {
				index = i
				break
			}
		}
		if !replace {
			record.Metadata = uniqueLabel(record.Metadata, id, next.Profiles)
		}
		if index < 0 {
			next.Profiles = append(next.Profiles, record)
		} else {
			next.Profiles[index] = record
		}
	}
	if hasAuthoring {
		if replace {
			next.Authoring = incoming
		} else {
			next.Authoring = authoring.Merge(next.Authoring, incoming)
		}
		if err := validateAuthoring(next); err != nil {
			return err
		}
	} else if replace {
		for _, p := range r.state.Profiles {
			id, _ := profileID(p.Metadata)
			if !seen[id] {
				authoring.PruneProfile(next.Authoring, id)
			}
		}
	}
	var current string
	_ = json.Unmarshal(next.Settings["currentProfileId"], &current)
	exists := false
	for _, record := range next.Profiles {
		id, _ := profileID(record.Metadata)
		exists = exists || id == current
	}
	if !exists {
		if len(next.Profiles) > 0 {
			next.Settings["currentProfileId"] = next.Profiles[0].Metadata["id"]
		} else {
			next.Settings["currentProfileId"] = json.RawMessage("null")
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return r.persist(next)
}

// Reset keeps the migration marker and monotonic catalog generation: legacy
// SharedPreferences must never repopulate data after an explicit reset.
func (r *Repository) Reset() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.persist(Document{Version: Version, Revision: r.state.Revision, Migrated: true, Settings: Object{}, Profiles: []Record{}})
}
