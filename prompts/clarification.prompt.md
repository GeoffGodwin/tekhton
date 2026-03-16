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
4. Note in CODER_SUMMARY.md which clarifications you incorporated
