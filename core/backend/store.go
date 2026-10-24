package backend

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
)

var ErrNoState = errors.New("backend state does not exist")

// Desired input, committed input and compiled artifacts share one atomic file.
// Reserve room for two compatible 16 MiB source profiles plus their JSON plans.
const maxStateBytes = 128 << 20

type Desired struct {
	Running bool  `json:"running"`
	Input   Input `json:"input,omitempty"`
}
type Applied struct {
	Plan    PlanData                 `json:"plan"`
	Input   Input                    `json:"input"`
	Running bool                     `json:"running"`
	Nodes   map[string]NodePersisted `json:"nodes,omitempty"`
}
type Pending struct {
	Fingerprint string `json:"fingerprint"`
	OperationID string `json:"operationId"`
	Method      string `json:"method"`
	NodeID      string `json:"nodeId,omitempty"`
	Generation  uint64 `json:"generation"`
}
type Receipt struct {
	OperationID string `json:"operationId"`
	Fingerprint string `json:"fingerprint"`
	Status      string `json:"status"`
	Method      string `json:"method,omitempty"`
	Generation  uint64 `json:"generation"`
	// Error is short human-readable text; ErrorCode is one of the stable
	// ErrorCode* values for failed and cancelled operations.
	Error        string         `json:"error,omitempty"`
	ErrorCode    string         `json:"errorCode,omitempty"`
	ErrorDetails map[string]any `json:"errorDetails,omitempty"`
}
type Document struct {
	Version    int       `json:"version"`
	Generation uint64    `json:"generation"` // high-water mark, including aborted plans
	Sequence   uint64    `json:"sequence"`
	Desired    Desired   `json:"desired"`
	Applied    *Applied  `json:"applied,omitempty"`
	Pending    *Pending  `json:"pending,omitempty"`
	Receipts   []Receipt `json:"receipts,omitempty"`
}

func newDocument() Document { return Document{Version: StorageVersion} }
func cloneDocument(d Document) Document {
	raw, _ := json.Marshal(d)
	var out Document
	_ = json.Unmarshal(raw, &out)
	return out
}
func validateDocument(d Document) error {
	if d.Version != StorageVersion {
		return fmt.Errorf("unsupported storage version %d", d.Version)
	}
	if d.Applied != nil {
		if _, err := RestorePlan(d.Applied.Plan); err != nil {
			return err
		}
		if d.Applied.Plan.Generation > d.Generation {
			return errors.New("applied generation exceeds high-water mark")
		}
		if _, err := canonicalJSON(d.Applied.Input); err != nil {
			return fmt.Errorf("applied input: %w", err)
		}
	}
	if d.Desired.Input != nil {
		if _, err := canonicalJSON(d.Desired.Input); err != nil {
			return fmt.Errorf("desired input: %w", err)
		}
	}
	if d.Pending != nil && (d.Pending.OperationID == "" || d.Pending.Generation > d.Generation) {
		return errors.New("invalid pending operation")
	}
	return nil
}

type Store interface {
	Load() (Document, error)
	Save(Document) error
}

// FileStore uses a single private document, so a plan, its generation and the
// transaction journal can never come from independently updated files.
type FileStore struct {
	path string
	mu   sync.Mutex
}

func NewFileStore(directory string) (*FileStore, error) {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	return &FileStore{path: filepath.Join(directory, "backend-v1.json")}, nil
}
func (s *FileStore) Load() (Document, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.load() }
func (s *FileStore) load() (Document, error) {
	f, err := os.Open(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return Document{}, ErrNoState
	}
	if err != nil {
		return Document{}, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return Document{}, err
	}
	if info.Size() > maxStateBytes {
		return Document{}, errors.New("backend state exceeds size limit")
	}
	raw, err := io.ReadAll(io.LimitReader(f, maxStateBytes+1))
	if err != nil {
		return Document{}, err
	}
	if len(raw) > maxStateBytes {
		return Document{}, errors.New("backend state exceeds size limit")
	}
	var d Document
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&d); err == nil {
		if !json.Valid(raw) {
			return Document{}, errors.New("invalid backend state")
		}
		err = validateDocument(d)
	}
	return d, err
}
func (s *FileStore) Save(d Document) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := validateDocument(d); err != nil {
		return err
	}
	// Fail closed for a newer schema or corrupted file, even if a caller tries to
	// save without first loading it. Recovery must never silently erase user data.
	if _, err := s.load(); err != nil && !errors.Is(err, ErrNoState) {
		return err
	}
	raw, err := json.Marshal(d)
	if err != nil {
		return err
	}
	if len(raw) > maxStateBytes {
		return errors.New("backend state exceeds size limit")
	}
	f, err := os.CreateTemp(filepath.Dir(s.path), ".backend-*")
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
	if err = os.Rename(f.Name(), s.path); err != nil {
		return err
	}
	// After the rename every Load, including one after a process restart,
	// observes the new document. Reporting a failed directory flush as a
	// rejected save would leave the caller's memory behind the state it will
	// act on after restart, so the save counts as committed. The next Save
	// flushes the directory again.
	_ = syncDirectory(filepath.Dir(s.path))
	return nil
}

// syncDirectory flushes directory metadata; tests replace it to inject faults.
var syncDirectory = func(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
