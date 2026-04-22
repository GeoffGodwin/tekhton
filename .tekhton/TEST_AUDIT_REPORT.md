## Test Audit Report

### Audit Summary
Tests audited: 2 files, 26 test assertions
Verdict: PASS

---

### Findings

#### COVERAGE: Invariant 9a/9b dynamic ordering assertions are tautological
- File: tests/test_tui_lifecycle_invariants.sh:398–435
- Issue: Invariant 9a and 9b assert that `_TUI_STAGES_COMPLETE` contains a "preflight"/"intake" entry and that a matching event exists in `_TUI_RECENT_EVENTS`. Both are guaranteed by construction — the test itself calls `tui_stage_end` then `tui_append_event` in that order, so the ordering can never be reversed by the test. The assertions verify API mechanics (tui_stage_end populates stages_complete; tui_append_event appends to the ring buffer) but not that tekhton.sh itself places the consumer block after the matching `tui_stage_end`. The production ordering guarantee is validated by 9c, 9d, and 9e, which are static grep-based checks on tekhton.sh and the producing modules; those are correctly grounded.
- Severity: MEDIUM
- Action: Add an inline comment on 9a/9b making their scope explicit — e.g. "# 9a/9b: smoke-test that the API mechanics work; the production call-site ordering guarantee is enforced by 9d/9e below." No assertion changes required.

#### COVERAGE: Invariant 1 setup mixes old API misuse with the substage API without a clear intent marker
- File: tests/test_tui_lifecycle_invariants.sh:113–119
- Issue: The test calls `tui_stage_begin "scout"` (the pre-M113 incorrect pattern for a sub-class stage, which allocates a lifecycle id under "scout" and resets `_TUI_STAGE_START_TS`) and then manually sets `_TUI_CURRENT_SUBSTAGE_LABEL`/`_TUI_CURRENT_SUBSTAGE_START_TS` before calling `tui_substage_end`. The purpose — verifying that sub-class labels never reach `_TUI_STAGES_COMPLETE` even under the old misuse pattern — is valid and the assertion is correctly grounded. However the brief comment "substage-class via policy; tui_stage_begin still allocates id but pill=no" is the only signal that this is an intentional regression simulation; a reader unfamiliar with M113 history may read it as a setup error.
- Severity: LOW
- Action: Expand the inline comment to state the scenario: "# Simulate pre-M113 regression: caller mistakenly uses tui_stage_begin for a sub-class label. Verify the misuse still does not produce a stages_complete row." No code change required.

---

### Non-Findings (passing review)

**Assertion honesty** — All assertions derive expected values from real implementation state: bash globals written by actual `tui_*` calls, `tui_status.json` produced by `_tui_write_status`, `get_stage_policy` return values, and `grep` results on production source files. No hard-coded magic values disconnected from implementation logic. The Invariant 8a expected string `"coder » scout"` is correct — it is the format produced by `_tui_compute_source` given the stage and substage labels the test itself passed to the API.

**Implementation exercise** — Both test files source real library code (`lib/common.sh`, `lib/pipeline_order.sh`, `lib/tui.sh`, which transitively loads `lib/tui_ops.sh` and `lib/tui_ops_substage.sh`). All nine invariants call real implementation functions (`tui_stage_begin`, `tui_stage_end`, `tui_substage_begin`, `tui_substage_end`, `run_op`, `log`, `get_stage_policy`). `_activate()` seeds the required globals directly rather than mocking them, and `_tui_write_status` executes on every helper call, producing a real `tui_status.json` that the Python parse helpers consume.

**Test weakening** — Both audited files are new; no existing tests were modified. Not applicable.

**Naming** — All assertions use `=== Invariant N: <description> ===` headers and `pass`/`fail` messages that encode the scenario and expected outcome. The deliverables test (`test_m119_deliverables.sh`) uses similarly descriptive step labels.

**Scope alignment** — Every function called in assertions is confirmed present in production source (`tui_substage_begin`, `tui_substage_end`, `_tui_autoclose_substage_if_open`, `run_op` in `lib/tui_ops.sh`/`lib/tui_ops_substage.sh`; `get_stage_policy` in `lib/pipeline_order_policy.sh`, sourced by `lib/pipeline_order.sh`). The coder summary confirms no function bodies in `lib/` or `stages/` were modified — only comment blocks — so all call sites remain valid.

**Test isolation** — `test_tui_lifecycle_invariants.sh` creates a fresh `TMPDIR` via `mktemp -d` with a `trap 'rm -rf "$TMPDIR"' EXIT` guard and routes all file I/O (`_TUI_STATUS_FILE`, `_TUI_STATUS_TMP`, `LOG_FILE`) through it. No live build reports, pipeline logs, or run artifacts are read. `test_m119_deliverables.sh` reads checked-in source files (`docs/tui-lifecycle-model.md`, `lib/tui_ops.sh`, `tools/tui_render.py`, `tools/tui_render_timings.py`, `CLAUDE.md`, `tests/test_tui_lifecycle_invariants.sh`) — these are deliverables under structural verification, not mutable run artifacts, and fall outside the isolation-flag criteria.

**Invariant 7 (no parallel mechanism)** — The grep correctly restricts to `lib/`, `stages/`, and `tekhton.sh`, excluding test files (which legitimately reference the retired strings as grep targets and historical markers). The production code grep of `_TUI_OPERATION_LABEL`, `current_operation`, and `tui_stage_transition` would catch any real regression.

**Invariant 4 and 6 complementary coverage** — Invariant 4 verifies that `tui_substage_end` does not write to `_TUI_STAGES_COMPLETE` and that only `tui_stage_end` does. Invariant 6 verifies the entire substage API (begin, end, auto-close) is silent under `TUI_LIFECYCLE_V2=false`. Together these cover both the positive path and the opt-out gate across all substage entry points.

**`test_m119_deliverables.sh` function presence checks** — Test 8 searches both `lib/tui_ops.sh` and `lib/tui_ops_substage.sh` for `^${fn}()` patterns. All four functions (`tui_substage_begin`, `tui_substage_end`, `_tui_autoclose_substage_if_open` in `tui_ops_substage.sh`; `run_op` in `tui_ops.sh`) are confirmed present at line-start positions matching the pattern.
