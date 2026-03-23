#### Milestone 9: Security Agent Stage & Finding Classification
Dedicated security review stage that scans coder output for vulnerabilities,
classifies findings by severity and fixability, and produces a structured
SECURITY_REPORT.md. Runs after the build gate, before the reviewer. Enabled
by default (opt-out via SECURITY_AGENT_ENABLED=false).

Seeds Forward (V4): When parallel execution lands, this stage transitions from
serial (after coder, before reviewer) to parallel (alongside reviewer with
merged findings). The data model and report format are designed to support both
execution modes without changes.

Files to create:
- `stages/security.sh` — `run_stage_security()`: invoke security agent, parse
  SECURITY_REPORT.md output, classify findings by severity (CRITICAL/HIGH/MEDIUM/LOW),
  route fixable CRITICAL/HIGH findings to security rework loop (bounded by
  SECURITY_MAX_REWORK_CYCLES), route unfixable findings per SECURITY_UNFIXABLE_POLICY
  (escalate → HUMAN_ACTION_REQUIRED.md, halt → pipeline exit, waiver → log and continue).
  MEDIUM/LOW findings written to SECURITY_NOTES.md for reviewer context. Stage skipped
  cleanly when SECURITY_AGENT_ENABLED=false.
  **Fast-path skip:** Before invoking the agent, parse CODER_SUMMARY.md for changed
  file types. If ALL changed files are docs-only (.md, .txt, .rst), config-only
  (.json, .yaml, .toml without code), or asset-only (images, fonts), skip the
  security scan entirely with a log message. This avoids wasting turns on trivial
  changes like README edits or config formatting.
  **Post-rework build gate:** After each security rework cycle, re-run the build
  gate (same as after review rework). A security fix that breaks the build must be
  caught before re-scanning. Flow: security finding → coder rework → build gate →
  re-scan (or proceed if max cycles reached).
- `prompts/security_scan.prompt.md` — Security scan prompt template. Instructs agent to:
  (1) read CODER_SUMMARY.md for changed files, (2) read only those files,
  (3) analyze for OWASP Top 10, injection, auth flaws, secrets exposure, insecure
  dependencies, crypto misuse, (4) produce SECURITY_REPORT.md with structured format:
  each finding has severity (CRITICAL/HIGH/MEDIUM/LOW), category (OWASP ID or custom),
  file:line, description, fixable (yes/no/unknown), and suggested fix.
  Includes static rule reference section for offline operation.
  When SECURITY_ONLINE_SOURCES is available, instructs agent to cross-reference
  known CVE databases and dependency advisories.
- `prompts/security_rework.prompt.md` — Security rework prompt for coder. Injects
  fixable CRITICAL/HIGH findings from SECURITY_REPORT.md as mandatory fixes.
  Structured like coder_rework.prompt.md: read the finding, read the file, fix it,
  verify the fix doesn't introduce new issues.
- `templates/security.md` — Security agent role definition (copied to target project
  by --init). Defines the agent's security expertise, review methodology, and
  output format expectations. Includes static reference material for common
  vulnerability patterns organized by language/framework.

Files to modify:
- `tekhton.sh` — Add `source "${TEKHTON_HOME}/stages/security.sh"` to the stage
  source block. Insert `run_stage_security` call between the build gate (end of
  Stage 1) and `run_stage_review` (Stage 2). Update `--start-at` handling to
  support `--start-at security` for resuming from security stage. Update stage
  numbering in headers: Stage 1 Coder, Stage 2 Security, Stage 3 Reviewer,
  Stage 4 Tester. Add `--skip-security` flag for one-off bypass.
- `lib/config_defaults.sh` — Add security agent config defaults:
  SECURITY_AGENT_ENABLED=true (opt-out model), CLAUDE_SECURITY_MODEL (defaults to
  CLAUDE_STANDARD_MODEL), SECURITY_MAX_TURNS=15, SECURITY_MIN_TURNS=8,
  SECURITY_MAX_TURNS_CAP=30, SECURITY_MAX_REWORK_CYCLES=2,
  MILESTONE_SECURITY_MAX_TURNS=$(( SECURITY_MAX_TURNS * 2 )),
  SECURITY_BLOCK_SEVERITY=HIGH (minimum severity triggering rework),
  SECURITY_UNFIXABLE_POLICY=escalate (escalate|halt|waiver),
  SECURITY_OFFLINE_MODE=auto (auto|offline|online — auto detects connectivity),
  SECURITY_ONLINE_SOURCES="" (optional: snyk, nvd, ghsa),
  SECURITY_ROLE_FILE=.claude/agents/security.md,
  SECURITY_NOTES_FILE=SECURITY_NOTES.md,
  SECURITY_REPORT_FILE=SECURITY_REPORT.md,
  SECURITY_WAIVER_FILE="" (optional path to pre-approved waivers list).
- `lib/config.sh` — Add SECURITY_* keys to config validation. Validate
  SECURITY_UNFIXABLE_POLICY is one of escalate|halt|waiver. Validate
  SECURITY_BLOCK_SEVERITY is one of CRITICAL|HIGH|MEDIUM|LOW.
