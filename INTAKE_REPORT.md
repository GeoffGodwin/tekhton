## Verdict
PASS

## Confidence
97

## Reasoning
- Scope is tightly defined: single file change to `.claude/agents/coder.md` with explicit exclusions for `templates/coder.md`, `prompts/coder.prompt.md`, all `lib/` and `stages/` files
- Exact content to add is provided verbatim as a markdown code block — no interpretation required
- Acceptance criteria are specific and mechanically verifiable (section exists, named rules present, concrete patterns included, no other files changed)
- Watch For section is thorough and pre-empts likely implementation mistakes (grep vs sed/awk distinction, sourced-file rule applicability, avoiding shellcheck overlap)
- No new config keys, template variables, or pipeline changes — no migration impact section needed
- No UI components — UI testability criterion not applicable
- `bash tests/run_tests.sh` as the verification step is concrete and sufficient given the single-file, non-library scope
