<!-- milestone-meta
id: "3"
status: "todo"
-->

# m03 — Pipeline State Wedge

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Second Phase 1 leaf wedge. Pipeline state is resume-critical: every interrupted run must come back cleanly. Landing it after m02 lets it inherit the proven wedge pattern (Go writer, bash shim, JSON proto envelope) instead of being the one to discover its edge cases. |
| **Gap** | `lib/state.sh` writes a markdown-with-headings file via heredoc (with quote-stripping workarounds for shell escaping at line 39–42) and reads it back with `awk` regexes (`orchestrate.sh:99-101`). Field addition is a heredoc + awk-rule edit; resume on header drift silently truncates. WSL/NTFS redirection requires a specific dance at line 57. |
| **m03 fills** | `internal/state/` owns a `Snapshot` struct serialized to JSON (`state.snapshot.v1`). `os.Rename` provides POSIX atomicity. Resume becomes `json.Unmarshal`. The bash heredoc + awk parser is replaced. A one-milestone legacy reader handles transition from V3 markdown state files. |
| **Depends on** | m02 |
| **Files changed** | `internal/state/snapshot.go`, `internal/state/snapshot_test.go`, `internal/state/legacy_reader.go`, `internal/proto/state_v1.go`, `cmd/tekhton/state.go`, `lib/state.sh` (shim), `testdata/state/` |
| **Stability after this milestone** | Stable. Resume from any V3-era state file works (legacy reader handles markdown), resume from any post-m03 state file works (JSON), and the cutover is a single shim swap on the writer side. |
| **Dogfooding stance** | Land in working copy after the resume-from-legacy parity test (AC #6) and the SIGINT-resume integration test (AC #7) both pass. The legacy markdown reader stays in place for one milestone cycle (m04 → m05) before being removed in m05; this gives any in-flight V3 state files a clean migration window. |

---

## Design

### JSON contract

`internal/proto/state_v1.go`:

```go
type StateSnapshotV1 struct {
    Proto             string            `json:"proto"`              // "tekhton.state.v1"
    RunID             string            `json:"run_id"`
    StartedAt         string            `json:"started_at"`         // RFC3339Nano
    UpdatedAt         string            `json:"updated_at"`
    Mode              string            `json:"mode"`               // "human" | "milestone" | "express" | …
    ResumeTask        string            `json:"resume_task,omitempty"`
    ExitStage         string            `json:"exit_stage,omitempty"`
    ExitReason        string            `json:"exit_reason,omitempty"`
    LastEventID       string            `json:"last_event_id,omitempty"`
    MilestoneID       string            `json:"milestone_id,omitempty"`
    ReviewCycle       int               `json:"review_cycle,omitempty"`
    PipelineAttempt   int               `json:"pipeline_attempt,omitempty"`
    AgentCallsTotal   int               `json:"agent_calls_total,omitempty"`
    Errors            []ErrorRecordV1   `json:"errors,omitempty"`
    Extra             map[string]string `json:"extra,omitempty"`     // forward-compat
}
```

The field set is the union of every section the bash heredoc currently writes. `Extra` is the escape hatch for v1.x additive fields; v2 happens only if a field changes meaning.

### Package shape

`internal/state/snapshot.go`:

```go
type Store struct {
    path string
    mu   sync.Mutex
}

func New(path string) *Store
func (s *Store) Read() (*proto.StateSnapshotV1, error)
func (s *Store) Write(snap *proto.StateSnapshotV1) error    // tmpfile + os.Rename
func (s *Store) Update(fn func(*proto.StateSnapshotV1)) error  // read-modify-write under mutex
func (s *Store) Clear() error                                 // remove the file
```

`Write` writes to `path + ".tmp"`, `fsync`s, then `os.Rename` to the final path. `os.Rename` is atomic on POSIX; on Windows the wrapper falls back to `MoveFileEx` with `MOVEFILE_REPLACE_EXISTING`.

### Legacy reader

`internal/state/legacy_reader.go` parses the V3 markdown format using the same regex shapes the existing `awk` rules use. Triggered when `Read()` finds a file whose first non-blank line is `## ` rather than `{`. On a successful parse it logs a `STATE_LEGACY_MIGRATED` causal event (one per state file) and writes the JSON form back on the next `Update`. The legacy reader code is annotated `// REMOVE IN m05` so it doesn't survive the cycle.

### CLI surface

`cmd/tekhton/state.go`:

| Command | Replaces | Behavior |
|---------|----------|----------|
| `tekhton state read [--path P]` | `awk` blocks in orchestrate.sh | Print one JSON object on stdout. Exit 1 if no state file. Exit 2 if file is corrupt (caller should not retry). |
| `tekhton state write [--path P]` | `_write_pipeline_state` heredoc | Read JSON from stdin, atomic-write to path. |
| `tekhton state update [--path P] --field K=V …` | various heredoc edits | Read-modify-write a single field set. |
| `tekhton state clear [--path P]` | `clear_pipeline_state` | Remove the file; no error if absent. |

`load_intake_tweaked_task` becomes `tekhton state read` piped to `jq -r .resume_task`. The bash side is a one-liner.

### Bash shim

`lib/state.sh` collapses to ~40 lines. The current 178-line file (heredoc writer, awk reader, quote-stripping, WSL dance) becomes:

```bash
write_pipeline_state() {
    local path="${1:-$PIPELINE_STATE_FILE}"; shift || true
    local args=()
    while [[ $# -gt 0 ]]; do
        args+=(--field "$1=$2"); shift 2
    done
    tekhton state update --path "$path" "${args[@]}"
}

read_pipeline_state_field() {
    local path="${1:-$PIPELINE_STATE_FILE}" field="$2"
    tekhton state read --path "$path" 2>/dev/null | jq -er ".${field} // empty"
}

clear_pipeline_state() {
    tekhton state clear --path "${1:-$PIPELINE_STATE_FILE}"
}

load_intake_tweaked_task() {
    read_pipeline_state_field "$PIPELINE_STATE_FILE" resume_task
}
```

WSL/NTFS quirks live inside `os.Rename`'s Windows fallback now; the bash dance is gone.

### Resume routing

`lib/orchestrate.sh` and `lib/state.sh` are the only callers that `awk`-parse state. After the shim swap, `_load_pipeline_state` becomes `read_pipeline_state_field` calls. The 14 `_ORCH_*` globals stay (they're refactored out in Phase 4); only the parse layer moves.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/state/snapshot.go` | Create | `Store` type, atomic write, JSON read. ~120 lines. |
| `internal/state/snapshot_test.go` | Create | Round-trip table tests, atomic-write crash sim (write fails mid-rename), concurrent-update test. |
| `internal/state/legacy_reader.go` | Create | V3 markdown parser, marked `// REMOVE IN m05`. ~80 lines. |
| `internal/proto/state_v1.go` | Create | `StateSnapshotV1` + `ErrorRecordV1`. |
| `cmd/tekhton/state.go` | Create | `read`/`write`/`update`/`clear` subcommands. |
| `lib/state.sh` | Modify | 178 → ~40 lines. Heredoc writer, awk reader, quote-stripping, WSL dance all deleted. |
| `testdata/state/` | Create | Golden V3 markdown state files (3 modes: human, milestone, express); golden JSON expected outputs. |

---

## Acceptance Criteria

- [ ] `tekhton state read` of a fresh JSON snapshot round-trips through `tekhton state write` byte-identical (modulo `updated_at` timestamp).
- [ ] `tekhton state read` of a V3 markdown state file parses successfully via the legacy reader and emits a `STATE_LEGACY_MIGRATED` causal event exactly once.
- [ ] `tekhton state update --field exit_stage=coder --field review_cycle=2` mutates only those two fields; all other fields preserved.
- [ ] `os.Rename`-based atomic write: simulated crash (kill mid-rename) leaves either the old file intact or the new file complete — never a truncated file. Test forces this with a wrapper that sleeps between write and rename.
- [ ] Concurrent `Update` calls serialize correctly (table test with 10 goroutines × 50 updates; final state matches the last applied update per field).
- [ ] **Resume parity (gating).** `scripts/state-resume-parity-check.sh` runs a fixture pipeline that gets SIGINT'd at three different stages (intake, coder, tester). Each is resumed twice — once via HEAD~1 bash reader, once via HEAD shim. All six resumes produce the same downstream stage output (CODER_SUMMARY.md, REVIEWER_REPORT.md, …) byte-identical.
- [ ] **SIGINT integration.** `scripts/test-sigint-resume.sh` interrupts a real run and resumes successfully without manual intervention. Runs in CI.
- [ ] `lib/state.sh` is ≤ 50 lines after this milestone (down from 178).
- [ ] `grep -rn "awk.*PIPELINE_STATE\|awk.*Exit Reason\|heredoc.*PIPELINE_STATE" lib/ stages/` returns nothing.
- [ ] Existing `tests/test_state*.sh` and `tests/test_resume*.sh` pass unchanged.
- [ ] Self-host check (m01) and causal log parity test (m02) still pass.
- [ ] Go test coverage for `internal/state` ≥ 80%.

## Watch For

- **The legacy reader is intentionally short-lived.** It exists for one milestone (m04 ships with it; m05 deletes it). Do not let it accrete features. Do not write JSON-to-markdown back-compat — the migration is one-way.
- **`updated_at` is the only field that should differ on round-trip.** If anything else drifts (field reordering, whitespace), the parity test will fail and the wedge is incorrect.
- **WSL/NTFS atomicity.** `os.Rename` on Windows requires `MOVEFILE_REPLACE_EXISTING`. The Go stdlib handles this since Go 1.5 but the test suite must include a Windows runner case (CI matrix from m01 covers this).
- **Heredoc quote-stripping at lib/state.sh:39-42 is a known quirk.** When deleting it, verify no caller now relies on the stripped form. Search for `resume_task=` assignments across all stages — there are 4 known sites.
- **`tekhton state read` returns exit code 1 vs 2 for "missing" vs "corrupt".** Bash callers must distinguish these — corruption should trigger `--diagnose`, not silent retry. Document in the shim.
- **Don't merge `Extra` into top-level fields.** That's the v1.x forward-compat hatch. If a future field deserves first-class status, bump to v2 and migrate, don't promote silently.

## Seeds Forward

- **m04 hardening:** fuzz test on `state.snapshot.v1` parser. m03 ships unit tests; m04 ships the fuzz harness against this same package.
- **m05 (Phase 2 entry):** removes the legacy markdown reader. m03 marks the relevant code with `// REMOVE IN m05` so the deletion is mechanical.
- **Phase 4 orchestration port:** when `lib/orchestrate.sh` moves to Go, it will use `internal/state.Store` directly. m03 keeps the API in-process-friendly so this isn't a re-port.
- **`tekhton status` (future):** renders the JSON state in a human-readable layout (the V3 markdown format, recreated client-side). m03 does not implement this — it's a Phase 4 nicety — but the JSON shape exists to support it.
