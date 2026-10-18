package backend

import (
	"context"
	"encoding/json"
)

// NodePlan contains compiler-owned data only. Executable locations, file
// descriptors, physical DNS and permissions come from the trusted host.
type NodePlan struct {
	ID         string            `json:"nodeId"`
	Type       string            `json:"type"`
	Name       string            `json:"name"`
	Host       string            `json:"host"`
	Port       int               `json:"port"`
	UDP        bool              `json:"udp"`
	Files      map[string]string `json:"files"`
	Metadata   map[string]string `json:"metadata"`
	Check      NodeCheck         `json:"connectivityCheck"`
	Activation *NodeActivation   `json:"activation,omitempty"`
}
type NodeCheck struct {
	URLs            []string `json:"urls"`
	Required        bool     `json:"required"`
	Timeout         int64    `json:"timeout"`
	StartupTimeout  int64    `json:"startup-timeout"`
	RetryInterval   int64    `json:"retry-interval"`
	Requests        int      `json:"requests"`
	Concurrency     int      `json:"concurrency"`
	MinSuccessRatio *float64 `json:"min-success-ratio,omitempty"`
	Resolver        string   `json:"resolver,omitempty"`
}
type NodeActivation struct {
	Mode string `json:"mode"`
	Wake struct {
		URLs       []string `json:"urls"`
		Interval   int64    `json:"interval"`
		Failures   int      `json:"failures"`
		RetryAfter int64    `json:"retry-after"`
	} `json:"wake"`
	Sleep struct {
		Idle int64 `json:"idle"`
	} `json:"sleep"`
	ContainingGroups []string `json:"containing-groups"`
	WatchGroup       string   `json:"watch-group"`
}
type NodeLaunch struct {
	Node     NodePlan
	Strategy string // ByeDPI only; already validated by the compiler.
	SNI      string
	Probe    bool
	Port     int // Probe listener allocated by the host, zero uses the compiled port.
}
type NodeProbe struct {
	Host          string
	Port          int
	URL, Resolver string
}

// NodeAdapter implements external-process mechanisms. It makes no decisions
// about strategy selection, retries, sleep, wake, cancellation or rollback.
// Stop fences a prior Start for the same node; StopAll fences every process.
type NodeAdapter interface {
	Prepare(context.Context, NodePlan) error
	Start(context.Context, NodeLaunch) error
	Stop(context.Context, string) error
	StopAll(context.Context) error
	Observe(context.Context, string) (Observation, error)
	Listening(context.Context, NodePlan) (bool, error)
	AllocatePort(context.Context) (int, error)
	Probe(context.Context, NodeProbe) (bool, error)
}

// RuntimeInspection is a read-only engine/platform view used by coordinator
// policy. Failure to observe activity must never count as proof of idleness.
type RuntimeInspection interface {
	HasNetwork(context.Context) (bool, error)
	TestGroup(context.Context, string, []string) (bool, error)
	Selected(context.Context, []string) (map[string]string, error)
	Connections(context.Context) ([][]string, error)
	NetworkScope(context.Context) (string, error)
}

func (p NodePlan) Clone() NodePlan {
	raw, _ := json.Marshal(p)
	var out NodePlan
	_ = json.Unmarshal(raw, &out)
	return out
}
