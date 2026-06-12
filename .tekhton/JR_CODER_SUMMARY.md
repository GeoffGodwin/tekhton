## What Was Fixed

- `lib/mcp_resolve.sh:158` — Added provider-spec guard to `_cli_supports_mcp_config()`: resolves `${PROVIDER:-codex,claude}`; when `claude` is absent from the spec, logs `MCP/Serena: claude not in provider chain — skipping claude MCP wiring`, sets `_CLI_MCP_CONFIG_SUPPORTED=0`, and returns 1. Skips the `claude --help` probe entirely.
- `lib/common.sh:175` — Added provider-spec guard to `check_usage_threshold()`: resolves `${PROVIDER:-codex,claude}`; when `claude` is absent, returns 0 silently (allow) without calling `claude usage`. The feature is claude-quota-specific.
- `scripts/audit-raw-claude.sh` — Created per the m20 design. Greps `lib/`, `stages/`, `tekhton.sh`, and `tekhton-legacy.sh` for the `claude` binary in command position (direct call, pipe, `&&`/`||`, `exec`, and line-continuation forms). Allowlists `lib/quota_probe.sh` until m21. Exits non-zero with the hit list when any unlisted raw `claude` call is found. Made executable.

## Files Modified

- `lib/mcp_resolve.sh`
- `lib/common.sh`
- `scripts/audit-raw-claude.sh` (created)
