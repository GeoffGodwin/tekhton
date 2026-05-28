## Verdict
PASS

## Confidence
91

## Reasoning
- Scope is tightly defined with explicit in/out-of-scope callouts: template rewrite, `_SERENA_BIN` resolver, substitution paths, and VERSION/CHANGELOG are in; stale-config migration (28.3) and runtime probing (28.2) are explicitly excluded
- Every code change is specified to the line: exact JSON template body, exact bash declarations, exact sed block replacement — two developers would produce identical implementations
- Acceptance criteria are all mechanically testable: grep checks, `bash -n` syntax validation, `python -m json.tool` JSON parse, test suite regression gate, VERSION/CHANGELOG/MANIFEST spot checks
- "Watch For" section covers the two real risks (POSIX vs Windows dual-path and scope creep into 28.2/28.3) with enough precision to prevent accidental over-reach
- No user-facing config keys are added, so no Migration impact section is required; the short-circuit on existing configs is intentionally preserved and explained
- No UI components; UI testability criterion is not applicable
