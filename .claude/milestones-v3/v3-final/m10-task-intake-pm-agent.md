#### Milestone 10: Task Intake / PM Agent (Pre-Stage Gate)
<!-- milestone-meta
id: "10"
status: "done"
-->

A pre-pipeline agent that evaluates task and milestone clarity before committing
pipeline resources. Silently passes or auto-tweaks milestones that are "good enough."
Only escalates to the human when the task is genuinely too ambiguous for a reasonable
judgement call. Configurable clarity threshold in pipeline.conf.

This is NOT a new command — it's a pre-stage in the existing flow that runs before
the Scout. It makes Tekhton accessible to users who have ideas and understand what
they want but don't necessarily write formal acceptance criteria.

Files to create:
- `stages/intake.sh` — `run_stage_intake()`: pre-stage gate before Scout/Coder.
  Reads the current milestone (or raw task string if no milestones). Invokes
  the intake agent to evaluate clarity along dimensions: scope definition,
  testability, acceptance criteria completeness, ambiguity level. Agent produces
  INTAKE_REPORT.md with one of four verdicts:
  (1) PASS — milestone is clear enough, proceed as-is.
  (2) TWEAKED — milestone was unclear but agent made reasonable judgement calls.
  Produces a revised milestone description with changes annotated. Auto-proceeds
  unless INTAKE_CONFIRM_TWEAKS=true.
  (3) SPLIT_RECOMMENDED — task is too large for one milestone. Produces recommended
  sub-milestones that can be added to the DAG. Escalates to human for approval
  (or auto-splits if INTAKE_AUTO_SPLIT=true).
  (4) NEEDS_CLARITY — genuinely ambiguous, cannot make a reasonable call. Produces
  specific questions for the human. Writes to CLARIFICATIONS.md using the existing
  clarification protocol. Pipeline pauses.
  Stage is skipped cleanly when INTAKE_AGENT_ENABLED=false.
- `prompts/intake_scan.prompt.md` — Intake evaluation prompt. Instructs agent to:
  (1) read the milestone file (or task string), (2) read CLAUDE.md for project
  context, (3) read PROJECT_INDEX.md summary if available (for brownfield projects
  where task clarity depends on understanding existing code structure),
  (4) read the INTAKE_HISTORY_BLOCK (when available) — a summary of historical
  verdicts, rework patterns, and causal outcomes for similar milestones, extracted
  from the causal event log by the shell before agent invocation.
  (5) evaluate along a clarity rubric: Is the scope bounded? Are
  acceptance criteria testable? Are there implicit assumptions that need stating?
  Could two competent developers interpret this differently? Does the milestone
  declare its migration impact (new config keys, new .claude/ files, format
  changes)? If the milestone adds user-facing configuration or files and has
  no "Migration impact" section, flag it for addition (TWEAKED or NEEDS_CLARITY
  depending on how much is missing). (6) produce
  INTAKE_REPORT.md with verdict, confidence score (0-100), reasoning, and either
  tweaks, split recommendations, or questions depending on verdict.
  The prompt includes examples of each verdict level to calibrate the agent.
  When INTAKE_HISTORY_BLOCK includes patterns like "milestones with similar scope
  required 3+ rework cycles," the agent should factor this into its confidence
  scoring and may recommend preventive tweaks (tighter acceptance criteria,
  explicit Watch For items).
- `prompts/intake_tweak.prompt.md` — When verdict is TWEAKED, this prompt generates
  the revised milestone content. Instructs agent to: preserve the original intent,
  add missing acceptance criteria, clarify ambiguous scope boundaries, add
  Watch For items if obvious risks exist. Annotates changes with `[PM: ...]`
  markers so the human can see what was adjusted.
- `templates/intake.md` — Intake agent role definition (copied by --init). Defines
  the agent's PM expertise: task decomposition, scope assessment, acceptance
  criteria writing, ambiguity detection. Emphasizes: "Your job is to help, not
  gatekeep. Pass anything that a competent developer could reasonably execute.
  Only pause for genuine ambiguity."

