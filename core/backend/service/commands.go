package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strconv"
	"time"

	"core/backend/profiles"
)

func (a *App) perform(ctx context.Context, method string, params json.RawMessage, operationID string) (Receipt, error) {
	result := Receipt{}
	if err := ctx.Err(); err != nil {
		return result, err
	}
	apply := false
	switch method {
	case "backup.export":
		blob, err := a.exportBackup(ctx)
		result.Blob = &blob
		return result, err
	case "backup.restore":
		var request struct {
			Token        string `json:"token"`
			OnlyProfiles bool   `json:"onlyProfiles"`
			Replace      bool   `json:"replace"`
		}
		if err := decodeParams(params, &request); err != nil {
			return result, err
		}
		runtimeID, err := a.restoreBackup(ctx, request.Token, request.OnlyProfiles, request.Replace)
		result.RuntimeOperationID = runtimeID
		result.Revision = a.profiles.Snapshot().Revision
		return result, err
	case "profile.import.file":
		var request struct {
			Token    string          `json:"token"`
			Metadata profiles.Object `json:"metadata"`
			Select   bool            `json:"select"`
		}
		if err := decodeParams(params, &request); err != nil {
			return result, err
		}
		name, err := a.blobPath(request.Token)
		if err != nil {
			return result, err
		}
		source, err := readBounded(name, profiles.MaxProfileBytes)
		if err != nil {
			return result, err
		}
		nested, _ := json.Marshal(map[string]any{"metadata": request.Metadata, "source": string(source), "select": request.Select})
		return a.perform(ctx, "profile.put", nested, operationID)
	case "settings.patch":
		var request struct {
			Patch            profiles.Object `json:"patch"`
			ExpectedRevision uint64          `json:"expectedRevision"`
		}
		if err := decodeParams(params, &request); err != nil {
			return result, err
		}
		if request.Patch == nil {
			return result, errors.New("settings patch is required")
		}
		if err := a.patchSettings(ctx, request.Patch, request.ExpectedRevision); err != nil {
			return result, err
		}
		for key := range request.Patch {
			switch key {
			case "patchClashConfig", "vpnProps", "networkProps", "overrideDns", "scriptProps", "currentProfileId", "appSetting":
				apply = true
			}
		}
	case "profile.put":
		var request struct {
			Metadata         profiles.Object `json:"metadata"`
			Source           *string         `json:"source"`
			ExpectedRevision uint64          `json:"expectedRevision"`
			Select           bool            `json:"select"`
		}
		if err := decodeParams(params, &request); err != nil {
			return result, err
		}
		if request.Metadata == nil {
			return result, errors.New("profile metadata is required")
		}
		var id string
		_ = json.Unmarshal(request.Metadata["id"], &id)
		if id == "" {
			id = strconv.FormatInt(time.Now().UnixMilli(), 10)
			request.Metadata["id"] = jsonValue(id)
		}
		var record profiles.Record
		var err error
		if request.Source == nil {
			record, err = a.profiles.UpdateMetadata(ctx, id, request.Metadata, request.ExpectedRevision)
		} else {
			if request.ExpectedRevision == 0 {
				defaultProfileMetadata(request.Metadata)
			}
			record, err = a.profiles.Put(ctx, request.Metadata, *request.Source, request.ExpectedRevision)
		}
		if err != nil {
			return result, err
		}
		result.ProfileID = id
		result.Revision = record.Revision
		if request.Select {
			if err = a.patchSettings(ctx, profiles.Object{"currentProfileId": jsonValue(id)}, 0); err != nil {
				return result, err
			}
			apply = true
		} else {
			if a.isCurrent(id) {
				if request.Source != nil {
					apply = true
				} else {
					for key := range request.Metadata {
						switch key {
						case "selectedMap", "overrideData", "providerHeaders", "label":
							apply = true
						}
					}
				}
			}
		}
	case "profile.delete":
		var request struct {
			ProfileID        string `json:"profileId"`
			ExpectedRevision uint64 `json:"expectedRevision"`
		}
		if err := decodeParams(params, &request); err != nil {
			return result, err
		}
		apply = a.isCurrent(request.ProfileID)
		if err := a.profiles.Delete(request.ProfileID, request.ExpectedRevision); err != nil {
			return result, err
		}
		result.ProfileID = request.ProfileID
	case "profile.select":
		var request struct {
			ProfileID *string `json:"profileId"`
		}
		if err := decodeParams(params, &request); err != nil {
			return result, err
		}
		if request.ProfileID != nil {
			if _, err := a.profiles.Get(*request.ProfileID); err != nil {
				return result, err
			}
			result.ProfileID = *request.ProfileID
			record, err := a.profiles.Get(*request.ProfileID)
			if err != nil {
				return result, err
			}
			if err = a.customize(ctx, record.Metadata, false); err != nil {
				return result, err
			}
		}
		if err := a.patchSettings(ctx, profiles.Object{"currentProfileId": jsonValue(request.ProfileID)}, 0); err != nil {
			return result, err
		}
		apply = true
	case "profile.reorder":
		var request struct {
			ProfileIDs       []string `json:"profileIds"`
			ExpectedRevision uint64   `json:"expectedRevision"`
		}
		if err := decodeParams(params, &request); err != nil {
			return result, err
		}
		if err := a.profiles.Reorder(ctx, request.ProfileIDs, request.ExpectedRevision); err != nil {
			return result, err
		}
	case "profile.validate":
		var request struct {
			Source string `json:"source"`
		}
		if err := decodeParams(params, &request); err != nil {
			return result, err
		}
		return result, a.validateSource(ctx, request.Source)
	case "subscription.refresh":
		var request struct {
			ProfileID     string `json:"profileId"`
			DeviceHeaders *bool  `json:"deviceHeaders"`
		}
		if err := decodeParams(params, &request); err != nil {
			return result, err
		}
		record, err := a.subscriptions.Update(ctx, request.ProfileID, a.deviceHeadersRequested(request.DeviceHeaders))
		result.ProfileID = request.ProfileID
		result.Revision = record.Revision
		return result, err
	case "profile.import.url":
		var request struct {
			Metadata      profiles.Object `json:"metadata"`
			Select        bool            `json:"select"`
			DeviceHeaders *bool           `json:"deviceHeaders"`
		}
		if err := decodeParams(params, &request); err != nil {
			return result, err
		}
		if request.Metadata == nil {
			return result, errors.New("profile metadata is required")
		}
		var id string
		_ = json.Unmarshal(request.Metadata["id"], &id)
		if id == "" {
			id = newID("profile")
			request.Metadata["id"] = jsonValue(id)
		}
		defaultProfileMetadata(request.Metadata)
		record, err := a.subscriptions.Import(ctx, request.Metadata, a.deviceHeadersRequested(request.DeviceHeaders))
		result.ProfileID = id
		result.Revision = record.Revision
		if err != nil {
			return result, err
		}
		if err = a.customize(ctx, record.Metadata, true); err != nil {
			return result, err
		}
		if request.Select {
			if err = a.patchSettings(ctx, profiles.Object{"currentProfileId": jsonValue(id)}, 0); err != nil {
				return result, err
			}
			apply = true
		}
	}
	if err := ctx.Err(); err != nil {
		return result, err
	}
	a.publish()
	if apply {
		receipt, err := a.applyCurrent(runtimeID(operationID), false)
		result.RuntimeOperationID = receipt.OperationID
		if err != nil {
			return result, err
		}
	}
	if result.Revision == 0 {
		result.Revision = a.profiles.Snapshot().Revision
	}
	return result, nil
}
func (a *App) patchSettings(ctx context.Context, patch profiles.Object, expected uint64) error {
	a.dataMu.Lock()
	defer a.dataMu.Unlock()
	for range 8 {
		if err := ctx.Err(); err != nil {
			return err
		}
		revision := a.profiles.Snapshot().Revision
		if expected != 0 && revision != expected {
			return profiles.ErrConflict
		}
		err := a.profiles.UpdateSettings(patch, revision)
		if !errors.Is(err, profiles.ErrConflict) || expected != 0 {
			return err
		}
	}
	return profiles.ErrConflict
}
func (a *App) isCurrent(id string) bool {
	var current string
	_ = json.Unmarshal(a.profiles.Snapshot().Settings["currentProfileId"], &current)
	return id != "" && id == current
}
func jsonValue(value any) json.RawMessage { raw, _ := json.Marshal(value); return raw }
func defaultProfileMetadata(metadata profiles.Object) {
	defaults := map[string]any{"url": "", "autoUpdate": true, "autoUpdateDuration": int64(24 * time.Hour / time.Microsecond), "selectedMap": map[string]any{}, "unfoldSet": []any{}, "providerHeaders": map[string]any{}, "overrideData": map[string]any{"enable": false}}
	for key, value := range defaults {
		if _, ok := metadata[key]; !ok {
			metadata[key] = jsonValue(value)
		}
	}
}

func runtimeID(id string) string {
	sum := sha256.Sum256([]byte(id))
	return "runtime-" + hex.EncodeToString(sum[:])
}
