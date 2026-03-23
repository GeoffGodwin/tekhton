# Drift Log

## Metadata
- Last audit: 2026-03-23
- Runs since audit: 1

## Unresolved Observations

## Resolved
- [RESOLVED 2026-03-23] `lib/detect_ci.sh:16` — Header comment documents the output format as `CI_SYSTEM|BUILD_CMD|TEST_CMD|LINT_CMD|DEPLOY_TARGET|CONFIDENCE` (6 fields) but the actual emitted format has 7 fields (the 6th field `_lang` is a placeholder that `_format_ci_section` discards). The spec comment should reflect the real 7-field format to avoid future confusion.
- [RESOLVED 2026-03-23] [detect_workspaces.sh:97 / detect_workspaces.sh:116 / detect_workspaces.sh:143] Three separate awk invocations use similar "find array body between delimiters" patterns for pnpm-workspace.yaml, lerna.json, and Cargo.toml respectively. The logic differs enough (YAML vs JSON vs TOML) that a shared helper isn't straightforward, but the pattern is worth noting for a future consolidation pass.
- [RESOLVED 2026-03-23] [detect_ci.sh:87-93, _inject_ci_commands:88] The 7-field pipe-delimited format (`CI_SYSTEM|BUILD|TEST|LINT|DEPLOY|LANG|CONF`) is undocumented in the function comment, which says only 6 fields. The `_detect_dockerfile_langs` emitter established the 7th field; the comment never caught up. Low risk of divergence since there are only two call sites, but it's a documentation gap that will bite the next person adding a CI parser.
- [RESOLVED 2026-03-23] `lib/detect_ai_artifacts.sh:81` — `dir_name` loop variable reused in the `_KNOWN_AI_FILES` loop where it actually refers to a file name. Carry-over from previous cycle.
- [2026-03-22 | RESOLVED 2026-03-22] All three prior drift entries (SX-1, SX-2, SF-1) were fully addressed in commit 58c3ea3.
- [2026-03-22 | RESOLVED 2026-03-22] `lib/indexer_helpers.sh` — `&&`-chained seen-set pattern was refactored to `if/then/fi` style in commit 58c3ea3. No remaining occurrences of this pattern in the codebase.
