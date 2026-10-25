package main

import "github.com/metacubex/http"

type RouteState struct {
	CoreEpoch    uint64            `json:"core-epoch"`
	PicksVersion uint64            `json:"picks-version"`
	Picks        map[string]string `json:"picks"`
}

type ProbeParams struct {
	Url       string            `json:"url"`
	ProxyName string            `json:"proxy-name"`
	Headers   map[string]string `json:"headers"`
	Timeout   int64             `json:"timeout"`
	MaxBody   int64             `json:"max-body"`
}

type ProbeResult struct {
	StatusCode  int      `json:"status-code"`
	Delay       int64    `json:"delay"`
	Body        string   `json:"body"`
	Url         string   `json:"url"`
	Chains      []string `json:"chains"`
	Rule        string   `json:"rule"`
	RulePayload string   `json:"rule-payload"`
	Error       string   `json:"error,omitempty"`
	Message     string   `json:"message,omitempty"`

	CoreEpoch    uint64 `json:"core-epoch"`
	PicksVersion uint64 `json:"picks-version"`

	// Unexported, so it never reaches Dart: only the in-core checks read
	// response headers, and ProbeResult is the shape the Dart side decodes.
	header    http.Header
	lowerBody string
}

type MemoryStats struct {
	Rss          uint64 `json:"rss"`
	HeapInuse    uint64 `json:"heapInuse"`
	HeapIdle     uint64 `json:"heapIdle"`
	StackInuse   uint64 `json:"stackInuse"`
	RuntimeOther uint64 `json:"runtimeOther"`
}

type ProxiesData struct {
	Proxies map[string]any `json:"proxies"`
	All     []string       `json:"all"`
}
