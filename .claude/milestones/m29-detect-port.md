<!-- milestone-meta
id: "29"
status: "split"
-->

# m29 — Detect Port

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — port the detect subsystem (`lib/detect*.sh`, 10 files, ~2,666 lines of bash) to `internal/detect/`. The detect subsystem is the tech-stack inference engine: it walks the project tree to identify languages, frameworks, build commands, workspaces, services, CI configuration, infrastructure, test frameworks, documentation quality, and AI artifact markers. Those findings drive `init`, `express`, `rescan`, `health_checks`, and the scout/coder prompts. Until the detect subsystem is Go, every pipeline invocation that touches stack inference pays the bash startup overhead — and every new language/framework detection requires touching both bash and, eventually, Go. Closing this milestone retires ~2.7k lines of bash and removes the largest read-side bash subsystem remaining after m22 (Preflight Port). |
| **Gap** | At m27.3 close (Bash Env Audit + Parity Gates), `lib/detect*.sh` owns ten files of language/framework/tooling detection with no Go counterpart. The bash `format_detection_report` in `detect_report.sh:17-86` is a 70-line function calling eight detector functions in sequence. No Go `Detector` interface exists, no parity-gate fixtures exist, and no `tekhton detect` Cobra surface exists. The bash detect files are sourced by six callers: `lib/init.sh`, `lib/express.sh`, `lib/rescan.sh`, `lib/health_checks.sh`, `lib/health_checks_hygiene.sh`, and `tekhton-legacy.sh`. |
| **m29 fills** | This is the **parent milestone** of a two-child arc, following the m27/m28 split pattern. m29 captures the cross-cutting design (`internal/detect/` package shape, `Detector` interface contract, parity-gate strategy, fixture set) and links the two children. m29.1 ports the core engine, report formatter, and the languages detector, and lands the parity-gate scaffolding. m29.2 implements the eight remaining domain detectors, migrates all bash callers atomically, deletes the ten bash files, and bumps VERSION to `4.29.0`. Each child is independently dogfood-able. VERSION bumps on m29.2 close, not on m29.1 (matches m27.3 pattern). |
| **Depends on** | m27 |
| **Files changed** | This parent milestone authors no production code. Child milestones touch `internal/detect/`, `cmd/tekhton/detect.go`, `lib/common.sh`, `lib/init.sh`, `lib/express.sh`, `lib/rescan.sh`, `lib/health_checks.sh`, `lib/health_checks_hygiene.sh`, `tekhton-legacy.sh`, `tests/testdata/detect/`, `tests/test_detect_parity.sh`, `scripts/capture-detect-baselines.sh`, `scripts/wedge-audit.sh`, `docs/v4-phase5-stub.md`, `VERSION`, and the 10 deletions under `lib/detect*.sh`. See the per-child files for exact paths. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m22 | Preflight Port — established the `internal/<subsystem>/` + `tekhton <subcommand>` pattern, "delete bash files outright, no transition shim", and the parity-gate fixture strategy. m29 follows the same shape. |
| m27 | Bash env audit + parity gates. m29.1's parity gate inherits the "byte-identical against captured baseline" pattern m27.3 established for `PREFLIGHT_REPORT.md`. |
| m27.3 | Last-decimal-child VERSION bump precedent. m29.2 closes the arc and bumps VERSION → `4.29.0`; m29.1 does not bump. |
| m28 | Two-child parent-with-`status: "split"` pattern; parent file remains until both children close, then parent flips to `done`. |
| **m29** | **Detect subsystem ported to `internal/detect/`; ten `lib/detect*.sh` files deleted; all bash callers migrated to `tekhton detect summary --json`; `VERSION` → `4.29.0`.** |

---

## Design

### Sequencing note

m29 splits into m29.1 (core engine + report + languages detector + parity gate scaffolding) and m29.2 (eight domain detectors + caller migration + bash deletions + VERSION bump), in that order. The split is warranted by size: the detect subsystem is ~2,666 lines versus preflight's ~1,500 — m22 could port the whole preflight subsystem in one shot; m29 cannot safely do the same without exceeding the milestone size that past experience (m23's partial cascade) showed is the failure threshold.

m29.1 establishes the `Detector` interface contract and the parity-gate fixtures so m29.2 has a fixed target. The bash files stay in place through m29.1's close; every existing caller still sources bash. The Go engine ships in parallel but no caller invokes it yet — `tekhton detect summary` is Hidden and development-only during m29.1. m29.2 atomically cuts all callers over and deletes the bash.

### Goal 1 — `internal/detect/` package shape

