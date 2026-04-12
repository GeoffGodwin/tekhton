# Drift Log

## Metadata
- Last audit: never
- Runs since audit: 4

## Unresolved Observations
- [2026-04-12 | "[BUG] README.md lies about macOS being zero-setup. Update"] `.claude/agents/coder.md`, `.claude/agents/architect.md`, `.claude/agents/jr-coder.md` — agent role definitions use "Bash 4+" while every other authoritative source (README.md, CLAUDE.md, install.sh, installation.md, common-errors.md) now consistently says "Bash 4.3+". The inconsistency is harmless today but will mislead a future editor checking the agent files for the requirement floor.
- [2026-04-12 | "[BUG] Promote install.sh:125 bash-version warning to a hard"] `install.sh:64` / `tekhton.sh:64` — Both files guard only on major version < 4 while advertising "bash 4.3+" in error messages. The inconsistency is identical in both files, suggesting it was a deliberate simplification. If ever tightened, both guards should be updated together.

## Resolved
