<!-- milestone-meta
id: "30"
status: "done"
-->

# m30 — Crawler Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — port the crawler subsystem (`lib/crawler*.sh` + `lib/rescan*.sh`, 6 + 2 = 8 files, ~1,708 lines of bash) to `internal/crawler/`. The crawler is the project-introspection engine: it walks the project tree, classifies files, parses dependency manifests, samples high-value content, and emits the `.claude/index/` artifact set (`tree.txt`, `inventory.jsonl`, `dependencies.json`, `configs.json`, `tests.json`, `samples/manifest.json`, `meta.json`). Those artifacts are the load-bearing input to `init` (first-run project bootstrap) and `rescan` (incremental update). Until the crawler is Go, every `tekhton --init` and `tekhton --rescan` invocation hands control back to bash for a multi-second tree walk + manifest parse — exactly the shape of work Go would do faster and more correctly. Closing this milestone retires roughly 1.7k lines of bash and removes the largest remaining read-side bash subsystem in the codebase. |
| **Gap** | At m29 close (Detect Port), `internal/detect/` owns language inference, framework detection, and the `_extract_json_keys` helper that crawler currently consumes from bash. The crawler itself is still 1,708 lines of bash across 8 files: `lib/crawler.sh` (orchestration + tree walk), `lib/crawler_inventory.sh` (file inventory + config inventory), `lib/crawler_inventory_emitters.sh` (JSON/JSONL emitters for inventory/configs/tests), `lib/crawler_content.sh` (content sampling + binary-file detection + budget-aware truncation), `lib/crawler_deps.sh` (7 manifest parsers: npm/Cargo/pyproject/go.mod/Gemfile/Gradle/pom.xml), `lib/crawler_emit.sh` (dependency JSON emitter + meta JSON emitter), `lib/rescan.sh` (incremental orchestrator + significance classifier), `lib/rescan_helpers.sh` (git-diff change detection, metadata extraction, file-type predicates). The artifact JSON shape under `.claude/index/` is a load-bearing contract that init, scout, and downstream agents already consume — porting must preserve it byte-for-byte. |
| **m30 fills** | This is the **parent milestone** of a two-child arc, split per the m27 / m28 pattern. m30 captures the cross-cutting design (`internal/crawler/` package shape, `tekhton crawler <subcommand>` CLI surface, artifact-schema-stability contract, parity-gate strategy) and links the two children. m30.1 ports the crawler core (the 6 `crawler*.sh` files producing `.claude/index/` artifacts). m30.2 ports rescan (the 2 `rescan*.sh` files implementing the incremental update path), which depends on m30.1 because rescan reuses the inventory / content / deps engines. Each child is independently dogfood-able: the crawler is only invoked by `init` and `rescan`, never by the main `tekhton --milestone` flow, so a half-ported arc does not block the dogfood loop. `VERSION` bumps on m30.2 close, not on m30.1 (matches m27.3 pattern). |
| **Depends on** | m29 |
| **Files changed** | This parent milestone authors no production code. Child milestones touch `internal/crawler/`, `cmd/tekhton/crawler.go`, `lib/init.sh`, `tekhton-legacy.sh`, and the 8 deletions under `lib/crawler*.sh` and `lib/rescan*.sh`. See the per-child files for exact paths. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m22 | Preflight Port — established the "delete bash files outright, no transition shim" pattern for a self-contained read-side subsystem. m30 follows the same shape. |
| m27 | Three-way decimal split pattern (m27 / m27.1 / m27.2 / m27.3) where VERSION bumps only on the closing child. m30 inherits this. |
| m28 | Two-children-or-more parent-with-`status: "split"` pattern; the parent file remains in the repo until both children close, then the parent flips to `done`. |
| m29 | Detect Port — established `internal/detect/` and ported `_extract_json_keys`, `_DETECT_EXCLUDE_DIRS`, `assess_doc_quality`. m30 imports these as Go packages instead of consuming them via bash sourcing. |
| **m30** | **Crawler + rescan ported to `internal/crawler/`; eight `lib/crawler*.sh` and `lib/rescan*.sh` files delete; `.claude/index/` artifact schema preserved byte-identical.** |

