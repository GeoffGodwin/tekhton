# Drift Log

## Metadata
- Last audit: 2026-05-06
- Runs since audit: 3

## Unresolved Observations
- [2026-05-06 | "Implement Milestone 14: Milestone DAG State Machine Wedge"] `internal/dag` package: the cross-language contract for `frontier` and `active` is bare newline-separated IDs (matches m13's `tekhton manifest list` pattern). Both patterns diverge from the `internal/proto/` stamped-envelope principle stated in the reviewer checklist. The pattern is internally consistent, but the codebase now has two divergent cross-language seam styles (JSON for state/causal, plain text for manifest/dag). A future milestone that documents the seam taxonomy and picks one style would reduce this tension.
- [2026-05-06 | "Implement Milestone 14: Milestone DAG State Machine Wedge"] `lib/milestone_dag.sh` line 33: `<<< "${deps//,/$' '}"` is a bashism (here-string with parameter expansion). This is valid Bash 4.3+ and consistent with the project's shell policy; noting it for future portability awareness.
- [2026-05-06 | "Implement Milestone 13: Manifest Parser Wedge"] Inconsistent `set -euo pipefail` usage across `lib/` files: `common.sh` and `agent.sh` omit it; `config.sh`, `gates.sh`, and the new `orchestrate_main.sh` include it. The project rule says sourced files should not carry the directive. None of the changed files violate this in a new or novel way — the pattern predates M12 — but as the lib tree grows through V4 wedges, a consistent convention would reduce future reviewer friction.
- [2026-05-06 | "M12"] Inconsistent `set -euo pipefail` usage across `lib/` files: `common.sh` and `agent.sh` omit it; `config.sh`, `gates.sh`, and the new `orchestrate_main.sh` include it. The project rule says sourced files should not carry the directive. None of the changed files violate this in a new or novel way — the pattern predates M12 — but as the lib tree grows through V4 wedges, a consistent convention would reduce future reviewer friction.

## Resolved
- [RESOLVED 2026-05-06] None — no runtime files changed in this milestone; spike changes live on the isolated `theseus/m11-pathb-spike` branch by design.
- [RESOLVED 2026-05-06] `run.go:makeCancelHook` — If `reaper.Kill()` returns nil without having killed anyone (because `Attach` never recorded a pid — only possible when `cmd.Process == nil` at attach time, which cannot happen after a successful `cmd.Start()`), the leader-only `cmd.Process.Kill()` fallback is silently skipped. The `WaitDelay` backstop ensures eventual reaping. Risk is negligible in practice; noting for future-reader clarity.
- [RESOLVED 2026-05-06] `fake_agent.sh` header mode table has been stale since `hang` mode was added (pre-m09); m09 adds two more modes without updating it. A one-time pass to synchronise the header with the `case` block would stop this from accumulating across milestones.
- [RESOLVED 2026-05-06] `run.go:makeCancelHook` — If `reaper.Kill()` returns nil without having killed anyone (because `Attach` never recorded a pid — only possible when `cmd.Process == nil` at attach time, which cannot happen after a successful `cmd.Start()`), the leader-only `cmd.Process.Kill()` fallback is silently skipped. The `WaitDelay` backstop ensures eventual reaping. Risk is negligible in practice; noting for future-reader clarity.
- [RESOLVED 2026-05-06] `fake_agent.sh` header mode table has been stale since `hang` mode was added (pre-m09); m09 adds two more modes without updating it. A one-time pass to synchronise the header with the `case` block would stop this from accumulating across milestones.
