<!-- milestone-meta
id: "01"
status: "todo"
-->

# m01 (V5) — Provider Interface and Claude Reference Implementation

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | V5 Phase 1, Milestone 1. The V4 Ship-of-Theseus migration closed yesterday with every pipeline stage Go-native — but every stage still calls into `internal/supervisor/` which is hard-wired to the `claude` CLI. With Claude licensing changes landing in a week, this dependency is now a hard strategic risk: a single upstream policy change can take the entire pipeline offline. V5's polyglot arc breaks the dependency. m01 is the seam: define the `Provider` interface and ship Claude as the reference implementation. Zero behavior change to existing pipeline runs — every stage continues to invoke agents the same way — but the seam now exists for m02-m08 to widen and for Codex (P3) and local Qwen (P5) to plug in. |
| **Gap** | Today `internal/supervisor/` exposes `Run(ctx, *AgentRequest) (*AgentResult, error)` directly to stages. Every stage's invocation seam (`invokeReviewerAgent` in `internal/stages/review/cycle.go`, `invokeScanAgent` in `internal/stages/security/run.go`, `invokeCoderAgent` in `internal/stages/coder/coder.go`, etc.) calls the supervisor without abstraction. The supervisor's body is Claude-specific: `exec.CommandContext("claude", ...)`, Claude-flavored JSON envelope parsing, Claude-specific Retry-After header handling, Claude-specific quota pause semantics. No interface separates "what the stage needs from an agent" from "how Claude CLI delivers it." m01 lifts that abstraction: a small Go interface `provider.Provider` with one method (`RunAgent`), a typed Request/Result envelope, and Claude as the first implementation. The supervisor stays as Claude's underlying machinery — m01 does NOT rewrite supervisor internals, it just wraps them behind the interface. |
| **m01 fills** | (1) `internal/provider/provider.go` — `Provider` interface with `RunAgent(ctx, *Request) (*Result, error)` + `Name() string`. Request/Result types capture the cross-provider shape (prompt, tools, max turns, model, optional event channel for streaming; outcome category, turns used, error category, null-run detection). (2) `internal/provider/claude/claude.go` — Claude reference implementation that translates `provider.Request` → existing supervisor invocation → `provider.Result`. Wraps the existing `internal/supervisor/` package without modifying it. (3) `internal/provider/event.go` — `Event` type for streaming TUI events (`TurnStart`, `ToolCall`, `AssistantChunk`, `TurnEnd`). For m01 the Claude provider emits only `TurnStart` and `TurnEnd` (the simpler subset); m07 widens the Codex provider to emit the full set. (4) `internal/provider/provider_test.go` + `internal/provider/claude/claude_test.go` — unit tests for the interface contract + Claude wrapper. (5) `internal/provider/claude/parity_test.go` — drives the same agent invocation through both paths (direct supervisor AND via Claude provider) and asserts byte-for-byte identical `Result`. (6) `docs/v5-provider-seam.md` (new, short) — documents the provider seam contract for m02-m08 implementers. (7) No stage code changes in this milestone — m02 owns moving stages over to the provider seam. |
| **Depends on** | none (V5 fresh start) |
| **Files changed** | `internal/provider/provider.go` (create, ~140 LOC), `internal/provider/event.go` (create, ~50 LOC), `internal/provider/provider_test.go` (create, ~120 LOC), `internal/provider/claude/claude.go` (create, ~180 LOC), `internal/provider/claude/claude_test.go` (create, ~150 LOC), `internal/provider/claude/parity_test.go` (create, ~120 LOC), `internal/provider/claude/testdata/` (create — recorded supervisor output fixtures for the parity tests), `docs/v5-provider-seam.md` (create, ~150 lines), `VERSION` (modify — bump to 5.1.0 on close per dogfood precedent) |

### V5 Phase 1 arc context

