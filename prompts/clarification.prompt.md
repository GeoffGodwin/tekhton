<!-- This template is NOT currently rendered via render_prompt("clarification").
     Post-clarification coder re-runs use render_prompt("coder") which already
     includes the {{IF:CLARIFICATIONS_CONTENT}} block. This file is retained as
     a standalone reference template for future use cases where clarification
     context needs to be injected independently of the coder prompt. -->

## Human Clarifications

The pipeline paused to collect answers to blocking questions from a previous agent run.
These answers from the human override any assumptions the previous agent made.
Integrate these answers into your implementation — they are authoritative.

{{IF:CLARIFICATIONS_CONTENT}}
--- BEGIN FILE CONTENT: CLARIFICATIONS ---
{{CLARIFICATIONS_CONTENT}}
--- END FILE CONTENT: CLARIFICATIONS ---
{{ENDIF:CLARIFICATIONS_CONTENT}}

When incorporating these answers:
1. Treat each answer as a definitive design decision
2. If an answer contradicts a prior assumption, follow the answer
3. If an answer says "skip", proceed with your best judgment on that question
4. Note in {{CODER_SUMMARY_FILE}} which clarifications you incorporated
