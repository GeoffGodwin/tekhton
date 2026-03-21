# Reviewer Report — Milestone 19: Smart Init Orchestrator (Re-review)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `init.sh:192`: `git -C "$project_dir" rev-parse --git-dir &>/dev/null 2>&1` — `2>&1` is redundant after `&>/dev/null` (shellcheck SC2069). Carried over from prior review; not yet fixed.
- `tekhton.sh` header comment block (lines 14–30): `--reinit` flag still absent from the comment block. Carried over from prior review; not yet fixed.
- ARCHITECTURE.md still needs updating per ACP-1 and ACP-2 (add `lib/init.sh`, `lib/init_config.sh`, `lib/prompts_interactive.sh` to Layer 3; update `--init` description in Layer 1; add prompt helpers to `lib/common.sh` entry). Carried over from prior review.

## Coverage Gaps
- No tests added for `run_smart_init()`, `_generate_smart_config()`, or the prompt helpers. Milestone acceptance criteria specify explicit Node.js, Rust, and Python scenarios. Tests covering config generation output for each language would validate confidence-annotation logic and required-tools detection.

## ACP Verdicts
- ACP-1: Smart Init replaces template-copy init — **ACCEPT**. Required by the milestone spec; backward-compatible; all existing artifacts still produced.
- ACP-2: Interactive prompt helpers in common.sh — **ACCEPT**. Functions correctly extracted to `lib/prompts_interactive.sh`, resolving the prior 300-line violation.

## Drift Observations
- `init.sh` sources `init_config.sh` and `prompts_interactive.sh` via `BASH_SOURCE`-relative path resolution while all other library sourcing in the codebase uses `${TEKHTON_HOME}/lib/`. Convention gap noted in prior review; still present.

---

## Blocker Verification (prior CHANGES_REQUIRED)

**Blocker 1 — `lib/common.sh` exceeded 300-line limit**: RESOLVED. The three prompt helpers (`prompt_confirm`, `prompt_choice`, `prompt_input`) have been extracted to `lib/prompts_interactive.sh`. `lib/common.sh` is now 232 lines, well under the limit.

**Blocker 2 — `prompt_input()` missing non-interactive guard**: RESOLVED. `prompts_interactive.sh:81–84` now has the guard (`if ! [[ -t 0 ]] && ! [[ -c /dev/tty ]]; then echo "${default}"; return 0; fi`), consistent with `prompt_confirm` and `prompt_choice`.
