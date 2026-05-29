# Coder Summary

## Status: COMPLETE

## What Was Implemented

m29.1 — Detect Core + Report. Scaffolds the Go-side detect subsystem
port: `Detector` interface + `Engine` orchestrator + `Summary` type,
markdown report formatter, `LanguagesDetector` (the foundational
detector m29.2 depends on), parity-gate fixtures with captured bash
baselines, `tekhton detect summary` Cobra surface, and the read-only
contract test that pins the package's no-write invariant.

No bash files are modified or deleted at m29.1's close — every existing
caller (`lib/init.sh`, `lib/express.sh`, `lib/rescan.sh`,
`lib/health_checks*.sh`, `tekhton-legacy.sh`) still sources
`lib/detect*.sh`, so tekhton-stable can rebuild safely. The bash
subsystem stays intact as the rollback path through m29.2's cutover.

### Goal-by-goal delivery

1. **Engine + interface** (`internal/detect/detect.go`) — `Detector`,
   `Input`, `Result`, `Summary`, `Engine`, `Engine.Run` enforce
   languages-first via the dedicated dispatch + `ErrLanguagesDetectorMissing`
   sentinel. `Summary.attach` demuxes detector Results into per-domain
   fields (Languages, Frameworks today; Commands/Workspaces/Services/CI/
   Infrastructure/TestFrameworks/DocQuality/AIArtifacts are stub-empty
   until m29.2 registers their detectors).

2. **Report formatter** (`internal/detect/report.go`) — per-section
   `renderXxx` functions matching the bash `_format_<section>` shape.
   Whitespace is load-bearing (`fmt.Fprintln(b)` blank lines in the
   same positions as bash `echo ""`).

3. **Languages detector** (`internal/detect/languages.go`) — ports
   `detect_languages` + `detect_frameworks` + `detect_ui_framework`
   from `lib/detect.sh`. Three-pass shape: manifest detection, source
   file counting (top-2-levels via `git ls-files` when available,
   `filepath.WalkDir` fallback otherwise), merge + confidence scoring,
   then framework detection. The CLAUDE.md fallback (three strategies)
   is implemented for parity with the bash fallback path.

4. **CLI surface** (`cmd/tekhton/detect.go`) — `tekhton detect summary
   --markdown|--json [--project-dir DIR]`. Hidden, matching the
   m21/m22 precedent. `--json` emits the `Summary` struct verbatim;
   `--markdown` (default) calls `detect.Render`.

5. **Parity-gate scaffolding** — Three fixture projects under
   `tests/testdata/detect/`:
   - `monorepo-pnpm/` — pnpm workspace, TypeScript root, React/Vue/Express packages
   - `polyglot-services/` — Go root, Python sidecar, Dockerfile, k8s, GitHub CI
   - `ai-heavy-mess/` — `.claude/`, `.cursorrules`, `AGENTS.md`, half-finished pyproject.toml

   `scripts/capture-detect-baselines.sh` regenerates the bash baselines
   under `tests/testdata/detect/baselines/`. `tests/test_detect_parity.sh`
   extracts the `### Project Type / ### Languages / ### Frameworks`
   sections from both bash baseline and Go output and asserts they
   match byte-for-byte. All three fixtures pass.

6. **Read-only contract test** (`internal/detect/readonly_test.go`) —
   grep-scans every non-test `.go` file in the package for forbidden
   write API invocations (`os.Create(`, `os.WriteFile(`, `os.OpenFile`
   with O_WRONLY/O_CREATE, `os.Remove(`, `os.RemoveAll(`, `os.MkdirAll(`,
   `os.Mkdir(`, `os.Rename(`, `ioutil.WriteFile(`). Patterns require
   the trailing `(` so doc-comment references don't trip the check.
   Verified red by injecting `internal/detect/violation.go` containing
   `os.WriteFile(...)`, observing failure, removing the file, and
   confirming green again.

## Acceptance Criteria — verified

- [x] `internal/detect/detect.go` exports `Detector` interface with
      `Name()` + `Run(ctx, *Input) (*Result, error)`.
- [x] `Summary` struct carries `ProjectDir, Languages, Frameworks,
      Commands, EntryPoints, Workspaces, Services, CI, Infrastructure,
      TestFrameworks, DocQuality, AIArtifacts`. m29.2 fields are
      stub-empty.
- [x] `Engine.Run()` invokes `languages` detector first regardless of
      registration order — `TestLanguagesFirstInvariant` in
      `internal/detect/detect_test.go` registers a non-languages
      detector first and asserts `languages` ran first AND that the
      non-languages detector saw `Input.Languages` populated.
- [x] `LanguagesDetector` against `tests/testdata/detect/monorepo-pnpm/`
      returns `typescript` with `package.json` manifest. Verified via
      `tekhton detect summary --project-dir
      tests/testdata/detect/monorepo-pnpm` showing `| typescript |
      medium | package.json |` (medium because fixture files are
      untracked → `git ls-files` returns zero source files → no
      manifest+source promotion to "high"; matches bash behavior).
- [x] `Render(*Summary)` emits `## Tech Stack Detection Report` header
      and `| Language | Confidence | Manifest |` table header.
      `TestRenderMatchesBashShape` covers it.
