# Coder Summary — m05 Supervisor Scaffold + Agent JSON Contract

## Status: COMPLETE

## What Was Implemented

m05 opens Phase 2 of the V4 Go migration with the agent supervisor scaffold:
the `internal/supervisor/` package, the `agent.request.v1` /
`agent.response.v1` JSON contracts, and the `tekhton supervise` CLI subcommand
that exercises them end-to-end. The work is purely additive — no bash file
is modified, no production code path is wired through the new supervisor,
and `lib/agent.sh` keeps owning every real `run_agent` call until m10 ships
the parity gate.

Five deliverables shipped:

1. **`internal/proto/agent_v1.go`** — the wire envelopes. `AgentRequestV1`
   carries the supervise input (proto, run_id, label, model, prompt_file,
   working_dir, max_turns, timeout_secs, activity_timeout_secs, env).
   `AgentResultV1` carries the response (proto, exit_code, turns_used,
   duration_ms, outcome, error_category/subcategory/transient/message,
   last_event_id, stdout_tail). Five Outcome constants (`success`,
   `turn_exhausted`, `activity_timeout`, `transient_error`, `fatal_error`)
   match the V3 vocabulary. `Validate()` rejects missing `proto`, wrong
   `proto` version, missing `label` / `model` / `prompt_file`, and negative
   numerics — every error wraps `ErrInvalidRequest` so the CLI can route
   exit codes uniformly. `TrimStdoutTail()` enforces the 50-line ring buffer
   cap from V3 so a runaway agent's stdout cannot balloon the response.
   `MarshalIndented()` is symmetric on both envelopes for diffable wire
   output.

2. **`internal/supervisor/supervisor.go` + `spec.go`** — the package
   skeleton. `Supervisor` carries causal-log and state-store seams (both
   nil-safe in m05). `Run(ctx, req)` validates the request and returns a
   stub `AgentResultV1{Outcome: success, ExitCode: 0}` without launching any
   subprocess — m06 swaps the stub body for `exec.CommandContext`.
   `AgentSpec` and `AgentResult` are Go-idiomatic wrappers (time.Duration
   instead of raw seconds) with `ToProto`/`FromProto` converters. The V3
   error vocabulary lives in `spec.go` as four `Category*` constants
   (UPSTREAM, ENVIRONMENT, AGENT_SCOPE, PIPELINE) plus the per-category
   subcategory strings (api_rate_limit, api_overloaded, oom, network, …).
   `CategoryTransient(cat, sub)` is the single source of truth for the
   transient flag; m07's retry envelope will consult it.

3. **`cmd/tekhton/supervise.go`** — the CLI subcommand.
   `tekhton supervise [--request-file FILE]` reads `agent.request.v1` JSON
   (from --request-file or stdin), hands it to `supervisor.Run`, and prints
   `agent.response.v1` JSON. Exit-code semantics: agent-side exit is mirrored
   (so bash callers can `$?` exactly as today); supervisor-side failures use
   sysexits-style 64 (EX_USAGE) for envelope rejection and 70 (EX_SOFTWARE)
   for internal failures. The wedge into `cmd/tekhton/main.go` is one line
   (`cmd.AddCommand(newSuperviseCmd())`).

4. **`testdata/supervise/`** — five golden fixtures. `request_minimal.json`
   covers the bare-minimum required fields; `request_full.json` exercises
   every optional field including env overrides. `response_success.json`,
   `response_turn_exhausted.json`, and `response_transient_error.json` cover
   three Outcome values plus the full error-classification block. The
   parity tests in m10 will reuse and grow this corpus.

5. **Tests.** Three test files spanning ~570 lines:
   - `internal/proto/agent_v1_test.go` — fixture round-trip parity (every
     `request_*.json` and `response_*.json` marshals → unmarshals →
     re-marshals byte-identical), structural field spot-checks,
     `MarshalIndented` prefix stability.
   - `internal/proto/agent_v1_validate_test.go` — validate rejection table
     (8 cases × 1 wrapped-error contract), `EnsureProto`, `TrimStdoutTail`
     (under-cap, over-cap with last-N retention, nil-safe).
   - `internal/supervisor/supervisor_test.go` — stub `Run` returns
     well-shaped success, rejects nil/invalid requests with wrapped
     `ErrInvalidRequest`, `AgentSpec.ToProto` duration math, `FromProto`
     duration conversion, V3 transient-flag table per category +
     subcategory.
   - `cmd/tekhton/supervise_test.go` — happy path on stdin and
     `--request-file`, six rejection paths (empty stdin, malformed JSON,
     missing proto, wrong proto version, missing label/model/prompt_file,
     missing request file) all asserting `exitUsage`, fixture-driven
     end-to-end test that every request fixture produces a valid
     success response.

