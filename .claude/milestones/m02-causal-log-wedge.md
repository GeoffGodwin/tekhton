<!-- milestone-meta
id: "2"
status: "done"
-->

# m02 — Causal Log Wedge

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | First Phase 1 leaf wedge. The causal log is read by many callers, written by few — exactly the shape that minimizes seam blast radius for the first real bash↔Go boundary. Proving the wedge pattern here de-risks every wedge that follows. |
| **Gap** | `lib/causality.sh` and `lib/causality_query.sh` build structured event logs with grep/awk/sed and a 27-line `_json_escape` helper because bash has no JSON library. Per-stage monotonic counters live in files in `${_CAUSAL_SEQ_DIR}` because subshell-emitted IDs can't survive in memory. The whole thing is fragile and well-known to leak (DESIGN_v6.md §3 calls this out). |
| **m02 fills** | Move the writer side to `internal/causal/`. `lib/causality.sh` becomes a 5-line shim per function that exec's `tekhton causal emit …`. `CAUSAL_LOG.jsonl` is now produced exclusively by Go. The query layer (`causality_query.sh`) is unchanged — query and emit are independent so external tools (and the unported bash query layer) read the same JSONL. |
| **Depends on** | m01 |
| **Files changed** | `internal/causal/log.go`, `internal/causal/log_test.go`, `internal/causal/emit.go`, `internal/proto/causal_v1.go`, `cmd/tekhton/causal.go`, `lib/causality.sh` (shim), Makefile, `testdata/causal/` |
| **Stability after this milestone** | Stable. All `emit_event` call sites continue to work via the shim. The causal log file format is unchanged (asserted by golden-file diff in acceptance). |
| **Dogfooding stance** | Safe to swap into working copy after the parity test (AC #9) passes against a real self-hosted run. The user controls the swap moment by holding the bash supervisor unchanged elsewhere — only `lib/causality.sh` flips to the shim. |

---

## Design

### JSON contract

Define `causal.event.v1` in `internal/proto/causal_v1.go`:

```go
package proto

type CausalEventV1 struct {
    Proto      string            `json:"proto"`        // "tekhton.causal.v1"
    RunID      string            `json:"run_id"`
    EventID    string            `json:"event_id"`     // e.g. "coder-7"
    Stage      string            `json:"stage"`
    Type       string            `json:"type"`
    Detail     string            `json:"detail,omitempty"`
    CausedBy   []string          `json:"caused_by,omitempty"`
    Timestamp  string            `json:"ts"`           // RFC3339Nano
    Fields     map[string]string `json:"fields,omitempty"`
}
```

The `proto` envelope (DESIGN_v4.md "JSON Protocol Versioning") is the version handshake: bash shims that read the file with `jq` will keep working as long as the major doesn't change. New optional fields are additive within v1.

### Package shape

`internal/causal/log.go`:

```go
type Log struct {
    path    string
    writer  *bufio.Writer
    mu      sync.Mutex
    seq     map[string]*atomic.Int64   // per-stage counter
    cap     int                          // CAUSAL_LOG_MAX_EVENTS
    runID   string
}

func Open(path string, cap int, runID string) (*Log, error)
func (l *Log) Emit(stage, evType, detail string, causedBy []string, fields map[string]string) (eventID string, err error)
func (l *Log) Evict() error                 // in-place rewrite when count > cap
func (l *Log) Archive(target string) error  // rotate + retention enforcement
func (l *Log) Close() error
```

Per-stage counter is `*atomic.Int64` — replaces the file-based counter dance. Eviction is in-place rewrite under `l.mu`, fired when `events > cap`. The archive layer enforces `CAUSAL_LOG_RETENTION_RUNS` exactly as the bash version did.

### CLI surface

`cmd/tekhton/causal.go` wires three subcommands:

| Command | Replaces | Behavior |
|---------|----------|----------|
| `tekhton causal init [--path P] [--cap N] [--run-id R]` | `init_causal_log` | Truncate path, write a header line, return event ID `init-1`. |
| `tekhton causal emit --stage S --type T [--detail D] [--caused-by ID]... [--field K=V]...` | `emit_event` | Append one event to the log path (read from `${CAUSAL_LOG_FILE}` env). Print the assigned event ID on stdout. |
| `tekhton causal archive --retention N` | archive logic in `causality.sh` | Rotate + prune to `N` archived runs. |

Stdin is not used. Args are validated; missing required flags fail fast with a typed error.

### Bash shim

`lib/causality.sh` collapses to ~30 lines total:

```bash
emit_event() {
    local stage="$1" type="$2" detail="${3:-}"
    shift 3 || true
    local args=(--stage "$stage" --type "$type")
    [[ -n "$detail" ]] && args+=(--detail "$detail")
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --caused-by) args+=(--caused-by "$2"); shift 2 ;;
            --field)     args+=(--field "$2");     shift 2 ;;
            *)           shift ;;
        esac
    done
    tekhton causal emit "${args[@]}"
}

init_causal_log() {
    tekhton causal init --path "$CAUSAL_LOG_FILE" --cap "$CAUSAL_LOG_MAX_EVENTS" --run-id "$RUN_ID" >/dev/null
}
```

`_json_escape` is deleted entirely. `_LAST_EVENT_ID` and `_CAUSAL_EVENT_COUNT` cease to exist as on-disk caches (the Go process owns the counter in memory) but are exposed via a tiny `tekhton causal status` subcommand if any caller still reads them.

### Query layer

`lib/causality_query.sh` is unchanged. It reads `CAUSAL_LOG.jsonl` line-by-line with `jq`, which works whether the writer is bash or Go. This is the explicit contract: the on-disk format is the seam, not the writer.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/causal/log.go` | Create | `Log` type, `Open`/`Emit`/`Evict`/`Archive`/`Close`. ~150 lines. |
| `internal/causal/log_test.go` | Create | Table-driven unit tests for Emit, Evict (cap edge cases), Archive (retention). Concurrent-emit goroutine test for the per-stage counter. |
| `internal/causal/emit.go` | Create | Pure functions: `formatEventID(stage, n)`, JSONL line builder, RFC3339Nano timestamp. |
| `internal/proto/causal_v1.go` | Create | `CausalEventV1` struct + `Marshal`/`Unmarshal` helpers. |
| `cmd/tekhton/causal.go` | Create | Cobra subcommands: `init`, `emit`, `archive`, `status`. |
| `lib/causality.sh` | Modify | Shrunk to ~30 lines; all logic delegated to `tekhton causal …`. `_json_escape` deleted. |
| `Makefile` | Modify | `make test` now actually has tests to run. |
| `testdata/causal/` | Create | Golden files: known-input → expected JSONL line, used by both Go and bash parity tests. |

---

## Acceptance Criteria

- [ ] `tekhton causal init --path /tmp/c.jsonl --cap 100 --run-id r1` creates the file and assigns event ID `init-1`.
- [ ] `tekhton causal emit --stage coder --type started --detail "x"` appends one valid `causal.event.v1` line, prints `coder-1` on stdout, and increments the stage counter.
- [ ] Concurrent emits across stages assign monotonic per-stage IDs (verified by Go race-test running 10 goroutines × 100 emits and asserting no duplicate IDs per stage).
- [ ] Eviction fires when `count > cap`: log is rewritten in place, retains the last `cap` events, runs in `O(cap)` not `O(file)`.
- [ ] Archive rotation respects `CAUSAL_LOG_RETENTION_RUNS`; older archives deleted; current log truncated.
- [ ] `lib/causality.sh::_json_escape` is deleted; no other bash file calls it (`grep -r _json_escape lib/ stages/` returns nothing).
- [ ] All bash callers of `emit_event` work without modification — verified by running `bash tests/run_tests.sh` on a project that exercises every stage and asserting the same event count + types as the V3 baseline.
- [ ] `lib/causality_query.sh` is unchanged and reads the new log files correctly (existing `tests/test_causality_query.sh` passes).
- [ ] **Parity test (gating).** `scripts/causal-parity-check.sh` runs the same fixture pipeline twice — once with `lib/causality.sh` at HEAD~1 (bash writer), once at HEAD (Go writer) — and `diff`s the resulting `CAUSAL_LOG.jsonl` files. Differences allowed only on `ts` (timestamps) and the `proto` field; everything else byte-identical.
- [ ] Self-host check (m01) still passes.
- [ ] Go test coverage for `internal/causal` ≥ 80%.

## Watch For

- **Per-stage counter must be in-process.** The bash version used files because subshells lost in-memory state; the Go version owns the counter in `*Log` and `Emit` returns the ID synchronously. Do not regress to file-based counters.
- **Stage names are case-sensitive and free-form.** Don't normalize them; `coder` and `Coder` are different counters by design (this matches the bash behavior).
- **Causal log file path is read from `$CAUSAL_LOG_FILE`.** Don't hardcode `.tekhton/CAUSAL_LOG.jsonl` — the config var exists for a reason (test isolation, alternative TEKHTON_DIR layouts).
- **`tekhton causal emit` is on the hot path.** Each agent invocation emits 5–20 events. Optimize for fast startup (no heavy package init) — measure under `time` and ensure the per-call overhead is < 20ms vs the bash version's ~5ms per `_json_escape` round.
- **Don't change the JSONL format silently.** The contract is `causal.event.v1`. Bash query callers expect the same field names and types. New fields are additive only.
- **Archive concurrency.** If a `tekhton causal emit` and `tekhton causal archive` race, the emit must not lose data. Use file locking (`syscall.Flock`) or write-then-rename semantics on the archive side.

## Seeds Forward

- **m03 pipeline state:** uses the same wedge pattern (Go writer, bash shim) and the same `proto` envelope convention. m02 establishes the shim shape; m03 reuses it.
- **m05 supervisor:** will emit causal events from inside Go directly (no shim hop). The `internal/causal` package must export an in-process API, not just the CLI.
- **Causal query layer port (Phase 4):** `lib/causality_query.sh` stays bash through Phase 1–3. When it ports, it imports `internal/causal` directly and skips the JSONL parse hop. m02 keeps the import path stable so this is a re-link, not a rewrite.
- **Decision §2 (SQLite vs flat files):** the trigger is "causal-log query latency exceeds 500ms in a typical run." m02 should add a benchmark in `internal/causal/log_test.go` that measures append + read of 2000 events so the trigger is observable.