- `lib/hooks.sh` or `lib/finalize.sh` — Include SECURITY_NOTES.md and
  SECURITY_REPORT.md in archive step. Include security findings summary in
  RUN_SUMMARY.json.
- `lib/prompts.sh` — Register new template variables: SECURITY_REPORT_CONTENT,
  SECURITY_NOTES_CONTENT, SECURITY_FINDINGS_BLOCK (summary of findings for
  reviewer injection), SECURITY_FIXES_BLOCK (summary of security fixes applied
  during rework, for tester awareness).
- `prompts/tester.prompt.md` — Add conditional security fixes block:
  `{{IF:SECURITY_FIXES_BLOCK}}## Security Fixes Applied
  The following security issues were fixed during this run. Ensure your tests
  cover the fix behavior (e.g., input validation, auth checks).
  {{SECURITY_FIXES_BLOCK}}{{ENDIF:SECURITY_FIXES_BLOCK}}`
- `prompts/reviewer.prompt.md` — Add conditional security context block:
  `{{IF:SECURITY_FINDINGS_BLOCK}}## Security Findings (from Security Agent)
  {{SECURITY_FINDINGS_BLOCK}}{{ENDIF:SECURITY_FINDINGS_BLOCK}}`
  Instructs reviewer to treat CRITICAL/HIGH unfixed items as context for their
  own review but not to duplicate the security agent's work.
- `lib/state.sh` — Add "security" as valid pipeline stage for state persistence
  and resume. Support `--start-at security`.

Acceptance criteria:
- `run_stage_security()` invokes security agent and produces SECURITY_REPORT.md
- SECURITY_REPORT.md contains structured findings with severity, category, file:line,
  fixable flag, and suggested fix for each finding
- Findings classified as CRITICAL or HIGH (configurable via SECURITY_BLOCK_SEVERITY)
  with fixable=yes trigger rework loop back to coder
- Rework loop bounded by SECURITY_MAX_REWORK_CYCLES (default 2) — exhaustion
  proceeds to reviewer with unfixed items in SECURITY_NOTES.md
- Findings classified as unfixable + CRITICAL/HIGH follow SECURITY_UNFIXABLE_POLICY:
  escalate writes to HUMAN_ACTION_REQUIRED.md and continues, halt exits pipeline,
  waiver logs to SECURITY_NOTES.md and continues
- MEDIUM/LOW findings always go to SECURITY_NOTES.md (never trigger rework)
- Reviewer prompt includes SECURITY_FINDINGS_BLOCK when findings exist
- When SECURITY_AGENT_ENABLED=false, stage is cleanly skipped (no error, no output)
- When SECURITY_OFFLINE_MODE=auto and no connectivity, agent uses static rules only
- `--start-at security` resumes pipeline from security stage
- `--skip-security` bypasses security stage for a single run
- Pipeline state saves/restores correctly through security stage
- Stage numbering updated throughout: Coder(1), Security(2), Review(3), Test(4)
- Fast-path skip: docs-only / config-only / asset-only changes skip security scan
- Post-rework build gate: build gate runs after each security rework cycle
- Tester prompt includes SECURITY_FIXES_BLOCK when security fixes were applied
- Dynamic turns: SECURITY_MIN_TURNS and SECURITY_MAX_TURNS_CAP respected
- Milestone mode: MILESTONE_SECURITY_MAX_TURNS used when --milestone active
- All existing tests pass
- `bash -n stages/security.sh` passes
- `shellcheck stages/security.sh` passes

Watch For:
- Stage renumbering from 3 to 4 stages affects header output, progress tracking,
  and any hardcoded "Stage N / 3" strings. Grep for "/ 3" in all stages.
- The rework loop in security mirrors the review rework loop but routes to a
  DIFFERENT prompt (security_rework vs coder_rework). The coder needs to understand
  it's fixing security issues, not review feedback.
- SECURITY_REPORT.md parsing must be robust — the agent may not perfectly follow
  the format. Use the same grep-based verdict extraction pattern as review.sh.
- The `--start-at` chain must be updated: coder → security → review → test.
  Skipping to review should also skip security. Skipping to security should
  require CODER_SUMMARY.md to exist.
- SECURITY_WAIVER_FILE is optional — when provided, known-waivered CVEs/patterns
  should not trigger rework. This is a simple grep-based check, not a full
  policy engine.
- The security agent role file (templates/security.md) needs to be comprehensive
  enough to work offline but not so large it wastes context. Target ~200 lines
  covering the most common vulnerability patterns.

Seeds Forward:
- M10 (PM Agent) can reference security posture when evaluating task readiness
- Dashboard UI will render SECURITY_REPORT.md findings in a dedicated panel
- V4 parallel execution converts this from serial to parallel-with-reviewer
- The SECURITY_WAIVER_FILE pattern is reusable for other policy-driven gates
- SECURITY_NOTES.md feeds into the future Tech Debt Agent's backlog
