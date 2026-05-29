## Verdict
PASS

## Confidence
95

## Reasoning
- Scope is precisely defined: four numbered goals with explicit in/out-of-scope boundaries; "Watch For" reinforces what is deferred (probe logic to m28.2, stale-config migration to m28.3)
- All five modified files are named and described; no ambiguity about what changes
- Design section provides verbatim bash snippets and the exact sed block, leaving no implementation decisions to the developer
- Acceptance criteria are fully mechanical: string-grep checks, JSON validation via `python -m json.tool`, bash syntax check, test-suite invocation, VERSION and CHANGELOG content checks — none are aspirational
- POSIX/Windows dual-path requirement is called out explicitly in the design and in "Watch For," matching the existing `_SERENA_PYTHON` pattern
- Migration impact is intentionally deferred to m28.3 and clearly documented as such; no new user-facing config keys are introduced
- "Seeds Forward" section makes cross-subtask contracts explicit (`_SERENA_BIN` must be set on every successful exit; detector substring for m28.3)
- No UI components involved; UI testability criterion not applicable
