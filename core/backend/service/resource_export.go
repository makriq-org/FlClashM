package service

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"unicode/utf8"

	"core/backend/authoring"
	"core/profilecodec"
)

type providerResourceParams struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

func (a *App) providerResource(ctx context.Context, p providerResourceParams) ([]byte, error) {
	if strings.TrimSpace(p.Name) == "" || len(p.Name) > 1024 || strings.ContainsRune(p.Name, 0) {
		return nil, errors.New("provider name is required and must contain 1..1024 bytes")
	}
	if p.Type != "proxy" && p.Type != "rule" {
		return nil, errors.New("provider type must be proxy or rule")
	}
	if a.readProviderResource == nil {
		return nil, errors.New("provider resource reader is unavailable")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	data, err := a.readProviderResource(ctx, p.Name, p.Type)
	if err != nil {
		return nil, err
	}
	if len(data) > profilecodec.MaxResourceBytes {
		return nil, errors.New("provider resource exceeds 16 MiB limit")
	}
	return data, ctx.Err()
}

func inspectResource(data []byte) any {
	format := "binary"
	// MRS is always preview-only, even when its text representation is available.
	if bytes.HasPrefix(data, []byte{0x28, 0xb5, 0x2f, 0xfd}) {
		format = "mrs"
	} else if utf8.Valid(data) {
		format = "text"
	}
	return struct {
		Format   string `json:"format"`
		Size     int    `json:"size"`
		Editable bool   `json:"editable"`
	}{format, len(data), format == "text"}
}

// savedResourceBytes is shared by read and export; neither fetches a remote URL.
func savedResourceBytes(row authoring.Object, collection string) ([]byte, error) {
	var data []byte
	if encoded := authoring.String(row, "contentBase64"); encoded != "" {
		if len(encoded) > base64.StdEncoding.EncodedLen(profilecodec.MaxResourceBytes) {
			return nil, errors.New("resource exceeds 16 MiB limit")
		}
		var err error
		data, err = base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			return nil, err
		}
	} else {
		data = []byte(authoring.String(row, "content"))
	}
	if collection == "iconSets" && len(data) == 0 && row["icons"] != nil {
		data = append([]byte(nil), row["icons"]...)
	}
	if len(data) > profilecodec.MaxResourceBytes {
		return nil, errors.New("resource exceeds 16 MiB limit")
	}
	return data, nil
}

func (a *App) exportResource(ctx context.Context, method string, params json.RawMessage) (Receipt, error) {
	var data []byte
	var asText bool
	var err error
	if method == "provider.export" {
		var p struct {
			providerResourceParams
			AsText bool `json:"asText"`
		}
		if err = decodeParams(params, &p); err != nil {
			return Receipt{}, err
		}
		data, err = a.providerResource(ctx, p.providerResourceParams)
		asText = p.AsText
	} else {
		var p struct {
			Collection string          `json:"collection"`
			ID         json.RawMessage `json:"id"`
			AsText     bool            `json:"asText"`
		}
		if err = decodeParams(params, &p); err != nil {
			return Receipt{}, err
		}
		var row authoring.Object
		row, _, err = a.profiles.Resource(ctx, p.Collection, authoring.ID(p.ID))
		if err == nil {
			data, err = savedResourceBytes(row, p.Collection)
			if err == nil && len(data) == 0 && authoring.String(row, "url") != "" {
				err = errors.New("resource has no saved content; update it before exporting")
			}
		}
		asText = p.AsText
	}
	if err != nil {
		return Receipt{}, err
	}
	if asText {
		data, err = profilecodec.DumpRules(data)
		if err != nil {
			return Receipt{}, err
		}
	}
	if len(data) > profilecodec.MaxResourceBytes {
		return Receipt{}, errors.New("resource exceeds 16 MiB limit")
	}
	if err = ctx.Err(); err != nil {
		return Receipt{}, err
	}
	blob, err := a.newBlob()
	if err != nil {
		return Receipt{}, err
	}
	blob.Size, err = a.writeBlob(ctx, blob.Token, func(w io.Writer) error { _, err := w.Write(data); return err })
	if err != nil {
		_ = a.removeBlob(blob.Token)
		return Receipt{}, err
	}
	return Receipt{Blob: &blob}, nil
}
