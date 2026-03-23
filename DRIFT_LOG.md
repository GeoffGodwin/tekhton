# Drift Log

## Metadata
- Last audit: 2026-03-23
- Runs since audit: 2

## Unresolved Observations
- [2026-03-23 | "Implement Milestone 13: Watchtower Data Layer & Causal Event Log"] `dashboard.sh:source "$(dirname "${BASH_SOURCE[0]}")/dashboard_parsers.sh"` — the only file in the codebase that sources a sibling using `BASH_SOURCE`-relative path instead of `${TEKHTON_HOME}/lib/`. May cause confusion during future refactors.
- [2026-03-23 | "Implement Milestone 13: Watchtower Data Layer & Causal Event Log"] `causality.sh:_json_escape` and `dashboard_parsers.sh:_to_js_string/_write_js_file` are both low-level output utilities that live in different modules. As the dashboard grows, having `_json_escape` in causality.sh while output helpers live in dashboard_parsers.sh may cause confusion about where to put new utilities.
- [2026-03-23 | "Implement Milestone 13: Watchtower Data Layer & Causal Event Log"] `finalize.sh` hook label sequence (a,b,c,d,e,f,g,h,i,j,**l** — skipping k) and the new hook registered out of alphabetical position relative to its label. Minor doc drift that accumulates if more hooks are added without renaming.

## Resolved
- [2026-03-22 | RESOLVED 2026-03-22] All three prior drift entries (SX-1, SX-2, SF-1) were fully addressed in commit 58c3ea3.
- [2026-03-22 | RESOLVED 2026-03-22] `lib/indexer_helpers.sh` — `&&`-chained seen-set pattern was refactored to `if/then/fi` style in commit 58c3ea3. No remaining occurrences of this pattern in the codebase.
