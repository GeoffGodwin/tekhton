# Drift Log

## Metadata
- Last audit: 2026-05-08
- Runs since audit: 1

## Unresolved Observations
- [2026-05-08 | "Implement Milestone 19: tekhton run Top-Level Command"] All `orchestrate_*.sh` sourced library files still carry `set -euo pipefail`. Per CLAUDE.md sourced lib files should not repeat this declaration (they inherit). The pattern predates m19; the new `orchestrate_complete.sh` and `orchestrate_save.sh` replicate it correctly. Worth a family-wide hygiene pass in a dedicated non-blocking milestone.
- [2026-05-08 | "Implement Milestone 19: tekhton run Top-Level Command"] `scripts/run-parity-check.sh` header describes a 10-scenario comparison (lines 5–18) but the script body implements 4 structural checks. The gap is acknowledged inline but the headline may mislead future developers; either update the comment or stub the remaining 6 scenarios.

## Resolved
- [RESOLVED 2026-05-08] `internal/pipeline/runner.go:279` — `runReviewLoop`'s dead loop body (see Non-Blocking Note above) may attract future developers who add a second iteration without realizing the outer loop owns coder reruns. A short doc comment on the function stating "returns after exactly one review run" would guard against this drift.
- [RESOLVED 2026-05-08] lib/errors.sh:78-91 -- The inline _is_non_diagnostic_line is a deliberate dual implementation (retained to avoid forking the binary per line in test drivers). It will silently drift from classify.go::IsNonDiagnosticLine as the noise-pattern set evolves. A comment pointing to the canonical Go location would help future authors know which file is authoritative.
- [RESOLVED 2026-05-08] `internal/config/defaults.go:599` — `AGENT_ACTIVITY_TIMEOUT` carries an explicit comment explaining it "lives in lib/agent_monitor.sh today (not in config_defaults.sh)" and mirrors the operative default so milestone-mode math works. This workaround should be removed once `agent_monitor.sh` is ported (its wedge should add the key to `baseDefaults` with authority, not as a shadow copy).
- [RESOLVED 2026-05-08] `cmd/tekhton/config.go:215` — `printDiagnostics` is defined as a package-level function that takes an anonymous writer interface. The other Cobra command handlers (causal, state, dag, etc.) consistently use `cmd.ErrOrStderr()` inline. The helper is 3 lines; inlining it at the two call sites would be consistent with the rest of the package.
- [RESOLVED 2026-05-08] `lib/prompts_io.sh` — `_safe_read_file` is the only function in the m15 diff that uses `[ ]` brackets rather than `[[ ]]`. Inherited from the pre-m15 implementation; worth a one-liner cleanup when the file is next touched.
- [RESOLVED 2026-05-08] `cmd/tekhton/prompt.go:96` — `home + "/prompts"` string concatenation for path assembly is inconsistent with `filepath.Join` usage elsewhere in the Go tree. Accumulates as a minor style inconsistency.
- [RESOLVED 2026-05-08] **OS-1: Bashism in `lib/milestone_dag.sh` line 33.** The construct `done <<< "${deps//,/$'\n'}"` (here-string with parameter expansion) is valid Bash 4.3+ and is consistent with CLAUDE.md Rule 2, which targets Bash 4.3+ as the minimum shell. The project has no portability requirement below Bash 4.3. This is a portability footnote, not a structural violation. No remediation is warranted.
