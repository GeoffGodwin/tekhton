<!-- milestone-meta
id: "12"
status: "done"
-->

# m12 — Orchestrate Loop Wedge

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 4 — first wedge after the m11 decision picked Path A. `lib/orchestrate.sh` is the next-largest bash subsystem and the natural successor to the supervisor: the orchestration loop drives the supervisor, so porting it captures the in-process advantage Phase 4 was designed to unlock. |
| **Gap** | After m10 the bash orchestrator (`lib/orchestrate.sh` + 7 helpers, ~1869 LOC) shells out to `lib/agent.sh` which shells out to `tekhton supervise`. Two subprocess hops per agent invocation. The `_RWR_*` and `LAST_AGENT_*` globals exist solely as a contract between the bash orchestrator and the bash agent shim — they round-trip through env vars. |
| **m12 fills** | (1) `internal/orchestrate` package owning the outer pipeline loop (`run_pipeline_attempt`, `_save_orchestration_state`, recovery dispatch). Calls `internal/supervisor.Retry` directly. (2) `tekhton orchestrate run-attempt` subcommand exposes the loop for bash callers; `lib/orchestrate.sh` shrinks to a ~50-line shim. (3) `internal/proto/orchestrate_v1.go` defines `attempt.request.v1` / `attempt.result.v1`. (4) `_RWR_*` globals delete in this milestone — orchestrate now owns the supervisor result without round-tripping through bash. |
| **Depends on** | m10, m11 |
| **Files changed** | `internal/orchestrate/` (new package), `internal/proto/orchestrate_v1.go` (new), `cmd/tekhton/orchestrate.go` (new), `lib/orchestrate.sh` (shim rewrite), `lib/orchestrate_helpers.sh` / `lib/orchestrate_loop.sh` / `lib/orchestrate_state_save.sh` / `lib/orchestrate_recovery*.sh` (delete or shrink), `lib/agent.sh` (delete `_RWR_*` exports), `scripts/orchestrate-parity-check.sh` (new), `tests/test_*.sh` (adapt) |
| **Stability after this milestone** | Stable. Bash orchestrator shrinks dramatically; the public `tekhton.sh --task` invocation still works. Phase 4 begins. |
| **Dogfooding stance** | Cutover happens in this milestone (not split across two). The parity gate is the safety net. |

---

## Design

### Goal 1 — `internal/orchestrate` package

Public API (mirrors what `lib/orchestrate.sh` exposes today):

```go
package orchestrate

type Loop struct {
    state    *state.Store
    causal   *causal.Log
    sup      *supervisor.Supervisor
    cfg      Config
}

func New(state *state.Store, causal *causal.Log, cfg Config) *Loop
func (l *Loop) RunAttempt(ctx context.Context, req *proto.AttemptRequestV1) (*proto.AttemptResultV1, error)
func (l *Loop) Resume(ctx context.Context) (*proto.AttemptResultV1, error)
```

The recovery dispatch (`_dispatch_recovery_class` in
`lib/orchestrate_recovery.sh`) maps the supervisor's classified error
(transient / quota / fatal / activity_timeout) to a continuation policy.
That logic moves into `internal/orchestrate/recovery.go` and consults
`internal/supervisor.AgentError` via `errors.Is` rather than bash regex.

### Goal 2 — Subprocess→in-process collapse

`lib/agent.sh` today builds a request envelope, shells to `tekhton
supervise`, parses the response, exports `_RWR_*` globals. That whole
trip is internal to the Go side after this milestone. The bash shim
becomes a `tekhton orchestrate run-attempt` invocation that takes the
already-rendered task / milestone context and returns a single
`attempt.result.v1` envelope.

### Goal 3 — Wedge audit pattern additions

`scripts/wedge-audit.sh` adds:

- `^[[:space:]]*export[[:space:]]+_RWR_` — regression guard against
  re-introducing the round-trip globals.
