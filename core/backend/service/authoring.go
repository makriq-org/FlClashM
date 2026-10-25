package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"core/backend"
	"core/backend/authoring"
	"core/backend/profiles"
)

type sourceParams struct {
	Source       string `json:"source"`
	Token        string `json:"token"`
	AgeSecretKey string `json:"ageSecretKey"`
}

func (a *App) readSource(ctx context.Context, p sourceParams) (string, error) {
	if p.Source != "" && p.Token != "" {
		return "", errors.New("specify source or token")
	}
	source := p.Source
	if p.Token != "" {
		name, err := a.blobPath(p.Token)
		if err != nil {
			return "", err
		}
		raw, err := readBounded(name, profiles.MaxProfileBytes)
		if err != nil {
			return "", err
		}
		source = string(raw)
	}
	if !utf8.ValidString(source) || len(source) > profiles.MaxProfileBytes {
		return "", errors.New("source must be bounded UTF-8")
	}
	if p.AgeSecretKey != "" {
		if a.compiler.DecodeProfile == nil {
			return "", errors.New("encrypted profile decoder is unavailable")
		}
		var err error
		source, err = a.compiler.DecodeProfile(ctx, source, p.AgeSecretKey)
		if err != nil {
			return "", err
		}
	}
	return source, ctx.Err()
}
func (a *App) validatePreview(ctx context.Context, p sourceParams) map[string]string {
	source, err := a.readSource(ctx, p)
	if err == nil {
		err = a.validateSource(ctx, source)
	}
	message := ""
	if err != nil {
		message = err.Error()
	}
	return map[string]string{"message": message}
}
func (a *App) renderProfile(ctx context.Context, id string) (Blob, error) {
	input, err := a.captureProfileInput(&id)
	if err != nil {
		return Blob{}, err
	}
	config, err := a.compiler.BuildProfile(ctx, input)
	if err != nil {
		return Blob{}, err
	}
	data, err := json.Marshal(config)
	if err != nil {
		return Blob{}, err
	}
	blob, err := a.newBlob()
	if err != nil {
		return Blob{}, err
	}
	size, err := a.writeBlob(ctx, blob.Token, func(w io.Writer) error { _, err := w.Write(data); return err })
	if err != nil {
		_ = a.removeBlob(blob.Token)
		return Blob{}, err
	}
	blob.Size = size
	return blob, nil
}
func (a *App) replaceAuthoring(ctx context.Context, params json.RawMessage, operationID string) (Receipt, error) {
	var p struct {
		ExpectedRevision  *uint64               `json:"expectedRevision"`
		Collections       authoring.Collections `json:"collections"`
		Profiles          []profiles.Object     `json:"profiles"`
		DeletedProfileIDs []string              `json:"deletedProfileIds"`
		Token             string                `json:"token"`
	}
	if err := decodeParams(params, &p); err != nil {
		return Receipt{}, err
	}
	if p.ExpectedRevision == nil {
		return Receipt{}, errors.New("expectedRevision is required")
	}
	if p.Token != "" {
		if p.Collections != nil {
			return Receipt{}, errors.New("specify collections or token")
		}
		name, err := a.blobPath(p.Token)
		if err != nil {
			return Receipt{}, err
		}
		raw, err := readBounded(name, profiles.MaxDocumentBytes)
		if err != nil {
			return Receipt{}, err
		}
		if err = json.Unmarshal(raw, &p.Collections); err != nil {
			return Receipt{}, err
		}
	}
	result := Receipt{}
	if err := a.profiles.ReplaceAuthoringTransaction(ctx, p.Collections, p.Profiles, p.DeletedProfileIDs, *p.ExpectedRevision, func() error {
		if err := a.operations.disableBootstrap(); err != nil {
			return err
		}
		receipt, err := a.runtime.Submit(backend.Request{APIVersion: backend.APIVersion, OperationID: runtimeID(operationID), Method: "stop"})
		result.RuntimeOperationID = receipt.OperationID
		return err
	}); err != nil {
		return result, err
	}
	result.Revision = *p.ExpectedRevision + 1
	return result, nil
}
func (a *App) resourceMutation(ctx context.Context, method string, params json.RawMessage) (Receipt, error) {
	var p struct {
		Collection       string          `json:"collection"`
		ID               json.RawMessage `json:"id"`
		ExpectedRevision *uint64         `json:"expectedRevision"`
		Content          *string         `json:"content"`
		ContentBase64    *string         `json:"contentBase64"`
		Token            string          `json:"token"`
	}
	if err := decodeParams(params, &p); err != nil {
		return Receipt{}, err
	}
	id := authoring.ID(p.ID)
	row, rev, err := a.profiles.Resource(ctx, p.Collection, id)
	if err != nil {
		return Receipt{}, err
	}
	if p.ExpectedRevision != nil && rev != *p.ExpectedRevision {
		return Receipt{}, profiles.ErrConflict
	}
	if method != "authoring.resource.update" && p.ExpectedRevision == nil {
		return Receipt{}, errors.New("expectedRevision is required")
	}
	var data []byte
	binary := false
	switch method {
	case "resource.refresh", "authoring.resource.update":
		address := authoring.String(row, "url")
		u, err := url.Parse(address)
		if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
			return Receipt{}, errors.New("resource URL must be HTTP(S)")
		}
		timeout, cancel := context.WithTimeout(ctx, 2*time.Minute)
		defer cancel()
		request, err := http.NewRequestWithContext(timeout, http.MethodGet, address, nil)
		if err != nil {
			return Receipt{}, err
		}
		request.Header.Set("User-Agent", a.subscriptions.UserAgent)
		response, err := a.subscriptions.Client.Do(request)
		if err != nil {
			return Receipt{}, err
		}
		if response == nil || response.Body == nil {
			return Receipt{}, errors.New("resource transport returned no body")
		}
		defer response.Body.Close()
		if response.StatusCode < 200 || response.StatusCode >= 300 {
			return Receipt{}, fmt.Errorf("resource HTTP status %d", response.StatusCode)
		}
		data, err = io.ReadAll(io.LimitReader(response.Body, profiles.MaxProfileBytes+1))
		if err != nil {
			return Receipt{}, err
		}
		binary = p.Collection == "clashProviders" && authoring.String(row, "format") == "mrs"
	case "resource.put":
		choices := 0
		if p.Content != nil {
			choices++
			data = []byte(*p.Content)
		}
		if p.ContentBase64 != nil {
			choices++
			data, err = base64.StdEncoding.DecodeString(*p.ContentBase64)
			binary = true
		}
		if p.Token != "" {
			choices++
			name, e := a.blobPath(p.Token)
			if e != nil {
				return Receipt{}, e
			}
			data, err = readBounded(name, profiles.MaxProfileBytes)
			binary = p.Collection == "clashProviders" && authoring.String(row, "format") == "mrs"
		}
		if choices != 1 {
			return Receipt{}, errors.New("one resource content or token is required")
		}
		if err != nil {
			return Receipt{}, err
		}
	}
	if len(data) > profiles.MaxProfileBytes {
		return Receipt{}, errors.New("resource exceeds size limit")
	}
	if !binary && !utf8.Valid(data) {
		return Receipt{}, errors.New("resource must be UTF-8")
	}
	patch := authoring.Object{"lastUpdateTime": authoring.Value(a.now().UTC())}
	if binary {
		if p.Collection != "clashProviders" {
			return Receipt{}, errors.New("binary content is only supported for rule providers")
		}
		patch["contentBase64"] = authoring.Value(base64.StdEncoding.EncodeToString(data))
		patch["content"] = authoring.Value(nil)
	} else {
		patch["content"] = authoring.Value(string(data))
		patch["contentBase64"] = authoring.Value(nil)
	}
	if p.Collection == "clashProviders" {
		compiled, err := a.compiler.CompileResource(ctx, data)
		if err != nil {
			return Receipt{}, err
		}
		patch["behavior"] = authoring.Value(compiled.Behavior)
		patch["format"] = authoring.Value(compiled.Format)
		patch["contentBase64"] = authoring.Value(base64.StdEncoding.EncodeToString(data))
		patch["content"] = authoring.Value(nil)
	}
	if p.Collection == "iconSets" {
		var icons []authoring.Object
		if json.Unmarshal(data, &icons) != nil {
			var doc struct {
				Icons []authoring.Object `json:"icons"`
			}
			if json.Unmarshal(data, &doc) != nil || doc.Icons == nil {
				return Receipt{}, errors.New("invalid icon set")
			}
			icons = doc.Icons
		}
		for _, icon := range icons {
			if strings.TrimSpace(authoring.String(icon, "name")) == "" || strings.TrimSpace(authoring.String(icon, "url")) == "" {
				return Receipt{}, errors.New("invalid icon declaration")
			}
		}
		patch["icons"] = authoring.Value(icons)
	}
	if err = a.profiles.PutResource(ctx, p.Collection, id, patch, rev); err != nil {
		return Receipt{}, err
	}
	return Receipt{Revision: rev + 1}, nil
}
func (a *App) readResource(ctx context.Context, collection, id string) (any, error) {
	row, _, err := a.profiles.Resource(ctx, collection, id)
	if err != nil {
		return nil, err
	}
	data, err := savedResourceBytes(row, collection)
	if err != nil {
		return nil, err
	}
	result := map[string]any{"contentBase64": base64.StdEncoding.EncodeToString(data), "size": len(data)}
	if last := authoring.String(row, "lastUpdateTime"); last != "" {
		result["lastModified"] = last
	}
	return result, nil
}

func (a *App) currentUsesProfile(id string) bool {
	snapshot := a.profiles.Snapshot()
	var current string
	_ = json.Unmarshal(snapshot.Settings["currentProfileId"], &current)
	if current == "" || current == id {
		return false
	}
	label, custom := "", false
	for _, record := range snapshot.Profiles {
		if authoring.String(authoring.Object(record.Metadata), "id") == id {
			label = authoring.String(authoring.Object(record.Metadata), "label")
			if label == "" {
				label = id
			}
		}
		if authoring.String(authoring.Object(record.Metadata), "id") == current {
			custom = authoring.String(authoring.Object(record.Metadata), "type") == "custom"
		}
	}
	if !custom || label == "" {
		return false
	}
	for _, row := range authoring.Scoped(snapshot.Authoring["proxyGroups"], current) {
		if string(row["include-all-providers"]) == "true" || string(row["include-all"]) == "true" {
			return true
		}
		var names []string
		_ = json.Unmarshal(row["use"], &names)
		for _, name := range names {
			if name == label {
				return true
			}
		}
	}
	return false
}
