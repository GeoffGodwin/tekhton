## Verdict
PASS

## Confidence
88

## Reasoning
- Scope is well-defined: three specific failing test files are named
- Decision framework is clear: analyze whether code or tests need fixing (not both blindly)
- A competent developer can execute this as a standard bug triage workflow: run tests, examine failures, diff against recent commits, decide fix direction
- No migration impact — this is a pure bug investigation/fix task
- No UI components involved
- The "most recent changes" context is accessible via `git log` / `git diff`, which is standard practice
