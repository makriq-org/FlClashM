// Package service composes the portable application backend: profiles,
// subscriptions, settings, compilation, runtime commands and their API. Android
// supplies mechanisms; neither Flutter nor an Android class owns this lifetime.
package service

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
	_ "time/tzdata"

	"core/backend"
	"core/backend/compile"
	"core/backend/profiles"
)

type Options struct {
	Directory        string
	LegacySettings   []byte
	ReadLegacySource func(string) (string, error)
	LegacyRunning    bool
	LegacyTimeZone   string
	LegacyUTCOffset  int
	Compiler         *compile.Compiler
	ValidateSource   profiles.Validator
	Engine           backend.EngineAdapter
	Platform         backend.PlatformAdapter
	Nodes            backend.NodeOptions
	HTTPClient       profiles.HTTPClient
	DeviceHeaders    func(context.Context) (map[string]string, error)
	UserAgent        string
	Ticks            <-chan time.Time
	Now              func() time.Time
}
type App struct {
	noticeMu                            sync.Mutex
	now                                 func() time.Time
	runtimeMu                           sync.Mutex
	resetting                           atomic.Bool
	platform                            backend.PlatformAdapter
	presentationMu                      sync.Mutex
	presentationGeneration              uint64
	presentationTitle, presentationMode string
	presentationGroups                  []string
	presentationSelected                map[string]string
	inspection                          backend.RuntimeInspection
	directory                           string
	transferMu                          sync.Mutex
	validateSource                      profiles.Validator
	runtime                             *backend.Backend
	profiles                            *profiles.Repository
	compiler                            *compile.Compiler
	operations                          *operationStore
	subscriptions                       *profiles.Subscriptions
	ctx                                 context.Context
	cancel                              context.CancelFunc
	workers                             sync.WaitGroup
	dataMu                              sync.Mutex
	eventMu                             sync.Mutex
	eventSequence                       uint64
	subscribers                         map[uint64]chan Event
	subscriberID                        uint64
}
type Snapshot struct {
	APIVersion int               `json:"apiVersion"`
	Sequence   uint64            `json:"seq"`
	Runtime    backend.Snapshot  `json:"runtime"`
	Catalog    profiles.Document `json:"catalog"`
}
type Event struct {
	APIVersion      int              `json:"apiVersion"`
	Sequence        uint64           `json:"seq"`
	Runtime         backend.Snapshot `json:"runtime"`
	CatalogRevision uint64           `json:"catalogRevision"`
	ResyncRequired  bool             `json:"resyncRequired,omitempty"`
}

func (a *App) NotifyPlatform(event backend.PlatformEvent) error {
	return a.runtime.NotifyPlatform(event)
}

