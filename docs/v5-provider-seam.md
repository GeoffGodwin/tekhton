# V5 Provider Seam Contract

> **Audience:** Implementers of m02–m08 (stage migration, Codex provider,
> Qwen provider). Read this before touching any `internal/provider/` code.

---

## Provider Interface Contract

```go
type Provider interface {
    Name() string
    RunAgent(ctx context.Context, req *Request) (*Result, error)
}
```

**Name** returns the provider's canonical identifier: `"claude"`, `"codex"`,
`"qwen-local"`. Used in routing decisions, telemetry tags, and operator
banners. It MUST be stable across process restarts — do not generate it
dynamically.

**RunAgent** blocks until the agent loop terminates. It MUST:
- Return a non-nil `*Result` on success (error nil).
- Return a non-nil `*Result` AND a non-nil error when a partial result is
  available alongside a failure (e.g., the supervisor produced a result but
  also returned an error).
- Return `(nil, error)` when no result is available (e.g., context cancelled
  before first turn).
- Close `req.EventChan` exactly once before returning, if `req.EventChan` is
  non-nil. Callers drain with `for ev := range ch { ... }`.
- Be safe to call concurrently from multiple goroutines (no shared mutable
  state in the receiver).

---

## Outcome Mapping Table

`Outcome` is the primary signal stages branch on. Every provider MUST map
its exit conditions to exactly one of these:

| Outcome | When to use |
|---------|-------------|
| `OutcomeSuccess` | Agent loop completed; work was produced. |
| `OutcomeUpstreamError` | Provider infrastructure failure: quota, network, 5xx. The retry envelope (m07) will retry. |
| `OutcomeTimeout` | Per-invocation wall-clock timeout fired before completion. |
| `OutcomeMaxTurns` | MaxTurns cap reached; agent did not self-terminate. |
| `OutcomeNullRun` | Agent exited but produced no meaningful work (zero turns, or exit≠0 within null-run threshold). The orchestrator splits or escalates. |
| `OutcomeAborted` | Context was cancelled by the caller. Not retried — the cancellation was intentional. |
| `OutcomeUnknown` | The provider produced an outcome that doesn't map to any of the above. Stages treat this as a failure warranting investigation. Telemetry MUST track the rate — a rising `OutcomeUnknown` rate means the mapping table is incomplete. |

**Do not return `OutcomeSuccess` for `OutcomeUnknown`.** The unknown case
exists precisely so silent misclassification doesn't hide failures.

---

## Event Contract

```go
type Event struct {
    Kind      EventKind
    Timestamp time.Time
    Turn      int               // 1-indexed; 0 if not turn-specific.
    Content   string
    Metadata  map[string]string
}
```

**Channel lifecycle:** The provider MUST close `req.EventChan` before
returning from `RunAgent`. Callers use `for ev := range ch { ... }` and
rely on the close to terminate. A provider that does not close the channel
will deadlock the caller.

**m01 minimum event set (Claude provider):**

| Event | When emitted | Turn field |
|-------|-------------|------------|
| `EventTurnStart` | Before the supervisor run begins | 1 |
| `EventTurnEnd` | After the supervisor run completes | Turns used |
| `EventRunEnd` | Immediately before channel close | 0 |

**m07+ full event set (Codex provider and beyond):**

Emit the full set including `EventAssistantChunk`, `EventToolCall`, and
`EventToolResult`. Consumers switch on `Kind` and ignore unknown values —
the m01 event set is forward-compatible.

**Unknown event kinds:** Consumers MUST NOT panic on an unknown `EventKind`.
Use a default case in the switch:

```go
switch ev.Kind {
case provider.EventTurnStart:
    // handle
default:
    // ignore — future provider emitted something new
}
```

---

## Translation Pattern

The Claude provider in `internal/provider/claude/` is the worked example.
Follow this pattern for every new provider:

### 1. Define an internal interface over the underlying runtime

```go
// supervisorRunner is the subset of *supervisor.Supervisor used by Provider.
// Defined as an interface so parity tests can inject a stub.
type supervisorRunner interface {
    Run(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error)
}
```

This keeps the provider testable without modifying the runtime package and
without requiring a real agent binary in CI.

### 2. Translate Request → runtime invocation

Write any inline content (e.g., the prompt string) to a temp file if the
underlying runtime requires a file path. Clean up with `defer`.

### 3. Translate runtime result → Result

```go
func translateResult(v1 *proto.AgentResultV1) *provider.Result {
    res := supervisor.FromProto(v1)
    raw, _ := json.Marshal(v1)    // capture for postmortem
    return &provider.Result{
        Outcome:         translateOutcome(res),
        TurnsUsed:       res.TurnsUsed,
        NullRun:         res.IsNullRun(),
        RawProviderData: raw,      // always populate — postmortem reads this
        // ... other fields
    }
}
```

`RawProviderData` MUST be populated. It is the escape hatch for
provider-specific diagnostics that don't fit the typed struct — postmortem
tooling reads it without needing to know the provider.

### 4. Parity test

Add six fixture scenarios covering every `Outcome` category. The supervisor
(or equivalent runtime) is stubbed — do NOT invoke the real agent binary in
parity tests. The six required scenarios are:

1. `trivial_success` → `OutcomeSuccess`
2. `multi_turn_with_tools` → `OutcomeSuccess`
3. `upstream_error` → `OutcomeUpstreamError`
4. `null_run` → `OutcomeNullRun`
5. `max_turns_exhausted` → `OutcomeMaxTurns`
6. `context_cancelled` → error returned, no Result

---

## m01 Non-Goals

These are explicitly out of scope for m01 and will be addressed in later
milestones:

- **No stage changes.** Stages still call `internal/supervisor/` directly.
  m02 migrates all stage callers to consume `provider.Provider`.
- **No supervisor refactor.** `internal/supervisor/` is unchanged. It becomes
  internal to the Claude provider package after m02.
- **No ToolSchema definition.** `provider.ToolSchema` is an empty struct
  placeholder. m04 defines the cross-provider tool-schema shape and adds the
  Claude translator.
- **No per-provider tool-format translation.** Follows from no ToolSchema.
- **No `ProviderSpecific` population.** The field exists for m04+ use. m01
  stages pass nil or empty maps.
- **No full streaming event set.** The Claude provider emits only
  `EventTurnStart`, `EventTurnEnd`, and `EventRunEnd`. The richer events
  (`EventAssistantChunk`, `EventToolCall`, `EventToolResult`) come in m07
  when the Codex provider adds streaming parity.
- **No provider routing config.** `pipeline.conf` per-stage `PROVIDER=` key
  lands in m09, after two providers exist.
- **No cost tracking.** A future `internal/cost/` package will extract token
  counts from `RawProviderData`. Out of m01 scope.
