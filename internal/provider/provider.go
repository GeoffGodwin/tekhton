// Package provider defines the cross-provider interface for invoking
// agents. The Tekhton pipeline calls Provider.RunAgent without knowing
// which provider (Claude CLI, Codex CLI, local Qwen) is on the other
// end. Per-provider implementations live in internal/provider/<name>/.
//
// V5 m01 — Interface + Claude reference. m02 moves stages over.
// m05–m08 add Codex. P5 adds local Qwen.
package provider

import (
	"context"
	"time"
)

// ToolSchema is a placeholder for m04. m01 ships with an empty struct;
// m04 defines the cross-provider tool-schema shape and per-provider
// translation functions.
type ToolSchema struct{}

// Provider is the interface every agent backend implements.
//
// RunAgent runs a full agent loop with the given prompt and tools and
// returns when the loop terminates. Streaming events are emitted to
// Request.EventChan if set; callers that don't need streaming pass nil.
//
// Name returns the provider's canonical name ("claude", "codex",
// "qwen-local"). Used for routing, telemetry, and operator-facing banners.
type Provider interface {
	Name() string
	RunAgent(ctx context.Context, req *Request) (*Result, error)
}

// Request is the per-invocation envelope. Stages populate it from their
// config and the rendered prompt.
type Request struct {
	Prompt    string        // Complete prompt — system + user + context.
	Tools     []ToolSchema  // Tools the agent may call. Empty = no tools.
	MaxTurns  int           // Hard cap on agent iterations.
	Model     string        // Provider-specific model identifier.
	Label     string        // Operator-visible label ("Reviewer (cycle 1)").
	Timeout   time.Duration // Per-invocation timeout. 0 = no timeout.
	EventChan chan<- Event   // Optional streaming. nil = no streaming.

	// ProviderSpecific carries opaque per-provider config that does not
	// fit the cross-provider shape. Unused in m01; m04+ populates it for
	// per-provider tool-schema translation.
	ProviderSpecific map[string]string
}

// Result is the per-invocation outcome. Outcome is the primary signal;
// other fields carry diagnostic detail.
type Result struct {
	Outcome          Outcome
	TurnsUsed        int
	ExitCode         int    // Provider-specific exit code; 0 = success.
	ErrorCategory    string // "UPSTREAM" | "ENVIRONMENT" | "" — drives recovery.
	ErrorSubcategory string // Provider-specific subcategory.
	ErrorMessage     string // Operator-facing error text.
	LastReportPath   string // Where the agent wrote its output report, if any.
	NullRun          bool   // True if the agent exited without producing work.
	RawProviderData  []byte // Opaque per-provider capture for postmortem.
}

// Outcome is the high-level categorization of how an agent run ended.
// Stages branch on Outcome; the other Result fields refine classification.
type Outcome int

const (
	OutcomeUnknown      Outcome = iota
	OutcomeSuccess              // Agent completed normally.
	OutcomeUpstreamError        // Provider infrastructure failure (quota, network, 5xx).
	OutcomeTimeout              // Per-invocation timeout hit.
	OutcomeMaxTurns             // MaxTurns reached without natural exit.
	OutcomeNullRun              // Agent exited without producing work.
	OutcomeAborted              // Caller cancelled via context.
)
