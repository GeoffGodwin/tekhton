# Coder Summary

## Status: COMPLETE

## What Was Implemented

m28.2 — Serena Startup Probe + Truthful Status. Second subtask in the
m28 arc. m28.1 fixed config *generation*; m28.2 fixes *truth-telling* —
`start_mcp_server` no longer logs `Serena MCP integration enabled` for a
binary that won't actually launch.

### Goal 1 — `_probe_serena_startup`

Added to `lib/mcp.sh` immediately after `_resolve_serena_paths` /
`_SERENA_BIN` resolution, before `_resolve_mcp_config`. Body matches the
milestone spec verbatim: empty-`_SERENA_BIN` → return 1; otherwise
`timeout 2 "$_SERENA_BIN" start-mcp-server --help >/dev/null 2>&1`,
returning the timeout's exit translation. No retries, no debug capture,
no `--mcp-debug`. The probe is the cheapest possible argv-parser
exerciser — `--help` is the right shape per the milestone rationale.

### Goal 2 — `start_mcp_server` flow change

Inserted the probe gate between `log_verbose "[mcp] MCP config: …"` and
the state-set block (the line previously at 210). On probe failure:
two `warn` lines (`Serena startup probe failed (binary: …)` and
`Continuing without LSP-backed tools.`), clear `SERENA_MCP_AVAILABLE`
and `SERENA_ACTIVE` to the existing empty-string shape, return 1. The
return-1 contract is unchanged from the three other failure branches
(`Serena not found`, CLI lacks `--mcp-config`, config not generated);
the existing caller in `tekhton-legacy.sh` already swallows non-zero
returns and continues without LSP. On success: appended `(probe passed)`
to the existing log line so the difference is visible in `--verbose`
logs.

### Goal 3 — VERSION + CHANGELOG

`VERSION` bumped `4.27.5` → `4.27.6`. `CHANGELOG.md` gained a `### Changed`
entry under `[Unreleased]` above the existing m28.1 `### Fixed` entry,
copied verbatim from the milestone spec.

### Test maintenance (broken by my changes — required updates)