func Open(options Options) (*App, error) {
	if options.Compiler == nil || options.ValidateSource == nil {
		return nil, errors.New("backend compiler and source validator are required")
	}
	operations, err := openOperations(options.Directory, options.LegacyRunning, options.LegacyTimeZone, options.LegacyUTCOffset)
	if err != nil {
		return nil, err
	}
	repository, err := profiles.Open(options.Directory, options.ValidateSource)
	if err != nil {
		return nil, err
	}
	legacy := options.LegacySettings
	if len(legacy) == 0 {
		legacy = []byte(`{}`)
	}
	reader := options.ReadLegacySource
	if reader == nil {
		reader = func(id string) (string, error) {
			return profiles.ReadLegacySource(options.Compiler.Capabilities.ProfilesDir, id)
		}
	}
	if err = repository.Migrate(context.Background(), legacy, reader); err != nil {
		return nil, err
	}
	store, err := backend.NewFileStore(options.Directory)
	if err != nil {
		return nil, err
	}
	runtime, err := backend.Open(store, options.Compiler, options.Engine, nil, options.Platform, options.Nodes)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	app := &App{directory: options.Directory, platform: options.Platform, inspection: options.Nodes.Inspection, runtime: runtime, profiles: repository, compiler: options.Compiler, validateSource: options.ValidateSource, operations: operations, ctx: ctx, cancel: cancel, subscribers: map[uint64]chan Event{}}
	app.now = options.Now
	if app.now == nil {
		app.now = time.Now
	}
	if err = app.migrateNotices(options.LegacySettings); err != nil {
		cancel()
		_ = runtime.Close()
		return nil, err
	}
	app.workers.Go(func() { app.checkNotices(ctx, app.now()) })
	client := options.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 2 * time.Minute}
	}
	zone, zoneErr := time.LoadLocation(operations.document.LegacyTimeZone)
	if zoneErr != nil {
		zone = time.FixedZone("legacy", operations.document.LegacyUTCOffset)
	}
	app.subscriptions = &profiles.Subscriptions{Repository: repository, Client: client, DeviceHeaders: options.DeviceHeaders, UserAgent: options.UserAgent, Now: options.Now, LegacyTimeZone: zone, OnUpdated: app.profileUpdated}
	runtimeEvents, detach := runtime.Subscribe(1)
	app.workers.Go(func() {
		defer detach()
		var retainedGeneration uint64
		for {
			select {
			case <-ctx.Done():
				return
			case _, ok := <-runtimeEvents:
				if !ok {
					return
				}
				if runtime.Snapshot().AppliedGeneration > 0 {
					generation := runtime.Snapshot().AppliedGeneration
					if generation != retainedGeneration {
						app.retainAppliedSettings(ctx)
						retainedGeneration = generation
					}
					operations.mu.Lock()
					complete := operations.document.BootstrapComplete
					operations.mu.Unlock()
					if !complete {
						_ = operations.disableBootstrap()
					}
				}
				app.publish()
			}
		}
	})
	ticks := options.Ticks
	var ticker *time.Ticker
	if ticks == nil {
		ticker = time.NewTicker(time.Minute)
		ticks = ticker.C
	}
	app.workers.Go(func() {
		if ticker != nil {
			defer ticker.Stop()
		}
		for {
			select {
			case <-ctx.Done():
				return
			case now, ok := <-ticks:
				if !ok {
					return
				}
				if lists, ok := app.compiler.Lists.(interface{ Refresh(context.Context) }); ok {
					app.workers.Go(func() { lists.Refresh(ctx) })
				}
				app.checkNotices(ctx, now)
				for _, id := range app.subscriptions.Due(now) {
					_, _ = app.submitInternal("subscription.refresh", map[string]any{"profileId": id, "deviceHeaders": true})
				}
			}
		}
	})
	operations.mu.Lock()
	bootstrap := !operations.document.BootstrapComplete && operations.document.LegacyResume
	operations.mu.Unlock()
	plan, _, err := runtime.Applied()
	if err != nil {
		_ = app.Close()
		return nil, err
	}
	if plan == nil && bootstrap && app.currentSourceMissing() {
		// Consume the one-time legacy resume before starting network work. An
		// interrupted download is reported, never replayed as a pending command.
		if err = operations.disableBootstrap(); err != nil {
			_ = app.Close()
			return nil, err
		}
		if _, err = app.deferredRuntime(backend.Request{APIVersion: backend.APIVersion, OperationID: newID("boot"), Method: "runtime.start"}); err != nil {
			_ = app.Close()
			return nil, err
		}
		return app, nil
	}
	method := "recover"
	var input backend.Input
	if plan == nil {
		method = "apply"
		input, err = app.captureInput()
		if bootstrap {
			method = "connect"
		}
	}
	if err != nil {
		_ = app.Close()
		return nil, err
	}
	if _, err = runtime.Submit(backend.Request{APIVersion: backend.APIVersion, OperationID: newID("boot"), Method: method, Input: input}); err != nil {
		_ = app.Close()
		return nil, err
	}
	return app, nil
}
func newID(prefix string) string {
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		return prefix + "-" + time.Now().UTC().Format("20060102150405.000000000")
	}
	return prefix + "-" + hex.EncodeToString(nonce)
}
func (a *App) captureInput() (backend.Input, error) {
	for range 8 {
		catalog := a.profiles.Snapshot()
		var id string
		_ = json.Unmarshal(catalog.Settings["currentProfileId"], &id)
		rawSettings, _ := json.Marshal(catalog.Settings)
		decoder := json.NewDecoder(bytes.NewReader(rawSettings))
		decoder.UseNumber()
		var settings compile.Object
		if err := decoder.Decode(&settings); err != nil {
			return nil, err
		}
		request := compile.Input{Version: 1, Settings: settings, CatalogRevision: catalog.Revision}
		if id != "" {
			record, err := a.profiles.Get(id)
			if err != nil {
				if a.profiles.Snapshot().Revision != catalog.Revision {
					continue
				}
				if !errors.Is(err, profiles.ErrNotFound) {
					return nil, err
				}
			} else {
				rawMeta, _ := json.Marshal(record.Metadata)
				decoder = json.NewDecoder(bytes.NewReader(rawMeta))
				decoder.UseNumber()
				var metadata compile.Object
				_ = decoder.Decode(&metadata)
				request.Profile = &compile.RawProfile{ID: id, Text: record.Source, Metadata: metadata, Revision: record.Revision, SourceMissing: record.SourceMissing}
			}
		}
		if a.profiles.Snapshot().Revision != catalog.Revision {
			continue
		}
		raw, err := json.Marshal(request)
		return backend.Input(raw), err
	}
	return nil, profiles.ErrConflict
}
func (a *App) Snapshot() Snapshot {
	a.eventMu.Lock()
	defer a.eventMu.Unlock()
	return Snapshot{APIVersion: backend.APIVersion, Sequence: a.eventSequence, Runtime: a.runtime.Snapshot(), Catalog: a.profiles.Snapshot()}
}
func (a *App) publish() {
	a.eventMu.Lock()
	defer a.eventMu.Unlock()
	a.eventSequence++
	event := Event{APIVersion: backend.APIVersion, Sequence: a.eventSequence, Runtime: a.runtime.Snapshot(), CatalogRevision: a.profiles.Snapshot().Revision}
	for _, channel := range a.subscribers {
		select {
		case channel <- event:
		default:
			for len(channel) > 0 {
				<-channel
			}
			overflow := event
			overflow.ResyncRequired = true
			channel <- overflow
		}
	}
}
func (a *App) Subscribe(capacity int) (Snapshot, <-chan Event, func()) {
	a.eventMu.Lock()
	defer a.eventMu.Unlock()
	if capacity < 1 {
		capacity = 1
	}
	if capacity > 256 {
		capacity = 256
	}
	channel := make(chan Event, capacity)
	a.subscriberID++
	id := a.subscriberID
	a.subscribers[id] = channel
	snapshot := Snapshot{APIVersion: backend.APIVersion, Sequence: a.eventSequence, Runtime: a.runtime.Snapshot(), Catalog: a.profiles.Snapshot()}
	var once sync.Once
	return snapshot, channel, func() {
		once.Do(func() {
			a.eventMu.Lock()
			defer a.eventMu.Unlock()
			if ch := a.subscribers[id]; ch != nil {
				delete(a.subscribers, id)
				close(ch)
			}
		})
	}
}
func (a *App) profileUpdated(ctx context.Context, id string, revision uint64) error {
	a.checkNotices(ctx, a.now())
	if a.isCurrent(id) {
		record, err := a.profiles.Get(id)
		if err != nil {
			return err
		}
		if err = a.customize(ctx, record.Metadata, false); err != nil {
			return err
		}
	}
	a.publish()
	// A download may update another profile, or a desired selection that never
	// committed. Background work only reapplies the profile actually in use.
	_, input, err := a.runtime.Applied()
	if err != nil {
		return err
	}
	var applied compile.Input
	_ = json.Unmarshal(input, &applied)
	if applied.Profile == nil || applied.Profile.ID != id {
		return nil
	}
	catalog := a.profiles.Snapshot()
	var current string
	_ = json.Unmarshal(catalog.Settings["currentProfileId"], &current)
	if current != id {
		return nil
	}
	receipt, err := a.applyCurrent(newID("subscription"), false)
	if err != nil {
		return err
	}
	// Download completion alone is not a successful active-profile update. Wait
	// for its runtime result so rollback/failure reaches both UI and scheduling.
	_, err = a.runtime.Await(ctx, receipt.OperationID)
	return err
}
func (a *App) applyCurrent(id string, connect bool) (backend.Receipt, error) {
	a.runtimeMu.Lock()
	defer a.runtimeMu.Unlock()
	if a.resetting.Load() {
		return backend.Receipt{}, errors.New("data reset in progress")
	}
	generation := a.runtime.Snapshot().Generation
	input, err := a.captureInput()
	if err != nil {
		return backend.Receipt{}, err
	}
	method := "apply"
	if connect {
		method = "connect"
	}
	var captured compile.Input
	_ = json.Unmarshal(input, &captured)
	if captured.Profile == nil && a.runtime.Snapshot().DesiredRunning {
		if err := a.operations.disableBootstrap(); err != nil {
			return backend.Receipt{}, err
		}
		method = "stop"
		input = nil
	}
	return a.runtime.SubmitAtGeneration(backend.Request{APIVersion: backend.APIVersion, OperationID: id, Method: method, Input: input}, generation)
}
func (a *App) Close() error {
	a.cancel()
	a.workers.Wait()
	err := a.runtime.Close()
	a.eventMu.Lock()
	for id, channel := range a.subscribers {
		close(channel)
		delete(a.subscribers, id)
	}
	a.eventMu.Unlock()
	return err
}
func (a *App) ProfileSource(id string) (profiles.Record, error) { return a.profiles.Get(id) }
func (a *App) ExportSettings() ([]byte, error)                  { return a.profiles.ExportLegacy() }
