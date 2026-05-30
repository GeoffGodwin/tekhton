# Reviewer Report — m29.2 Detect Domain Detectors (Review Cycle 1)

## Verdict
APPROVED_WITH_NOTES

The eight Go detectors, parity gate, `common_detect.sh` wrapper surface, bash caller migration, wedge-audit guard, and all ten bash deletions are correctly implemented. The Go port faithfully mirrors bash behavior; the parity gate passes against the m29.1-locked baselines. Three acceptance criteria in the milestone spec are factually incorrect (spec authoring defects, not code defects) and require human acknowledgment or a milestone-file correction before the MANIFEST row is set to `done`. The `Framework.Kind` ACP is accepted. Coverage across workspaces, CI, infrastructure, and test-framework detectors is thin and tracked as forward debt under Coverage Gaps.

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- **[AC spec defect — waiver required] `aiArtifactHeuristics` order.** Milestone AC specifies the slice as `[claude_dir, claude_md, directive_language, directive_markdowns, config_files]` and `TestHeuristicOrder` to assert that sequence. The implementation has `[known_dirs, known_files, known_globs, claude_dir, claude_md, directive_markdowns]`. The AC names were authored against an incomplete reading of the bash flow — the three inline loops (`known_dirs`, `known_files`, `known_globs`) that execute before the `_detect_*` calls never appeared in the spec. The Go port is correct; the spec drifted. Human reviewer must correct the AC wording or issue a documented waiver before setting the MANIFEST row to `done`. No code change needed.
- **[AC spec defect — waiver required] `empty/` fixture `(none detected)` count.** Milestone AC requires `grep -c '(none detected)'` against the empty baseline to return at least 8. The frozen baseline has 4, because `renderWorkspaces`, `renderServices`, `renderCI`, `renderInfrastructure`, `renderTestFrameworks`, and `renderDocQuality` all early-return when their slices are empty — exactly matching `lib/detect_report.sh` behavior. The Go port is correct; the AC was authored against an idealized rendering that never matched bash. Parity gate passes. Human reviewer must correct the AC or waive it before closure.
- **[AC spec defect — waiver required] `VERSION` not bumped to `4.29.0`.** The AC requires `VERSION` to read `4.29.0` on close, but the repo is at `4.33.28` after m33.x milestones completed out-of-order. Setting VERSION backward would regress tooling. The AC assumed sequential execution; correct decision to leave VERSION at `4.33.28`. Human reviewer should mark this AC void.
- **Stale future-tense comments in `cmd/tekhton/detect.go`.** Lines around 30–33 still read "m29.2 will register the eight remaining domain detectors" and the function-level comment says "m29.2 will rewrite those callers" — both are now past tense and appear in `--help` output for the hidden subcommand. Worth updating in a follow-up pass.
- **Stale source comment in `lib/init_synthesize_helpers.sh:12`.** Still reads "Expects: `format_detection_report()` from `lib/detect_report.sh`" — that file was deleted in m29.2. Should reference `_tk_format_detection_report` from `lib/common_detect.sh`.
- **Singleton loop in `detect.go` `attach()` for DocQuality.** The `doc_quality` case iterates `rows` but overwrites `s.DocQuality` on every pass. Safe because the bash side emits exactly one row, but misleading without a comment documenting the singleton contract.
- **Unreachable `attach("languages", r)` case in `detect.go`.** `Engine.Run` skips the languages detector in the second pass via `continue` and populates `Languages`/`Frameworks` directly from `languagesFromResult`/`frameworksFromResult`. The case cannot be entered. Dead code, harmless, but worth removing for clarity.
- **Silent `strconv.Atoi` discard in `detect.go`.** `score, _ := strconv.Atoi(row["score"])` silently produces 0 on a malformed score field. Source is controlled Go output so risk is low, but a non-silent discard or comment would be more defensive.
- **`splitCSV`/`splitSemicolon` do not trim whitespace.** Space-padded tokens from a future bash change would pass through with leading/trailing spaces. Latent correctness gap; current bash output is disciplined.
- **`--markdown` flag in `cmd/tekhton/detect.go` is a no-op** beyond the mutual-exclusion guard with `--json`. A comment clarifying it is synonymous with the default would prevent reader confusion.
- **`command -v` guard in `lib/init_synthesize_helpers.sh` (around line 102).** The milestone's Watch For section explicitly flags this as dead weight post-m29.2 — the Go binary is unconditionally available. Remove in a follow-up pass; the guard could mask a PATH misconfiguration.
- **No compile-time `Detector` interface assertions** (e.g., `var _ Detector = CommandsDetector{}`) for any of the eight new detector types. Tests confirm compliance at runtime; a compile-time assertion catches breakage faster.

## Coverage Gaps
- `workspaces.go`: only pnpm and go-workspace paths have test coverage. Lerna, nx, cargo, gradle, and maven detectors (5 of 7 monorepo types) have no test-time signal.
- `ci.go`: only GitHub Actions and the Dockerfile language-column quirk are covered. GitLab CI, CircleCI, Jenkins/Jenkinsfile, and Bitbucket Pipelines detectors have no dedicated tests.
- `infrastructure.go`: only Terraform (AWS provider) and Pulumi are covered. CDK, CloudFormation/SAM, and Ansible paths are untested.
- `test_frameworks.go`: only pytest and jest/vitest coexistence are covered. Go, Rust, Ruby, Java, C#, Dart, and Shell detection paths (7 of 9 languages) have no test-time signal.
- `doc_quality.go`: API-docs scoring and architecture scoring paths have no dedicated tests. The `RichReadme` test asserts only a loose lower bound (`score >= 15`) that would not catch individual scorer regressions.
- `services.go`: k8s detection (`detectK8sServices`) has no test coverage — only docker-compose and Procfile are exercised.
- `ai_artifacts.go`: `known_dirs`, `known_files`, and `known_globs` heuristics have no dedicated test cases beyond transitive coverage from `ClaudeDir`/`ClaudeMD` cases.

## ACP Verdicts
- ACP: Adding `Kind` field to `Framework` — ACCEPT. The field is a necessary discriminator to split the unified `frameworks[]` array into UI and non-UI types, enabling the `jq '.frameworks[] | select(.kind == "ui")'` extraction path the milestone specifies for the `detect_ui_framework` migration. The `json:"kind,omitempty"` tag is correct: regular framework rows omit the field; UI framework rows carry it. The `_tk_detect_frameworks` exclusion filter (`(.kind // "") != "ui"`) and `_tk_detect_ui_framework` inclusion filter (`.kind == "ui"`) are mutually consistent. No ARCHITECTURE.md update required — the field is internal to `internal/detect/` and bash wrapper signatures are unchanged.

## Drift Observations
- `internal/detect/detect.go` — `attach("languages", r)` case branch is unreachable dead code; `Engine.Run` populates Languages/Frameworks directly before the second pass. Future maintainers may mistake it for an active code path.
- `lib/init_synthesize_helpers.sh:12` — Header comment references deleted `lib/detect_report.sh`. Not a runtime issue but will mislead anyone following the source trail.
- Three milestone ACs (heuristic order names, `(none detected)` count, VERSION) were authored against facts that were incorrect or assumed linear milestone execution. Milestone authoring should cross-check AC grep commands against actual bash output before locking a baseline — the parity-gate baselines are the ground truth, not the intuitive description in an AC.
