package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
)

const dataVersion = 1
const maxLedgerBytes = 2 << 20

type Receipt struct {
	PermissionRequired bool   `json:"permissionRequired,omitempty"`
	OperationID        string `json:"operationId"`
	Fingerprint        string `json:"fingerprint"`
	Method             string `json:"method"`
	Status             string `json:"status"`
	Error              string `json:"error,omitempty"`
	ProfileID          string `json:"profileId,omitempty"`
	Revision           uint64 `json:"revision,omitempty"`
	RuntimeOperationID string `json:"runtimeOperationId,omitempty"`
	Blob               *Blob  `json:"blob,omitempty"`
}
type appDocument struct {
	Version           int       `json:"version"`
	BootstrapComplete bool      `json:"bootstrapComplete"`
	LegacyResume      bool      `json:"legacyResume"`
	LegacyTimeZone    string    `json:"legacyTimeZone"`
	LegacyUTCOffset   int       `json:"legacyUtcOffset"`
	Receipts          []Receipt `json:"receipts,omitempty"`
}
type operation struct {
	receipt Receipt
	ctx     context.Context
	cancel  context.CancelFunc
	done    chan struct{}
}
type operationStore struct {
	mu       sync.Mutex
	path     string
	document appDocument
	running  map[string]*operation
}