Two existing tests (`test_mcp.sh` "start_mcp_server with everything set
up" and `test_mcp_lifecycle.sh` "start_mcp_server succeeds after state
reset") stubbed the Serena binary with `touch`, which creates an empty
non-executable file. The new probe correctly rejects that, breaking
both tests. Both updated to use a minimal executable shell stub:
`printf '#!/bin/sh\nexit 0\n' > .../serena && chmod +x .../serena`. This
matches the Seeds Forward note ("`_SERENA_BIN=/usr/bin/echo` returning
0 should make the probe pass") — any zero-exit binary is fine; the
probe deliberately does not depend on Serena-specific output. m28.3
will add the dedicated probe-stub tests against `/usr/bin/false`,
`/usr/bin/echo`, and a hanging script.

## Acceptance Criteria — verified

- [x] `_probe_serena_startup` runs `timeout 2 "$_SERENA_BIN" start-mcp-server --help`
      and returns 0 only when the spawned process exits 0 within the timeout.
      (Verified ad-hoc: `_SERENA_BIN=/usr/bin/echo _probe_serena_startup; echo $?`
      → 0; `_SERENA_BIN=/usr/bin/false _probe_serena_startup; echo $?` → 1.)
- [x] Returns 1 when `_SERENA_BIN` is empty. (Verified ad-hoc: `_SERENA_BIN=""
      _probe_serena_startup; echo $?` → 1.)
- [x] `start_mcp_server` calls `_probe_serena_startup` after `_resolve_mcp_config`
      and before the `SERENA_ACTIVE="true"` assignment (`lib/mcp.sh:223-231`).
- [x] On probe failure: `start_mcp_server` returns 1 and `SERENA_ACTIVE=""`
      (matches the three existing failure branches).
- [x] 2-second cap enforced — `timeout 2 .../hang.sh start-mcp-server --help`
      exits 124 in ≤ 2.1 s wall-clock (within the 3 s AC tolerance).
- [x] Pipeline continues after probe failure (`return 1` contract preserved;
      the existing caller in `tekhton-legacy.sh` already swallows non-zero).
- [x] `bash tests/run_tests.sh` — 492 shell PASS / 0 FAIL, all Go packages
      pass. Zero regressions vs. the m28.1-close baseline.
- [x] `VERSION` reads `4.27.6`.
- [x] `CHANGELOG.md` has the m28.2 `### Changed` entry under `[Unreleased]`.
- [ ] `.claude/milestones/MANIFEST.cfg` row for `m28.2` reads `done` —
      the finalize orchestrator's `mark_done` hook flips this on milestone
      close, not the coder pass.

Additional gates verified:

- [x] `shellcheck lib/mcp.sh` exits 0.
- [x] `shellcheck tekhton.sh lib/*.sh stages/*.sh` exits 0 (full tree
      pass; the pre-existing SC1091/SC2034 warnings in `tests/test_mcp.sh`
      and `tests/test_mcp_lifecycle.sh` were present at the m28.1-close
      baseline — verified by `git stash && shellcheck …`).
- [x] `bash tests/test_mcp.sh` — 22 PASS / 0 FAIL.
- [x] `bash tests/test_mcp_lifecycle.sh` — 3 PASS / 0 FAIL.
- [x] `bash tests/test_mcp_serena_bin.sh` — 22 PASS / 0 FAIL (m28.1
      surface still green; AC8 grep accepts `4.27.x` where x ≥ 5, so
      `4.27.6` passes that check).
- [x] File ceilings: `lib/mcp.sh` = 295 lines (was 270 at m28.1 close;
      net +25 lines for the probe function + gate block, still under
      the 300-line bash ceiling). Test files unchanged in length terms.

## Root Cause (bugs only)

N/A — m28.2 is a defensive feature, not a bug fix. The behavior change
is "tell the truth about MCP status", not "stop a panic". The motivating
incident (sdivi-rust M29: silent MCP failure ran two pipeline runs
without any operator-visible signal) is the rationale for the probe,
but there is no code defect being repaired in m28.2 itself — m28.1
fixed the underlying config template that produced the broken state.

## Files Modified

- `lib/mcp.sh` — Added `_probe_serena_startup()` function (16 lines
  including header); inserted probe gate (10 lines) into
  `start_mcp_server` between MCP-config log and state-set block;
  appended `(probe passed)` to success log line.
- `VERSION` — `4.27.5` → `4.27.6`.
- `CHANGELOG.md` — Added `### Changed` entry under `[Unreleased]` for
  m28.2 (above the existing m28.1 `### Fixed` entry).
- `tests/test_mcp.sh` — Updated "start_mcp_server with everything set
  up" stub: `touch` → executable `printf '#!/bin/sh\nexit 0\n' …` +
  `chmod +x …` so the probe passes (1-line comment + replacing 1
  `touch` line with 2 lines).
- `tests/test_mcp_lifecycle.sh` — Same test-stub update as above for
  "start_mcp_server succeeds after state reset".

## Human Notes Status

No HUMAN_NOTES.md items present in this task. The Clarifications block
in the prompt contained Q&A pairs from prior runs whose answers were
copies of the question text — noise, not signal. None of the prior
clarifications are relevant to m28.2 (they covered the Watchtower
dashboard, the `NON_BLOCKING_LOG`, the `--init`/`--plan` flow, and
notes-inconsistency reports — all in different subsystems).

## Docs Updated

None — no public-surface changes in this task. `_probe_serena_startup`
is underscore-prefixed (internal API). The user-visible effect is a
warning log line where there used to be a silent success, plus the
verbose log line now appends `(probe passed)`; neither warrants a doc
update. CHANGELOG.md gained the standard `Changed` entry that documents
the behavior change for downstream consumers.

## Observed Issues (out of scope)

- **`tests/test_mcp.sh` and `tests/test_mcp_lifecycle.sh` carry
  pre-existing SC1091 and SC2034 warnings on `source` lines and
  unused-variable assignments.** Confirmed pre-existing by
  `git stash && shellcheck tests/test_mcp.sh tests/test_mcp_lifecycle.sh`
  reporting the same warnings on the m28.1-close baseline. My m28.2
  edits added no new shellcheck warnings. Out of scope; cleanup
  belongs to a test-hygiene milestone.
- **`scripts/wedge-audit.sh` at 307 lines** — still 7 over the 300-line
  ceiling from the m27.3/m28.1 chain. No net changes here in m28.2. The
  extraction path (`scripts/wedge-audit-companions.sh`) is established;
  a follow-up milestone owns the lift.
- **`test_tester.sh` Test 2** — pre-existing UPSTREAM exit 1 failure
  (`stages/tester_tdd.sh:84`, `return` vs `exit 1`). Predates the m27
  and m28 series. Out of scope; not in the m28.2 surface.

## Architecture Change Proposals

None. The probe is a textbook resolver-time guard at the existing
`start_mcp_server` boundary, with no new dependency, no new interface
contract, and no layer-boundary change. The function naming
(`_probe_*` underscore-prefixed internal helper) and call site (within
`start_mcp_server` after resolution, before state-set) match the
existing pattern in this file (`_resolve_serena_paths`,
`_resolve_mcp_config`, `_cli_supports_mcp_config`).
