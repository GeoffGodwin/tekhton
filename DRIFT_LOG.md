# Drift Log

## Metadata
- Last audit: never
- Runs since audit: 3

## Unresolved Observations
- [2026-04-12 | "[BUG] Promote install.sh:125 bash-version warning to a hard"] `install.sh:64` / `tekhton.sh:64` — Both files guard only on major version < 4 while advertising "bash 4.3+" in error messages. The inconsistency is identical in both files, suggesting it was a deliberate simplification. If ever tightened, both guards should be updated together.

## Resolved
