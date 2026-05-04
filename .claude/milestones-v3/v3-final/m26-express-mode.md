#### Milestone 26: Express Mode (Zero-Config Execution)
<!-- milestone-meta
id: "26"
status: "done"
-->


Enable Tekhton to run without `--init` by auto-detecting project configuration
and using sensible defaults. When a user runs `tekhton "task"` in a project
with no `.claude/pipeline.conf`, the pipeline silently detects the tech stack,
infers commands, and executes immediately. Config is persisted on completion
so subsequent runs use the detected values.

This is the "try it in 30 seconds" experience. The full `--init` with interview,
synthesis, and milestone planning remains the recommended path for serious projects.
Express mode is for evaluation, one-off tasks, and quick fixes.

Files to create:
- `lib/express.sh` — Express mode orchestration:
  **Detection and config generation:**
  - `detect_express_config($project_dir)` — runs a FAST subset of the M12
    detection engine: language detection, build/test/lint command inference,
    project name from directory name or package manifest. No workspace
    detection, no CI/CD parsing, no doc quality assessment — those are --init
    features. Target: <3 seconds for detection.
  - `generate_express_config()` — builds an in-memory config from detection
    results + conservative defaults: CLAUDE_CODER_MODEL=sonnet,
    SECURITY_AGENT_ENABLED=true, INTAKE_AGENT_ENABLED=true,
    MAX_REVIEW_CYCLES=2, standard turn limits.
  - `persist_express_config($project_dir)` — after successful pipeline
    completion, writes `.claude/pipeline.conf` with auto-detected values,
    section headers, and comments: "# Auto-detected by Tekhton Express Mode.
    # Run 'tekhton --init' for full configuration with planning interview."
    Also writes minimal agent role files from Tekhton templates.
  **Express mode entry point:**
  - `enter_express_mode($project_dir, $task)` — called from tekhton.sh when
    no pipeline.conf exists. Runs detection, generates config, sets all
    pipeline variables in memory, then returns control to the normal pipeline
    flow. The rest of the pipeline (scout, coder, security, review, test)
    runs identically to configured mode.

- `templates/express_pipeline.conf` — Template for the auto-generated config
  file. Includes all section headers (Essential, Models, Pipeline Behavior,
  Security, Features, Quotas) with detected values filled in and descriptive
  comments. VERIFY markers on low-confidence detections.

Files to modify:
- `tekhton.sh` — At startup, after checking for pipeline.conf:
  If pipeline.conf not found AND TEKHTON_EXPRESS_ENABLED != false:
    Print: "No pipeline.conf found. Running in Express Mode (auto-detected config)."
    Print: "For full configuration, run: tekhton --init"
    Call `enter_express_mode()`
  If pipeline.conf not found AND TEKHTON_EXPRESS_ENABLED == false:
    Error and exit with current behavior (tell user to run --init)
  Source lib/express.sh.

- `lib/agent.sh` (or agent role resolution) — When agent role file
  (e.g., `.claude/agents/coder.md`) doesn't exist in the project, fall back
  to `${TEKHTON_HOME}/templates/coder.md` (the built-in template). This is
  a one-line change in the role file resolution path. Log: "Using built-in
  role template for [agent] (no project-specific role file found)."

- `lib/config_defaults.sh` — Add:
  TEKHTON_EXPRESS_ENABLED=true (can be disabled globally in ~/.tekhton/config
  for users who always want explicit --init),
  EXPRESS_PERSIST_CONFIG=true (write config on completion),
  EXPRESS_PERSIST_ROLES=false (don't copy role files by default — use
  built-in templates until user runs --init).

- `lib/config.sh` — Handle the case where config is generated in-memory
  (not loaded from file). The validation path must work for both file-loaded
  and express-generated configs.

- `lib/detect.sh` / `lib/detect_commands.sh` — Ensure the detection functions
  can be called independently (not just from --init flow). They should already
  be modular from M12, but verify no --init-specific state is required.

- `lib/finalize.sh` — After successful pipeline completion in express mode,
  call `persist_express_config()` if EXPRESS_PERSIST_CONFIG=true. Print:
  "Express config saved to .claude/pipeline.conf. Edit to customize."

Acceptance criteria:
- `tekhton "task"` works in a project with no .claude/ directory at all
- Detection runs in <3 seconds for typical projects
- Pipeline executes identically to a configured project (same stages, same
  agents, same gates)
- On completion, .claude/pipeline.conf is written with detected values
- Subsequent runs use the persisted config (no re-detection)
- Agent role files fall back to built-in templates when project-local files
  don't exist
- Express mode prints clear banner explaining what's happening and how to
  get full config
- TEKHTON_EXPRESS_ENABLED=false restores current behavior (error without --init)
- EXPRESS_PERSIST_CONFIG=false skips config persistence (truly ephemeral mode)
- Express mode works for: Node.js, Python, Go, Rust, Java, Ruby, C#, shell
  projects (all languages M12 detection supports)
- Detection failures (unknown language, no build command found) result in
  conservative defaults, not errors — the pipeline should still run
- All existing tests pass
- `bash -n lib/express.sh` passes
- `shellcheck lib/express.sh` passes

Watch For:
- Express mode must NOT run the full M12 detection suite (workspaces, CI/CD,
  services, doc quality). That's heavyweight and belongs in --init. Express
  runs the fast subset: language, build cmd, test cmd, lint cmd, project name.
- The config persistence must not overwrite an existing pipeline.conf. If the
  user ran --init between the express run and the next run (unlikely but
  possible), the --init config takes precedence.
- Agent role file fallback must be clearly logged so users understand why
  their agent behavior might differ from a fully configured project.
- Express mode should set PIPELINE_STATE so it's resumable. If the user
  interrupts and re-runs, it should resume, not re-detect.
- The in-memory config must be complete enough that ALL pipeline code paths
  work. Any config key that's read but not set will cause `set -u` to fail.
  The express config generator must set every key that config_defaults.sh sets.

Seeds Forward:
- The role file fallback (built-in templates when no project file) is reusable
  by --init for showing users what the defaults look like before customization
- Express config persistence is the starting point for --init --quick (Tier 1)
  which adds detection report and interactive confirmation
- The fast detection subset could be used by --diagnose to verify config
  matches actual project state
- V4 multi-platform support can use express mode as the common entry point
  across all platforms

Migration impact:
- New config keys: TEKHTON_EXPRESS_ENABLED, EXPRESS_PERSIST_CONFIG, EXPRESS_PERSIST_ROLES
- New files in .claude/: None (express mode creates pipeline.conf only on completion)
- Modified file formats: None
- Breaking changes: Projects without pipeline.conf now run instead of erroring
  (behavior change, but additive — old behavior available via TEKHTON_EXPRESS_ENABLED=false)
- Migration script update required: NO — express mode is auto-detected, not configured
