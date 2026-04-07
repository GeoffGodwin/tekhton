#### Milestone 27: Configurable Pipeline Order (TDD Support)
<!-- milestone-meta
id: "27"
status: "done"
-->


Add a PIPELINE_ORDER config key that controls stage execution order, enabling
test-driven development as an opt-in alternative to the default code-first flow.

The default order remains Scout → Coder → Security → Review → Test (standard).
The test_first order runs: Scout → Tester (write failing tests) → Coder (make
them pass) → Security → Review → Tester (verify all pass).

Seeds Forward (V4): The `auto` mode lets the PM agent (M10) decide per-milestone
based on task type analysis. Bug fixes → test_first. New features with unknown
API surface → standard. Requires PM agent maturity and calibration data.

Files to create:
- `lib/pipeline_order.sh` — Pipeline ordering logic:
  **Order definitions:**
  - `PIPELINE_ORDER_STANDARD=(scout coder security review test)` — current flow
  - `PIPELINE_ORDER_TEST_FIRST=(scout test_write coder security review test_verify)`
    — TDD flow with two tester invocations
  - `get_pipeline_order()` — returns the active order array based on config
  - `validate_pipeline_order($order)` — validates the order string is one of:
    standard, test_first, auto (auto reserved for V4, errors gracefully with
    "auto mode requires V4 — using standard")

  **Test-first stage variants:**
  - The tester stage needs to know if it's in "write failing tests" mode or
    "verify passing tests" mode. This is controlled by a TESTER_MODE variable:
    - `TESTER_MODE=write_failing` — first invocation in test_first order.
      Tester writes tests that SHOULD FAIL against the current codebase.
      Uses `prompts/tester_write_failing.prompt.md`.
    - `TESTER_MODE=verify_passing` — second invocation (or the single
      invocation in standard order). Tester writes/updates tests that should
      PASS. Uses existing `prompts/tester.prompt.md`.

- `prompts/tester_write_failing.prompt.md` — TDD-specific tester prompt:
  Instructs tester to:
  (1) Read the milestone/task acceptance criteria
  (2) Read SCOUT_REPORT.md for identified files and structure
  (3) Write test files that encode the EXPECTED behavior from acceptance criteria
  (4) These tests SHOULD FAIL when run against the current codebase — that's
      the point. A test that already passes is not testing new behavior.
  (5) Focus on interface contracts, not implementation details — the coder
      needs freedom to choose HOW to implement
  (6) Output TESTER_PREFLIGHT.md with: test files created, expected failures,
      the acceptance criteria each test covers
  **Critical guidance:**
  - Test PUBLIC interfaces only. Don't test internal methods that the coder
    hasn't created yet.
  - Use the project's existing test framework and conventions (detected by M12
    or from the tester role file).
  - If the task is creating entirely new modules with no existing interface,
    write tests against the interface DESCRIBED in the acceptance criteria.
    If the acceptance criteria don't describe an interface, write behavioral
    tests (e.g., "when I run command X, output should contain Y").
  - Keep tests simple and focused. The coder will extend them. Don't try to
    achieve full coverage in the pre-flight tests.

Files to modify:
- `tekhton.sh` — Replace hardcoded stage ordering with dynamic ordering from
  `get_pipeline_order()`. The stage functions themselves don't change — only
  the ORDER in which they're called changes. Add TESTER_MODE variable that's
  set before each tester invocation based on position in the order.
  When PIPELINE_ORDER=test_first:
    1. run_stage_scout
    2. TESTER_MODE=write_failing; run_stage_test  (write failing tests)
    3. run_stage_coder  (coder sees TESTER_PREFLIGHT.md as context)
    4. run_stage_security
    5. run_stage_review
    6. TESTER_MODE=verify_passing; run_stage_test  (verify tests pass)

- `stages/tester.sh` — Check TESTER_MODE at the start of run_stage_test().
  When write_failing: use tester_write_failing.prompt.md, output TESTER_PREFLIGHT.md,
  skip the test execution gate (tests are EXPECTED to fail).
  When verify_passing: use existing tester.prompt.md, run tests, enforce the
  test pass gate as normal.

- `stages/coder.sh` — When PIPELINE_ORDER=test_first, inject TESTER_PREFLIGHT.md
  content into coder prompt context. The coder sees the pre-written tests and
  knows: "Make these tests pass." This gives the coder a clear "done" signal.

