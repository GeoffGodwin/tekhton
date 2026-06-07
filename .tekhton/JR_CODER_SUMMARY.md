## What Was Fixed

- **[SECURITY HIGH] `dumpStageEnvPreExec` — credential exposure in `/tmp`**: Gated the entire function body behind `os.Getenv("TEKHTON_DEBUG_ENV") != ""` so the pre-exec env dump is opt-in only. Changed file permissions from `0o644` (world-readable) to `0o600` (owner-only).
- **[SECURITY MEDIUM] `buildBashScript` — post-sourcing env dump in bash wrapper**: Gated the `env | sort > /tmp/tekhton_stage_env_*_post.txt` line behind `os.Getenv("TEKHTON_DEBUG_ENV") != ""` so the post-exec dump is also opt-in only.

## Files Modified

- `internal/stagerunner/adapter.go`