Files to modify:
- `tekhton.sh` — Add `source "${TEKHTON_HOME}/stages/intake.sh"` to source block.
  Insert `run_stage_intake` call BEFORE the architect audit and Scout/Coder stage.
  The intake gate runs once per milestone (not per review cycle). If verdict is
  TWEAKED, update the milestone file in-place (or task string in non-milestone mode)
  before proceeding. If SPLIT_RECOMMENDED and approved, call existing
  `split_milestone()` infrastructure with the agent's recommended splits.
  If NEEDS_CLARITY, enter clarification pause (reuse existing clarification protocol
  from lib/clarify.sh).
  Add `--add-milestone "description"` flag: invokes the intake agent in
  "create" mode — evaluates the description, scopes it, writes a milestone
  file to MILESTONE_DIR, appends a row to MANIFEST.cfg, and exits. No
  pipeline run. This gives users a CLI path to add milestones to the DAG
  without running --replan. The intake agent applies the same clarity rubric
  and may TWEAK or ask for clarity before committing the milestone.
- `lib/config_defaults.sh` — Add intake agent config defaults:
  INTAKE_AGENT_ENABLED=true (opt-out, like security),
  CLAUDE_INTAKE_MODEL=opus (intake is a judgement call — use best model),
  INTAKE_MAX_TURNS=10 (should be fast — reading + evaluating, not coding),
  INTAKE_CLARITY_THRESHOLD=40 (confidence score below this → NEEDS_CLARITY),
  INTAKE_TWEAK_THRESHOLD=70 (confidence score below this but above clarity
  threshold → TWEAKED; above this → PASS),
  INTAKE_CONFIRM_TWEAKS=false (when true, pause for human to review tweaks
  before proceeding; when false, auto-proceed with tweaks),
  INTAKE_AUTO_SPLIT=false (when true, auto-add recommended splits to DAG
  without human approval),
  INTAKE_ROLE_FILE=.claude/agents/intake.md,
  INTAKE_REPORT_FILE=INTAKE_REPORT.md.
- `lib/config.sh` — Add INTAKE_* keys to config validation. Validate
  INTAKE_CLARITY_THRESHOLD is 0-100, INTAKE_TWEAK_THRESHOLD is 0-100 and
  greater than INTAKE_CLARITY_THRESHOLD. Validate model is valid.
- `lib/state.sh` — Add "intake" as valid pipeline stage for state persistence.
  Support `--start-at intake`. Intake results cached — re-running after a tweak
  does not re-evaluate the same milestone (uses a hash of milestone content).
  When verdict is TWEAKED in non-milestone mode, write tweaked task to
  `${TEKHTON_SESSION_DIR}/INTAKE_TWEAKED_TASK.md` so resume picks up the
  tweaked version instead of the original CLI argument.
- `lib/milestone_ops.sh` — When intake produces TWEAKED verdict, update the
  milestone file content and add a `<!-- PM-tweaked: YYYY-MM-DD -->` metadata
  comment so the human and dashboard can see what was adjusted.
- `lib/hooks.sh` or `lib/finalize.sh` — Include INTAKE_REPORT.md in archive.
  Include intake verdict and any tweaks in RUN_SUMMARY.json.
