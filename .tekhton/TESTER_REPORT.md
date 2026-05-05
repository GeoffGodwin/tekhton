## Planned Tests
- [x] `internal/proto/agent_v1_test.go` — Round-trip parity + structural field spot-checks for request and result fixtures
- [x] `internal/proto/agent_v1_validate_test.go` — Validate rejection table (8 cases), EnsureProto, TrimStdoutTail bounds
- [x] `internal/supervisor/supervisor_test.go` — Stub Run success/rejection, AgentSpec↔proto round-trip, CategoryTransient V3 mapping
- [x] `cmd/tekhton/supervise_test.go` — Happy path stdin/file, 7 rejection paths (exitUsage), fixture-driven CLI end-to-end

## Test Run Results
Passed: 501 (shell) + 250 (Python)  Failed: 0

Note: Go tests (`go test ./...`) require the Go 1.23 toolchain. Go is not
installed on the current machine (apt has 1.18, snap would need --classic
which requires sudo). Verification performed by code review — see below.

## Code Review Findings (Go tests, toolchain unavailable)

All four Go test files were reviewed against the implementation source and
fixtures. No defects found.

**`internal/proto/agent_v1_test.go`** (164 lines):
- `roundTripBytesIdentical` helper is correct: marshal→unmarshal→re-marshal
  byte-identical check works because Go's `encoding/json` is deterministic for
  the same struct.
- `TestAgentRequestV1_FixtureStructuralFields` assertions verified against
  `testdata/supervise/request_full.json` using Python cross-check: proto,
  label ("coder"), model ("claude-opus-4-7"), max_turns (60), timeout_secs
  (1800), activity_timeout_secs (600), env["TEKHTON_RUN_ID"] all match.
- `TestAgentResultV1_FixtureStructuralFields` verified against
  `response_transient_error.json`: proto, outcome ("transient_error"),
  error_category ("UPSTREAM"), error_transient (true), stdout_tail len (3)
  all match.
- `MarshalIndented` prefix test (`{\n  "proto":`) is correct given `proto` is
  the first declared field on `AgentResultV1` and `AgentRequestV1`.

**`internal/proto/agent_v1_validate_test.go`** (155 lines):
- 8-case rejection table covers every Validate() branch (missing proto, wrong
  proto, missing label, missing model, missing prompt_file, negative max_turns,
  negative timeout_secs, negative activity_timeout_secs). Each asserts
  `errors.Is(err, ErrInvalidRequest)` and error message substring.
- `EnsureProto` idempotency test (sets when empty, no-op when set) is correct.
- `TrimStdoutTail` three cases correct: under-cap no-op, over-cap retains last
  N lines (ring-buffer semantics verified), nil-safe.

**`internal/supervisor/supervisor_test.go`** (227 lines):
- Duration math: 30m→1800s and 10m→600s in `TestAgentSpec_ToProto` match
  `int(d / time.Second)` in `spec.go:42`.
- 65000ms→65s in `TestFromProto_DurationConversion` matches
  `time.Duration(p.DurationMs) * time.Millisecond` in `spec.go:76`.
- `CategoryTransient` table: UPSTREAM subcategories match `spec.go:132-141`
  (api_auth→false, all others→true); ENVIRONMENT (oom+network→true,
  disk_full+permissions→false) match `spec.go:139-144`; unknown category→false
  matches the `return false` default.
- `TestSupervisor_Run_StdoutTailEmptyOnStub` correctly guards the m05 contract
  that stub does not populate StdoutTail.

**`cmd/tekhton/supervise_test.go`** (206 lines):
- `runSupervise` helper correctly tests cobra command in-process without
  spawning a subprocess, using `cmd.SetIn`/`SetOut`/`SetErr`.
- `assertExitCode` uses `errors.As(err, &ec)` correctly: cobra's `Execute()`
  returns `RunE`'s error unwrapped, and `errExitCode` (defined in `state.go`)
  satisfies `errors.As` target matching.
- Empty-stdin path: `io.ReadAll(strings.NewReader(""))` returns `[]byte{}`
  with nil error, triggering the `len(data)==0` guard → exitUsage. ✓
- Missing-request-file path: `os.ReadFile("/nonexistent/...")` fails →
  `ErrInvalidRequest` wrap → exitUsage. ✓
- Fixture-driven CLI test globs all `request_*.json` files (both minimal and
  full); both have required fields so stub returns success for each. ✓

## Bugs Found
None

## Files Modified
- [x] `internal/proto/agent_v1_test.go`
- [x] `internal/proto/agent_v1_validate_test.go`
- [x] `internal/supervisor/supervisor_test.go`
- [x] `cmd/tekhton/supervise_test.go`
