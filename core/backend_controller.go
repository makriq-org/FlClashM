package main

import (
	"bytes"
	"context"
	"core/backend"
	application "core/backend/service"
	"crypto/rand"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/url"
	"strings"
	"sync"
	"time"

	controlhttp "github.com/metacubex/http"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/hub/route"
)

var backendController struct {
	server        *controlhttp.Server
	configuration string
}

type controllerWork struct {
	handler  controlhttp.Handler
	request  *controlhttp.Request
	response *controllerResponse
}

var controllerCommands sync.Map

type controllerResponse struct {
	headers controlhttp.Header
	status  int
	body    bytes.Buffer
}

func (r *controllerResponse) Header() controlhttp.Header { return r.headers }
func (r *controllerResponse) WriteHeader(code int) {
	if r.status == 0 {
		r.status = code
	}
}
func (r *controllerResponse) Write(data []byte) (int, error) {
	if r.status == 0 {
		r.status = 200
	}
	if r.body.Len()+len(data) > 1<<20 {
		return 0, errors.New("controller response too large")
	}
	return r.body.Write(data)
}

// Called under the engine adapter's serialized application, never from an
// asynchronous route.ReCreateServer goroutine.
func applyBackendController(ctx context.Context, controller *config.Controller) error {
	raw, _ := json.Marshal(controller)
	key := string(raw)
	if backendController.configuration == key {
		return nil
	}
	if backendController.server != nil {
		_ = backendController.server.Close()
		backendController.server = nil
		backendController.configuration = ""
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if controller.ExternalController == "" {
		backendController.configuration = key
		return nil
	}
	listener, err := (&net.ListenConfig{}).Listen(ctx, "tcp", controller.ExternalController)
	if err != nil {
		return err
	}
	route.SetEmbedMode(true)
	route.SetUIPath(controller.ExternalUI)
	server := &controlhttp.Server{Handler: route.NewEmbeddedRouter(&route.Config{Secret: controller.Secret, Cors: route.Cors{AllowOrigins: controller.Cors.AllowOrigins, AllowPrivateNetwork: controller.Cors.AllowPrivateNetwork}}, backendControllerGate), ReadHeaderTimeout: 15 * time.Second}
	backendController.server = server
	backendController.configuration = key
	go func() { _ = server.Serve(listener) }()
	return nil
}

func backendControllerGate(next controlhttp.Handler) controlhttp.Handler {
	return controlhttp.HandlerFunc(func(w controlhttp.ResponseWriter, r *controlhttp.Request) {
		if r.Method == "GET" || r.Method == "HEAD" || r.Method == "OPTIONS" {
			next.ServeHTTP(w, r)
			return
		}
		applicationMu.Lock()
		app := applicationBackend
		applicationMu.Unlock()
		if app == nil {
			controlhttp.Error(w, "backend is not ready", 503)
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, backend.MaxRequestBytes+1))
		if err != nil || len(body) > backend.MaxRequestBytes {
			controlhttp.Error(w, "invalid controller request", 400)
			return
		}
		path := strings.TrimSuffix(r.URL.Path, "/")
		if r.Method == "PATCH" && path == "/configs" {
			var patch map[string]json.RawMessage
			if json.Unmarshal(body, &patch) != nil {
				controlhttp.Error(w, "invalid settings", 400)
				return
			}
			if err = runApplicationCommand(r.Context(), app, "settings.patch", map[string]any{"patch": map[string]any{"patchClashConfig": patch}}); err != nil {
				controlhttp.Error(w, err.Error(), 400)
				return
			}
			w.WriteHeader(204)
			return
		}
		if r.Method == "PUT" && path == "/configs" {
			var request struct {
				Payload string `json:"payload"`
				Path    string `json:"path"`
			}
			if len(body) > 0 && json.Unmarshal(body, &request) != nil {
				controlhttp.Error(w, "invalid configuration request", 400)
				return
			}
			if request.Path != "" {
				controlhttp.Error(w, "use a profile payload to replace the active profile", 400)
				return
			}
			if request.Payload == "" {
				err = runApplicationCommand(r.Context(), app, "runtime.restart", nil)
			} else {
				var settings struct {
					ID string `json:"currentProfileId"`
				}
				raw, _ := app.ExportSettings()
				_ = json.Unmarshal(raw, &settings)
				if settings.ID == "" {
					controlhttp.Error(w, "no active profile", 400)
					return
				}
				var revision uint64
				for _, record := range app.Snapshot().Catalog.Profiles {
					var id string
					_ = json.Unmarshal(record.Metadata["id"], &id)
					if id == settings.ID {
						revision = record.Revision
						break
					}
				}
				err = runApplicationCommand(r.Context(), app, "profile.put", map[string]any{"metadata": map[string]string{"id": settings.ID}, "source": request.Payload, "expectedRevision": revision})
			}
			if err != nil {
				controlhttp.Error(w, err.Error(), 400)
				return
			}
			w.WriteHeader(204)
			return
		}
		if strings.HasPrefix(path, "/proxies/") && (r.Method == "PUT" || r.Method == "DELETE") {
			group, decodeErr := url.PathUnescape(strings.TrimPrefix(r.URL.EscapedPath(), "/proxies/"))
			if decodeErr != nil {
				controlhttp.Error(w, "invalid group", 400)
				return
			}
			var request struct {
				Name string `json:"name"`
			}
			if r.Method == "PUT" && (json.Unmarshal(body, &request) != nil || request.Name == "") {
				controlhttp.Error(w, "proxy name is required", 400)
				return
			}
			params := map[string]any{"group": group, "proxy": request.Name, "reset": r.Method == "DELETE"}
			if err = runApplicationCommand(r.Context(), app, "proxy.select", params); err != nil {
				controlhttp.Error(w, err.Error(), 400)
				return
			}
			w.WriteHeader(204)
			return
		}
		// File, process-upgrade and arbitrary config-path endpoints are not
		// embedding mechanisms. All supported transient effects run in the same
		// coordinator queue as native/UI engine commands.
		allowed := strings.HasPrefix(path, "/connections") || strings.HasPrefix(path, "/providers/") || strings.HasPrefix(path, "/cache/") || path == "/dns/flush"
		if !allowed {
			controlhttp.Error(w, "unsupported embedded controller command", 400)
			return
		}
		id := "controller-" + rand.Text()
		copyRequest := r.Clone(context.Background())
		copyRequest.Body = io.NopCloser(bytes.NewReader(body))
		response := &controllerResponse{headers: controlhttp.Header{}}
		controllerCommands.Store(id, controllerWork{next, copyRequest, response})
		params, _ := json.Marshal(map[string]string{"token": id})
		result := make(chan error, 1)
		go func() {
			defer controllerCommands.Delete(id)
			result <- runApplicationCommandWithID(context.Background(), app, id, "engine.command", backend.EngineCommand{Method: "controller.dispatch", Params: params})
		}()
		select {
		case <-r.Context().Done():
			return
		case err = <-result:
		}
		if err != nil {
			controlhttp.Error(w, err.Error(), 400)
			return
		}
		for name, values := range response.headers {
			w.Header()[name] = values
		}
		if response.status == 0 {
			response.status = 204
		}
		w.WriteHeader(response.status)
		_, _ = w.Write(response.body.Bytes())
	})
}

