# Reviewer Report — m34.1 (Stage-Port Arc: Docs + Go-adapter pattern)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `adapter.go::dumpStageEnvPreExec` (line 315) and the `buildBashScript` post-source dump (line 447) write env vars to world-readable `/tmp/tekhton_stage_env_<stage>_{pre,post}.txt` on every stage invocation. Added for #41 debugging — correctly best-effort, but the files accumulate stale artifacts across runs and expose process env to any co-tenant process on the host. Should be gated behind a `TEKHTON_DEBUG_ENV_DUMP=true` flag or removed once the #41 investigation concludes.
- `extractDocResponsibilities` in `skip.go` has a subtle parity gap with the bash `sed` pattern. Bash uses `/^## [^D]/d` — stops at any H2 whose first body character is not "D". Go stops at any H2 not matching the full `(?i)documentation\s+responsibilities` regex. A hypothetical `## Documentation Style Guide` heading continues extraction in bash but stops it in Go. No real project CLAUDE.md has two Documentation-prefixed H2s so this causes no practical divergence today, but it should be noted before the parity test baseline is extended.
- The `envBool` test comment at `stage_test.go:234` ("empty should fall back -> but test passes true as fallback to detect; assertion inverted") mischaracterizes what happens: empty string is explicitly mapped to `false` in the switch, not the fallback. The test logic is correct; only the comment is misleading.
- `ARCHITECTURE.md` not updated — per the summary's explicit deferral to m34.2 closeout. Acceptable.

## Coverage Gaps
- The `docs-run` (full agent invocation) scenario is unit-tested via a stub `AgentRunner` in `stage_test.go` but is absent from the parity shell harness (explicitly marked `make dogfood` only due to CI/agent-availability constraints). Acceptable as stated.

## Drift Observations
- The `/tmp/tekhton_stage_env_<stage>_{pre,post}.txt` diagnostic dumps (`adapter.go:315-324`, `buildBashScript:447`) fire unconditionally on every production stage run. These were introduced for the #41 investigation — they belong behind a debug flag rather than always-on. Production pipelines running across many stages will accumulate stale `/tmp` files and log sensitive env values (API tokens, keys present in the environment) to a world-readable path on multi-user hosts.