```
internal/detect/
├── detect.go          # Engine + Detector interface + Input/Result/Summary types
├── report.go          # Markdown report formatter (ports lib/detect_report.sh)
├── languages.go       # LanguagesDetector (ports detect_languages + detect_frameworks + detect_ui_framework)
├── commands.go        # CommandsDetector (ports lib/detect_commands.sh) — m29.2
├── workspaces.go      # WorkspacesDetector (ports lib/detect_workspaces.sh) — m29.2
├── services.go        # ServicesDetector (ports lib/detect_services.sh) — m29.2
├── ci.go              # CIDetector (ports lib/detect_ci.sh) — m29.2
├── infrastructure.go  # InfrastructureDetector (ports lib/detect_infrastructure.sh) — m29.2
├── test_frameworks.go # TestFrameworksDetector (ports lib/detect_test_frameworks.sh) — m29.2
├── doc_quality.go     # DocQualityDetector (ports lib/detect_doc_quality.sh) — m29.2
├── ai_artifacts.go    # AIArtifactsDetector (ports lib/detect_ai_artifacts.sh) — m29.2
├── readonly_test.go   # Read-only contract enforcement — m29.1
└── *_test.go          # Unit + parity tests
```

### Goal 2 — `tekhton detect` Cobra surface

`cmd/tekhton/detect.go` registers a Hidden `tekhton detect` root with one subcommand:

```
tekhton detect summary --json|--markdown --project-dir <p>
```

`Hidden: true` matches `tekhton finalize` + `tekhton preflight`. m29.1 wires `LanguagesDetector` only; m29.2 registers all nine detectors. After m29.2, bash callers exec `tekhton detect summary --json` through a `_tk_detect_summary` helper in `lib/common.sh`.

### Goal 3 — Parity-gate fixture set

Three fixture projects under `tests/testdata/detect/` provide the ground truth for Go↔bash byte-comparison:

- **`monorepo-pnpm/`** — `package.json` with `workspaces` field, `pnpm-workspace.yaml`, three packages (mixed React/Vue/Express, `.tsx`/`.vue`/`.ts`). Exercises every code path in `detect_languages` + `detect_frameworks` + `detect_ui_framework`.
- **`polyglot-services/`** — `go.mod` at root, `services/sidecar-py/pyproject.toml`, `Dockerfile`, `k8s/deployment.yaml`, `.github/workflows/ci.yml`. Exercises infrastructure + services + CI + commands detection paths.
- **`ai-heavy-mess/`** — `.claude/`, `.cursorrules`, `AGENTS.md`, `CLAUDE.md` with directive language, half-finished `pyproject.toml`. Exercises `detect_ai_artifacts` heuristic order and `detect_doc_quality` partial-doc path.

Baselines are captured once at m29.1 close by `scripts/capture-detect-baselines.sh` and locked. m29.2 must match them byte-for-byte from the Go engine.

### Goal 4 — Caller migration (m29.2)

Six callers migrate atomically when all eight domain detectors are green and the parity gate passes across all three fixtures. The migration introduces `_tk_detect_summary` in `lib/common.sh` plus nine per-domain accessor wrappers. The atomic step prevents any mixed bash/Go detect state.

---

## Children

| Child | Summary | Status |
|-------|---------|--------|
| [m29.1](m29.1-detect-core-and-report.md) | Core engine + report formatter + languages detector + parity-gate scaffolding | todo |
| [m29.2](m29.2-detect-domain-detectors.md) | Eight domain detectors + caller migration + bash deletions + VERSION → 4.29.0 | todo |

## Watch For

- **The 2-child split is size-driven, not aesthetic.** Past experience with m23 showed that single-shot ports of >2,000-line bash subsystems produce partial cascades. m29's two-child structure is the deliberate design response.
- **Read-only contract is a package boundary.** `internal/detect/readonly_test.go` (m29.1) enforces that no detect package file uses `os.Create`, `os.WriteFile`, etc. Every m29.2 detector must keep that test green.
- **`ai_artifacts.go` heuristic order is load-bearing.** `classify_ai_tool` uses the first matching finding to disambiguate ties; reordering heuristics changes the output. The `ai-heavy-mess` fixture's baseline is the byte-level reference.
- **Parity-gate baselines lock at m29.1 close.** Do not regenerate during m29.2. Baseline divergence means the Go port is wrong, not the baseline.
- **Dogfood stability.** At m29.1 close: zero bash files changed, all callers on bash — tekhton-stable can rebuild freely. At m29.2 close: all callers on Go, all bash files deleted — tekhton-stable rebuilds on the Go side. The unsafe intermediate state (some callers on Go, some on bash) must never be pushed.

## Seeds Forward

- **m30 (Crawler Port):** Imports `internal/detect` as a Go package instead of sourcing bash. The `_extract_json_keys` and `assess_doc_quality` helpers from detect become Go-side dependencies.
- **Per-detector Cobra subcommands:** If a caller needs only one domain, `tekhton detect commands --json` is a trivial follow-up. Out of scope for m29.
- **`Summary` as a versioned proto:** Promoting `Summary` to `internal/proto/detect_summary.v1.go` with a `Version string` field would let the JSON contract evolve safely. Flagged for the proto-contract cleanup arc.