---

## Design

### Sequencing note

m30 splits into m30.1 (crawler core) and m30.2 (rescan), in that order. The split is mandatory, not aesthetic: rescan reuses the inventory / content / deps engines that m30.1 ports. Landing rescan first would mean re-porting those engines a second time when m30.1 lands — or keeping a bash shim for the inventory call, which defeats the purpose. Reverse-order ports do not work here.

Within the arc, m30.1 is the larger lift (six files, 1,271 lines, seven manifest parsers, the JSON emitter chain). m30.2 is the smaller incremental layer (two files, 437 lines, primarily the git-diff change-detection logic and the significance classifier). Treating them as independent milestones keeps the per-milestone patch-bump churn bounded (m22's ~17 patch bumps over ~1500 LOC is the rate-of-burn benchmark).

### Goal 1 — `internal/crawler/` package shape

```
internal/crawler/
├── crawler.go            # Orchestrator: Crawl(ctx, project, budget) -> Result
├── inventory.go          # File inventory + config inventory + tests inventory
├── content.go            # Content sampling, binary detection, budget-aware truncation
├── deps.go               # Seven manifest parsers, dispatched by filename
├── emit.go               # JSON/JSONL emitters for the artifact set
├── tree.go               # Directory tree walker (replaces `tree`/find fallback)
├── annotations.go        # Package-purpose lookup table (replaces _annotate_package)
├── rescan.go             # Incremental rescan (lands in m30.2, scaffolded in m30.1)
├── significance.go       # Change classification (trivial/moderate/major) — m30.2
├── testdata/             # Fixture project trees for parity tests
└── *_test.go             # Unit + parity tests
```

The package exposes one high-level entry point per child:

```go
// m30.1
func Crawl(ctx context.Context, opts Options) (*Result, error)
// m30.2
func Rescan(ctx context.Context, opts RescanOptions) (*Result, error)
```

`Options` carries `ProjectDir`, `BudgetChars`, `IndexDir`, `Detector *detect.Detector` (for the m29-ported helpers — `_extract_json_keys`, `assess_doc_quality`). `Result` carries `IndexDir`, `FileCount`, `TotalLines`, `Manifests []Manifest`, `Errors []error`. The split between "writes to `.claude/index/`" (side effect) and "returns metadata" (pure) must be clean — the Go port separates the write step from the read/compute step explicitly. The bash version interleaves them.

### Goal 2 — `tekhton crawler <subcommand>` Cobra surface

Mirror the m22 + m23 pattern. `cmd/tekhton/crawler.go` registers:

```
tekhton crawler crawl   --project-dir <p> --budget <n> --json   # Full crawl (m30.1)
tekhton crawler rescan  --project-dir <p> --budget <n> --full   # Incremental (m30.2)
tekhton crawler inventory --project-dir <p> --json              # Just inventory.jsonl
tekhton crawler deps      --project-dir <p> --json              # Just dependencies.json
tekhton crawler content   --project-dir <p> --budget <n> --json # Just samples/
```

The `crawl` and `rescan` subcommands are the production entry points (called by `lib/init.sh` and `tekhton-legacy.sh` respectively, replacing the `crawl_project` and `rescan_project` bash function bodies). The `inventory`, `deps`, `content` subcommands are developer-facing introspection levers (Hidden = false, useful for "why did the crawler classify this file as binary?" debugging). All four take `--json` and emit the same artifact body that lands in `.claude/index/` to stdout when invoked with that flag — the file-write path and the stdout path share one emitter.

### Goal 3 — Artifact schema-stability contract

The `.claude/index/` artifact set is the load-bearing contract this arc must not break:

| Artifact | Schema source | Consumers |
|----------|---------------|-----------|
| `tree.txt` | Plain text, annotated dir listing | `index_view.sh`, human-readable PROJECT_INDEX.md |
| `inventory.jsonl` | One JSON object per file with `path`, `lines`, `size_category` | meta.json, view generator |
| `dependencies.json` | `{manifests: [...], key_dependencies: [...]}` | view generator, future Go consumers |
| `configs.json` | Array of `{file, purpose}` | view generator |
| `tests.json` | Test structure / counts | view generator |
| `samples/manifest.json` | `{samples: [{original, stored, chars}], total_chars, budget_chars}` | view generator, `_extract_sampled_files` |
| `samples/<file>.txt` | Truncated file content | view generator |
| `meta.json` | `{schema_version, project_name, scan_date, scan_commit, file_count, total_lines, tree_lines, doc_quality_score}` | rescan (`_extract_scan_metadata`), view generator |

Parity is asserted at *schema* level (every documented key present, types preserved) AND at *byte* level for fixed-input fixtures (after `scan_date` normalization). The schema check survives reorganization-of-internals churn; the byte check catches regressions in field-formatting (number precision, key ordering, trailing newlines). Both gates land in m30.1; m30.2 extends the byte gate to the incremental-update path.

### Goal 4 — Parity gate strategy

`tests/test_crawler_parity.sh` and `tests/test_rescan_parity.sh` each diff Go crawler output against a frozen bash baseline across three representative fixture projects under `internal/crawler/testdata/`:

1. **`small_repo/`** — a tiny Python project: 8 files, `pyproject.toml`, no submodules, no monorepo. Exercises the simple path: one manifest, flat tree, single-language detection.
2. **`monorepo/`** — `packages/foo/`, `packages/bar/`, `apps/baz/` with `package.json` in each. Exercises the monorepo sub-project loop in `crawler_deps.sh:44-61` (cap at 5).
3. **`with_submodules/`** — a project with a `.gitmodules` file pointing at two submodules, mixed languages (Rust + Go + Python). Exercises the git-aware file listing path and the manifest-dispatch across language families.

Baselines live at `internal/crawler/testdata/baselines/<fixture>/<artifact>.golden` and were captured by running the bash crawler against the fixture before the port. The parity test normalizes `scan_date`, `scan_commit` (replaced with `<commit>`), and any temp-file path embedded in the output, then `diff -u` against the baseline. Non-zero diff = fail.

### Goal 5 — The Detect-uses-Crawler dependency

m29 (Detect Port) ported three crawler-consumed bash helpers to Go:
1. `_DETECT_EXCLUDE_DIRS` → `detect.DefaultExcludeDirs()` slice.
2. `_extract_json_keys` → `detect.ExtractJSONKeys(path, keys...)`.
3. `assess_doc_quality` → `detect.AssessDocQuality(projectDir)`.

m30 imports `github.com/geoffgodwin/tekhton/internal/detect` and calls those functions directly. The bash equivalents (still present in `lib/detect*.sh` until m29 closes them out) MUST NOT be re-implemented inside `internal/crawler/`. Duplication is the trap.

**Verify the dependency on inspection.** During m30 implementation, grep `internal/crawler/` for any string matching `_DETECT_`, `_extract_json`, or `doc_quality` — every hit should be a call into the `detect` package, never a re-implementation. If m29's API surface is not yet sufficient (e.g. `ExtractJSONKeys` doesn't return version strings), file an issue against m29 and block on it rather than copying the bash logic into m30.

