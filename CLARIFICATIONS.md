
# Intake Clarifications — 2026-03-23 23:22:36

- What is the "Watchtower dashboard"? Is it a Tekhton component, an optional add-on, or part of a target project? Where is it defined in the codebase?
- Which specific static UI files are expected to be present in `.claude/dashboard/`? (e.g., `index.html`, `dashboard.js`, asset bundles — list them)
- How should these files get there? Options: (a) checked into the repo, (b) copied by `tekhton.sh` or an init step, (c) generated at startup, (d) output of a build process.
- What is the current failure mode? When are the files missing — on fresh clone, after `--init`, after a pipeline run, or in some other scenario?
- Is `.claude/dashboard/` already in `.gitignore`, and is that part of the problem?


# Clarifications — 2026-03-23 23:22:36

## Q: What is the "Watchtower dashboard"? Is it a Tekhton component, an optional add-on, or part of a target project? Where is it defined in the codebase?
**A:** What is the "Watchtower dashboard"? Is it a Tekhton component, an optional add-on, or part of a target project? Where is it defined in the codebase?

## Q: Which specific static UI files are expected to be present in `.claude/dashboard/`? (e.g., `index.html`, `dashboard.js`, asset bundles — list them)
**A:** What is the "Watchtower dashboard"? Is it a Tekhton component, an optional add-on, or part of a target project? Where is it defined in the codebase?

## Q: How should these files get there? Options: (a) checked into the repo, (b) copied by `tekhton.sh` or an init step, (c) generated at startup, (d) output of a build process.
**A:** What is the "Watchtower dashboard"? Is it a Tekhton component, an optional add-on, or part of a target project? Where is it defined in the codebase?

## Q: What is the current failure mode? When are the files missing — on fresh clone, after `--init`, after a pipeline run, or in some other scenario?
**A:** What is the "Watchtower dashboard"? Is it a Tekhton component, an optional add-on, or part of a target project? Where is it defined in the codebase?

## Q: Is `.claude/dashboard/` already in `.gitignore`, and is that part of the problem?
**A:** What is the "Watchtower dashboard"? Is it a Tekhton component, an optional add-on, or part of a target project? Where is it defined in the codebase?


# Intake Clarifications — 2026-03-23 23:36:49

- What is `NON_BLOCKING_LOG`? Is it a file in the project directory (e.g., `.claude/logs/NON_BLOCKING.log` or similar), a section in an existing log file, or output from a pipeline run?
- What items are currently in the log? Please paste the current contents so the scope can be assessed.
- What does "resolved" mean for each item type — is it a code fix, a config change, a suppression with rationale, or something else?
- If the log contains heterogeneous items (e.g., shellcheck warnings, missing config defaults, runtime edge cases), should they all be addressed in one milestone or split by concern?


# Clarifications — 2026-03-23 23:36:49

## Q: What is `NON_BLOCKING_LOG`? Is it a file in the project directory (e.g., `.claude/logs/NON_BLOCKING.log` or similar), a section in an existing log file, or output from a pipeline run?
**A:** What is `NON_BLOCKING_LOG`? Is it a file in the project directory (e.g., `.claude/logs/NON_BLOCKING.log` or similar), a section in an existing log file, or output from a pipeline run?

## Q: What items are currently in the log? Please paste the current contents so the scope can be assessed.
**A:** What is `NON_BLOCKING_LOG`? Is it a file in the project directory (e.g., `.claude/logs/NON_BLOCKING.log` or similar), a section in an existing log file, or output from a pipeline run?

## Q: What does "resolved" mean for each item type — is it a code fix, a config change, a suppression with rationale, or something else?
**A:** What is `NON_BLOCKING_LOG`? Is it a file in the project directory (e.g., `.claude/logs/NON_BLOCKING.log` or similar), a section in an existing log file, or output from a pipeline run?

## Q: If the log contains heterogeneous items (e.g., shellcheck warnings, missing config defaults, runtime edge cases), should they all be addressed in one milestone or split by concern?
**A:** What is `NON_BLOCKING_LOG`? Is it a file in the project directory (e.g., `.claude/logs/NON_BLOCKING.log` or similar), a section in an existing log file, or output from a pipeline run?


# Intake Clarifications — 2026-04-02 11:06:24

## Q: What specific behavior constitutes the "circular" flow? (e.g., `--init` loops back to re-ask questions already answered, greenfield path incorrectly routes to brownfield instructions, synthesis agent re-triggers crawl, config is regenerated on re-run)

## Q: Which code path exhibits the bug — the crawl/detect phase, the synthesis agent, the config emitters, or the prompts themselves?

## Q: What is the expected behavior after the fix? (e.g., `--init` completes in a single pass, brownfield and greenfield prompts never co-appear, a specific flag or state variable gates the path)

## Q: Are there specific files or functions known to be involved (e.g., `lib/init.sh`, `stages/init_synthesize.sh`, a particular prompt template)?

## Q: Is there a reproduction case — e.g., "run `--init` on a repo with an existing CLAUDE.md and observe X"?


# Clarifications — 2026-04-02 11:06:24

## Q: What specific behavior constitutes the "circular" flow? (e.g., `--init` loops back to re-ask questions already answered, greenfield path incorrectly routes to brownfield instructions, synthesis agent re-triggers crawl, config is regenerated on re-run)
**A:** When you drop Tekhton into a project and run either --init or --plan after it's run it tells you to run the other. Ideally in a greenfield setup you would run --plan then --init and then you'd run tasks. In Brownfield you would run --init then --plan-from-index and then run tasks and then there's --init --full to do an init with synthesis in one shot followed by tasks. Having one step tell you to do the other is confusing to the end user if they've already run that step previously.

## Q: Which code path exhibits the bug — the crawl/detect phase, the synthesis agent, the config emitters, or the prompts themselves?
**A:** It shows up in the recommended next steps section. The pipeline should feel very clear to the user to use. You follow the readme, it leads you from one step to the next, you then have your necessary files generated and you start completing tasks.

## Q: What is the expected behavior after the fix? (e.g., `--init` completes in a single pass, brownfield and greenfield prompts never co-appear, a specific flag or state variable gates the path)
**A:** I think it would be better to have tekhton --init determine what comes next. ith init as it's the initialization whether green or brown. From that point it should determine and tell you what to do next. Either it realizes it's a greenfield project and asks you to run --plan or it's a brownfield project and it needs to detect context first then build out the necessary files (DESIGN, CLAUDE, Milestones, etc). So either we need a pre-init phase or we need to make it clearer. Right now it's very confusing to determine whether plan or init should be run first and which should be run second. Logically consider how confusing that is. This needs to be simple for new developers to use.

## Q: Are there specific files or functions known to be involved (e.g., `lib/init.sh`, `stages/init_synthesize.sh`, a particular prompt template)?
**A:** Probably live/plan.sh, lib/init.sh as the biggest functions involved but those may lead to more adjacent files.

## Q: Is there a reproduction case — e.g., "run `--init` on a repo with an existing CLAUDE.md and observe X"?
**A:** If you run either --init or --plan regardless of the state of the repo it will then tell you to run the other. You can reproduce this and just keep running one after the other again and again.

