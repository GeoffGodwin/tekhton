<!-- milestone-meta
id: "29"
status: "split"
-->

# m29 — Detect Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — sixth dogfooded V4 milestone arc, continuing the Ship-of-Theseus port of bash subsystems to Go. The detect subsystem sits behind every `tekhton init`, every `express` invocation, every `rescan`, and the intake stage's stack-fingerprint prompt — ten bash files totalling 2,666 lines that scan a project tree and emit pipe-delimited tech-stack tuples. Today every one of those entry points sources `lib/detect*.sh` directly; there is no Go equivalent, no parity gate, and no machine-readable surface. Until detect ports, the bash-to-Go boundary in init/express/rescan stays one of the noisiest in the codebase, with every new framework or workspace style requiring a bash edit. m29 is the arc that pulls the detect subsystem behind the same `internal/<subsystem>` + `tekhton <subcommand>` seam the m21–m25 arc established for finalize, preflight, TUI, notes, and drift. |
| **Gap** | `lib/detect.sh` (476 lines) hosts the language + framework + UI engine. `lib/detect_report.sh` (230 lines) wraps it in markdown for `PROJECT_INDEX.md` and intake prompts. Eight per-domain detectors (`detect_commands.sh` 444, `detect_workspaces.sh` 283, `detect_ai_artifacts.sh` 257, `detect_ci.sh` 245, `detect_test_frameworks.sh` 194, `detect_doc_quality.sh` 193, `detect_services.sh` 188, `detect_infrastructure.sh` 156) layer on commands, monorepo enumeration, CI/CD discovery, framework introspection, doc-quality scoring, service maps, IaC presence, and AI-artifact heuristics. Every consumer (`lib/init.sh`, `lib/express.sh`, `lib/rescan.sh`, `lib/health_checks.sh`, `lib/health_checks_hygiene.sh`, `tekhton-legacy.sh:2278`) sources the bash directly and parses pipe-delimited stdout. There is no struct contract, no programmatic Go caller, no parity test against captured baselines — every regression surfaces at user-run time as a missed framework or misclassified language. The bash split into ten files was a maintainability shim, not a design — it leaks across them via the report formatter that calls each. |
| **m29 fills** | This arc splits into two child milestones, both delivering pieces of `internal/detect/` (Go) plus a `tekhton detect` Cobra subcommand. **m29.1** ports the core engine (`detect.sh` → `internal/detect/detect.go`) and the markdown report formatter (`detect_report.sh` → `internal/detect/report.go`), establishes the `Detector` interface + `Engine.Run()` orchestrator, sets up the parity-gate scaffolding under `tests/test_detect_parity.sh`, and lands the `tekhton detect` Cobra root with a single `summary --json` subcommand initially. **m29.2** ports the eight per-domain detectors as `Detector` implementations under `internal/detect/` (one file per domain: `commands.go`, `workspaces.go`, `services.go`, `ci.go`, `infrastructure.go`, `test_frameworks.go`, `doc_quality.go`, `ai_artifacts.go`), wires each into the engine's registration order, deletes all ten `lib/detect*.sh` files, rewrites bash callers to exec `tekhton detect summary --json`, and bumps `VERSION` to `4.29.0`. The arc is read-only by contract — no detector writes state, the Go port enforces this with a package-level lint that forbids `os.Create` / `os.WriteFile` outside the CLI's stdout sink. |
| **Depends on** | m27 |
| **Files changed** | `internal/detect/`, `cmd/tekhton/detect.go`, `lib/detect*.sh` (10 deletions across m29.1 + m29.2), `lib/init.sh`, `lib/express.sh`, `lib/rescan.sh`, `lib/health_checks.sh`, `lib/health_checks_hygiene.sh`, `tekhton-legacy.sh`, `tests/test_detect_parity.sh`, `tests/testdata/detect/`, `docs/v4-phase5-stub.md`, `VERSION` (on m29.2 close). |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m21 | Finalize chain orchestrator + 8 hooks ported. Established `internal/<subsystem>/` package pattern + `tekhton <subcommand>` Hidden Cobra surface. |
| m22 | Preflight subsystem ported in full; six bash files deleted. Established the "fully ported = bash deletions" milestone shape m29 follows. |
| m23 | TUI ops port. Same shape as m22. |
| m24 | Notes port. Same shape as m22. |
| m25 | Drift + clarify port. Same shape as m22. |
| m26 | Stage and finalize env contract. Producer-side stabilization the detect bash never needed (read-only contract). |
| m27 | Bash env audit gates. The audit's allowlist covers detect bash too, until m29.2 deletes those files. |
| **m29** | **Detect subsystem ported in full; ten bash files deleted; `tekhton detect summary --json` becomes the canonical surface.** |

