# Reviewer Report — m09 Windows/WSL Reaper + fsnotify Change Detection

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `go.mod` marks `github.com/fsnotify/fsnotify v1.9.0` as `// indirect` but the package is directly imported by `internal/supervisor/fsnotify.go` (unconditionally). Similarly `golang.org/x/sys v0.13.0` is directly imported by `reaper_windows.go` (under `//go:build windows`). Running `go mod tidy` would promote both to direct requirements. No impact on compilation or behavior.
- `run_test.go` at 684 lines exceeds the 600-line soft target. Domain-coherent (all `run()` integration and unit tests). Per CLAUDE.md Rule 8 the split signal is purpose fragmentation, not line count — a future `run_activity_test.go` is reasonable but not required by m09.
- `fake_agent.sh` header mode table lists modes through `long_line` but omits `hang`, `silent_fs_writer`, and `silent_no_writes`. The new env vars (`FAKE_AGENT_WORKDIR`, `FAKE_AGENT_FS_INTERVAL`, `FAKE_AGENT_FS_COUNT`) are documented in the inline `silent_fs_writer` case comment but not the top-level table. Follows the same pre-existing pattern as the `hang` mode omission.

## Coverage Gaps
- Windows end-to-end reaper path (actual `TerminateJobObject` against a live process on Windows) is deferred to m10's CI `windows-latest` matrix. Acknowledged and acceptable per milestone design.

## Drift Observations
- `run.go:makeCancelHook` — If `reaper.Kill()` returns nil without having killed anyone (because `Attach` never recorded a pid — only possible when `cmd.Process == nil` at attach time, which cannot happen after a successful `cmd.Start()`), the leader-only `cmd.Process.Kill()` fallback is silently skipped. The `WaitDelay` backstop ensures eventual reaping. Risk is negligible in practice; noting for future-reader clarity.
- `fake_agent.sh` header mode table has been stale since `hang` mode was added (pre-m09); m09 adds two more modes without updating it. A one-time pass to synchronise the header with the `case` block would stop this from accumulating across milestones.

---

### Review notes

**Reaper (POSIX/Windows):** Both implementations are structurally correct. The two LOW security findings — the Windows `Kill()` TOCTOU (handle left open under the lock while `TerminateJobObject` runs outside it) and log-injection in `emitSupervisorEvent` — are already captured in the security report and not duplicated here. Both are marked `fixable:yes`.

**ActivityWatcher:** Dual fsnotify/fallback design is clean. Exclusion logic is segment-level, cross-platform (via `filepath.ToSlash`), and the `TestIsExcluded_Cases` table-driven test covers the false-positive edge case (`git_helper.sh` is not excluded). `sync.Once` makes `Close()` idempotent; nil-receiver guards on `HadActivitySince`, `IsFallback`, and `Close` match the documented contract. Dynamic directory add-on-CREATE is correctly gated behind the `isExcluded` filter so excluded roots like `node_modules/` don't sneak back in via CREATE events.

**run.go integration:** `activityOverrideCap` as a package-internal constant (not an `AgentRequestV1` field) is the right call given the milestone's explicit Watch For. The `activityTimeoutInputs` struct extraction keeps `handleActivityTimeout` independently unit-testable. `emitSupervisorEvent` nil-causal guard ensures tests using `New(nil, nil)` don't require a log setup.

**Test coverage:** 90.4% statement coverage exceeds the ≥80% AC. The fsnotify tests cover detection timing, all exclusion cases, dynamic subdir add, fallback mode (both directions), nil safety, and idempotent close. The run_test.go additions cover override, cap-exhaustion, and no-watcher branches via both integration and pure-unit paths.

**V4 migration discipline:** Bash `lib/agent_monitor*.sh` correctly left untouched; Go implementation is feature-complete but production cut-over gated on m10's parity tests. Complies with CLAUDE.md Rule 9.
