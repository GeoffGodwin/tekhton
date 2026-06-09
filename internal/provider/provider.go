// Package provider defines the cross-provider interface for invoking
// agents. The Tekhton pipeline calls Provider.RunAgent without knowing
// which provider (Claude CLI, Codex CLI, local Qwen) is on the other
// end. Per-provider implementations live in internal/provider/<name>/.
//
// V5 m01 — Interface + Claude reference. m02 moves stages over.
// m03 defines ToolSchema fully and ships the Claude translator.
// m05–m08 add Codex. P5 adds local Qwen.
package provider

import (
	"context"
	"errors"
	"time"
)

// ToolSchema is the Tekhton-internal canonical representation of an
// agent tool. Per-provider translators convert this to native tool-use
// formats (Claude's tool_use blocks, Codex's function calling, local
// LLMs' pseudo-tools).
//
// V5 m03 — Defined. m04 wires stages to populate Request.Tools with
// canonical schemas from internal/provider/tools/canonical.go.
type ToolSchema struct {
	// Name is the canonical tool name. Cross-provider — every
	// provider's translator uses this string. Examples: "Read",
	// "Write", "Edit", "Bash".
	Name string

	// Description is a one-line description of the tool's purpose.
	// Used in agent prompts and provider tool-list payloads.
	Description string

	// Parameters is a JSON-schema-shaped object describing the tool's
	// input parameters. The format follows JSON Schema draft 2020-12
	// with a strict subset:
	//   - type: "object" required at the top level
	//   - properties: map of named parameters
	//   - required: array of required parameter names
	//   - additionalProperties: false (enforced)
	Parameters ParameterSchema

	// BehaviorHints carries cross-provider guidance about the tool's
	// behavior — useful for providers that need to inject safety
	// notices, output-size limits, or tool-ordering preferences into
	// their native format.
	BehaviorHints BehaviorHints
}

// ParameterSchema describes the JSON-schema-shaped parameters block for
// a tool. Only the strict cross-provider subset is represented.
type ParameterSchema struct {
	Type                 string                       // "object"
	Properties           map[string]ParameterProperty
	Required             []string
	AdditionalProperties bool // enforced false by ValidateToolSchema
}

// ParameterProperty describes a single named parameter within a tool's
// parameter schema.
type ParameterProperty struct {
	Type        string             // "string" | "integer" | "boolean" | "array"
	Description string
	Items       *ParameterProperty // non-nil for type="array"
	Enum        []string           // optional; restricts allowed values
}

// BehaviorHints carries cross-provider guidance about a tool's behavior.
// The Claude translator currently ignores BehaviorHints; future providers
// (Codex, local Qwen) may consume them to inject safety notices or inject
// tool descriptions into prompts.
type BehaviorHints struct {
	ModifiesFiles  bool // true for Write, Edit
	Reads          bool // true for Read, Glob, Grep
	ExecutesShell  bool // true for Bash
	MaxOutputBytes int  // 0 = provider default
	LongRunning    bool // true if tool may run >60s
}

// ValidateToolSchema returns an error if t is malformed. Providers call
// this before translation to surface caller bugs early.
func ValidateToolSchema(t ToolSchema) error {
	if t.Name == "" {
		return errors.New("toolschema: Name is required")
	}
	if t.Description == "" {
		return errors.New("toolschema: Description is required")
	}
	if t.Parameters.Type != "object" {
		return errors.New("toolschema: Parameters.Type must be \"object\"")
	}
	if t.Parameters.AdditionalProperties {
		return errors.New("toolschema: Parameters.AdditionalProperties must be false")
	}
	return nil
}

// Tier constants. The chain consults these to order providers and gate
// fallthrough via --require-tier.
const (
	TierSubscription = "subscription" // Free within quota (ChatGPT Plus/Pro, etc.)
	TierAPI          = "api"          // Paid per-token (Anthropic API, OpenAI API key)
	TierLocal        = "local"        // Free, no quota (local llama.cpp / vLLM — V5 Phase 2)
	TierUnknown      = "unknown"      // Provider cannot determine its tier
)

// TierCostRank returns an integer ordering: smaller is cheaper.
// local (0) < subscription (1) < api (2) < unknown (3).
// Used by Chain to sort providers when --cost-rank-chain is set.
func TierCostRank(tier string) int {
	switch tier {
	case TierLocal:
		return 0
	case TierSubscription:
		return 1
	case TierAPI:
		return 2
	default:
		return 3
	}
}

// Provider is the interface every agent backend implements.
//
// RunAgent runs a full agent loop with the given prompt and tools and
// returns when the loop terminates. Streaming events are emitted to
// Request.EventChan if set; callers that don't need streaming pass nil.
//
// Name returns the provider's canonical name ("claude", "codex",
// "qwen-local"). Used for routing, telemetry, and operator-facing banners.
//
// Tier returns the cost tier for this provider — one of TierSubscription,
// TierAPI, TierLocal, or TierUnknown. The chain uses Tier to order
// providers cheapest-first and to enforce --require-tier limits.
type Provider interface {
	Name() string
	Tier() string
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

	// WorkingDir is the subprocess working directory. Empty = inherit caller's cwd.
	WorkingDir string
	// AllowedTools is a space-separated list of tool names the agent may call.
	// Empty = no restriction.
	AllowedTools string

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
	// TierUsed is set by Chain when a provider succeeds. One of the TierXxx
	// constants. Empty string when the result came from a single (non-chained)
	// provider invocation.
	TierUsed string
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
