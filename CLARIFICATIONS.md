
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