- `prompts/coder.prompt.md` — Add conditional block:
  `{{IF:TESTER_PREFLIGHT_CONTENT}}## Pre-Written Tests (TDD Mode)
  Tests have been written before your implementation. Your goal is to make
  ALL of these tests pass while also satisfying the acceptance criteria.
  Read the test files listed in TESTER_PREFLIGHT.md to understand the
  expected interface contracts.
  {{TESTER_PREFLIGHT_CONTENT}}{{ENDIF:TESTER_PREFLIGHT_CONTENT}}`

- `lib/config_defaults.sh` — Add:
  PIPELINE_ORDER=standard (standard|test_first|auto),
  TDD_PREFLIGHT_FILE=TESTER_PREFLIGHT.md,
  TESTER_WRITE_FAILING_MAX_TURNS=10 (less than full tester — just writing
  tests, not debugging them).

- `lib/config.sh` — Validate PIPELINE_ORDER is one of standard|test_first|auto.
  When auto: warn "auto mode is V4 — falling back to standard" and set to standard.

- `lib/prompts.sh` — Register TESTER_PREFLIGHT_CONTENT template variable.

- `lib/state.sh` — State persistence must track TESTER_MODE so resume works
  correctly. If interrupted between test_write and coder, resume at coder
  (tests already written). If interrupted between coder and test_verify,
  resume at test_verify.

Acceptance criteria:
- PIPELINE_ORDER=standard produces identical behavior to current pipeline
  (zero regression)
- PIPELINE_ORDER=test_first runs tester before coder with write_failing mode
- Tester in write_failing mode produces TESTER_PREFLIGHT.md with test files
  and expected failure descriptions
- Coder in test_first mode sees TESTER_PREFLIGHT.md content and "make these
  tests pass" instruction
- Tester in verify_passing mode (second pass) runs tests and enforces pass gate
- PIPELINE_ORDER=auto falls back to standard with a warning message
- Resume from any point in both orderings works correctly
- State persistence tracks TESTER_MODE for accurate resume
- Build gate still runs between coder and security in both orderings
- Security agent still runs between coder and reviewer in both orderings
- The reviewer sees the same context regardless of pipeline order
- All existing tests pass
- `bash -n lib/pipeline_order.sh` passes
- `shellcheck lib/pipeline_order.sh` passes

Watch For:
- The tester writing "failing" tests in a brownfield project might write tests
  that fail for the WRONG reason (import errors, missing fixtures, etc). The
  prompt must be very clear: tests should fail because the feature doesn't
  exist yet, not because the test setup is broken. If test_write produces
  tests that can't even be parsed/loaded, that's a signal to fall back to
  standard order.
- PIPELINE_ORDER affects stage numbering in progress output. "Stage 2 of 6"
  vs "Stage 2 of 5" needs to adapt. Use the order array length, not a
  hardcoded count.
- The coder in test_first mode might need MORE turns than standard mode if
  the pre-written tests are extensive. Consider a CODER_TDD_TURN_MULTIPLIER
  (default 1.2) that gives the coder slightly more budget when working against
  pre-written tests.
- Don't inject TESTER_PREFLIGHT.md into the security agent or reviewer — they
  don't need it and it wastes context.
- The test_first flow has TWO tester invocations per pipeline run. This costs
  more than standard order. Users should understand this trade-off. Add a note
  to the config file: "# test_first uses two tester passes (higher cost, TDD rigor)"

Seeds Forward:
- V4 `auto` mode: PM agent evaluates milestone and recommends pipeline order.
  Bug fix tasks → test_first. New module creation → standard. Refactoring → standard.
  Data-driven: track which order produces fewer rework cycles per task type.
- The TESTER_PREFLIGHT.md format is reusable by the test integrity audit (M20)
  as a baseline reference for "what tests were originally intended to verify"
- Multi-platform support (V4) needs pipeline ordering to be platform-agnostic.
  This milestone ensures ordering is config-driven, not hardcoded.

Migration impact:
- New config keys: PIPELINE_ORDER, TDD_PREFLIGHT_FILE, TESTER_WRITE_FAILING_MAX_TURNS
- New files in .claude/: None
- Modified file formats: None
- Breaking changes: None — default is standard (identical to current behavior)
- Migration script update required: NO — new config key with backward-compatible default
