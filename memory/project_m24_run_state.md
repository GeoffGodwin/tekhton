---
name: project-m24-run-state
description: M23/M24 pipeline run state - M23 reverted to todo after failed M24 coder run; Notes Port not implemented
metadata:
  type: project
---

M23 (TUI Ops Port) was marked done in commit b17436a, but the M24 coder run failed to implement the Notes Port (no internal/notes/ package was created). The pipeline synthesized CODER_SUMMARY.md and REVIEWER_REPORT.md from git state. Only VERSION was bumped (4.23.1 -> 4.23.3).

**Why:** The coder agent ran for 3 agent calls (2938s) but produced no implementation code for M24. The MANIFEST.cfg was subsequently reverted to mark M23 as todo again (pipeline reset), meaning M23 will be re-run.

**How to apply:** When M23/M24 come up again, note that the actual TUI ops implementation (internal/tui/ops.go, pause.go, substage.go, builder.go, liveness.go, state.go; cmd/tekhton/tui.go) was never implemented — only sidecar.go (from M19) and status.go exist. The post-M23 fix to lib/project_version_bump.sh (MINOR regression guard) was implemented and tests were added.
