# Reviewer Report — M56: Service Readiness Probing

## Verdict
APPROVED_WITH_NOTES

## ACP Verdicts
- ACP: Extract service logic to `lib/preflight_services.sh` — ACCEPT — `preflight.sh` was already 607 lines; extraction follows the established module-splitting pattern used by `agent_monitor_helpers.sh`, `drift_artifacts.sh`, etc. Backward-compatible via `command -v` guard in `run_preflight_checks()`. Architecture doc update still needed (see Non-Blocking Notes).

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `preflight_services.sh` is 493 lines (exceeds 300-line ceiling). The ACP documents why this was necessary (preflight.sh was already 607 lines), so the split is correct — but if this file grows further, consider splitting inference (`_pf_infer_*`) from probing/reporting.
- `ARCHITECTURE.md` needs a `lib/preflight_services.sh` entry in the Layer 3 library listing. The ACP explicitly flags this but no update was made in this milestone.
- `docker info &>/dev/null 2>&1` (preflight_services.sh:304) — `&>` already redirects both stdout and stderr to /dev/null; the trailing `2>&1` is redundant. Same pattern at line 375.
- `_probe_service_port`: the `timeout_s` parameter is only respected by the `nc` fallback; the `/dev/tcp` primary path carries no enforced timeout. Practically fine for localhost (ECONNREFUSED returns instantly), but the parameter is misleadingly named — a filtered port could block indefinitely on the primary path.
- `grep -oP` (PCRE) in `_preflight_check_dev_server` (preflight_services.sh:328, 342) won't work on macOS stock grep. This is consistent with the M55 precedent in `preflight.sh` and is not new debt, but the risk accumulates.

## Coverage Gaps
- No test covering `_pf_infer_from_packages` Python (requirements.txt) or Go (go.mod) paths — only Node.js package.json was tested in the M56 cases.
- No test asserting the startup instructions text appears in the report (only that `## Services` section and table header are present).

## Drift Observations
- `preflight.sh` at 618 lines and `preflight_services.sh` at 493 lines — both well above the 300-line ceiling. The pre-flight subsystem now totals ~1,100 lines across two files. If a further M55/M56 check is ever added (e.g., CI service config detection), a third split will be needed.