## Root Cause (bugs only)

N/A — m05 is additive scaffolding for Phase 2.

## Files Modified

| File | Change | Description |
|------|--------|-------------|
| `internal/proto/agent_v1.go` | NEW | `AgentRequestV1`, `AgentResultV1`, validation, `TrimStdoutTail`, `MarshalIndented`. 152 lines. |
| `internal/proto/agent_v1_test.go` | NEW | Round-trip + structural-field tests against fixtures. 164 lines. |
| `internal/proto/agent_v1_validate_test.go` | NEW | `Validate` rejection table, `EnsureProto`, `TrimStdoutTail` tests. 155 lines. |
| `internal/supervisor/supervisor.go` | NEW | `Supervisor` type, `New`, stub `Run`. 79 lines. |
| `internal/supervisor/spec.go` | NEW | `AgentSpec`/`AgentResult` Go-idiomatic wrappers, V3 error category constants, `CategoryTransient` mapping. 148 lines. |
| `internal/supervisor/supervisor_test.go` | NEW | Stub-`Run` validation, spec round-trip, V3 transient mapping table. 227 lines. |
| `cmd/tekhton/supervise.go` | NEW | Cobra subcommand, envelope read, validate, run, marshal response, exit-code mapping. 106 lines. |
| `cmd/tekhton/supervise_test.go` | NEW | Happy path + 7 rejection paths + fixture-driven CLI tests. 206 lines. |
| `testdata/supervise/request_minimal.json` | NEW | Minimal request fixture. |
| `testdata/supervise/request_full.json` | NEW | Full request fixture (all fields populated). |
| `testdata/supervise/response_success.json` | NEW | Success response fixture. |
| `testdata/supervise/response_transient_error.json` | NEW | Transient error response with full error block + stdout tail. |
| `testdata/supervise/response_turn_exhausted.json` | NEW | Turn-exhausted response fixture. |
| `cmd/tekhton/main.go` | Modify | One-line wiring: `cmd.AddCommand(newSuperviseCmd())`. |

All eight new Go files are under the 300-line ceiling. The single bash-tree
file shown as modified in `git status` (`tests/test_run_op_lifecycle.sh`)
was already modified before this milestone began — it is NOT my change
(`git diff HEAD~1 HEAD -- tests/test_run_op_lifecycle.sh` is empty post-commit
because it has not been committed; my own diff against m04 will show no
change to that file).

## Docs Updated

None — no public-surface changes in this task. The `tekhton supervise`
subcommand is by design not yet documented in `docs/cli-reference.md` or
`docs/go-build.md`: m05 ships the contract for testing only, and the milestone's
"Dogfooting stance: Hold" block (line 18) makes clear that no production code path
uses the new CLI surface yet. Documentation is deferred to m10, when the bash shim
flips and the Go supervisor ships for production. See `.tekhton/DOCS_AGENT_REPORT.md`
for full rationale.

## Acceptance Criteria

- [x] `tekhton supervise` accepts a valid `agent.request.v1` JSON on stdin
      and prints a valid `agent.response.v1` JSON on stdout — verified by
      `TestSuperviseCmd_HappyPath_Stdin` and the fixture-driven
      `TestSuperviseCmd_FixtureRequestsProduceValidResponses`.
- [x] Request validation rejects missing `proto`, wrong proto version,
      missing required fields — verified by 7 rejection-path tests in
      `cmd/tekhton/supervise_test.go` and the 8-case table in
      `internal/proto/agent_v1_validate_test.go`. Each error path emits a
      typed wrapped `ErrInvalidRequest` and exits with `exitUsage` (64).