### Goal 6 — Children link

- **[m30.1 — Crawler Core](m30.1-crawler-core.md)** — ports `crawler.sh`, `crawler_inventory.sh`, `crawler_inventory_emitters.sh`, `crawler_content.sh`, `crawler_deps.sh`, `crawler_emit.sh` to `internal/crawler/{crawler,inventory,content,deps,emit,tree,annotations}.go`. Adds the `tekhton crawler crawl` / `inventory` / `deps` / `content` subcommands. Lands the parity gate for the full-crawl path. Six bash files delete. No VERSION bump.
- **[m30.2 — Rescan](m30.2-rescan.md)** — ports `rescan.sh` and `rescan_helpers.sh` to `internal/crawler/{rescan,significance}.go`. Adds the `tekhton crawler rescan` subcommand. Extends the parity gate to the incremental-update path; verifies skip-unchanged optimization preserves bash semantics. Two bash files delete. `VERSION` bumps to `4.30.0` on close.

See each child file for full design, acceptance criteria, and watch-fors.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `.claude/milestones/m30-crawler-port.md` | Create | This parent file; links the two children and captures cross-cutting design. |
| `.claude/milestones/m30.1-crawler-core.md` | Create | Child 1: core ports (6 bash files → `internal/crawler/`). |
| `.claude/milestones/m30.2-rescan.md` | Create | Child 2: rescan port (2 bash files → `internal/crawler/{rescan,significance}.go`). |
| `.claude/milestones/MANIFEST.cfg` | Modify | Three new rows: `m30|...|split|m29|...`, `m30.1|...|todo|m29|...`, `m30.2|...|todo|m30.1|...`. (Human-authored after sequential review, not in this milestone's deliverable.) |

The parent milestone authors no production code. All Go source, Cobra wiring, bash deletions, parity tests, and VERSION bump belong to the children.

---

## Acceptance Criteria

- [ ] `.claude/milestones/m30.1-crawler-core.md` exists and parses cleanly through `lib/milestone_dag.sh` (meta block at top, status `todo`, depends_on `m29`).
- [ ] `.claude/milestones/m30.2-rescan.md` exists and parses cleanly (meta block at top, status `todo`, depends_on `m30.1`).
- [ ] This parent file's meta block reads `status: "split"`.
- [ ] Both child files are linked from this parent's Design section (Goal 6 — Children link).
- [ ] m30.1 closes with `status: "done"` before m30.2 enters `in_progress`.
- [ ] m30.2 closes with `status: "done"`.
- [ ] On m30.2 close, this parent file's meta block flips from `status: "split"` to `status: "done"`.
- [ ] `VERSION` reads `4.30.0` on m30.2 close (m30.1 used a patch bump `4.29.N` only).
- [ ] `MANIFEST.cfg` has rows `m30|Crawler Port|done|m29|m30-crawler-port.md|phase5`, `m30.1|Crawler Core|done|m29|m30.1-crawler-core.md|`, `m30.2|Rescan|done|m30.1|m30.2-rescan.md|` at arc close.
- [ ] `find lib -name 'crawler*.sh' -o -name 'rescan*.sh'` returns zero matches at arc close.
- [ ] `bash tests/run_tests.sh` reports zero regressions vs. the m29-close baseline.
- [ ] Documentation updated where relevant (`docs/v4-phase5-stub.md` Hook-status table marks "Crawler" as "done (m30)", `CLAUDE.md` references the new `tekhton crawler` subcommand surface if currently mentions the bash crawler).

## Watch For

- **Artifact schema is the contract — not file paths.** Init, scout, and rescan consume `.claude/index/*.json` by *shape*. A field rename (`scan_commit` → `commit`), a numeric-format change (integer-as-string vs integer), or a key-ordering change in JSON output ripples into every downstream consumer. The parity gate's byte-level golden files exist specifically to catch this; do not relax the gate to "fields present" only.
- **Crawler reads the project tree; only writes `.claude/index/`.** The Go port must enforce this separation explicitly — no package under `internal/crawler/` may take a write handle to any path *outside* `${IndexDir}`. This is enforceable in tests (a fakeWriter that records every Write call and asserts the path prefix). The bash version trusts itself; the Go port should not.
- **`crawler_deps.sh` is heuristic-heavy. Preserve exact rule ordering.** The dependency inference uses regex matching with deliberate ordering (the simple `crate = "ver"` form is tested before the table `crate = { version = "x" }` form in Cargo parsing; `[dependencies]` vs `[dev-dependencies]` section detection happens before the bracket-end check). Porting this to Go is mechanical *if* the order is preserved exactly. Drift here surfaces as a dependency-list field with the wrong version string for some packages — silent and easy to miss without the parity gate.
- **Detect Port (m29) is a hard dependency, not a soft one.** If m29 ships an API surface that does not cover `_extract_json_keys`, `_DETECT_EXCLUDE_DIRS`, or `assess_doc_quality` (the three crawler call-outs), m30.1 blocks on m29 — do not work around it by re-implementing those helpers inside `internal/crawler/`. If m29 closes and the helpers are missing, that is an m29 drift, not an m30 problem.
- **Rescan's `detect_*` header docs are stale.** `lib/rescan.sh` claims dependencies on `detect_languages`, `detect_frameworks`, `detect_commands`, `format_detection_report` — `grep -nE 'detect_languages|detect_frameworks|detect_commands|format_detection_report' lib/rescan*.sh` returns zero call-site matches. The docstring lies. Rescan's only transitive detect dependency is via the `crawl_project` fallback path. The Go port should reflect actual call sites, not the bash header comments.
- **`crawler_inventory_emitters.sh` exists separately for size-management reasons.** The bash split was a 300-line-file convention, not a domain boundary. Do NOT mirror it in Go — the entire inventory emitter family belongs in `internal/crawler/emit.go` (or `inventory.go`) as one cohesive set. The 300-line file ceiling does not apply to Go (DESIGN_v4.md §Package Layout calls this out explicitly).

## Seeds Forward

- **m31 onwards — Scout / Init / Plan ports:** Init currently invokes `crawl_project` directly (`lib/init.sh:129`). After m30, init can call `internal/crawler.Crawl` as a Go-package call instead of execing `tekhton crawler crawl` — making the eventual m31+ Init Port cleaner. Surface this in the m31 design as "init's only remaining external call is now a Go-package import, not a bash sourcing."
- **Schema-version-1 artifact format:** `meta.json` carries `schema_version: 1`. The m30 port preserves this. Any future change to the artifact set (new fields, restructured manifest format) should bump `schema_version` and include a compatibility shim that reads v1 files and migrates them on next crawl. The skip-unchanged optimization in rescan (m30.2) depends on this — see m30.2's design.
- **Parity-test framework reuse:** `tests/test_crawler_parity.sh` and `tests/test_rescan_parity.sh` share the diff/normalize/compare scaffolding with `test_preflight_parity.sh` (m22), `test_finalize_parity.sh` (m21), and the per-stage env parity tests (m27.3). If a shared `tests/lib/parity.sh` driver hasn't already been extracted by m30 time, this is the milestone to extract it — five consumers is past the threshold where shared infrastructure pays for itself.
- **Performance baseline:** The bash crawler against a moderate project (~500 files) runs in ~3-5 seconds; most of that is `xargs wc -l` and the seven manifest parsers each shelling out. A Go port using `filepath.WalkDir` and native parsers should be 5-10x faster. m30 does not establish a hard performance target, but the m30.2 close-out should record `time tekhton crawler crawl` against each parity fixture in `docs/go-migration.md` — a useful before/after for the m20 dogfooding narrative.
- **`--json` flag as the migration ramp:** Every `tekhton crawler` subcommand emits the same artifact schema to stdout under `--json`. This makes the Cobra surface the canonical inspection lever — `jq` pipelines against `tekhton crawler deps --json` replace the bash `_parse_node_deps` callers in `tekhton-legacy.sh` once m30 closes. Subsequent Phase-5 milestones (notes, drift, etc.) that consume crawler data should reach for `--json` first, the on-disk artifacts second.
