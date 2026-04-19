# Reviewer Report — M102: TUI-Aware Finalize + Completion Flow

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/finalize.sh` is 571 lines — well above the 300-line ceiling. M102 adds only ~7 lines (the `_hook_tui_complete` function + registration call); the overage predates this milestone. Log for next cleanup pass.
- `lib/output_format.sh:227` — `$sev` is embedded unescaped into the JSON fragment in `_out_append_action_item`. Already flagged by the security agent (LOW/fixable); current callers only pass hardcoded literals so the risk is latent, but it should be routed through `_out_json_escape` before the first computed-severity caller lands.
- `lib/output_format.sh:237` — `_out_json_escape` does not strip JSON control characters U+0000–U+001F (excluding the explicitly handled `\n`, `\r`, `\t`). Already flagged LOW/fixable by the security agent. Add a `tr -d` pass or bash parameter expansion strip before the function returns.

## Coverage Gaps
- None

## Drift Observations
- `lib/output_format.sh:_out_json_escape` and `lib/tui_helpers.sh:_tui_escape` implement identical JSON string escape logic (backslash doubling, quote escaping, newline/CR/tab). As the output bus matures these should be consolidated into a single authoritative function rather than maintained in parallel — a future edit to one that isn't mirrored in the other will produce inconsistent escaping between CLI and TUI paths.
- `lib/finalize.sh:532-534` — comment references milestone numbers (M97, M102) inline. These rotate as the history of the file extends. The load-bearing observation (action_items accumulate in `_hook_commit` so `_hook_tui_complete` must run last) should be expressed as a causal statement rather than a changelog entry.
