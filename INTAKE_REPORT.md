## Verdict
PASS

## Confidence
92

## Reasoning
- Scope is exceptionally well-defined: every prompt file is categorized by tier (1/2/3) with explicit per-file instructions
- Standard blocks are provided verbatim — zero ambiguity about what text to add
- "Already Done" section prevents accidental double-modification of existing prompts
- Out-of-scope list is explicit and comprehensive (13 prompts named)
- Acceptance criteria are concrete and mechanical: balanced IF/ENDIF pairs, render tests with SERENA_ACTIVE=true vs ""
- Migration impact is declared: no new config keys, zero impact when Serena/repo map disabled
- Watch For section covers the main risks (prompt size inflation, over-instruction, conditional edge cases)
- The ≤15 lines constraint on tester.prompt.md additions is specific and enforceable
- Not a UI milestone — UI testability criteria not applicable