func openOperations(directory string, legacyResume bool, zone string, offset int) (*operationStore, error) {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	store := &operationStore{path: filepath.Join(directory, "application-v1.json"), document: appDocument{Version: dataVersion, LegacyResume: legacyResume, LegacyTimeZone: zone, LegacyUTCOffset: offset}, running: map[string]*operation{}}
	raw, err := readBounded(store.path, maxLedgerBytes)
	if errors.Is(err, os.ErrNotExist) {
		err = store.saveLocked(store.document)
		return store, err
	}
	if err != nil {
		return nil, err
	}
	if err = decodeDocument(raw, &store.document); err != nil {
		return nil, err
	}
	for i := range store.document.Receipts {
		receipt := &store.document.Receipts[i]
		if receipt.Status == "accepted" {
			receipt.Status = "interrupted"
			receipt.Error = "operation interrupted before acknowledgement"
		}
	}
	if err = store.saveLocked(store.document); err != nil {
		return nil, err
	}
	return store, nil
}
func decodeDocument(raw []byte, out *appDocument) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if !json.Valid(raw) || decoder.Decode(out) != nil {
		return errors.New("invalid application journal")
	}
	if out.Version != dataVersion {
		return errors.New("unsupported application journal version")
	}
	return nil
}
func readBounded(name string, limit int64) ([]byte, error) {
	f, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if info.Size() > limit {
		return nil, errors.New("application document exceeds limit")
	}
	raw, err := io.ReadAll(io.LimitReader(f, limit+1))
	if len(raw) > int(limit) {
		return nil, errors.New("application document exceeds limit")
	}
	return raw, err
}
func (s *operationStore) saveLocked(next appDocument) error {
	if raw, err := readBounded(s.path, maxLedgerBytes); err == nil {
		var current appDocument
		if err = decodeDocument(raw, &current); err != nil {
			return err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	raw, err := json.Marshal(next)
	if err != nil {
		return err
	}
	if len(raw) > maxLedgerBytes {
		return errors.New("application journal exceeds limit")
	}
	f, err := os.CreateTemp(filepath.Dir(s.path), ".application-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(raw)
	}
	if err == nil {
		err = f.Sync()
	}
	if err == nil {
		err = f.Close()
	}
	if err == nil {
		err = os.Rename(f.Name(), s.path)
	}
	if err != nil {
		return err
	}
	directory, err := os.Open(filepath.Dir(s.path))
	if err != nil {
		return err
	}
	defer directory.Close()
	if err = directory.Sync(); err != nil {
		return err
	}
	s.document = next
	s.document.Receipts = append([]Receipt(nil), next.Receipts...)
	return nil
}
func requestFingerprint(method string, params json.RawMessage) (string, error) {
	if len(params) == 0 {
		params = json.RawMessage(`{}`)
	}
	var value any
	decoder := json.NewDecoder(bytes.NewReader(params))
	decoder.UseNumber()
	if !json.Valid(params) || decoder.Decode(&value) != nil {
		return "", errors.New("invalid command parameters")
	}
	if _, ok := value.(map[string]any); !ok {
		return "", errors.New("command parameters must be an object")
	}
	canonical, _ := json.Marshal([]any{method, value})
	hash := sha256.Sum256(canonical)
	return hex.EncodeToString(hash[:]), nil
}
func appendReceipt(receipts []Receipt, receipt Receipt) []Receipt {
	out := append([]Receipt(nil), receipts...)
	for i := range out {
		if out[i].OperationID == receipt.OperationID {
			out[i] = receipt
			return out
		}
	}
	out = append(out, receipt)
	if len(out) > 128 {
		out = out[len(out)-128:]
	}
	return out
}
func (s *operationStore) accept(parent context.Context, id, method string, params []byte) (*operation, Receipt, error) {
	fingerprint, err := requestFingerprint(method, params)
	if err != nil {
		return nil, Receipt{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, receipt := range s.document.Receipts {
		if receipt.OperationID == id {
			if receipt.Fingerprint != fingerprint || receipt.Method != method {
				return nil, Receipt{}, errors.New("operationId reused for a different command")
			}
			return nil, receipt, nil
		}
	}
	pending := 0
	for _, op := range s.running {
		if op.receipt.Status == "accepted" {
			pending++
		}
	}
	if pending >= 8 {
		return nil, Receipt{}, errors.New("application command queue is full")
	}
	receipt := Receipt{OperationID: id, Fingerprint: fingerprint, Method: method, Status: "accepted"}
	next := s.document
	next.Receipts = appendReceipt(next.Receipts, receipt)
	if err = s.saveLocked(next); err != nil {
		return nil, Receipt{}, err
	}
	ctx, cancel := context.WithCancel(parent)
	op := &operation{receipt: receipt, ctx: ctx, cancel: cancel, done: make(chan struct{})}
	s.running[id] = op
	return op, receipt, nil
}
func (s *operationStore) finish(op *operation, result Receipt, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	result.OperationID = op.receipt.OperationID
	result.Fingerprint = op.receipt.Fingerprint
	result.Method = op.receipt.Method
	result.Status = "succeeded"
	if err != nil {
		result.Status = "failed"
		result.Error = err.Error()
		if len(result.Error) > 2048 {
			result.Error = result.Error[:2048]
		}
		if op.ctx.Err() != nil {
			result.Status = "cancelled"
		}
	}
	next := s.document
	next.Receipts = appendReceipt(next.Receipts, result)
	if saveErr := s.saveLocked(next); saveErr != nil {
		result.Status = "failed"
		result.Error = "application journal commit failed"
	}
	op.receipt = result
	close(op.done)
	op.cancel()
	if len(s.running) > 128 {
		for id, old := range s.running {
			if old != op && old.receipt.Status != "accepted" {
				delete(s.running, id)
				break
			}
		}
	}
}
func (s *operationStore) get(id string) (Receipt, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if op := s.running[id]; op != nil {
		return op.receipt, nil
	}
	for _, receipt := range s.document.Receipts {
		if receipt.OperationID == id {
			return receipt, nil
		}
	}
	return Receipt{}, errors.New("unknown application operation")
}
func (s *operationStore) cancel(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	op := s.running[id]
	if op == nil || op.receipt.Status != "accepted" {
		return false
	}
	op.cancel()
	return true
}
func (s *operationStore) disableBootstrap() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := s.document
	next.LegacyResume = false
	next.BootstrapComplete = true
	return s.saveLocked(next)
}