---

## Design

### Sequencing note

m29 is split into two children. The split mirrors the m27.1–m27.3 precedent: the parent stays in MANIFEST with `status=split`, on-disk for arc context; the children carry the work. The split point is the `Detector` interface boundary — m29.1 designs and lands the engine + report + interface; m29.2 implements eight `Detector` bodies against that interface. m29.1 must close before m29.2 starts because m29.2's package layout depends on m29.1's interface decisions.

Both children are independently dogfood-able: detect is read-only by contract, so a partially-ported tree (engine in Go, domain detectors still in bash via the report formatter's call-out) cannot corrupt user state. tekhton-stable can rebuild between m29.1 and m29.2 safely. The arc parent (m29) carries no implementation — it's a manifest anchor + this design overview.

### Goal 1 — `internal/detect/` package shape

The package is structured around a `Detector` interface + a single `Engine` that registers them in a fixed order matching the bash `format_detection_report` call sequence (`detect_report.sh:17-86`):

```go
// internal/detect/detect.go
package detect

import "context"

type Detector interface {
    Name() string                                   // "languages", "commands", "workspaces", …
    Run(ctx context.Context, in *Input) (*Result, error)
}

type Input struct {
    ProjectDir string
    Languages  []Language // pre-computed by the languages detector; later detectors may consume
    Frameworks []Framework
}

type Result struct {
    Detector string
    Findings []Finding     // flat per-detector findings; report.go renders them
}

type Engine struct {
    Detectors []Detector
    cache     map[string]*Result
}

func (e *Engine) Run(ctx context.Context, projectDir string) (*Summary, error) { … }
```

`Summary` is the unified output struct — one field per domain — that the CLI marshals as JSON and the report formatter renders as markdown. The same struct serves every caller; the difference is rendering, not detection logic.

### Goal 2 — `tekhton detect` Cobra surface

A single root command with one initial subcommand keeps the bash-side migration mechanical:

```bash
tekhton detect summary --json --project-dir <path>      # Machine-readable; one JSON per call.
tekhton detect summary --markdown --project-dir <path>  # The report.go markdown render.
```

Per-detector subcommands (`tekhton detect languages`, `tekhton detect commands`, …) are *not* in m29 scope. Reason: every existing bash caller invokes the report formatter or a small handful of top-level functions (`detect_languages`, `detect_commands`, `detect_services`); none of them need finer-grained access. Adding per-detector subcommands is a deferrable cleanup once we see how the JSON consumer pattern actually shakes out.

Trade-off considered: per-detector subcommands would mirror the bash function surface more faithfully and let bash callers replace a single `detect_services` call with a single `tekhton detect services --json` call without parsing a larger blob. Rejected because (a) every actual caller already invokes 3+ detectors in sequence and would benefit from a single batched call, (b) per-detector subcommands multiply the surface area we have to keep stable across versions, (c) the parity gate is simpler with one canonical output shape. If a future caller emerges that wants exactly one domain, we add a subcommand then.

### Goal 3 — Parity gate strategy

The parity gate (`tests/test_detect_parity.sh`) runs the bash report formatter and the Go engine against three fixture projects, diffs the output (after timestamp + path normalization), and fails on any byte delta. Fixture set under `tests/testdata/detect/`:

1. **`monorepo-pnpm/`** — pnpm workspaces, TypeScript root, three packages with mixed React + Vue + Express. Exercises languages, frameworks, ui_framework, workspaces, commands, services, test_frameworks.
2. **`polyglot-services/`** — Go monorepo with a Python sidecar and a Dockerfile + k8s manifest set. Exercises infrastructure, services, ci (GitHub Actions), commands.
3. **`ai-heavy-mess/`** — A repository that intentionally exercises every AI-artifact heuristic: `.claude/`, `.cursorrules`, `AGENTS.md`, a `CLAUDE.md` with directive language, plus a half-finished `pyproject.toml` to test doc_quality scoring against a partially-documented codebase.

The gate captures the bash baseline once at m29.1 close (committed to `tests/testdata/detect/baselines/`) and locks the Go port against it byte-for-byte from m29.1 forward. The capture script lives at `scripts/capture-detect-baselines.sh` so a future drift between bash and Go (during the m29.2 implementation window) is reproducible.

### Goal 4 — Read-only enforcement

Detect is read-only by contract. The Go port enforces this with a package-level test (`internal/detect/readonly_test.go`) that grep-scans every `.go` file in the package for `os.Create`, `os.WriteFile`, `os.OpenFile.*O_WRONLY`, `os.Remove`, `os.MkdirAll`, `os.Rename`, and `ioutil.WriteFile`. Any match fails the test. The CLI surface (`cmd/tekhton/detect.go`) is allowed `os.Stdout` writes but nothing else.

The bash side has the same property (no detect file writes anything), but until m29.2 deletes them, the contract is convention only. Post-m29.2 the contract is a compile/test gate.

### Goal 5 — VERSION bump policy

Following the m27.3 precedent: only the last decimal child bumps `VERSION`. m29.1 leaves VERSION untouched (still `4.27.x` at m29.1 start, `4.28.x` after m28 lands, no bump at m29.1 close). m29.2 bumps `VERSION` to `4.29.0` on close — closing the m29 arc.

The parent m29 (this file) bumps nothing. It's a manifest anchor + arc design; it has no implementation deliverable of its own.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `.claude/milestones/MANIFEST.cfg` | Modify | Add `m29\|Detect Port\|split\|m27\|m29-detect-port.md\|phase5` plus child rows `m29.1` + `m29.2`. (Human-handled per task instructions.) |
| `.claude/milestones/m29.1-detect-core-and-report.md` | Create | Child milestone: engine + report + interface + parity gate scaffolding + `tekhton detect summary` Cobra root. |
| `.claude/milestones/m29.2-detect-domain-detectors.md` | Create | Child milestone: eight `Detector` implementations + ten bash deletions + caller rewrites + VERSION bump. |

The parent milestone (m29) has no code deliverables of its own. All work happens in m29.1 and m29.2.

---

## Acceptance Criteria

- [ ] `.claude/milestones/m29.1-detect-core-and-report.md` exists, conforms to `MILESTONE_TEMPLATE.md`, and declares `depends_on: m27` in both its meta block and Overview table.
- [ ] `.claude/milestones/m29.2-detect-domain-detectors.md` exists, conforms to `MILESTONE_TEMPLATE.md`, and declares `depends_on: m29.1` in both its meta block and Overview table.
- [ ] Both child milestones include a parity-gate acceptance criterion that names the three fixture projects (`monorepo-pnpm`, `polyglot-services`, `ai-heavy-mess`).
- [ ] m29.2 includes a `VERSION` acceptance criterion specifying `4.29.0` on close; m29.1 does not.
- [ ] Both child milestones include a Watch For bullet documenting the read-only contract and the dogfood-stability invariant.
- [ ] This parent file (m29) sits at `.claude/milestones/m29-detect-port.md` with `status: "split"` and remains on disk through both children's lifecycle (deleted only when both children close per `internal/finalize/cleanup_milestone.go`).
- [ ] `.claude/milestones/MANIFEST.cfg` carries three rows after the human's sequential-review pass: parent (`m29` with status=split) + two children (`m29.1`, `m29.2` with status=todo).

## Watch For

- **The parent milestone has no implementation.** Do not add code-level acceptance criteria here; they belong in m29.1 and m29.2. This file is the arc anchor + cross-cutting design — same shape as the post-split `m27.md` after the m27.1/m27.2/m27.3 carve-up.
- **Detect functions are called from at least six bash entry points** — `lib/init.sh`, `lib/express.sh`, `lib/rescan.sh`, `lib/health_checks.sh`, `lib/health_checks_hygiene.sh`, `tekhton-legacy.sh:2278`. The `tekhton detect summary --json` surface must cover every existing call without forcing the bash caller to know which sub-detector ran. If a caller currently parses `detect_languages` output specifically, the JSON summary still needs a `.languages[]` field with the same per-row shape.
- **`detect_ai_artifacts.sh` is heuristic-heavy and false-positive-prone.** The Go port must preserve the exact heuristic order (`_detect_claude_dir_artifacts` → `_detect_claude_md` → `_scan_for_directive_language` → `_detect_directive_markdowns` → `_dir_has_config_files`). Reordering changes which finding wins on a tie, which changes the markdown output, which fails the parity gate. m29.2's `ai_artifacts.go` is the highest-risk file in the arc; land it last and lean hard on the parity gate.
- **Three-way fan-out between Go callers, bash callers, and the Cobra CLI.** During the m29.1→m29.2 transition window the report formatter must call out to either the Go engine OR the bash detectors depending on whether m29.2 has landed. The cleanest way is to keep the bash report formatter intact through m29.1 (the Go engine + report ship in parallel but bash callers still source bash through m29.1 close) and switch every caller in m29.2 atomically when the bash files delete. Do NOT mix-and-match — leaving some bash callers on the bash report and others on `tekhton detect` for a milestone is a parity-gate footgun.
- **m28 is reserved for an out-of-band Serena fix** (per manifest `m28-serena-mcp-template-and-validation.md`). m29's `depends_on` is m27, not m28 — the Serena arc is unrelated and runs in parallel. Do not let an m28-in-progress block m29 startup.
- **Dogfood stability between children.** Both m29.1 and m29.2 are independently dogfood-able. m29.1 leaves the bash detect files in place — the Go engine ships but isn't yet the canonical path. m29.2 cuts every caller over and deletes the bash. A tekhton-stable rebuild after m29.1 and before m29.2 is safe; do not gate it on the full arc closing.

## Seeds Forward

- **m29.1 (Detect Core + Report):** Engine + interface + report formatter + parity scaffolding. Establishes the contract m29.2 implements against.
- **m29.2 (Detect Domain Detectors):** Eight `Detector` bodies + ten bash deletions + caller migrations + VERSION bump to `4.29.0`. Closes the arc.
- **Future: per-detector Cobra subcommands.** If a caller emerges that wants exactly one domain (e.g. a future intake stage that only needs `commands`), `tekhton detect commands --json` can land as a follow-up without breaking the existing `summary --json` surface. The `Detector` interface is already per-domain; the CLI just needs to wire one subcommand per `Detector` to its own `Run()`.
- **Future: detect cache.** The bash version re-runs every detector on every call site within a single `tekhton init` (init.sh:81-105 calls `detect_languages`, `detect_frameworks`, `detect_commands`, `detect_workspaces`, `detect_services`, `detect_ci_config` in sequence; some of those internally call `detect_languages` again). The Go `Engine.Run()` caches per-run by default. A future milestone could surface the cache as a long-lived `.tekhton/.detect-cache.json` for use across `init` → `rescan` → `express` invocations, gated on a project-tree-hash invalidation key. Out of scope for m29.
- **V5 multi-language workspace detection:** `DESIGN_v5.md` flags monorepo + polyglot service mesh as a first-class concept. m29's per-detector contract (`workspaces.go` + `services.go` + `infrastructure.go` returning structured findings) is the right shape — V5 extends them with provider/cloud awareness without changing the `Detector` interface.
- **Read-only contract as a package convention.** If the contract holds for a year, propose codifying it as a Go linter (`detect_readonly_lint.go`) that runs across every `internal/<subsystem>/` package known to be read-only (detect, dag, manifest). Out of scope for m29; flagged for future cleanup arcs.
