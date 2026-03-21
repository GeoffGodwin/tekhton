
## Shell Stack Notes

- All scripts must use `set -euo pipefail` at the top.
- All `.sh` files must pass `shellcheck` with zero warnings.
- Quote all variable expansions: `"$var"` not `$var`.
- Use `[[ ]]` for conditionals, `$(...)` for command substitution.
- Keep files under 300 lines. Split into libraries if longer.
