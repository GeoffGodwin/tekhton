# ai-heavy-mess fixture

This is the "AI-heavy mess" fixture for the m29 detect parity gate.
Exercises ai_artifacts + doc_quality detectors (m29.2 scope).

## Project Identity

- Python — half-finished pyproject.toml at the root
- Anthropic Claude — `.claude/` config dir present
- Cursor — `.cursorrules` directive file
- Generic AI agents — `AGENTS.md` instructing the model

You MUST follow these directives:
- ALWAYS run `pytest` before commits
- NEVER touch the .git directory
- IMPORTANT: be careful with secrets

## Tech Stack

**Languages:**
- Python
- TypeScript

(TypeScript here is aspirational — there is no package.json yet.)
