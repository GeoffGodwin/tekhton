# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [x] [2026-05-07 | "M15"] `lib/prompts_io.sh:40,51` — `_safe_read_file` uses `[ ]` instead of `[[ ]]` for its two conditionals. Pre-existing code carried over from the old `lib/prompts.sh`; shellcheck passes. Worth normalising to `[[ ]]` in a cleanup pass.
- [ ] [2026-05-07 | "M15"] `cmd/tekhton/prompt.go:96` — `return home + "/prompts"` uses string concatenation instead of `filepath.Join`. Harmless on Linux (a trailing `/` in `$TEKHTON_HOME` produces a benign double-slash), but idiomatic Go uses `filepath.Join` for path assembly.
- [x] [2026-05-07 | "M15"] `scripts/prompt-parity-check.sh` sits at 294 lines — 6 lines under the hard ceiling. Any new edge-case fixture or additional variant could push it over. Consider extracting the fixture helpers into a sibling file if the script grows.

## Resolved