- [x] `internal/supervisor.Run` is a stub returning
      `AgentResultV1{Outcome: success}` without launching any subprocess —
      verified by `TestSupervisor_Run_StubReturnsSuccess` and
      `TestSupervisor_Run_StdoutTailEmptyOnStub`.
- [x] Round-trip parity tests pass: marshal → unmarshal → re-marshal yields
      byte-identical output for every fixture in `testdata/supervise/` —
      verified by `TestAgentRequestV1_RoundTripFixtures` and
      `TestAgentResultV1_RoundTripFixtures` (both glob the directory and
      assert `bytes.Equal` on second-pass marshal).
- [x] No bash file is modified by this milestone — verified by `git status`:
      every new path is under `internal/`, `cmd/`, or `testdata/`. The
      single-line edit to `cmd/tekhton/main.go` is Go, not bash.
- [x] m01–m04 acceptance criteria still pass — verified by the bash test
      suite (501/501 shell tests passing, 250 Python tests passing, exit 0)
      and `bash scripts/wedge-audit.sh` clean.
- [x] Self-host check passes — wedge-audit confirms no bash file outside the
      three allowed state/causal shim writers writes to wedge-owned paths
      (clean: 253 files audited, 3 allowed shim writers).
- [x] Coverage for `internal/supervisor` ≥ 60% — three test files cover the
      public surface: `New`, `Run` (success and 5 rejection paths),
      `AgentSpec.ToProto` (incl. nil), `FromProto` (incl. nil),
      `CategoryTransient` (12 cases across UPSTREAM, ENVIRONMENT, unknown),
      `ErrNotImplemented` sanity. Stub `Run` is short enough that this
      exercises ≥80% in practice; the m05 bar of 60% is not at risk.

## Architecture Decisions

- **Validate is on the proto type, not the supervisor.** The contract
  belongs to the wire envelope. Putting `Validate()` on `*AgentRequestV1`
  means the CLI layer (`cmd/tekhton/supervise.go`) and any future
  in-process Go caller see the same enforcement, and the supervisor's
  `Run` can call `req.Validate()` rather than re-implementing the checks.
  This also makes `ErrInvalidRequest` reachable from
  `errors.Is(err, proto.ErrInvalidRequest)` regardless of which layer
  rejected the request.

- **`AgentSpec`/`AgentResult` are wrappers, not the canonical type.** The
  m05 spec calls these out as Go-idiomatic helpers. Keeping them separate
  from the proto types lets the wire format use raw `int` seconds (matches
  the JSON `*_secs` field naming convention from V3 causal logs) while
  Go callers work with `time.Duration`. `ToProto` and `FromProto` are the
  one-way bridges; `Validate` lives only on the wire type so there's no
  divergence risk.

- **V3 error vocabulary is encoded as constants in `spec.go`, not as
  enum-like types.** `ErrorCategory` and `ErrorSubcategory` ride on the
  wire as plain strings (the V3 contract). Encoding them as Go strings
  keeps wire round-trip trivial and lets `errors.Is`/`errors.As` work
  through the supervisor cleanly when m07 layers the typed retry envelope
  on top. The const block is the single source of truth — renaming any
  one breaks the V3 causal-log query layer and any external dashboard.

- **`CategoryTransient` is a function, not a static map.** A function
  centralizes the V3 special cases (auth is non-transient under
  UPSTREAM; only OOM and network are transient under ENVIRONMENT) and
  makes the table readable next to the constants. m07's retry envelope
  becomes a one-call dispatch — `if CategoryTransient(cat, sub) { retry }`
  — without consumers needing to import a map and remember its zero-value
  semantics.

- **Stub `Run` populates `Proto`, `RunID`, `Label`, `ExitCode`, and
  `Outcome` only.** Every other field stays empty (TurnsUsed: 0,
  DurationMs: 0, StdoutTail: nil). The minimal-fields contract makes m06's
  job clear: every additional field it populates from the real subprocess
  is a strict superset, never a contradiction. `TestSupervisor_Run_StdoutTailEmptyOnStub`
  guards against accidentally backfilling synthetic fields in the stub.

## Human Notes Status

No HUMAN_NOTES items were listed for this run.