- `lib/prompts.sh` — Register INTAKE_REPORT_CONTENT, INTAKE_TWEAKS_BLOCK,
  INTAKE_HISTORY_BLOCK template variables. INTAKE_HISTORY_BLOCK is populated by
  querying the causal event log (when available via M13's lib/causality.sh):
  ```bash
  if type verdict_history &>/dev/null; then
      INTAKE_HISTORY_BLOCK=$(verdict_history "intake" 10)
      # Also include: rework cycle counts for recent milestones,
      # split frequency, common failure patterns
      local rework_data
      rework_data=$(events_by_type "rework_cycle" 10)
      INTAKE_HISTORY_BLOCK+=$'\n'"Rework patterns: ${rework_data}"
  fi
  ```
  When lib/causality.sh is not available (pre-M13 builds, CAUSAL_LOG_ENABLED=false),
  INTAKE_HISTORY_BLOCK is empty and the conditional block in the prompt is skipped.
- `lib/orchestrate.sh` — In --complete mode, `run_stage_intake` is called once
  per milestone iteration, not once at pipeline start. Each milestone in the
  frontier gets its own intake evaluation. This ensures auto-advanced milestones
  also get clarity checking.
- `lib/metrics.sh` — Record intake verdicts and confidence scores in run metrics.
  Fields: intake_verdict, intake_confidence, intake_tweaks_applied (boolean),
  intake_questions_asked (count). Used for threshold calibration over time.
- `prompts/scout.prompt.md` — Add optional context block:
  `{{IF:INTAKE_TWEAKS_BLOCK}}## PM Agent Notes{{INTAKE_TWEAKS_BLOCK}}
  {{ENDIF:INTAKE_TWEAKS_BLOCK}}`
  So the scout sees any scope clarifications the intake agent made.

Acceptance criteria:
- `run_stage_intake()` evaluates current milestone/task and produces INTAKE_REPORT.md
- INTAKE_REPORT.md contains: verdict (PASS|TWEAKED|SPLIT_RECOMMENDED|NEEDS_CLARITY),
  confidence score (0-100), reasoning, and verdict-specific payload
- Verdict PASS → pipeline proceeds immediately, no user interaction
- Verdict TWEAKED → milestone file updated with annotated changes, pipeline proceeds
  (or pauses if INTAKE_CONFIRM_TWEAKS=true)
- Verdict SPLIT_RECOMMENDED → recommended sub-milestones presented, pipeline pauses
  for human approval (or auto-splits if INTAKE_AUTO_SPLIT=true)
- `tekhton --add-milestone "description"` creates a scoped milestone file + manifest
  entry using the intake agent in create mode, without running the pipeline
- Verdict NEEDS_CLARITY → specific questions written to CLARIFICATIONS.md, pipeline
  pauses using existing clarification protocol
- When INTAKE_AGENT_ENABLED=false, stage is cleanly skipped
- Intake does NOT re-evaluate a milestone whose content hash hasn't changed since
  last evaluation (avoids noise on resume)
- `[PM: ...]` annotations in tweaked milestones are visible in milestone files
- Scout prompt includes PM notes when tweaks were made
- Intake verdict and tweaks included in RUN_SUMMARY.json
- Two separate thresholds: INTAKE_CLARITY_THRESHOLD and INTAKE_TWEAK_THRESHOLD
  are independently configurable; lowering clarity threshold makes gate more permissive
- Tweaked task string persists to session dir for resume in non-milestone mode
- In --complete mode, intake runs once per milestone (not once per pipeline start)
- Intake verdict and confidence scores recorded in run metrics
- Intake agent reads PROJECT_INDEX.md when available for project context
- When causal log is available (M13): INTAKE_HISTORY_BLOCK injected into prompt
  with historical verdict distribution, rework cycle averages, and split frequency
- When causal log is unavailable: INTAKE_HISTORY_BLOCK is empty, prompt
  conditional block skipped, no errors
- All existing tests pass
- `bash -n stages/intake.sh` passes
- `shellcheck stages/intake.sh` passes

Watch For:
- The intake agent MUST default to PASS for well-scoped milestones. Calibrate the
  prompt examples heavily toward PASS verdicts with a few TWEAKED examples. The
  agent should feel like a helpful colleague, not a bureaucratic gate.
- Confidence score thresholds (40/70 defaults) will need tuning. The initial values
  are conservative — expect adjustment after real-world usage. Log the scores to
  metrics so we can calibrate.
- TWEAKED milestone writes must use atomic tmpfile+mv pattern (same as manifest writes).
- In non-milestone mode (raw task string), tweaks modify the TASK variable in memory
  and log the original vs tweaked task. No file to update.
- The content hash for skip-on-resume should use `sha256sum` of the milestone file
  content (or task string). Store in session dir, not in the milestone file itself.
- SPLIT_RECOMMENDED integrates with the existing `split_milestone()` infrastructure
  from M01. The intake agent's recommended splits must match the format that
  `split_milestone()` expects.
- The opus model default for intake is intentional — this is a judgement call stage
  where model quality directly affects user experience. It runs once per milestone,
  so the cost is bounded.
- Monorepo support: the intake agent should note when a task seems to span multiple
  project boundaries but should NOT try to solve the monorepo problem itself. That's
  a separate V4 concern. For now, it flags it as a NEEDS_CLARITY question.

Seeds Forward:
- Dashboard UI will show intake verdicts, tweaks, and confidence scores
- Brownfield 2.0 init can use the intake agent to evaluate auto-generated milestones
- The confidence scoring pattern is reusable for other quality gates
- PM tweak annotations create an audit trail for milestone evolution
- The causal log integration means the PM agent improves over time — it learns
  from the project's history of what kinds of milestones succeed vs need rework.
  This is the first agent in Tekhton that consumes structured pipeline memory
  rather than just reading static config.
- V4: intake agent could correlate its confidence scores with actual outcomes
  (causal log tracks whether a PASS milestone actually passed without rework)
  to self-calibrate the INTAKE_CLARITY_THRESHOLD and INTAKE_TWEAK_THRESHOLD