| Milestone | Concern addressed |
|-----------|------------------|
| **m01** | **Provider interface defined; Claude reference implementation ships. Stages still call supervisor directly — no behavior change.** |
| m02 | Refactor `internal/supervisor/` callers (all stages) to consume `Provider` instead. After m02, the supervisor is purely internal to the Claude provider. |
| m03 | Stage-level agent-invocation seam consumes Provider across every `internal/stages/*/` package. |
| m04 | Tekhton `ToolSchema` type + Claude translator. Sets up the per-provider tool-format translation pattern. |
| m05–m08 | Codex provider end-to-end (envelope translation, tool schema translation, streaming + TUI events, quota/retry parity). |
| m09 | `pipeline.conf` per-stage provider selection + fallback chain. |
| m10 | End-to-end dogfood: run a full milestone on Codex. |

---

## Design

### Sequencing note

m01 ships the seam without changing stage behavior. Existing tests pass
unchanged; the parity test in `internal/provider/claude/parity_test.go`
locks in that the Claude provider produces identical Results to the
direct supervisor path. After m01 the codebase has TWO ways to invoke
Claude — m02 retires the direct path.

### Goal 1 — `Provider` interface

**File:** `internal/provider/provider.go`.

```go
// Package provider defines the cross-provider interface for invoking
// agents. The Tekhton pipeline calls Provider.RunAgent without knowing
// which provider (Claude CLI, Codex CLI, local Qwen) is on the other
// end. Per-provider implementations live in internal/provider/<name>/.
//
// V5 m01 — Interface + Claude reference. m02 moves stages over.
// m05-m08 add Codex. P5 adds local Qwen.
package provider

import "context"

// Provider is the interface every agent backend implements.
//
// RunAgent runs a full agent loop with the given prompt and tools and
// returns when the loop terminates. Streaming events are emitted to
// Request.EventChan if set; callers that don't need streaming pass nil.
//
// Name returns the provider's canonical name ("claude", "codex",
// "qwen-local"). Used for routing, telemetry, and operator-facing
// banners.
type Provider interface {
    Name() string
    RunAgent(ctx context.Context, req *Request) (*Result, error)
}

// Request is the per-invocation envelope. Stages populate it from
// their config + the rendered prompt.
type Request struct {
    Prompt    string           // The complete prompt — system + user + context.
    Tools     []ToolSchema     // Tools the agent may call. Empty = no tools.
    MaxTurns  int              // Hard cap on agent iterations.
    Model     string           // Provider-specific model identifier.
    Label     string           // Operator-visible label ("Reviewer (cycle 1)").
    Timeout   time.Duration    // Per-invocation timeout. 0 = no timeout.
    EventChan chan<- Event     // Optional streaming. nil = no streaming.

    // ProviderSpecific lets a provider receive opaque config that
    // doesn't fit the cross-provider shape. The Claude provider
    // consumes ProviderSpecific["claude.model_path"], etc.
    ProviderSpecific map[string]string
}

// Result is the per-invocation outcome. Outcome is the primary signal;
// the other fields carry diagnostic detail.
type Result struct {
    Outcome          Outcome
    TurnsUsed        int
    ExitCode         int     // Provider-specific exit code, 0 = success.
    ErrorCategory    string  // "UPSTREAM" | "ENVIRONMENT" | "" — drives recovery.
    ErrorSubcategory string  // Provider-specific subcategory.
    ErrorMessage     string  // Operator-facing error text.
    LastReportPath   string  // Where the agent wrote its output report (if any).
    NullRun          bool    // True if the agent exited without producing work.
    RawProviderData  []byte  // Opaque per-provider diagnostic capture for postmortem.
}

// Outcome is the high-level categorization of how an agent run ended.
// Stages branch on Outcome; the other Result fields refine the
// classification.
type Outcome int

const (
    OutcomeUnknown      Outcome = iota
    OutcomeSuccess              // Agent completed normally.
    OutcomeUpstreamError        // Provider infrastructure failure (quota, network, 5xx).
    OutcomeTimeout              // Per-invocation timeout hit.
    OutcomeMaxTurns             // Hit MaxTurns without natural exit.
    OutcomeNullRun              // Agent exited without producing work.
    OutcomeAborted              // Caller cancelled via context.
)
```

