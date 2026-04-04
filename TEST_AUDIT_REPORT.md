## Test Audit Report

### Audit Summary
Tests audited: 1 file, 32 test sections (~54 assertions)
Verdict: PASS

---

### Findings

#### COVERAGE: Port probe ephemeral-port discovery is fragile
- File: tests/test_preflight.sh:798
- Issue: `socat TCP-LISTEN:0` + `ss -tlnp | grep "pid=${socat_pid}"` to discover the assigned ephemeral port is a race — the `ss` query runs 0.5s after socat starts, and PID-based matching may miss the entry depending on `ss` output format. If this path fails, the fallback uses `nc -l -p 39182` on a fixed port, but `-p` is not universal across `nc` implementations. The test does degrade gracefully (calls `pass` and skips), so this cannot inflate the pass count — but the positive `_probe_service_port` path (detecting an open port) may never execute on some systems.
- Severity: MEDIUM
- Action: Replace ephemeral-port discovery with a fixed high port (e.g., 49991) bound directly: `socat TCP4-LISTEN:49991,fork /dev/null &` or `{ nc -l 49991 || true; } &`. Eliminates the PID-based `ss` race entirely.

#### COVERAGE: CI downgrade test only asserts the negative
- File: tests/test_preflight.sh:998
- Issue: The CI environment test (lines 982–1005) asserts only `_PF_WARN -eq 0`. It does not assert `_PF_PASS -ge 1`. If service inference were to silently produce no entries (e.g., a future regex change in `_pf_infer_from_env`), the test would pass vacuously because `warn=0` holds for an empty `_PF_SERVICES` array. The CI-downgrade behavior would go unverified.
- Severity: LOW
- Action: Add a second assertion after the existing check: `[[ "$_PF_PASS" -ge 1 ]]` with message `"CI should convert service miss to a pass record (pass=$_PF_PASS)"`.

---

### Positive Notes (for record)

1. **Assertion honesty is high.** All counters (`_PF_PASS`, `_PF_WARN`, `_PF_FAIL`, `_PF_SERVICES`) derive from actual function execution against fixture inputs. No hard-coded expected values — counts are verified against real output of `_pf_infer_from_compose`, `_pf_infer_from_packages`, etc.

2. **State isolation is correct.** Every test section resets `_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=(); _PF_LANGUAGES=""; _PF_TEST_FWS=""` before calling the function under test. Counter accumulation across sections is prevented.

3. **Reviewer-identified gaps are all closed.** REVIEWER_REPORT.md flagged: (a) no test for `_pf_infer_from_packages` Python/Go paths; (b) no test asserting startup instructions appear in the report. Both are fully addressed by the three new M56 sections: requirements.txt (line 1011), go.mod (line 1059), and startup instructions (line 1108).

4. **No existing tests were weakened.** The M55 sections (lines 53–623) are untouched. No assertions removed or broadened.

5. **Implementation exercise is real.** Tests source `lib/preflight.sh` and `lib/preflight_services.sh` and call the actual functions — no mocking of the functions under test. The only targeted mock is PATH restriction for the Docker daemon test (line 859), which is correct technique.

6. **Startup instructions test bypasses non-determinism correctly.** Rather than probing a real port and hoping a service isn't running, the test directly injects a `not_running` entry into `_PF_SERVICES` (line 1124) and calls `_pf_emit_services_report` to verify report content. This is the right tradeoff: deterministic verification of report logic without relying on external process state.

7. **Scope is fully aligned.** All referenced functions (`_pf_infer_from_packages`, `_pf_infer_from_compose`, `_pf_infer_from_env`, `_pf_add_service`, `_probe_service_port`, `_preflight_check_docker`, `_preflight_check_services`, `_preflight_check_dev_server`, `_pf_emit_services_report`) exist in the sourced implementation files. No orphaned or stale references.

8. **Test naming is clear.** Section banners encode both scenario and ecosystem (`"=== Service inference: requirements.txt (Python) ==="`, `"=== Service dedup: multiple sources ==="`). Fail messages include diagnostic values (`"got ${#_PF_SERVICES[@]}"`).
