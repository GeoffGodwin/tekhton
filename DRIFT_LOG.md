# Drift Log

## Metadata
- Last audit: 2026-03-19
- Runs since audit: 1

## Unresolved Observations
- [2026-03-19 | "Implement Milestone 14: Turn Exhaustion Continuation Loop"] Both the Sr Coder and Jr Coder touched the `agent_monitor.sh` header (lines 3-4). Sr Coder updated it as part of the extraction; Jr Coder confirmed it was already correct. No double-write conflict occurred — final state is correct. This is expected coordination when Simplification and Staleness items touch the same file, not a process concern.
- [2026-03-19 | "Implement Milestone 14: Turn Exhaustion Continuation Loop"] --
- [2026-03-19 | "Implement Milestone 13.2.1: "] `stages/tester.sh:101` — the pipeline `grep ... | tee -a "$LOG_FILE"` appends grep output to the log. If `$LOG_FILE` is the same file already being written by `run_agent`, this can produce duplicate entries. Not introduced by this milestone but worth flagging for the audit log.
- [2026-03-18 | "Finish implementing Milestone 13.2.1: Core Retry Envelope in run_agent()"] `lib/config.sh` is 342 lines — exceeds the 300-line ceiling. Pre-existing issue, no changes to scope in this rework. Candidate for a future `lib/config_defaults.sh` extraction.
- [2026-03-18 | "Finish implementing Milestone 13.2.1: Core Retry Envelope in run_agent()"] --
- [2026-03-18 | "Implement Milestone 13.2.1: Core Retry Envelope in run_agent()"] `lib/agent_monitor.sh` remains well over 300 lines. Pre-existing, noted in prior review. Warrants a future split.
- [2026-03-18 | "Implement Milestone 13.2.1: Core Retry Envelope in run_agent()"] --
- [2026-03-18 | "Continue Implementing Milestone 13.1: Retry Infrastructure — Config, Reporting, and Monitoring Reset"] `lib/agent_monitor.sh:211` — The activity-timeout kill sequence inside the FIFO reader subshell uses `kill "$_TEKHTON_AGENT_PID"` directly, but the outer `_run_agent_abort` trap already does the same. These two kill paths are logically duplicated. Not a bug — the subshell can't reach the trap — but worth a comment explaining why the inner kill is necessary.
- [2026-03-18 | "Continue Implementing Milestone 13.1: Retry Infrastructure — Config, Reporting, and Monitoring Reset"] `lib/common.sh:61-65` — `_print_box_line` falls back to a bare `echo "${_bv}"` (no padding, no right border) when `printf` fails. On any system where printf is absent the empty-line rendering will be visually broken. The same fallback pattern exists in the content branch. Low likelihood in practice.
- [2026-03-18 | "Implement Milestone 13.1: Retry Infrastructure — Config, Reporting, and Monitoring Reset"] `lib/common.sh:77-86` vs `lib/common.sh:132-141`: `_box_line` and `_rbox_line` are nested functions with identical implementations (identical `printf` calls, identical fallback `echo`). The only difference is the name. If a future contributor modifies one without the other, the rendering diverges silently.
(none)

## Resolved
