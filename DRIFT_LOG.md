# Drift Log

## Metadata
- Last audit: 2026-03-23
- Runs since audit: 1

## Unresolved Observations
- [2026-03-23 | "Implement Milestone 17: Pipeline Diagnostics & Recovery Guidance"] `diagnose_rules.sh:299` — `# shellcheck disable=SC2034` is placed above the `_rule_unknown()` function definition line. SC2034 disables apply to the immediately following statement, not the function body, so any suppressed assignment inside the function is not actually covered. Shellcheck reports clean, so benign — but the comment placement may confuse future readers.
- [2026-03-23 | "Implement Milestone 17: Pipeline Diagnostics & Recovery Guidance"] `lib/state.sh:112-119` — `clear_pipeline_state()` uses `[ -f ]` (POSIX single brackets) for both its original check and the new M17 addition. Project standard is `[[ ]]`. Pre-existing inconsistency in the function; M17 added code matches existing local style rather than the project standard.

## Resolved
- [RESOLVED 2026-03-23] `lib/quota.sh:24` — `_QUOTA_SAVED_PIPELINE_STATE=""` is declared as a global but never set or read anywhere in the file. It is vestigial from the `write_pipeline_state()` integration that was ultimately not implemented. Should be removed to avoid confusion.
- [RESOLVED 2026-03-23] `lib/health.sh:94,193` — `assess_project_health` and `reassess_project_health` each own a full copy of the dimension-check loop and composite calculation. This is the largest instance of deliberate duplication introduced in M15 and should be tracked for future consolidation.
- [RESOLVED 2026-03-23] `lib/health_checks.sh:279` — `sample_count=$(echo "$sample_files" | grep -c '.' || true)` counts non-empty lines via grep; using `wc -l <<< "$sample_files"` or `mapfile` would be more idiomatic and avoids spawning two processes.
- [RESOLVED 2026-03-23] `lib/dashboard.sh:62-76` — `_copy_static_files()` documentation/implementation mismatch (always-overwrite vs. only-if-newer). Low severity but sets a misleading expectation for future maintainers.
- [RESOLVED 2026-03-23] `app.js:656-669` — `trendArrow()` hardcodes `runs.length < 20` as the minimum for trend comparison and uses `slice(0,10)` / `slice(10,20)`. The data order assumption (newest-first) is load-bearing but not enforced or tested anywhere in the pipeline.
- [RESOLVED 2026-03-23] `dashboard.sh:source "$(dirname "${BASH_SOURCE[0]}")/dashboard_parsers.sh"` — the only file in the codebase that sources a sibling using `BASH_SOURCE`-relative path instead of `${TEKHTON_HOME}/lib/`. May cause confusion during future refactors.
- [RESOLVED 2026-03-23] `causality.sh:_json_escape` and `dashboard_parsers.sh:_to_js_string/_write_js_file` are both low-level output utilities that live in different modules. As the dashboard grows, having `_json_escape` in causality.sh while output helpers live in dashboard_parsers.sh may cause confusion about where to put new utilities.
- [RESOLVED 2026-03-23] `finalize.sh` hook label sequence (a,b,c,d,e,f,g,h,i,j,**l** — skipping k) and the new hook registered out of alphabetical position relative to its label. Minor doc drift that accumulates if more hooks are added without renaming.
- [2026-03-22 | RESOLVED 2026-03-22] All three prior drift entries (SX-1, SX-2, SF-1) were fully addressed in commit 58c3ea3.
- [2026-03-22 | RESOLVED 2026-03-22] `lib/indexer_helpers.sh` — `&&`-chained seen-set pattern was refactored to `if/then/fi` style in commit 58c3ea3. No remaining occurrences of this pattern in the codebase.