- [x] `tekhton detect summary --help` exits 0; `--json --project-dir
      tests/testdata/detect/monorepo-pnpm` emits valid JSON with
      `.languages` entries. `TestDetectCmd_JSONShape` covers it.
- [x] Three fixture directories exist with the contents described in
      m29.1 Goal 5.
- [x] Three baselines under `tests/testdata/detect/baselines/` are
      non-empty and were generated by `scripts/capture-detect-baselines.sh`
      against the m29.1-close bash tree.
- [x] `scripts/capture-detect-baselines.sh` exists, is executable,
      exits 0.
- [x] `tests/test_detect_parity.sh` exists, is executable, exits 0
      across all three fixtures asserting on the three required
      sections.
- [x] `internal/detect/readonly_test.go` passes. Red-on-violation
      verified.
- [x] `go test ./internal/detect/... ./cmd/tekhton/...` passes.
- [x] `bash scripts/audit-bash-env.sh` exits 0.
- [x] `shellcheck` exits 0 on the new bash files (SC1091 info-level
      notes about unresolvable source paths do not fail the gate).
- [x] `bash tests/run_tests.sh` reports the same pass/fail shape as the
      m27.3 baseline. One pre-existing timeout flake
      (`test_finalize_parity.sh`, 60s deadline under load); the test
      passes standalone — confirmed by re-running. Not a regression
      from m29.1.
- [x] No `lib/detect*.sh` file is modified or deleted in m29.1.
      `git diff --stat HEAD -- lib/detect` is empty.
- [x] No bash caller of detect is modified.
- [x] `docs/v4-phase5-stub.md` updated: row 13 (`init.sh` + crawler/detect_*)
      flipped to "in progress (m29.1 …)" with detail; LOC budget table
      gains "End of Phase 5 m29.1 ~3300" entry (unchanged from m25 —
      m29.1 adds Go LOC without deleting bash); m29.1 closing notes
      section added.

## Files Modified

- `internal/detect/detect.go` (NEW) — engine + interface + types.
- `internal/detect/helpers.go` (NEW) — read-only fs/io helpers shared
  across the package.
- `internal/detect/languages.go` (NEW) — `LanguagesDetector` port.
- `internal/detect/report.go` (NEW) — markdown report formatter.
- `internal/detect/detect_test.go` (NEW) — engine + invariant tests.
- `internal/detect/languages_test.go` (NEW) — languages detector tests.
- `internal/detect/report_test.go` (NEW) — formatter shape tests.
- `internal/detect/readonly_test.go` (NEW) — read-only contract.
- `cmd/tekhton/detect.go` (NEW) — Cobra surface (Hidden).
- `cmd/tekhton/detect_test.go` (NEW) — CLI smoke + JSON-shape contract.
- `cmd/tekhton/main.go` — added one `cmd.AddCommand(newDetectCmd())`
  registration line.
- `tests/testdata/detect/monorepo-pnpm/` (NEW) — 8 fixture files.
- `tests/testdata/detect/polyglot-services/` (NEW) — 6 fixture files.
- `tests/testdata/detect/ai-heavy-mess/` (NEW) — 5 fixture files.
- `tests/testdata/detect/baselines/{monorepo-pnpm,polyglot-services,ai-heavy-mess}.md`
  (NEW) — frozen bash baselines.
- `tests/testdata/detect/README.md` (NEW) — fixture directory overview.
- `scripts/capture-detect-baselines.sh` (NEW) — baseline regeneration
  helper.
- `tests/test_detect_parity.sh` (NEW) — m29.1 parity gate.
- `docs/v4-phase5-stub.md` — row 13 flipped to "in progress (m29.1)";
  LOC budget entry; closing notes for m29.1.
- `ARCHITECTURE.md` — added entries for `internal/detect/` and
  `cmd/tekhton/detect.go` so the file list stays grep-able.

## Docs Updated

- `ARCHITECTURE.md` (added the two new package + CLI entries).
- `docs/v4-phase5-stub.md` (Phase 5 status row + LOC budget + closing
  notes).
- `tests/testdata/detect/README.md` (NEW fixture overview).

The bash detect tree is unchanged at m29.1, so no `lib/detect*.sh`-side
docs needed to move. m29.2 will own the bash-side delete + caller
cutover doc updates.

## Human Notes Status

No `HUMAN_NOTES.md` items injected for this task. The Clarifications
block at the top of the prompt contained Q&A pairs from prior unrelated
runs (Watchtower dashboard, `NON_BLOCKING_LOG`, `--init`/`--plan` flow,
HUMAN_NOTES inconsistency); none of those relate to m29.

## Architecture Change Proposals

None. m29.1 follows the established `internal/<subsystem>/` +
`cmd/tekhton/<subsystem>.go` + parity-gate pattern from m22 (preflight)
and m21 (finalize). No layer boundaries crossed, no new dependencies
introduced, no contract changes.

## Observed Issues (out of scope)

None worth recording. The pre-existing `test_finalize_parity.sh` 60-second
timeout flake reproduces under load and passes standalone — it's a
known artifact of the bash test runner's blanket 60s default and is
not within m29.1's scope to address.
