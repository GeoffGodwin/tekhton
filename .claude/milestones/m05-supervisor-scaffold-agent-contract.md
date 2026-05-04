<!-- milestone-meta
id: "5"
status: "todo"
-->

# m05 — Supervisor Scaffold + Agent JSON Contract

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Opens Phase 2 — the agent supervisor wedge. Per DESIGN_v4.md, the supervisor moves "as one entangled spine" because FIFO-monitor / retry / quota-pause / spinner interactions are too coupled to wedge piecewise. m05–m10 form one stability arc; this milestone establishes the package, the JSON contract, and the no-op `tekhton supervise` subcommand that later milestones flesh out. |
| **Gap** | No `internal/supervisor/` package exists. No agent request/response JSON contract is defined. The bash side (`lib/agent.sh`, `lib/agent_monitor.sh`, `lib/agent_retry.sh`, `lib/agent_monitor_helpers.sh`, `lib/agent_monitor_platform.sh`, `lib/agent_retry_pause.sh`) has no Go counterpart even in stub form. |
| **m05 fills** | (1) `internal/supervisor/` package skeleton with `Supervisor`, `AgentSpec`, `AgentResult` types. (2) `agent.request.v1` and `agent.response.v1` proto definitions. (3) `tekhton supervise --label … --model …` subcommand that accepts the request envelope on stdin, prints a stub response on stdout, and exits 0 (real execution lands in m06). (4) Round-trip parity tests for both protos against existing bash invocation patterns. |
| **Depends on** | m04 |
| **Files changed** | `internal/supervisor/supervisor.go`, `internal/supervisor/spec.go`, `internal/proto/agent_v1.go`, `cmd/tekhton/supervise.go`, `internal/supervisor/supervisor_test.go`, `testdata/supervise/` |
| **Stability after this milestone** | **Not stable for production until m10 lands.** The Go supervisor exists but is not on any production code path. `lib/agent.sh` is unchanged; the bash supervisor handles every real `run_agent` call until m10 cuts over. |
| **Dogfooding stance** | Hold. Do NOT swap any agent code path to the Go supervisor until m10. m05–m09 build the supervisor incrementally; mid-arc swaps would expose half-built behavior and risk silent regressions. The Go binary is invocable for testing only. |

---

## Design

### Phase 2 stability framing

This is a **single 6-milestone wedge** by design. The bash supervisor (`lib/agent_monitor.sh` and friends) keeps running production until m10's parity test passes; only then does `lib/agent.sh` flip to call `tekhton supervise`. Every milestone in m05–m09 is a building-block, not a release candidate. The user controls the swap moment after m10 ships.

### JSON contracts

`internal/proto/agent_v1.go`:

```go
type AgentRequestV1 struct {
    Proto        string            `json:"proto"`         // "tekhton.agent.request.v1"
    RunID        string            `json:"run_id"`
    Label        string            `json:"label"`         // "coder", "scout", "tester", …
    Model        string            `json:"model"`         // "claude-opus-4-7", "claude-sonnet-4-6", …
    MaxTurns     int               `json:"max_turns"`
    PromptFile   string            `json:"prompt_file"`   // path to rendered prompt
    WorkingDir   string            `json:"working_dir"`
    Timeout      int               `json:"timeout_secs"`
    ActivityTO   int               `json:"activity_timeout_secs"`
    EnvOverrides map[string]string `json:"env,omitempty"`
}

type AgentResultV1 struct {
    Proto             string   `json:"proto"`         // "tekhton.agent.response.v1"
    RunID             string   `json:"run_id"`
    Label             string   `json:"label"`
    ExitCode          int      `json:"exit_code"`
    TurnsUsed         int      `json:"turns_used"`
    DurationMs        int64    `json:"duration_ms"`
    Outcome           string   `json:"outcome"`        // "success" | "turn_exhausted" | "activity_timeout" | "transient_error" | "fatal_error"
    ErrorCategory     string   `json:"error_category,omitempty"`
    ErrorSubcategory  string   `json:"error_subcategory,omitempty"`
    ErrorTransient    bool     `json:"error_transient,omitempty"`
    ErrorMessage      string   `json:"error_message,omitempty"`
    LastEventID       string   `json:"last_event_id,omitempty"`
    StdoutTail        []string `json:"stdout_tail,omitempty"`  // ring buffer, ≤ 50 lines
}
```

The `Outcome` enum union and the error fields preserve the V3 `CATEGORY|SUBCATEGORY|TRANSIENT|MESSAGE` taxonomy (DESIGN_v4.md "Error Taxonomy") in structured form. `StdoutTail` replaces the file-based ring buffer that bash dumped at exit because subshell locals couldn't propagate.

### Package shape

`internal/supervisor/supervisor.go`:

```go
type Supervisor struct {
    causal *causal.Log
    state  *state.Store
    // m06+: subprocess fields, activity timer, signal handlers
}

func New(causal *causal.Log, state *state.Store) *Supervisor

// Run is the central entry point. m05 stub returns AgentResultV1{Outcome:"success", ExitCode:0}
// without launching a subprocess; m06 lands the real exec.CommandContext path.
func (s *Supervisor) Run(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error)
```

`AgentSpec` and `AgentResult` are thin Go-side wrappers around the proto types so call sites can use Go idiom (`time.Duration` vs `int seconds`).

### CLI surface

`cmd/tekhton/supervise.go`:

