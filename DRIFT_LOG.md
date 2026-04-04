# Drift Log

## Metadata
- Last audit: 2026-04-03
- Runs since audit: 4

## Unresolved Observations
- [2026-04-03 | "Address all 7 open non-blocking notes in NON_BLOCKING_LOG.md. Fix each item and note what you changed."] `_pf_infer_from_compose` resets `in_ports=0` on encountering a non-list line inside a ports block but does not reset `in_ports` when transitioning to a new service block. In practice this is fine because `in_ports` resets when the outer loop sees the next service line — but subtly fragile if YAML has services with no blank line between them.
- [2026-04-03 | "Address all 7 open non-blocking notes in NON_BLOCKING_LOG.md. Fix each item and note what you changed."] `trap - INT TERM` after `rm -f "$_prompt_file"` in `_call_planning_batch` restores default signal handling globally within the shell, which could mask a SIGINT sent during the spinner teardown window. Negligible in practice.
- [2026-04-03 | "M56"] `preflight.sh` at 618 lines and `preflight_services.sh` at 493 lines — both well above the 300-line ceiling. The pre-flight subsystem now totals ~1,100 lines across two files. If a further M55/M56 check is ever added (e.g., CI service config detection), a third split will be needed.
- [2026-04-03 | "architect audit"] **`lib/error_patterns.sh:119-123` — `cut` fork count performance note** The drift observation itself concludes "No action now" and explicitly states correctness is not in question. The classification body in `load_error_patterns()` executes once per pipeline run with results cached in `_EP_LOADED`; at 52 patterns the cost is not observable. Replacing five `cut` invocations with bash parameter expansion would be premature optimization. The observation recommends revisiting only if the registry grows past ~500 patterns. This item requires no code change at this time. It should remain in the drift log for future consideration if the registry grows significantly.

## Resolved
