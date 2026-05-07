# Reviewer Report — m15 Prompt Engine Wedge

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
None

## Simple Blockers (jr coder)
None

## Non-Blocking Notes
- `lib/prompts_io.sh:40,51` — `_safe_read_file` uses `[ ]` instead of `[[ ]]` for its two conditionals. Pre-existing code carried over from the old `lib/prompts.sh`; shellcheck passes. Worth normalising to `[[ ]]` in a cleanup pass.
- `cmd/tekhton/prompt.go:96` — `return home + "/prompts"` uses string concatenation instead of `filepath.Join`. Harmless on Linux (a trailing `/` in `$TEKHTON_HOME` produces a benign double-slash), but idiomatic Go uses `filepath.Join` for path assembly.
- `scripts/prompt-parity-check.sh` sits at 294 lines — 6 lines under the hard ceiling. Any new edge-case fixture or additional variant could push it over. Consider extracting the fixture helpers into a sibling file if the script grows.

## Coverage Gaps
None

## Drift Observations
- `lib/prompts_io.sh` — `_safe_read_file` is the only function in the m15 diff that uses `[ ]` brackets rather than `[[ ]]`. Inherited from the pre-m15 implementation; worth a one-liner cleanup when the file is next touched.
- `cmd/tekhton/prompt.go:96` — `home + "/prompts"` string concatenation for path assembly is inconsistent with `filepath.Join` usage elsewhere in the Go tree. Accumulates as a minor style inconsistency.

---

## Review Notes

**Go engine (`internal/prompt/prompt.go`)** — Clean. `processConditionals` correctly mirrors the bash `while {{IF:` / `sed /IF/,/ENDIF/d` semantics: single-pass per varName, bounded by `maxConditionalIterations=50` matching the bash `max_iterations=50` guard. `stripBlockRanges` replicates `sed /A/,/B/d` range semantics (non-recursive, open range swallows tail on unbalanced input). `substituteVars` lexicographic sort via `sort.Strings` matches `sort -u` in the oracle. Triple `TrimRight` + `+"\n"` sequence correctly replicates bash `$()` stripping + `echo` re-add. `EnvVars()` correctly handles `=`-in-value (splits on first `=` only) and silently drops empty-name entries (`idx <= 0`). TASK wrapping is byte-identical between both paths. Sentinel `ErrTemplateNotFound` properly wrapped with `%w`.

**CLI (`cmd/tekhton/prompt.go`)** — `resolvePromptsDir` priority order (`--prompts-dir` > `$TEKHTON_PROMPTS_DIR` > `$TEKHTON_HOME/prompts`) matches the spec. Exit codes (`exitNotFound=1`, `exitUsage=64`) are consistent with the project's `errExitCode`/`exitCoder` pattern. `loadPromptVars` empty-file shortcut correctly returns an empty map without a parse error.

**Bash shim (`lib/prompts.sh`, 55 lines)** — Well under the 60-line wedge ceiling. The `grep -hoE ... | sed -E ... | sort -u` inside the process substitution is correct; an empty result (template with no placeholders) delivers empty input to the while loop, which exits 0 cleanly — `|| true` is not needed because `read`'s non-zero return is the loop termination condition, not a `set -e` escape.

**`lib/prompts_io.sh`** — Correctly extracted. Helpers are moved verbatim, not modified. The `source "${TEKHTON_HOME}/lib/prompts_io.sh"` re-source in the shim preserves transitive reachability for all ~10 callers that previously reached these helpers through `lib/prompts.sh`.

**Parity script (`scripts/prompt-parity-check.sh`)** — Frozen oracle is clearly marked DO NOT MODIFY and runs deterministically without depending on git history. Covers the full matrix (45 templates × 3 variants) plus the four Watch-For edge cases. Smoke mode (`--use-fallback`) correctly limits itself to confirming the bash path is non-fatal rather than falsely claiming parity. `trap 'rm -rf "$d"' RETURN` cleanup in `_diff_inline` is valid bash 4.3+.

**V4 migration discipline** — The bash engine is gone: `lib/prompts.sh` is now a 55-line shim with no engine logic remaining. No dual implementation. `internal/prompt/` and `cmd/tekhton/prompt.go` land in the correct locations. `lib/prompts_io.sh` is a legitimate new bash file (extracted helpers required to keep the shim under the wedge ceiling, used by non-prompt callers — not new non-shim logic).

**Documentation** — `ARCHITECTURE.md` and `CLAUDE.md` updated; `## Docs Updated` section present. Public surfaces (`tekhton prompt render` subcommand, `internal/prompt.Render` Go API) documented via Go doc comments.
