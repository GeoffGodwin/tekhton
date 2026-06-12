## Verdict
CHANGES_REQUIRED

The complex blocker (`lib/plan_batch.sh:88`) has been resolved: `_call_planning_batch()`
now routes through `tekhton supervise` using `_shim_write_request` / `_shim_field` from
`lib/agent_shim.sh`. All four assertions in `tests/test_plan_batch_provider_boundary.sh`
pass (A/B/C/D). Labels `plan_interview`, `plan_generate`, `replan` wired to callers for
`PROVIDER_<LABEL>` routing. The non-blocking test-guard regression note was also fixed:
assertion A now runs before the skip guard. Three simple blockers remain for the jr coder
(`lib/mcp_resolve.sh`, `lib/common.sh`, `scripts/audit-raw-claude.sh`).

**Drift Observation (planning stream-json mode):** In the new route, the planning agent
runs via `tekhton supervise` with `stream-json` output. `StdoutTail` contains JSON event
lines rather than raw document text. Callers already have the `_disk_rescued` fallback
pattern (checks on-disk files written by the agent via Write tool). Planning prompts are
designed for text-output mode and will need to be updated in a future milestone to work
optimally with tool-using agents; for now, `_disk_rescued` covers file-producing providers.

## Complex Blockers (senior coder)
- ~~`lib/plan_batch.sh:88`~~ — RESOLVED. `_call_planning_batch()` now uses `_shim_write_request` to build an `agent.request.v1` envelope and execs `tekhton supervise`. Spinner, exit-code contract, and `/dev/tty` progress indicator preserved. Labels `plan_interview` / `plan_generate` / `replan` wired at callers. All four assertions in `tests/test_plan_batch_provider_boundary.sh` pass.

## Simple Blockers (jr coder)
- `lib/mcp_resolve.sh:158` — `_cli_supports_mcp_config()` runs the `claude --help | grep -q --mcp-config` probe unconditionally. Add a one-line provider-spec guard before the probe: resolve the effective provider spec (`${PROVIDER:-codex,claude}`); if the spec does not contain `claude`, log a skip line (`MCP/Serena: claude not in provider chain — skipping claude MCP wiring`) and return 1. `tests/test_mcp_resolve_provider_guard.sh` self-skips until this guard is present.
- `lib/common.sh:175` — `check_usage_threshold()` calls `claude usage` unconditionally. Add the same provider-spec guard: when `claude` is not in the resolved spec, return 0 (allow) silently — the feature is claude-quota-specific. `tests/test_common_usage_threshold_guard.sh` self-skips until this guard is present.
- `scripts/audit-raw-claude.sh` does not exist. Create it per the m20 design (mirrors `scripts/audit-bash-env.sh` conventions): grep `lib/ stages/ tekhton.sh tekhton-legacy.sh` for the claude binary in command position (flag, subcommand, and line-continuation forms); allowlist `lib/quota_probe.sh` until m21; exit non-zero with the hit list when any unlisted call is found. `tests/test_audit_raw_claude.sh` self-skips until the script exists, and the live tree-scan assertion (the CI gate) does not run.

## Non-Blocking Notes
- ~~`tests/test_plan_batch_provider_boundary.sh:28-32`~~ — FIXED. Assertion A now runs unconditionally before the skip guard. Regression scenario (raw claude reintroduced while binary is built) is now caught.
- `cmd/tekhton/run_stage.go:setStageProviders` — the `primaryStage` parameter is accepted and immediately discarded (`_ = primaryStage`). Either remove the parameter and update the caller or add a TODO comment explaining why optimising to a single-stage resolution was deferred.
- `cmd/tekhton/supervise.go` — `--no-retry` flag is silently accepted and ignored (`_ = noRetry`). When the flag is set, emit a one-line deprecation warning (`retry is now provider-internal; --no-retry has no effect`) so operators know the flag is dead.
- `internal/runner/supervise_bridge.go:57` — `os.ReadFile(req.PromptFile)` reads the caller-supplied path with no containment check (flagged LOW/A01 by the security agent). The fix is one line: `filepath.Clean` + `strings.HasPrefix` against `os.TempDir()` or `$TEKHTON_DIR`.

## Coverage Gaps
- `supervise_bridge_test.go` — `BridgeFromProviderResult` is tested for nil result and synthesis path but NOT for the RawProviderData unmarshal path (the "full fidelity" fast path the claude provider uses). Add a test case with valid `AgentResultV1` JSON in `RawProviderData` to confirm the unmarshal branch fires, that the caller-supplied Label override is applied, and that RunID is honoured only when non-empty in the request.

## ACP Verdicts
- None

## Drift Observations
- `cmd/tekhton/run.go:342-354` and `cmd/tekhton/run_stage.go:setOneStageProvider` maintain nearly identical `SetProvider` fan-outs for all 8 stage packages. The shared list is a DRY violation waiting to diverge — extract to a shared helper in a cleanup milestone.
- `internal/runner/supervise_bridge.go` is now the authoritative resolution entry point for the supervise seam, but the file has no cross-reference to its call site in `cmd/tekhton/supervise.go`. The entry point is easy to miss for future contributors.
