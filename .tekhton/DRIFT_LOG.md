# Drift Log

## Metadata
- Last audit: 2026-05-05
- Runs since audit: 4

## Unresolved Observations
- [2026-05-06 | "Implement Milestone 10: Supervisor Parity Suite + Bash Cutover"] `run.go:makeCancelHook` — If `reaper.Kill()` returns nil without having killed anyone (because `Attach` never recorded a pid — only possible when `cmd.Process == nil` at attach time, which cannot happen after a successful `cmd.Start()`), the leader-only `cmd.Process.Kill()` fallback is silently skipped. The `WaitDelay` backstop ensures eventual reaping. Risk is negligible in practice; noting for future-reader clarity.
- [2026-05-06 | "Implement Milestone 10: Supervisor Parity Suite + Bash Cutover"] `fake_agent.sh` header mode table has been stale since `hang` mode was added (pre-m09); m09 adds two more modes without updating it. A one-time pass to synchronise the header with the `case` block would stop this from accumulating across milestones.
- [2026-05-06 | "Implement Milestone 9: Windows/WSL Reaper + fsnotify Change Detection"] `run.go:makeCancelHook` — If `reaper.Kill()` returns nil without having killed anyone (because `Attach` never recorded a pid — only possible when `cmd.Process == nil` at attach time, which cannot happen after a successful `cmd.Start()`), the leader-only `cmd.Process.Kill()` fallback is silently skipped. The `WaitDelay` backstop ensures eventual reaping. Risk is negligible in practice; noting for future-reader clarity.
- [2026-05-06 | "Implement Milestone 9: Windows/WSL Reaper + fsnotify Change Detection"] `fake_agent.sh` header mode table has been stale since `hang` mode was added (pre-m09); m09 adds two more modes without updating it. A one-time pass to synchronise the header with the `case` block would stop this from accumulating across milestones.

## Resolved