The interface is intentionally minimal. Anything cross-provider
ambiguity falls into `ProviderSpecific` (request-side) or
`RawProviderData` (result-side) for now; m04 will introduce the
typed `ToolSchema`.

### Goal 2 — `Event` type for streaming

**File:** `internal/provider/event.go`.

```go
package provider

import "time"

// Event is one streaming event from an agent run. The TUI sidecar
// (m97) consumes Events for live progress display; stages may also
// consume them for cycle bookkeeping.
type Event struct {
    Kind      EventKind
    Timestamp time.Time
    Turn      int               // 1-indexed, 0 if not turn-specific.
    Content   string            // For AssistantChunk: the chunk text. For ToolCall: the tool name.
    Metadata  map[string]string // Per-Kind extras (tool args, error category, etc.).
}

type EventKind int

const (
    EventUnknown        EventKind = iota
    EventTurnStart                // A new turn begins.
    EventAssistantChunk           // A chunk of the assistant's response.
    EventToolCall                 // The assistant invoked a tool.
    EventToolResult               // The tool returned.
    EventTurnEnd                  // Turn complete.
    EventRunEnd                   // The whole run is done.
)
```

For m01 the Claude provider emits only `EventTurnStart`, `EventTurnEnd`,
and `EventRunEnd` — the minimum needed for the TUI to show "Cycle 1, 2,
3, ... done." The richer events (`EventAssistantChunk`, `EventToolCall`,
`EventToolResult`) come in m07 when the Codex provider adds streaming
parity. The interface is forward-compatible; consumers switch on Kind
and ignore unknown events.

### Goal 3 — Claude reference implementation

**File:** `internal/provider/claude/claude.go`.

```go
// Package claude is the Claude CLI provider implementation. It wraps
// internal/supervisor/ — the existing m05-m10 supervisor — without
// modifying it. m01 ships this as the reference. m02 retires direct
// supervisor calls from stages so the supervisor becomes purely
// internal to this package.
package claude

import (
    "context"
    "time"

    "github.com/geoffgodwin/tekhton/internal/provider"
    "github.com/geoffgodwin/tekhton/internal/supervisor"
)

// Provider implements provider.Provider against the Claude CLI via
// the supervisor package.
type Provider struct {
    Supervisor *supervisor.Supervisor
}

// New constructs a Claude provider with the default supervisor.
func New() *Provider {
    return &Provider{Supervisor: supervisor.New()}
}

func (p *Provider) Name() string { return "claude" }

func (p *Provider) RunAgent(ctx context.Context, req *provider.Request) (*provider.Result, error) {
    if req == nil {
        return nil, errors.New("claude provider: nil request")
    }

    // Translate provider.Request → supervisor.AgentRequest.
    sreq := &supervisor.AgentRequest{
        Prompt:   req.Prompt,
        MaxTurns: req.MaxTurns,
        Model:    req.Model,
        Label:    req.Label,
        Timeout:  req.Timeout,
        // ... per-field translation
    }

    // Wire streaming events if requested.
    if req.EventChan != nil {
        sreq.EventCh = adaptSupervisorEvents(req.EventChan)
    }

    sres, err := p.Supervisor.Run(ctx, sreq)
    if err != nil {
        return nil, err
    }

    // Translate supervisor.AgentResult → provider.Result.
    return &provider.Result{
        Outcome:          translateOutcome(sres),
        TurnsUsed:        sres.TurnsUsed,
        ExitCode:         sres.ExitCode,
        ErrorCategory:    sres.ErrorCategory,
        ErrorSubcategory: sres.ErrorSubcategory,
        ErrorMessage:     sres.ErrorMessage,
        LastReportPath:   sres.LastReportPath,
        NullRun:          sres.NullRun,
        RawProviderData:  sres.RawJSON,
    }, nil
}

// translateOutcome maps the supervisor's existing exit-classification
// onto provider.Outcome. The mapping table is the contract — m02-m08
// implementers consult it before adding new outcome categories.
func translateOutcome(sres *supervisor.AgentResult) provider.Outcome {
    if sres.NullRun {
        return provider.OutcomeNullRun
    }
    if sres.ErrorCategory == "UPSTREAM" {
        return provider.OutcomeUpstreamError
    }
    if sres.TimedOut {
        return provider.OutcomeTimeout
    }
    if sres.TurnsUsed >= sres.MaxTurnsAttempted {
        return provider.OutcomeMaxTurns
    }
    if sres.ExitCode == 0 {
        return provider.OutcomeSuccess
    }
    return provider.OutcomeUnknown
}
```

