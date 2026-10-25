package profiles

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"

	"core/backend/authoring"
)

func validateAuthoring(doc Document) error {
	owners := map[string]authoring.Object{}
	for _, p := range doc.Profiles {
		id, _ := profileID(p.Metadata)
		owners[id] = authoring.Object(p.Metadata)
	}
	return authoring.Validate(doc.Authoring, owners)
}
func (r *Repository) AuthoringSnapshot() authoring.Snapshot {
	r.mu.Lock()
	defer r.mu.Unlock()
	metadata := make([]authoring.Object, 0, len(r.state.Profiles))
	for _, record := range r.state.Profiles {
		metadata = append(metadata, authoring.Object(clone(record.Metadata)))
	}
	return authoring.Snapshot{Revision: r.state.Revision, Profiles: metadata, Collections: authoring.Normalize(clone(r.state.Authoring))}
}

// ReplaceAuthoring uses the catalog revision, including revision zero, rather
// than a second clock. An edit cannot race a profile removal or backup restore.
func (r *Repository) ReplaceAuthoring(ctx context.Context, collections authoring.Collections, expected uint64) error {
	return r.ReplaceAuthoringTransaction(ctx, collections, nil, nil, expected, nil)
}

// ReplaceAuthoringTransaction atomically updates editor declarations, profile
// metadata and tombstones. Supplied profiles are upserts, ordered as supplied;
// omitted profiles and all original sources remain intact. beforeLast follows
// DeleteWithSelection's durable-stop contract and must not read this repository.
func (r *Repository) ReplaceAuthoringTransaction(ctx context.Context, collections authoring.Collections, updates []Object, deleted []string, expected uint64, beforeLast func() error) error {
	if collections == nil {
		return errors.New("authoring collections are required")
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if expected != r.state.Revision {
		return ErrConflict
	}
	next := clone(r.state)
	next.Authoring = authoring.Normalize(clone(collections))
	removed := map[string]bool{}
	for _, id := range deleted {
		if removed[id] {
			return errors.New("duplicate deleted profile id")
		}
		removed[id] = true
		found := false
		for _, record := range next.Profiles {
			key, _ := profileID(record.Metadata)
			found = found || key == id
		}
		if !found {
			return ErrNotFound
		}
	}
	supplied := map[string]bool{}
	ordered := []Record{}
	for _, patch := range updates {
		id, err := profileID(patch)
		if err != nil {
			return err
		}
		if supplied[id] || removed[id] {
			return errors.New("duplicate or deleted profile update")
		}
		supplied[id] = true
		var record Record
		found := false
		for _, previous := range next.Profiles {
			key, _ := profileID(previous.Metadata)
			if key == id {
				record = previous
				record.Metadata = mergeObjects(record.Metadata, patch)
				if !reflect.DeepEqual(previous.Metadata, record.Metadata) {
					record.Revision = r.state.Revision + 1
				}
				found = true
				break
			}
		}
		if !found {
			if authoring.String(authoring.Object(patch), "type") != "custom" {
				return errors.New("new source profiles require profile import")
			}
			record = Record{Metadata: clone(patch), Digest: digest("{}"), Revision: r.state.Revision + 1}
			record.Metadata["autoUpdate"] = mustJSON(false)
			if err = r.writeSource("{}"); err != nil {
				return err
			}
		}
		ordered = append(ordered, record)
	}
	for _, record := range next.Profiles {
		key, _ := profileID(record.Metadata)
		if supplied[key] || removed[key] {
			continue
		}
		ordered = append(ordered, record)
	}
	previous := next.Profiles
	next.Profiles = ordered
	for _, record := range previous {
		key, _ := profileID(record.Metadata)
		if removed[key] {
			authoring.PruneProfile(next.Authoring, key)
			renameProvider(&next, record.Metadata, nil)
		} else if supplied[key] {
			for _, updated := range next.Profiles {
				updatedID, _ := profileID(updated.Metadata)
				if key == updatedID {
					renameProvider(&next, record.Metadata, updated.Metadata)
					break
				}
			}
		}
	}
	if err := validateAuthoring(next); err != nil {
		return err
	}
	var current string
	_ = json.Unmarshal(next.Settings["currentProfileId"], &current)
	if removed[current] {
		next.Settings["currentProfileId"] = mustJSON(nil)
		if len(next.Profiles) > 0 {
			next.Settings["currentProfileId"] = next.Profiles[0].Metadata["id"]
		}
	}
	// Validate and size-check the complete prospective document before a Stop.
	raw, err := json.Marshal(next)
	if err != nil {
		return err
	}
	if len(raw) > MaxDocumentBytes {
		return errors.New("profile store exceeds size limit")
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	if len(r.state.Profiles) > 0 && len(next.Profiles) == 0 && beforeLast != nil {
		if err = beforeLast(); err != nil {
			return err
		}
	}
	return r.persist(next)
}

// ImportAuthoring commits the edited profile, added provider sources and all
// declaration references together. Sources are staged before the catalog pointer.
func (r *Repository) ImportAuthoring(ctx context.Context, records []Record, collections authoring.Collections, expected uint64, selected string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if expected != r.state.Revision {
		return ErrConflict
	}
	next := clone(r.state)
	for _, record := range records {
		if err := ctx.Err(); err != nil {
			return err
		}
		id, err := profileID(record.Metadata)
		if err != nil {
			return err
		}
		if len(record.Source) > MaxProfileBytes {
			return errors.New("imported profile exceeds size limit")
		}
		record.Digest = digest(record.Source)
		record.Revision = r.state.Revision + 1
		if err = r.writeSource(record.Source); err != nil {
			return err
		}
		index := -1
		for i, p := range next.Profiles {
			key, _ := profileID(p.Metadata)
			if key == id {
				index = i
				break
			}
		}
		if index < 0 {
			next.Profiles = append(next.Profiles, record)
		} else {
			next.Profiles[index] = record
		}
	}
	next.Authoring = authoring.Normalize(clone(collections))
	if err := validateAuthoring(next); err != nil {
		return err
	}
	if selected != "" {
		next.Settings["currentProfileId"] = mustJSON(selected)
	}
	return r.persist(next)
}
func (r *Repository) Resource(ctx context.Context, collection, id string) (authoring.Object, uint64, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, 0, err
	}
	switch collection {
	case "scripts", "clashProviders", "iconSets":
	default:
		return nil, 0, errors.New("unsupported resource collection")
	}
	for _, row := range r.state.Authoring[collection] {
		if authoring.ID(row["id"]) == id {
			return clone(row), r.state.Revision, nil
		}
	}
	return nil, 0, ErrNotFound
}
func (r *Repository) PutResource(ctx context.Context, collection, id string, patch authoring.Object, expected uint64) error {
	snapshot := r.AuthoringSnapshot()
	if snapshot.Revision != expected {
		return ErrConflict
	}
	switch collection {
	case "scripts", "clashProviders", "iconSets":
	default:
		return errors.New("unsupported resource collection")
	}
	for i, row := range snapshot.Collections[collection] {
		if authoring.ID(row["id"]) != id {
			continue
		}
		for key, raw := range patch {
			if string(raw) == "null" {
				delete(row, key)
			} else {
				row[key] = append(json.RawMessage(nil), raw...)
			}
		}
		snapshot.Collections[collection][i] = row
		return r.ReplaceAuthoring(ctx, snapshot.Collections, expected)
	}
	return ErrNotFound
}

// Keep label-based upstream references stable when a subscription is renamed.
func renameProvider(doc *Document, previous, current Object) {
	if authoring.String(authoring.Object(previous), "type") == "custom" {
		return
	}
	oldName, newName := authoring.String(authoring.Object(previous), "label"), authoring.String(authoring.Object(current), "label")
	if oldName == "" {
		oldName = authoring.String(authoring.Object(previous), "id")
	}
	if newName == "" && current != nil {
		newName = authoring.String(authoring.Object(current), "id")
	}
	if oldName == newName {
		return
	}
	for _, row := range doc.Authoring["proxyGroups"] {
		var names []string
		if json.Unmarshal(row["use"], &names) == nil {
			out := []string{}
			for _, name := range names {
				if name == oldName {
					name = newName
				}
				if name != "" {
					out = append(out, name)
				}
			}
			row["use"] = mustJSON(out)
		}
		var positions Object
		if json.Unmarshal(row["use-position"], &positions) == nil && positions != nil {
			if value, ok := positions[oldName]; ok {
				delete(positions, oldName)
				if newName != "" {
					positions[newName] = value
				}
				row["use-position"] = mustJSON(positions)
			}
		}
	}
	for i, p := range doc.Profiles {
		var overrides Object
		if json.Unmarshal(p.Metadata["overrides"], &overrides) != nil {
			continue
		}
		var options Object
		if json.Unmarshal(overrides["proxy-providers"], &options) != nil || options == nil {
			continue
		}
		if value, ok := options[oldName]; ok {
			delete(options, oldName)
			if newName != "" {
				options[newName] = value
			}
			overrides["proxy-providers"] = mustJSON(options)
			p.Metadata["overrides"] = mustJSON(overrides)
			p.Revision = doc.Revision + 1
			doc.Profiles[i] = p
		}
	}
}

// CollectSources only removes content-addressed original-source blobs which no
// catalog record references. Runtime inputs already embed their own source text.
func (r *Repository) CollectSources(ctx context.Context) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	return r.collectSources()
}
