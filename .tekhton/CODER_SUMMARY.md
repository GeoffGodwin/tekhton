# Coder Summary

## Status: COMPLETE

## What Was Implemented

m27.1 — Env Audit Script + Initial Inventory. First sub-milestone of the
split-out m27 arc. Lands the tooling that m27.2 and m27.3 will consume:

1. **`scripts/audit-bash-env.sh`** — a grep-/awk-based scanner that flags
   any unguarded read (`${VAR}` or `$VAR` without `:-`/`-`/`:+`/`+`/`:=`/
   `=`/`:?`/`?` guard suffix) of a key in the m26 StageEnvV1 contract
   allowlist. Allowlist is the union of:
   - The 11 runtime/log-channel keys hand-emitted by
     `internal/runner/env.go:AsKV` (hardcoded as `_STAGE_ENV_KEYS`).
   - Every pipeline.conf key from `internal/config/defaults.go`, fetched
     dynamically via `tekhton config defaults --emit shell` so the
     allowlist auto-syncs when new defaults land.

   Behavior:
   - Skips lines whose first non-whitespace char is `#` (comments).
   - Tracks single-quoted heredocs (`<<'EOF'` / `<<-'EOF'`) and skips
     them entirely — bash does not expand `${VAR}` in those.
   - Skips backslash-escaped references (`\${VAR}`).
   - Detects guard forms by inspecting the character immediately after
     the name inside `${...}`.
   - Default targets are `lib/` + `stages/`; user may pass file or dir
     args.
   - Falls back to a minimal hardcoded allowlist with a `# WARNING:`
     stderr line when the `tekhton` binary is not on PATH (fresh
     clones; before `make build`).
   - Output format: `<file>:<line>:<varname>`, one per line, sorted by
     file then line (via `find … | sort`).
   - Exit code 0 when clean, 1 when any finding (CI gate ready).
   - Implementation uses POSIX `awk` (no `pcregrep` / `grep -P`
     dependency) for portability to macOS BSD environments.

2. **`tests/test_audit_bash_env.sh`** — six-case unit test against the
   fixture directory plus a performance assertion (default scan must
   complete in under 5s). Auto-discovered by `tests/run_tests.sh`.

3. **`tests/testdata/audit_bash_env/{01..06}-*.sh`** — six fixture
   files, one detection case each:
   - 01-guarded — `${MILESTONE_MODE:-false}` must not flag.
   - 02-unguarded — bare `${MILESTONE_MODE}` must flag at line 1.
   - 03-comment — `# echo "${MILESTONE_MODE}"` must not flag.
   - 04-conditional — `[[ -n "${MILESTONE_MODE+x}" ]]` must not flag.
   - 05-out-of-allowlist — `${SOME_LOCAL_VAR}` must not flag.
   - 06-heredoc — single-quoted heredoc body must not flag.

4. **`.tekhton/M27_INVENTORY.md`** — one-time snapshot of the audit
   findings against the current tree (1,049 entries across `lib/` and
   `stages/`). This is the canonical punch list m27.2 will consume and
   delete; it is committed at m27.1 close per the milestone design.

## Acceptance criteria — verified

All thirteen ACs in the milestone pass:

- script exists + executable.
- 01-guarded → exit 0, no stdout.
- 02-unguarded → exit 1, stdout contains `02-unguarded.sh:1:MILESTONE_MODE`.
- 03-comment / 04-conditional / 05-out-of-allowlist / 06-heredoc → exit 0.
- `tests/test_audit_bash_env.sh` → all eight cases green.
- Default scan completed in 0.08s on this tree (well under the 5s
  ceiling).
- `.tekhton/M27_INVENTORY.md` → 1,049 entries (≥20 required) in canonical
  `<file>:<line>:<varname>` format.
- Allowlist derivation succeeds when `tekhton config defaults --emit shell`
  is on PATH; emits `# WARNING:` on stderr and falls back to a minimal
  hardcoded set when the binary is missing — both verified.
- No regression in any `tests/test_audit_*.sh` family member (six other
  audit tests all green).
- `shellcheck scripts/audit-bash-env.sh tests/test_audit_bash_env.sh` →
  zero warnings.
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` → still zero warnings.

## Root Cause (bugs only)

N/A — m27.1 is a new feature milestone (audit tooling).

## Files Modified

- `scripts/audit-bash-env.sh` (NEW, 287 lines) — the audit script.
- `tests/test_audit_bash_env.sh` (NEW, 128 lines) — unit test against
  the six fixtures + 5s performance assertion. Auto-discovered.
- `tests/testdata/audit_bash_env/01-guarded.sh` (NEW) — guarded form
  negative fixture.
- `tests/testdata/audit_bash_env/02-unguarded.sh` (NEW) — bare
  `${MILESTONE_MODE}` positive fixture.
- `tests/testdata/audit_bash_env/03-comment.sh` (NEW) — comment-line
  negative fixture.
- `tests/testdata/audit_bash_env/04-conditional.sh` (NEW) — `${VAR+x}`
  existence-check negative fixture.
- `tests/testdata/audit_bash_env/05-out-of-allowlist.sh` (NEW) —
  not-in-allowlist negative fixture.
- `tests/testdata/audit_bash_env/06-heredoc.sh` (NEW) — single-quoted
  heredoc negative fixture.
- `.tekhton/M27_INVENTORY.md` (NEW, 1,049 lines) — transient inventory
  snapshot. Consumed and deleted by m27.2 per the milestone design.

All bash files I created are under the 300-line ceiling (largest is
the audit script at 287).

## Human Notes Status

No human notes listed for this run.

## Docs Updated

None — no public-surface changes in this task. m27.1 ships internal
tooling that does not appear in user-facing docs. The milestone design
itself defers any CI / `make dogfood` wiring (which would be a public
behavior change) to m27.3.

## Observed Issues (out of scope)

- The 1,049-entry inventory dwarfs the "~40+ trip sites" the milestone
  motivation estimated. Most of the volume comes from `lib/` files that
  read pipeline.conf-defaulted variables directly (e.g. every
  `${CODER_SUMMARY_FILE}` read in `lib/agent_helpers.sh`). These are
  protected at runtime by the m16 config loader exporting every key,
  but they are still unguarded reads under `set -u` if any caller
  bypasses `load_config`. m27.2 will need to triage which entries are
  genuine risks versus "we always source config first" assumptions —
  the milestone design anticipates this manual review step.
- `lib/artifact_defaults.sh` accounts for ~30+ findings because it
  reads `${TEKHTON_DIR}` unguarded at file-source time. That file is a
  data-only defaults file (sourced before TEKHTON_DIR's own
  initialization in some paths). Flagging it is correct behavior; the
  fix in m27.2 will be `${TEKHTON_DIR:-.tekhton}` per the existing
  pattern in `internal/config/defaults.go`.

## Architecture Change Proposals

None — m27.1 adds tooling under `scripts/` and tests under `tests/`,
both of which are already part of the architecture map. No new
dependency or layer boundary is introduced.

The script will eventually be wired into `make dogfood` and
`scripts/wedge-audit.sh` by m27.3 — that wiring is in those scripts'
existing surface area and does not require architecture changes.