- `tekhton[[:space:]]+supervise` outside the new shim — direct supervisor
  calls from bash bypass orchestrate's recovery dispatch.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/orchestrate/` | Create | New package: loop, recovery, state-save. ~600-800 LOC. |
| `internal/proto/orchestrate_v1.go` | Create | `attempt.request.v1` / `attempt.result.v1` envelopes. |
| `cmd/tekhton/orchestrate.go` | Create | `tekhton orchestrate run-attempt` / `resume` subcommands. |
| `lib/orchestrate.sh` | Modify | Rewrite as ~50-line shim. |
| `lib/orchestrate_helpers.sh` / `_loop.sh` / `_state_save.sh` / `_recovery*.sh` | Delete | Logic moves to Go. |
| `lib/agent.sh` | Modify | Drop `_RWR_*` exports; orchestrate consumes the supervisor result directly. |
| `lib/agent_shim.sh` | Modify | Drop `_RWR_*` shaping. |
| `scripts/orchestrate-parity-check.sh` | Create | Parity gate (~10 scenarios). |
| `scripts/wedge-audit.sh` | Modify | Add Phase 4 PATTERNS. |

---

## Acceptance Criteria

- [ ] `tekhton orchestrate run-attempt --request-file foo.json` produces an `attempt.result.v1` envelope identical in shape (modulo timestamps) to the V3 bash orchestrator's `RUN_SUMMARY.json` for the same fixture.
- [ ] `lib/orchestrate.sh` is ≤ 60 lines and contains no recovery logic.
- [ ] `git ls-files lib/orchestrate_helpers.sh lib/orchestrate_loop.sh lib/orchestrate_state_save.sh lib/orchestrate_recovery*.sh` returns no files.
- [ ] `grep -rn '_RWR_' lib/ stages/` returns no matches.
- [ ] `scripts/orchestrate-parity-check.sh` exits 0 against a 10-scenario matrix (happy path, transient retry, quota pause, fatal error, activity timeout, SIGINT mid-attempt, recovery-classified failure, milestone advance, resume from interrupted state, multi-attempt converge).
- [ ] `internal/orchestrate` coverage ≥ 80% (matches Phase 1/2 bar).
- [ ] `bash tests/run_tests.sh` passes; existing orchestrate-related tests adapted to drive the Go path.
- [ ] `scripts/self-host-check.sh` passes on `linux/amd64`, `darwin/amd64`, `windows/amd64`.
- [ ] `docs/go-migration.md` Phase 4 section opened (minimal — full retro lands when Phase 4 closes).

## Watch For

- **Recovery dispatch is the highest-risk piece.** The bash version (`_dispatch_recovery_class`) routes 6+ failure classes to different continuation policies. Each class gets a Go-side test fixture before cutover.
- **Don't roll the milestone DAG in here.** m12 ports the loop only. The DAG (`lib/milestone_dag.sh`) is m14. Sequencing matters: the loop needs the DAG to advance milestones, but for m12 the DAG stays as bash-shimmed state read by orchestrate.
- **`_RWR_*` deletion is final.** No deprecation period — the m11 decision picked Path A precisely because Phase 1+2 evidence supports clean cutover per wedge.
- **Stage-level integration stays in bash.** Stages (`stages/coder.sh`, `stages/review.sh`, etc.) still drive their own logic. m12 only ports the loop that calls stages, not the stages themselves.

## Seeds Forward

- **m13 — manifest wedge:** `lib/milestone_dag.sh` reads MANIFEST.cfg; m13 ports MANIFEST.cfg parsing into Go so orchestrate can advance milestones in-process.
- **m14 — milestone DAG wedge:** the DAG state machine + frontier computation. Depends on m13.
- **m17 — error taxonomy:** consolidates the recovery-dispatch error classes (introduced in m12) into `internal/errors` for cross-package use.
- **V5 multi-provider plug-point:** `internal/orchestrate.Loop` becomes the natural place to wire provider-aware policies. Out of scope for m12.
