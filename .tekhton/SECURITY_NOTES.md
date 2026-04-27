# Security Notes

Generated: 2026-04-27 18:05:21

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A03] [tests/resilience_arc_fixtures.sh:88-109] fixable:yes — `_arc_write_v2_failure_context` and `_arc_write_v1_failure_context` interpolate shell variables directly into JSON heredocs without escaping. Values containing `"` or `\` would produce malformed JSON and could cause assertion false-positives in future callers that pass dynamic input. All current callers use hardcoded string literals, so there is no runtime exploit path; the risk is confined to future misuse. Fix: use a `_json_escape` helper (already used in other test files in this repo) before interpolating into the heredoc.