```
tekhton supervise [--request-file FILE]
```

If `--request-file` is omitted, reads JSON from stdin. Validates the envelope (`proto` field correct, required fields present). Calls `Supervisor.Run(ctx, req)`. Prints `AgentResultV1` JSON on stdout. Exit code mirrors the result's `ExitCode` field (so bash callers can branch on `$?` exactly as they do today).

In m05 the stub `Run` returns success immediately; the subcommand exists so the contract can be exercised end-to-end without launching `claude`.

### Bash side

**No bash files are modified in m05.** `lib/agent.sh` keeps calling `_invoke_and_monitor` from `lib/agent_monitor.sh`. The `tekhton supervise` subcommand is invocable manually for testing but no production code path uses it.

### Test surface

Three test files:

1. `internal/proto/agent_v1_test.go` — round-trip tests for both protos against fixture JSON.
2. `internal/supervisor/supervisor_test.go` — `Run` returns valid `AgentResultV1` for a valid request, validation errors for malformed requests.
3. `testdata/supervise/` — golden requests/responses that the parity tests in m10 will reuse.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/supervisor/supervisor.go` | Create | `Supervisor` type, `New`, `Run` (stub returning success). ~60 lines. |
| `internal/supervisor/spec.go` | Create | Go-side wrappers `AgentSpec`/`AgentResult` and conversion helpers to/from proto. |
| `internal/proto/agent_v1.go` | Create | `AgentRequestV1` + `AgentResultV1` + `Marshal`/`Unmarshal`. |
| `cmd/tekhton/supervise.go` | Create | Cobra subcommand wiring; envelope validation; stdin/stdout JSON. |
| `internal/supervisor/supervisor_test.go` | Create | Stub-`Run` validation tests. |
| `internal/proto/agent_v1_test.go` | Create | Round-trip parity tests. |
| `testdata/supervise/` | Create | Golden requests + responses for downstream parity. |

---

## Acceptance Criteria

- [ ] `tekhton supervise` accepts a valid `agent.request.v1` JSON on stdin and prints a valid `agent.response.v1` JSON on stdout.
- [ ] Request validation rejects: missing `proto` field, wrong `proto` version, missing required fields (`label`, `model`, `prompt_file`). Each error path emits a typed error and a non-zero exit.
- [ ] `internal/supervisor.Run` is a stub: returns `AgentResultV1{Outcome: "success"}` without launching any subprocess. (m06 replaces this with the real path.)
- [ ] Round-trip parity tests pass for `AgentRequestV1` and `AgentResultV1`: marshal → unmarshal → re-marshal yields byte-identical output for every fixture in `testdata/supervise/`.
- [ ] **No bash file is modified** by this milestone (`git diff --name-only HEAD~1 HEAD` shows only files under `internal/`, `cmd/`, `testdata/`).
- [ ] m01–m04 acceptance criteria still pass.
- [ ] Self-host check passes (Go binary present, bash supervisor still owns every `run_agent` call).
- [ ] Coverage for `internal/supervisor` ≥ 60% (lower bar than m04's packages because `Run` is a stub; the bar moves to 80% in m10).

## Watch For

- **The supervisor stub MUST NOT be wired into `lib/agent.sh`.** Doing so at m05 would mean every agent call returns instant-success — a catastrophic regression. The shim flip is m10's responsibility, gated by the parity suite.
- **Proto field names are the contract.** Once published, renames are breaking. Use snake_case in JSON (matches V3 causal log convention) and Go idiom in struct fields.
- **`StdoutTail` is bounded.** Cap at 50 lines (matches V3 bash ring buffer). Don't let it accidentally grow — a runaway agent with megabytes of stdout would balloon the response otherwise.
- **`EnvOverrides` is a sharp tool.** Keep the allowed keys list narrow at the supervisor side. The bash invocation passes a curated env subset; preserve that hygiene in Go.
- **Error taxonomy parity.** `ErrorCategory` / `ErrorSubcategory` strings must match the V3 vocabulary exactly (UPSTREAM, INTERNAL, ENV, …). The mapping table lives in `internal/supervisor/spec.go` and is the single source of truth post-m10.
- **`tekhton supervise` exit code semantics.** Bash callers branch on `$?`. The CLI exit must mirror `result.ExitCode` faithfully — if the supervisor itself fails to run (validation, internal panic), use exit code 64 (sysexits.h `EX_USAGE`) or 70 (`EX_SOFTWARE`) to distinguish from agent-side failure.

## Seeds Forward

- **m06 supervisor core:** replaces the stub `Run` with the real `exec.CommandContext` path. The proto contract from m05 remains stable; m06 only fills the implementation.
- **m07 retry envelope:** wraps `Run` in a `Retry` helper that reads `ErrorCategory`/`ErrorSubcategory`/`ErrorTransient` from the result and dispatches typed errors. m05's typed error fields make this clean.
- **m10 parity & cutover:** the test fixtures in `testdata/supervise/` grow throughout Phase 2 and become the parity gate that m10 must pass before the bash shim flip.
- **`tekhton supervise` is the agent invocation seam.** Every Phase 4 stage that ports will go through it. The CLI surface must stay narrow — no per-stage flags on `supervise` itself; stage-specific concerns live in the request envelope.
- **Coverage bar moves with the wedge.** 60% in m05 (mostly stubs), rising as m06–m09 add real code, locked at 80% by m10.
