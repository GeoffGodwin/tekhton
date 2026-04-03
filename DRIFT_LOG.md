# Drift Log

## Metadata
- Last audit: 2026-04-03
- Runs since audit: 2

## Unresolved Observations
- [2026-04-03 | "M53"] `lib/error_patterns.sh:119-123` — `load_error_patterns()` uses `echo "$line" | cut -d'|' -f1..5` (five `cut` forks per pattern, 260 forks total on load). Since loading is cached this is acceptable for 52 patterns, but if the registry grows significantly (M54/M55 project-level extensions) this pattern costs more than bash parameter expansion would. Purely a performance note — correctness is fine.
- [2026-04-03 | "M53"] `lib/error_patterns.sh:266-267` — `annotate_build_errors()` does not include raw error output in its return value; callers in `gates.sh` must write raw errors separately. The API contract is implicit and only visible by reading both files. A doc comment on `annotate_build_errors` clarifying "caller is responsible for appending raw output" would prevent future misuse.
- [2026-04-03 | "M53"] -- **Verification summary (from coder):**
- [2026-04-03 | "M53"] `bash -n lib/error_patterns.sh` — PASS
- [2026-04-03 | "M53"] `shellcheck lib/error_patterns.sh` — CLEAN (0 warnings)
- [2026-04-03 | "M53"] `bash tests/test_error_patterns.sh` — 86/86 PASS
- [2026-04-03 | "M53"] `bash tests/run_tests.sh` — 250/250 shell tests PASS
- [2026-04-03 | "M53"] Pattern count: 52 (requirement: ≥ 30)
- [2026-04-03 | "M53"] All six categories present: `env_setup`, `service_dep`, `toolchain`, `resource`, `test_infra`, `code`
- [2026-04-03 | "M53"] Build-fix agent routing: `has_only_noncode_errors()` bypass present in `stages/coder.sh:1064`
- [2026-04-03 | "M53"] `errors.sh` taxonomy extended with M53 subcategories at line 287
- [2026-04-03 | "M53"] Registry-based UI auto-remediation replaces hardcoded Playwright/Cypress detection in `gates.sh:271-295`
(none)

## Resolved
