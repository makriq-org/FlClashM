package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"strings"
	"time"

	"core/backend"
	"core/backend/profiles"
)

func (a *App) perform(ctx context.Context, method string, params json.RawMessage, operationID string) (Receipt, error) {
	result := Receipt{}
	if err := ctx.Err(); err != nil {
		return result, err
	}
	apply := false
	switch method {
	case "data.reset":
		if err := decodeParams(params, &struct{}{}); err != nil {
			return result, err
		}
		if !a.resetting.CompareAndSwap(false, true) {
			return result, errors.New("data reset in progress")
		}
		defer a.resetting.Store(false)
		a.operations.mu.Lock()
		var pending []*operation
		for id, op := range a.operations.running {
			if id != operationID {
				op.cancel()
				pending = append(pending, op)
			}
		}
		a.operations.mu.Unlock()
		for _, op := range pending {
			select {
			case <-op.done:
			case <-ctx.Done():
				return result, ctx.Err()
			}
		}
		a.runtimeMu.Lock()
		defer a.runtimeMu.Unlock()
		if err := a.operations.disableBootstrap(); err != nil {
			return result, err
		}
		receipt, err := a.runtime.Submit(backend.Request{APIVersion: backend.APIVersion, OperationID: runtimeID(operationID), Method: "forget"})
		if err != nil {
			return result, err
		}
		completed, err := a.runtime.Await(ctx, receipt.OperationID)
		if err != nil {
			return result, err
		}
		if completed.Status != "succeeded" {
			return result, errors.New(completed.Error)
		}
		if err = a.profiles.Reset(); err != nil {
			return result, err
		}
		if err = a.clearProfileArtifacts(); err != nil {
			return result, err
		}
		a.noticeMu.Lock()
		a.operations.mu.Lock()
		cleared := a.operations.document
		cleared.SubscriptionNotices = nil
		err = a.operations.saveLocked(cleared)
		a.operations.mu.Unlock()
		a.noticeMu.Unlock()
		if err != nil {
			return result, err
		}
		a.presentationMu.Lock()
		a.presentationGeneration = 0
		a.presentationMu.Unlock()
		result.RuntimeOperationID = receipt.OperationID
		return result, nil
	case "ui.attach":
		if err := decodeParams(params, &struct{}{}); err != nil {
			return result, err
		}
		if err := a.runtime.PrepareForUI(); err != nil {
			return result, err
		}
		catalog := a.profiles.Snapshot()
		var app struct {
			AutoRun bool `json:"autoRun"`
		}
		_ = json.Unmarshal(catalog.Settings["appSetting"], &app)
		snapshot := a.runtime.Snapshot()
		if snapshot.DesiredRunning {
			return result, nil
		}
		var id string
		_ = json.Unmarshal(catalog.Settings["currentProfileId"], &id)
		if _, err := a.profiles.Get(id); err != nil {
			return result, nil
		}
		if !app.AutoRun {
			// Opening the UI prepares nodes for latency checks without requesting
			// VPN permission or persisting an intent to connect after process death.
			if err := a.ensureCurrentSource(ctx); err != nil {
				return result, err
			}
			input, err := a.captureInput()
			if err != nil {
				return result, err
			}
			receipt, err := a.runtime.SubmitAtGeneration(backend.Request{APIVersion: backend.APIVersion, OperationID: runtimeID(operationID), Method: "warm", Input: input}, snapshot.Generation)
			if errors.Is(err, backend.ErrSuperseded) {
				return result, nil
			}
			result.RuntimeOperationID = receipt.OperationID
			return result, err
		}
		if permissions, ok := a.platform.(backend.VPNPermissionReader); ok && a.requiresVPN() {
			granted, err := permissions.VPNPermission(ctx)
			if err != nil {
				return result, err
			}
			if !granted {
				result.PermissionRequired = true
				return result, nil
			}
		}
		if err := a.ensureCurrentSource(ctx); err != nil {
			return result, err
		}
		input, err := a.captureInput()
		if err != nil {
			return result, err
		}
		receipt, err := a.runtime.SubmitAtGeneration(backend.Request{APIVersion: backend.APIVersion, OperationID: runtimeID(operationID), Method: "connect", Input: input}, snapshot.Generation)
		if errors.Is(err, backend.ErrSuperseded) {
			return result, nil
		}
		result.RuntimeOperationID = receipt.OperationID
		return result, err

	case "profile.export":
		var request struct {
			ProfileID string `json:"profileId"`
		}
		if err := decodeParams(params, &request); err != nil {
			return result, err
		}
		record, err := a.profiles.Get(request.ProfileID)
		if err != nil {
			return result, err
		}
		blob, err := a.newBlob()
		if err != nil {
			return result, err
		}
		_, err = a.writeBlob(ctx, blob.Token, func(writer io.Writer) error { _, err := io.Copy(writer, strings.NewReader(record.Source)); return err })
		if err != nil {
			return result, err
		}
		blob.Size = int64(len(record.Source))
		result.Blob = &blob
		result.ProfileID = request.ProfileID
		result.Revision = record.Revision
		return result, ctx.Err()
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
			Token            string          `json:"token"`
			Metadata         profiles.Object `json:"metadata"`
			Select           bool            `json:"select"`
			ExpectedRevision uint64          `json:"expectedRevision"`
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
		nested, _ := json.Marshal(map[string]any{"metadata": request.Metadata, "source": string(source), "select": request.Select, "expectedRevision": request.ExpectedRevision})
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
			case "patchClashConfig", "vpnProps", "networkProps", "overrideDns", "scriptProps", "currentProfileId":
				apply = true
			case "appSetting":
				var fields profiles.Object
				_ = json.Unmarshal(request.Patch[key], &fields)
				for _, field := range []string{"overrideNetworkSettings", "testUrl", "closeConnections"} {
					if _, changed := fields[field]; changed {
						apply = true
					}
				}
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
			request.Metadata["lastUpdateDate"] = jsonValue(time.Now().UTC())
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
		var err error
		apply, err = a.profiles.DeleteWithSelection(request.ProfileID, request.ExpectedRevision, func() error {
			if err := a.operations.disableBootstrap(); err != nil {
				return err
			}
			receipt, stopErr := a.runtime.Submit(backend.Request{APIVersion: backend.APIVersion, OperationID: runtimeID(operationID), Method: "stop"})
			result.RuntimeOperationID = receipt.OperationID
			return stopErr
		})
		if err != nil {
			return result, err
		}
		result.ProfileID = request.ProfileID
		if result.RuntimeOperationID != "" {
			return result, nil
		}
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
	case "proxy.select":
		var request struct {
			Group string `json:"group"`
			Proxy string `json:"proxy"`
			Reset bool   `json:"reset"`
		}
		if err := decodeParams(params, &request); err != nil {
			return result, err
		}
		if request.Group == "" || (!request.Reset && request.Proxy == "") {
			return result, errors.New("group and proxy are required")
		}
		var id string
		_ = json.Unmarshal(a.profiles.Snapshot().Settings["currentProfileId"], &id)
		if id == "" {
			return result, errors.New("no active profile")
		}
		var err error
		for range 8 {
			record, readErr := a.profiles.Get(id)
			if readErr != nil {
				return result, readErr
			}
			selected := map[string]string{}
			_ = json.Unmarshal(record.Metadata["selectedMap"], &selected)
			if request.Reset {
				delete(selected, request.Group)
			} else {
				selected[request.Group] = request.Proxy
			}
			_, err = a.profiles.UpdateMetadata(ctx, id, profiles.Object{"selectedMap": jsonValue(selected)}, record.Revision)
			if !errors.Is(err, profiles.ErrConflict) {
				break
			}
		}
		if err != nil {
			return result, err
		}
		apply = a.isCurrent(id)
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
			Token  string `json:"token"`
		}
		if err := decodeParams(params, &request); err != nil {
			return result, err
		}
		if request.Token != "" {
			name, err := a.blobPath(request.Token)
			if err != nil {
				return result, err
			}
			bytes, err := readBounded(name, profiles.MaxProfileBytes)
			if err != nil {
				return result, err
			}
			request.Source = string(bytes)
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
		if err := a.ensureCurrentSource(ctx); err != nil {
			return result, err
		}
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
