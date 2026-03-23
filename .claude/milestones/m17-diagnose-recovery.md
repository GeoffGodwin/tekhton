#### Milestone 17: Pipeline Diagnostics & Recovery Guidance
Add a `tekhton --diagnose` command that reads the latest pipeline state and the
**causal event log** (from M13), identifies what went wrong with root-cause
tracing, and provides actionable recovery suggestions. Also generates a structured
DIAGNOSIS.md report that both the CLI and Watchtower can consume.

This milestone has immediate value — it solves the "what do I do now?" problem that
every Tekhton user hits when a pipeline run fails. No agent calls needed — this is
pure shell logic reading the causal log, state files, and applying diagnostic rules.

The key difference from a naive state-file-only approach: the causal log lets
--diagnose trace **why** a failure happened, not just **what** failed. A build
failure isn't just "BUILD_ERRORS.md exists" — it's "build broke because the
coder modified handler.py, which was triggered by a security rework cycle, which
was triggered by an injection finding." The user gets a causal chain, not a symptom.

The diagnose command is self-updating: as new stages land (security M09, intake M10,
etc.), their failure patterns are added to the diagnostic ruleset. The core
infrastructure built here supports all future stages.

Files to create:
- `lib/diagnose.sh` — Diagnostic engine:
  **State reader** (`_read_diagnostic_context()`):
  - Read the causal event log (CAUSAL_LOG.jsonl from M13) — this is the primary
    diagnostic input. Extract: last event, all error events, all verdict events,
    rework cycle count, the terminal event (last event before pipeline stopped).
  - Read pipeline state from PIPELINE_STATE.md (current stage, attempt count)
  - Read latest RUN_SUMMARY.json (outcome, per-stage results, error messages)
  - Read MANIFEST.cfg (milestone status, which is active/stuck)
  - Read error files: BUILD_ERRORS.md, SECURITY_REPORT.md (when M09 exists),
    INTAKE_REPORT.md (when M10 exists), HUMAN_ACTION_REQUIRED.md
  - Read agent log tails (last 20 lines of each stage's agent output)
  - Compile into a diagnostic context object (associative arrays).
  - When causal log exists: call `trace_cause_chain()` on the terminal error
    event to pre-compute the root-cause chain for use by diagnostic rules.

  **Failure classifier** (`classify_failure()`):
  Applies rules in priority order, returns the FIRST matching diagnosis:

  1. **BUILD_FAILURE** — BUILD_ERRORS.md exists and is non-empty
     Suggestions:
     - "Build failed. Errors in BUILD_ERRORS.md."
     - "Fix the build errors manually, then run: tekhton --start-at coder"
     - "Or let Tekhton retry: tekhton --milestone (it will attempt build fix)"
     If build_fix already attempted and failed:
     - "Automatic build fix was attempted and failed."
     - "The errors may require manual intervention. See BUILD_ERRORS.md."

  2. **REVIEW_REJECTION_LOOP** — Review stage completed 3+ cycles with no approval
     Suggestions:
     - "Reviewer rejected the code N times. The coder may be unable to address
       the feedback within the turn budget."
     - "Options: (1) Increase REVIEW_MAX_REWORK_CYCLES in pipeline.conf,
       (2) Read REVIEWER_REPORT.md and fix the issues manually,
       (3) Run: tekhton --start-at review to retry review only"

  3. **SECURITY_HALT** — Security stage returned HALT verdict
     (Available when M09 exists — detect by checking if stages/security.sh sourced)
     Suggestions:
     - "Security scan found CRITICAL unfixable vulnerabilities."
     - "Your SECURITY_UNFIXABLE_POLICY is set to 'halt'."
     - "Options: (1) Add waivers to SECURITY_WAIVER_FILE for known-accepted risks,
       (2) Fix the vulnerabilities manually and re-run,
       (3) Change SECURITY_UNFIXABLE_POLICY to 'escalate' to continue with warnings"

  4. **INTAKE_NEEDS_CLARITY** — Intake paused for human input
     (Available when M10 exists)
     Suggestions:
     - "The PM agent needs clarification on this milestone."
     - "Questions are in CLARIFICATIONS.md. Answer them and re-run."
     - "Or lower INTAKE_CLARITY_THRESHOLD if the gate is too aggressive."

  5. **QUOTA_EXHAUSTED** — Pipeline paused due to rate limiting
     (Available when M16 exists)
     Suggestions:
     - "Pipeline paused waiting for quota refresh."
     - "It will resume automatically. No action needed."
     - "If you need it sooner, wait for your 5-hour window to refresh."

  6. **STUCK_LOOP** — MAX_PIPELINE_ATTEMPTS reached with no progress
     Suggestions:
     - "Pipeline completed N attempts with no forward progress."
     - "This usually means the task is too complex for automatic resolution."
     - "Options: (1) Simplify the milestone and re-run,
       (2) Break it into smaller milestones: tekhton --split-milestone N,
       (3) Check the scout report for scope issues"

  7. **TURN_EXHAUSTION** — Agent hit max turns without completing
     Suggestions:
     - "The [stage] agent exhausted its turn budget ([N] turns)."
     - "Options: (1) Increase [STAGE]_MAX_TURNS in pipeline.conf,
       (2) Simplify the task scope,
       (3) Check if continuation is enabled (CONTINUATION_ENABLED=true)"

  8. **MILESTONE_SPLIT_DEPTH** — Max split depth reached
     Suggestions:
     - "Milestone was split N times and still couldn't complete."
     - "The task may be fundamentally too complex for automated splitting."
     - "Options: (1) Manually break it into smaller milestones,
       (2) Increase MILESTONE_MAX_SPLIT_DEPTH (currently N)"

  9. **TRANSIENT_ERROR** — Agent calls failed with server errors
     Suggestions:
     - "Claude API returned transient errors (server error, timeout)."
     - "This is usually temporary. Re-run: tekhton --resume"
     - "If persistent, check Claude API status: status.anthropic.com"

  10. **UNKNOWN** — No specific pattern matched
      Suggestions:
      - "No specific failure pattern identified."
      - "Check the latest agent output in .claude/runs/latest/"
      - "Re-run with DASHBOARD_VERBOSITY=verbose for more detail"

  **Report generator** (`generate_diagnosis_report()`):
  Produces DIAGNOSIS.md with:
  - **Causal chain** (when causal log available): "Root cause → intermediate
    events → terminal failure" as a human-readable trace. Uses
    `cause_chain_summary()` from lib/causality.sh. Example:
    ```
    Cause Chain:
    security.finding (A03:Injection in handler.py:42)
      → security.verdict (1 HIGH fixable)
      → coder.rework_cycle (security fix attempt)
      → build_gate.fail (3 compilation errors)
    ```
  - Failure classification and confidence
  - Current pipeline state summary
  - Specific suggestions (numbered, actionable)
  - Relevant file paths to inspect
  - Exact commands to run for each recovery option
  - History: if this is a recurring failure, note that ("This is the 3rd
    build failure in a row — consider manual intervention"). Uses
    `recurring_pattern()` from lib/causality.sh to query across archived logs.

  **Quick suggestions** (`print_diagnosis_summary()`):
  Terminal-friendly colored output:
  ```
  ╔══════════════════════════════════════════════════╗
  ║  DIAGNOSIS: BUILD_FAILURE                        ║
  ╠══════════════════════════════════════════════════╣
  ║  Build failed after security rework cycle.       ║
  ║  Errors: 3 compilation errors in src/api/        ║
  ║                                                  ║
  ║  Cause chain:                                    ║
  ║  security.finding → rework_cycle → build_gate    ║
  ║                                                  ║
  ║  Suggestions:                                    ║
  ║  1. Fix manually → tekhton --start-at coder      ║
  ║  2. Let Tekhton retry → tekhton --milestone      ║
  ║  3. See details → cat BUILD_ERRORS.md            ║
  ║                                                  ║
  ║  Full report: DIAGNOSIS.md                       ║
  ╚══════════════════════════════════════════════════╝
  ```
  When causal log is unavailable (pre-M13 runs, CAUSAL_LOG_ENABLED=false),
  falls back to symptom-only diagnosis (BUILD_FAILURE without cause chain).
  The terminal summary always includes the one-line cause chain when available.

- `lib/diagnose_rules.sh` — Diagnostic rule definitions:
  Each rule is a function: `_rule_build_failure()`, `_rule_review_loop()`, etc.
  Returns 0 if matched (with suggestions in a variable), 1 if not.
  Rules are registered in a priority-ordered array so new rules can be inserted
  by future milestones without modifying existing code:
  ```bash
  DIAGNOSE_RULES=(
      "_rule_build_failure"
      "_rule_review_loop"
      "_rule_security_halt"     # no-op until M09 exists
      "_rule_intake_clarity"    # no-op until M10 exists
      "_rule_quota_exhausted"   # no-op until M16 exists
      "_rule_stuck_loop"
      "_rule_turn_exhaustion"
      "_rule_split_depth"
      "_rule_transient_error"
      "_rule_unknown"
  )
  ```
  Rules that reference future stages (security, intake, quota) check for the
  presence of the relevant state files before matching. If the file doesn't
  exist (stage not implemented yet), the rule silently returns 1 (no match).
  This makes --diagnose forward-compatible without code changes when new
  stages are added.

Files to modify:
- `tekhton.sh` — Add `--diagnose` flag handling. When set:
  1. Source lib/diagnose.sh and lib/diagnose_rules.sh
  2. Call `_read_diagnostic_context()`
  3. Call `classify_failure()`
  4. Call `generate_diagnosis_report()` → DIAGNOSIS.md
  5. Call `print_diagnosis_summary()` → terminal output
  6. Exit (do not run pipeline)
  Also: at the end of ANY failed pipeline run, automatically print a one-liner:
  "Run 'tekhton --diagnose' for recovery suggestions."

- `lib/finalize.sh` — After a failed run, append the diagnose hint to the
  completion banner. Also write a LAST_FAILURE_CONTEXT.json with the failure
  classification and stage for --diagnose to consume quickly without re-parsing
  all state files.

- `lib/finalize_display.sh` — Add diagnose hint to failure banner output.

- `lib/dashboard.sh` — Add `emit_dashboard_diagnosis()`. Reads DIAGNOSIS.md
  and generates `data/diagnosis.js` with `window.TK_DIAGNOSIS = { ... }`.
  Watchtower Live Run tab shows diagnosis card when a failure is detected.

- `lib/state.sh` — Add LAST_FAILURE_CONTEXT path to session state management.

Acceptance criteria:
- `tekhton --diagnose` reads causal log + pipeline state and prints recovery suggestions
- DIAGNOSIS.md generated with causal chain, failure classification, suggestions, and commands
- When causal log exists: DIAGNOSIS.md includes a "Cause Chain" section tracing
  from the terminal failure back to its root cause event
- When causal log is absent: falls back gracefully to state-file-only diagnosis
  (no errors, just omits the cause chain section)
- All 10 diagnostic rules correctly identify their failure patterns
- Rules for future stages (security, intake, quota) are no-ops when those
  stages don't exist yet — no errors, no false matches
- Failed pipeline runs print "Run 'tekhton --diagnose' for recovery suggestions"
- Terminal output is colored and formatted for readability
- Terminal summary includes one-line cause chain when causal log available
- Each suggestion includes an exact command the user can copy-paste
- Recurring failure detection uses `recurring_pattern()` from causal log when
  available; falls back to reading LAST_FAILURE_CONTEXT files if no causal log.
  If the same failure type occurred in the last 3 runs, the diagnosis notes it.
- LAST_FAILURE_CONTEXT.json written on failure for fast --diagnose startup
- --diagnose works even if no pipeline has ever run (prints "No runs found")
- --diagnose works on resumed/interrupted pipelines (reads partial state)
- Dashboard data emitted when Watchtower is enabled
- All existing tests pass
- `bash -n lib/diagnose.sh lib/diagnose_rules.sh` passes
- `shellcheck lib/diagnose.sh lib/diagnose_rules.sh` passes
- New test file `tests/test_diagnose.sh` covers: each rule against fixture
  state, rule priority ordering, causal chain rendering from fixture causal logs,
  graceful fallback when causal log absent, recurring failure detection (both
  causal log and LAST_FAILURE_CONTEXT paths), terminal output formatting

Watch For:
- Rule priority matters. BUILD_FAILURE must be checked before STUCK_LOOP
  because a stuck loop caused by build failures should give build-specific
  advice, not generic stuck-loop advice. The causal chain often reveals this
  naturally (a stuck loop caused by build failures will have build_gate.fail
  in the chain), but the rule priority is still needed for the terminal summary
  classification label.
- Agent log tails (last 20 lines) may contain useful error context but could
  also contain noise. Only include them in the full DIAGNOSIS.md, not in the
  terminal summary.
- LAST_FAILURE_CONTEXT.json must be written atomically (tmpfile + mv) and
  must survive pipeline crashes (write it in a trap handler or early in the
  finalize sequence).
- The forward-compat pattern (check for file existence before matching) means
  --diagnose never needs updating when new stages land. The new stage just
  needs to emit events to the causal log (which it will, via M13's emit_event).
- Don't over-diagnose. If the pipeline succeeded, --diagnose should say
  "Last run completed successfully. No issues found." Not every run needs
  recovery suggestions.
- Recurring failure detection: prefer the causal log's `recurring_pattern()`
  (queries archived CAUSAL_LOG_*.jsonl files) when available. Fall back to
  LAST_FAILURE_CONTEXT files only when no archived causal logs exist. The
  causal log path is more accurate because it counts by event type, not just
  failure classification.
- **Causal chain rendering must be concise.** A 20-event chain is noise, not
  signal. Collapse intermediate events of the same type (e.g., "3 rework_cycles"
  instead of listing each one). Show at most 5 links in the terminal summary;
  the full chain goes in DIAGNOSIS.md.

Seeds Forward:
- M09 (Security) adds security-specific diagnostic rules automatically
  (SECURITY_HALT, SECURITY_REWORK_EXHAUSTED) — causal chain shows which
  finding triggered the halt
- M10 (PM Agent) adds intake-specific rules (INTAKE_NEEDS_CLARITY) — causal
  chain shows which milestone evaluation triggered the pause
- M16 (Autonomous Runtime) adds quota-specific rules (QUOTA_EXHAUSTED) —
  causal chain shows which agent call hit the limit
- Watchtower Live Run tab renders DIAGNOSIS.md content on failure, including
  causal chain visualization
- V4 interactive Watchtower could offer "click to run" recovery commands
- V4 LLM-powered diagnosis: feed the causal log to an agent for natural-language
  post-mortem analysis ("explain what went wrong in this run")
- The rule registry pattern enables plugins: users could add custom diagnostic
  rules via a hook in pipeline.conf
