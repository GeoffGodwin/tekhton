## Summary

Milestone m47 prevents post-verdict subprocess errors from overriding an APPROVED review verdict (the m38.4 + m46 manifest false-failure pattern). The core changes — `specialist.go` m47 warning accumulation, `warnings.go` JSON append helper, and the `runGo` adapter gate — are structurally sound. Stage names are validated against an allowlist before shell interpolation, eliminating any command injection surface. JSON warning encoding uses `encoding/json` with safe fallback behavior. The one security concern is a diagnostic environment dump introduced in adapter.go that writes the full subprocess environment — including API credentials from `os.Environ()` — to world-readable files at predictable `/tmp` paths.

## Findings
- [HIGH] [category:A02] [internal/stagerunner/adapter.go:345] fixable:yes — `dumpStageEnvPreExec` writes the full composed subprocess environment (inheriting `os.Environ()`, which likely includes `ANTHROPIC_API_KEY` and similar credentials) to `/tmp/tekhton_stage_env_<stage>_pre.txt` with `0o644` permissions. The file is world-readable by all local users and the path is predictable. Fix: change permission bits to `0o600`, or gate the dump behind a `TEKHTON_DEBUG_ENV=1` env flag and remove it once issue #41 is resolved.
- [MEDIUM] [category:A02] [internal/stagerunner/adapter.go:469] fixable:yes — The bash wrapper emits `env | sort > /tmp/tekhton_stage_env_%s_post.txt 2>/dev/null || true`, writing the full post-sourcing bash environment (parent env plus all lib/*.sh exports) to a second world-readable `/tmp` file. Same credentials exposure risk as the pre-exec dump. Fix: remove or gate behind the same `TEKHTON_DEBUG_ENV=1` flag.

## Verdict
FINDINGS_PRESENT
