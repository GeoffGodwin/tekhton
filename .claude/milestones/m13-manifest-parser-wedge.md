<!-- milestone-meta
id: "13"
status: "done"
-->

# m13 — Manifest Parser Wedge

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 4 — small, well-scoped wedge after m12. MANIFEST.cfg is the source of truth for milestone ordering, dependencies, and status. The bash parser (`lib/milestone_dag_io.sh::load_manifest`) is awk-heavy and shells to multiple helpers per call. Porting it isolates a small data-parsing surface ahead of m14's larger DAG state machine port. |
| **Gap** | `lib/milestone_dag_io.sh` (~200 LOC) reads/writes MANIFEST.cfg via awk + sed. Status updates (`dag_set_status`) are read-modify-write with no atomicity. Multiple bash callers (orchestrate, milestone_progress, draft_milestones) each parse the file independently. |
| **m13 fills** | (1) `internal/manifest` package owning MANIFEST.cfg parse + write. (2) `tekhton manifest list` / `tekhton manifest get <id>` / `tekhton manifest set-status <id> <status>` subcommands. (3) `internal/proto/manifest_v1.go` — but the on-disk format stays the legacy CSV-with-#comments shape (manifest is human-edited; flipping to JSON would break authoring). The proto here describes the parsed in-memory shape, not the disk shape. (4) Atomic writes (tmpfile + rename) for `set-status`. |
| **Depends on** | m12 |
| **Files changed** | `internal/manifest/` (new package), `internal/proto/manifest_v1.go` (new), `cmd/tekhton/manifest.go` (new), `lib/milestone_dag_io.sh` (shim rewrite), `scripts/manifest-parity-check.sh` (new) |
| **Stability after this milestone** | Stable. Only one external on-disk format (MANIFEST.cfg) and it's unchanged. All callers shimmed via the new CLI. |
| **Dogfooding stance** | Cutover within milestone. |

---

## Design

### Goal 1 — Manifest parser

```go
package manifest

type Entry struct {
    ID         string   // e.g. "12"
    Title      string
    Status     string   // todo | in_progress | done | skipped | split
    Depends    []string // upstream milestone IDs
    File       string   // .claude/milestones/m12-*.md
}

type Manifest struct {
    Entries []Entry
    Path    string
}

func Load(path string) (*Manifest, error)
func (m *Manifest) Save() error
func (m *Manifest) Get(id string) (*Entry, bool)
func (m *Manifest) SetStatus(id, status string) error
func (m *Manifest) Frontier() []*Entry  // milestones whose deps are all done
```

### Goal 2 — On-disk format unchanged

MANIFEST.cfg is human-edited (`tekhton --draft-milestones` appends rows;
operators occasionally tweak status by hand). Flipping it to JSON would
break that workflow. The Go reader/writer preserves:

- Comment lines (`#`) and blank lines round-trip in their original positions.
- Field order: `id,title,status,depends,file` (legacy CSV shape).
- No quote semantics added — the bash parser doesn't quote, so the Go writer doesn't either; values are validated at parse time to reject delimiters in fields.

### Goal 3 — `set-status` atomicity

`dag_set_status` in bash is read-modify-write via two awk passes plus an
mv. The Go writer uses `tmpfile + os.Rename` for atomicity (matching the
m03 state-wedge pattern).

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/manifest/` | Create | Loader, writer, frontier helper. ~250-350 LOC. |
| `internal/proto/manifest_v1.go` | Create | In-memory shape. ~50 LOC. |
| `cmd/tekhton/manifest.go` | Create | `manifest list / get / set-status / frontier` subcommands. ~150 LOC. |
| `lib/milestone_dag_io.sh` | Modify | Shrink from ~200 LOC to ~50-line shim. |
| `lib/milestone_dag.sh` | Modify | Update callers to use the shim's new field names (no behavior change). |
| `scripts/manifest-parity-check.sh` | Create | Read/write/round-trip parity. ~120 LOC. |

---

## Acceptance Criteria

- [ ] `tekhton manifest list` produces output matching `lib/milestone_dag_io.sh::load_manifest`'s prior format (verified by parity script against a fixture set).
- [ ] `tekhton manifest set-status 12 done` updates the file atomically (concurrent reads see either the pre- or post-state, never partial).
- [ ] Comment lines and blank lines round-trip unchanged through `Load → Save`.
- [ ] `lib/milestone_dag_io.sh` is ≤ 60 lines.
- [ ] `internal/manifest` coverage ≥ 80%.
- [ ] `scripts/manifest-parity-check.sh` exits 0 against a 6-fixture matrix (happy path, mixed statuses, dependency chain, split markers, comment preservation, partial-write recovery).
- [ ] `bash tests/run_tests.sh` passes; manifest-related tests (`test_validate_config*.sh`) adapted.

## Watch For

- **MANIFEST.cfg is human-authored.** Don't reformat. Comment placement, blank lines, and field spacing all matter. The parity script's "comment preservation" case is the canonical fixture.
- **Don't change the on-disk format.** A future v2 manifest could be JSON, but that's a separate decision and not for m13.
- **`split` status is a recent (m111) addition.** Round-trip it correctly; `tests/test_milestone_split_dag.sh` is the existing coverage.

## Seeds Forward

- **m14 — milestone DAG wedge:** `internal/manifest.Frontier` becomes the input to `internal/dag.State`. m14 ports the state machine that consumes manifest entries.
- **`tekhton --draft-milestones` (Phase 5):** the eventual port of `lib/draft_milestones.sh` will use `manifest.Append` rather than the current bash file-mangling.