**Critical constraint:** m01 does NOT modify `internal/supervisor/`.
The supervisor's API stays unchanged. Claude provider wraps. m02 will
move callers off the supervisor; that's where the supervisor becomes
private to this package.

### Goal 4 — Parity test

**File:** `internal/provider/claude/parity_test.go`.

The parity test is the safety net for m02. It drives the same agent
invocation through both code paths (direct supervisor AND via Claude
provider) and asserts byte-for-byte identical `provider.Result`:

```go
func TestClaudeProvider_ParityWithDirectSupervisor(t *testing.T) {
    // Set up a fixture-stubbed supervisor that replays a recorded
    // Claude CLI exchange. The same supervisor instance is invoked
    // twice — once directly, once through Claude provider — and the
    // results are compared.

    fixtures := []string{
        "trivial_success",
        "multi_turn_with_tools",
        "upstream_error",
        "null_run",
        "max_turns_exhausted",
        "context_cancelled",
    }

    for _, name := range fixtures {
        t.Run(name, func(t *testing.T) {
            sup := stubSupervisor(t, name)
            req := loadRequest(t, name)

            // Path 1 — direct supervisor.
            directRes, directErr := sup.Run(context.Background(), translateReqToSupervisor(req))

            // Path 2 — through Claude provider.
            cp := &claude.Provider{Supervisor: sup}
            providerRes, providerErr := cp.RunAgent(context.Background(), req)

            // Compare.
            if (directErr != nil) != (providerErr != nil) {
                t.Errorf("error mismatch: direct=%v provider=%v", directErr, providerErr)
            }
            if !resultsEquivalent(directRes, providerRes) {
                t.Errorf("result mismatch:\n  direct=%+v\n  provider=%+v", directRes, providerRes)
            }
        })
    }
}
```

The six fixtures cover every Outcome category. They're captured from
real Claude CLI runs during m01 implementation. After m01 ships, m02
runs these tests on every stage migration — if the parity breaks, the
stage migration regressed.

### Goal 5 — Documentation

**File:** `docs/v5-provider-seam.md` (new, ~150 lines).

Documents:
- The Provider interface contract (what callers can assume).
- The Outcome category mapping (what each Outcome means and how stages should branch on it).
- The Event type contract (what TUI consumers see).
- The translation pattern for new providers (the Claude provider as
  the worked example).
