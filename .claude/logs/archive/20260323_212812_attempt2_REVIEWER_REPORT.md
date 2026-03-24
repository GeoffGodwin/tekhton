# Reviewer Report — Milestone 16: Autonomous Runtime Improvements (Cycle 2)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- [SECURITY-MEDIUM] `prompts/security_rework.prompt.md:10` — `{{SECURITY_FIXABLE_BLOCK}}` is injected from parsed agent output without BEGIN/END FILE CONTENT delimiters. A misbehaving security agent could embed instructions that the rework coder receives as trusted prompt content. Wrap with delimited header matching the pattern used in the scan prompt.
- [SECURITY-LOW] `lib/indexer.sh:152` — `mktemp` fallback uses predictable PID-based path `/tmp/tekhton_indexer_$$`. On shared systems this is a symlink-injection risk. Remove the fallback and abort if `mktemp` fails.
- [SECURITY-LOW] `lib/finalize_summary.sh:48` — JSON escaping in `files_changed` array only handles `\` and `"`. Control characters (U+0000–U+001F) in git-tracked file paths produce malformed JSON. Apply full control-character escaping.
- [SECURITY-LOW] `lib/indexer_history.sh:151` — `safe_task` escaping omits JSON control characters other than newline, `\`, and `"`. Same fix as `finalize_summary.sh`.
- `lib/quota.sh:24` — `_QUOTA_SAVED_PIPELINE_STATE` declared and initialized to `""` but never set or read. Dead variable.

## Coverage Gaps
- No test exercises the full `enter_quota_pause` → `_quota_probe` → `exit_quota_pause` round trip against a mock claude binary. Timeout path of `enter_quota_pause` (returns 1) is also untested.
- `_ORCH_ATTEMPT` reset-on-success path in `orchestrate.sh:219-223` is not directly tested in `test_quota.sh` or any other test file.

## ACP Verdicts

None declared in CODER_SUMMARY.md.

## Drift Observations

- `lib/orchestrate.sh:122-125` — `_ORCH_AGENT_100_WARNED` flag is never reset between milestones in the auto-advance chain. If the first milestone crosses 100 agent calls, the warning fires once; subsequent milestones won't fire the warning even though it's a new milestone context.
- `lib/orchestrate_recovery.sh:81` — `progress_patterns` uses BRE `\|` passed to `grep -q` without `-E`. Portable but inconsistent with extended regex style used elsewhere. Works correctly.

---

## Prior Blocker Verification

**Complex Blocker — `lib/orchestrate_recovery.sh` causal log baseline:** FIXED.
`_ORCH_CAUSAL_LOG_BASELINE` is initialized to 0 at line 44 of `orchestrate.sh`, then captured via `wc -l < "$CAUSAL_LOG_FILE"` at the start of each iteration (lines 106-108). `_check_progress_causal_log` now reads only lines after the baseline using `tail -n "+$(( baseline + 1 ))"` (line 73). The heuristics are correctly scoped to the current attempt.

**Simple Blocker — `tests/test_milestone_split.sh:409` default depth assertion:** FIXED.
Line 409 now asserts `MILESTONE_MAX_SPLIT_DEPTH=6` with the label "defaults to 6". Line 425 also correctly documents the hard-cap test comment as "clamped to 10 (M16: raised from 5)".
