## Verdict
PASS

## Confidence
87

## Reasoning
- Scope is tightly bounded to two TTY-only regressions from the V4 port; in-scope/out-of-scope is explicit ("do not let Goal 2's sidecar rewrite hold Goal 1 hostage")
- Root cause hypotheses are specific and falsifiable (unconditional teardown trap vs `_TUI_ACTIVE` predicate; Go-writer vs Python-reader schema drift with exact field names called out)
- Files to modify/create are enumerated; change type (Modify vs Create) is stated for each
- Acceptance criteria are concrete and machine-checkable: named control sequences (`\e[?1049h/l`, `\e[2J`), minimum subcommand count (≥ 3), no-exception assertion on the contract test, named existing test suites that must not regress
- The one manual criterion (live smoke) is correctly scoped as manual with a documented rationale ("live rendering isn't unit-testable"), which is acceptable
- Watch For section covers the two highest-risk implementation mistakes (TTY-only repro invisibility, symmetric teardown, nesting-before-fields audit order, canonical-direction discipline) — these are actionable guards, not vague concerns
- No new user-facing config keys or file formats introduced; no Migration impact section needed
- `lib/sidecar_lifecycle.sh` is listed as Modify but does not appear in the CLAUDE.md V3 file tree (TUI files are `lib/tui.sh`, `lib/tui_helpers.sh`, etc.). A developer should verify the actual filename before editing; the milestone content supplies enough context (symmetric teardown, `_TUI_ACTIVE` predicate) to locate the correct file regardless of name. Not a blocker.