- The non-goals of m01 (no stage changes; no supervisor refactor; no
  tool-schema definition — that's m04).

m02-m08 implementers read this doc first.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/provider/provider.go` | Create | `Provider` interface, `Request`, `Result`, `Outcome`. ~140 LOC. |
| `internal/provider/event.go` | Create | `Event` type, `EventKind` enum. ~50 LOC. |
| `internal/provider/provider_test.go` | Create | Interface contract tests. ~120 LOC. |
| `internal/provider/claude/claude.go` | Create | Claude reference implementation. Wraps existing supervisor. ~180 LOC. |
| `internal/provider/claude/claude_test.go` | Create | Per-method tests for the Claude wrapper. ~150 LOC. |
| `internal/provider/claude/parity_test.go` | Create | Six-fixture parity test (Goal 4). ~120 LOC. |
| `internal/provider/claude/testdata/` | Create | Six recorded supervisor-exchange fixtures. |
| `docs/v5-provider-seam.md` | Create | Provider seam contract doc. ~150 lines. |
| `VERSION` | Modify | Bump 5.0.0 → 5.1.0 on close per dogfood precedent. |
| `.claude/milestones/m01-provider-interface-and-claude-ref.md` | Delete (finalize) | This file deletes on success per the finalize convention. |

---

## Acceptance Criteria

- [ ] `internal/provider/provider.go` exports `Provider` (interface), `Request` (struct), `Result` (struct), `Outcome` (type) with the documented constants. Verified by `go doc ./internal/provider` listing all four.
- [ ] `Provider` interface has exactly two methods: `Name() string` and `RunAgent(ctx context.Context, req *Request) (*Result, error)`. Verified by a Go-side test asserting `reflect.TypeOf((*provider.Provider)(nil)).Elem().NumMethod() == 2`.
- [ ] `internal/provider/event.go` exports `Event` (struct), `EventKind` (type) with the documented constants. Verified by `go doc`.
- [ ] `internal/provider/claude.Provider` implements `provider.Provider`. Verified by `var _ provider.Provider = (*claude.Provider)(nil)` compiling.
- [ ] `claude.Provider.Name()` returns `"claude"`. Verified by unit test.
- [ ] `claude.Provider.RunAgent` translates `*provider.Request` → supervisor invocation → `*provider.Result` without modifying the supervisor's exported API. Verified by `grep -nE 'func \(.*\*Supervisor\)' internal/supervisor/*.go` showing the supervisor's method set is identical to its pre-m01 shape.
- [ ] All six parity-test fixtures pass: `go test -run TestClaudeProvider_ParityWithDirectSupervisor ./internal/provider/claude/...`. Verified by `go test` output.
- [ ] `claude.translateOutcome` correctly maps `supervisor.AgentResult.NullRun=true` → `provider.OutcomeNullRun`. Verified by a unit test row.
- [ ] `claude.translateOutcome` correctly maps `supervisor.AgentResult.ErrorCategory="UPSTREAM"` → `provider.OutcomeUpstreamError`. Verified by a unit test row.
- [ ] `claude.Provider.RunAgent` emits `EventTurnStart`, `EventTurnEnd`, and `EventRunEnd` to `req.EventChan` when set. Verified by a streaming test that records events from a fixture invocation.
- [ ] Zero stage code is modified by m01. Verified by `git diff HEAD~ internal/stages/` returning empty.
- [ ] `internal/supervisor/` is NOT modified by m01. Verified by `git diff HEAD~ internal/supervisor/` returning empty.
- [ ] `docs/v5-provider-seam.md` exists and documents (a) the Provider interface contract, (b) the Outcome mapping table, (c) the Event contract, (d) the translation pattern, (e) the m01 non-goals. Verified by `grep -nE '^## ' docs/v5-provider-seam.md` returning at least five section headings.
- [ ] No regression in: existing `internal/supervisor/` tests, all stage tests (`internal/stages/*/*_test.go`), `cmd/tekhton/...` tests.
- [ ] `shellcheck` clean — no shell files added by this milestone.
- [ ] `golangci-lint run ./internal/provider/...` and `go vet ./internal/provider/...` clean.
- [ ] Full suite passes: `bash tests/run_tests.sh` + `go test ./...`.

## Watch For

- **Do NOT modify `internal/supervisor/`.** m01 is purely additive. The
  supervisor is the reference behavior; m02 migrates stages off it.
  Even an "obvious" refactor like renaming a supervisor method breaks
  the m02 parity-test safety net. If a supervisor change feels
  unavoidable, open a Drift Observation and continue without making it.
- **The `provider.Result` field set is the contract for m02-m08.** Adding
  a field later means stages have to handle the field absence in older
  providers. Get the field set right in m01. Specifically check: is
  there a per-cycle turn budget recalibration signal stages need? (The
  m37.2 reviewer used `BumpFromUsage` based on supervisor-side turn
  data — make sure that data is in `Result`.)
- **`RawProviderData` is the escape hatch.** Anything Claude-specific
  the supervisor reports that doesn't fit the cross-provider shape
  goes into this opaque byte buffer. Don't try to model every Claude
  field in the typed struct — the typed fields are the cross-provider
  shape; everything else is in `RawProviderData` for postmortem.
- **The fixture format for parity tests should be the recorded
  supervisor exchange**, not raw Claude CLI output. The parity test
  asserts the WRAPPER behavior (translation in/out), not the
  underlying CLI behavior. Mock the supervisor; let the supervisor's
  own tests prove it talks to Claude correctly.
- **`OutcomeUnknown` is the safety net for unmapped categories.** When
  the supervisor produces something the Outcome mapping doesn't
  recognize, return `OutcomeUnknown` rather than guessing. Stages
  treat `OutcomeUnknown` as a failure that warrants investigation,
  not as "probably success." Operator-facing telemetry should track
  the rate of `OutcomeUnknown` per provider.
- **The Event channel is single-direction.** Provider writes, consumer
  reads. The provider closes the channel when the run ends. Consumers
  MUST handle a closed channel (use `for ev := range ch { ... }`).
  Document this in the Event type's doc comment.
- **Don't expose `provider.Request.ProviderSpecific` to stage code yet.**
  The map exists for m04+ when per-provider tool schemas land. For m01
  the field is nil-able and unused. Stages don't populate it.
- **The Claude provider's `New()` factory uses `supervisor.New()` —
  the default constructor.** Don't accept a custom supervisor in
  `New()` for m01; that's m02 scope when stages need to inject test
  supervisors for parity tests. Keep m01's surface minimal.

## Seeds Forward

- **m02 — Stage callers consume Provider.** Every stage's
  `invokeXxxAgent` function changes signature to accept a
  `provider.Provider` instead of a `*supervisor.Supervisor`. After
  m02 the supervisor package can be moved to `internal/provider/claude/internal/supervisor/`
  (or stay where it is, but be unused except by the Claude provider).
- **m04 — ToolSchema.** Right now `provider.Request.Tools` is typed as
  `[]ToolSchema` but `ToolSchema` is a placeholder (probably an empty
  struct for m01). m04 defines it properly and adds the Claude
  translator. The placeholder shape lets m01 ship without prejudicing
  m04's design.
- **m05-m08 — Codex provider.** Implements `provider.Provider`
  against the Codex CLI. The translation in/out follows the same
  pattern as Claude. The parity test runs against Codex's six
  fixtures (re-captured from Codex CLI runs).
- **Provider routing (m09 candidate):** Once two providers exist,
  `pipeline.conf` learns a per-stage `PROVIDER=` config. The runner
  consults it to pick the right `Provider` instance. Fallback chains
  (`PROVIDER=claude,codex,qwen`) let the pipeline retry on a
  different provider if the first one returns `OutcomeUpstreamError`.
- **Cost tracking (m11+ candidate):** Each provider returns
  per-invocation token counts in `RawProviderData`. A future
  `internal/cost/` package extracts and accumulates per-run cost
  attribution. Out of m01 scope; the seam supports it.
- **Local Qwen (m15+ candidate):** Implements `provider.Provider`
  against llama.cpp / vLLM / ollama. Requires the agent-loop
  abstraction (since local LLMs don't own the loop) — likely splits
  the interface to add a `Complete(prompt)` method that local
  providers implement, with `RunAgent` being a default loop on top.
  Out of MVP scope; lands after the Codex path is proven.