func runApplicationCommand(ctx context.Context, app *application.App, method string, params any) error {
	return runApplicationCommandWithID(ctx, app, "control-"+rand.Text(), method, params)
}
func runApplicationCommandWithID(ctx context.Context, app *application.App, id, method string, params any) error {
	request, _ := json.Marshal(map[string]any{"apiVersion": 1, "operationId": id, "method": method, "params": params})
	var response struct {
		Error *backend.APIError `json:"error"`
	}
	if err := json.Unmarshal(app.Handle(request), &response); err != nil {
		return err
	}
	if response.Error != nil {
		return errors.New(response.Error.Message)
	}
	if strings.HasPrefix(method, "runtime.") || method == "engine.command" {
		_, err := app.AwaitRuntime(ctx, id)
		return err
	}
	receipt, err := app.Await(ctx, id)
	if err != nil {
		return err
	}
	if receipt.Status != "succeeded" {
		return errors.New(receipt.Error)
	}
	if receipt.RuntimeOperationID != "" {
		_, err = app.AwaitRuntime(ctx, receipt.RuntimeOperationID)
	}
	return err
}

func (backendEngine) Command(ctx context.Context, command backend.EngineCommand) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	var params struct {
		Token string `json:"token"`
		ID    string `json:"id"`
	}
	if len(command.Params) > 0 && json.Unmarshal(command.Params, &params) != nil {
		return errors.New("invalid engine command parameters")
	}
	switch command.Method {
	case "controller.dispatch":
		value, ok := controllerCommands.LoadAndDelete(params.Token)
		if !ok {
			return errors.New("controller request expired")
		}
		work := value.(controllerWork)
		work.handler.ServeHTTP(work.response, work.request.WithContext(ctx))
		return ctx.Err()
	case "connections.close":
		handleCloseConnections()
	case "connection.close":
		handleCloseConnection(params.ID)
	case "connections.reset":
		handleResetConnections()
	case "traffic.reset":
		handleResetTraffic()
	default:
		return errors.New("unsupported engine command")
	}
	return ctx.Err()
}
