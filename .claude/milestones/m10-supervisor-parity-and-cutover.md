<!-- milestone-meta
id: "10"
status: "todo"
-->

# m10 — Supervisor Parity Suite + Bash Cutover

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 2 / 6 — the closer. m05–m09 built the Go supervisor incrementally without touching production; m10 proves it matches the bash supervisor's behavior across every scenario the bash version handles, then flips `lib/agent.sh` to call `tekhton supervise` and deletes the now-superfluous bash supervisor files. This is the milestone where Phase 2 stability returns. |
| **Gap** | The Go supervisor exists but has never replaced bash on a production code path. No parity gate; no "remove `python3 -c` JSON parsing" cleanup; no causal-event-shape regression check across the full m126–m138 resilience arc. |
| **m10 fills** | (1) `scripts/supervisor-parity-check.sh` — a 12-scenario parity gate covering happy path, retries, quota pause, activity timeout, fsnotify override, SIGINT, Windows tree kill, OOM, transient errors, fatal errors, turn exhaustion, and the resilience-arc end-to-end flow. (2) `lib/agent.sh` flipped to call `tekhton supervise` for production agent calls. (3) `lib/agent_monitor.sh`, `lib/agent_retry.sh`, `lib/agent_monitor_helpers.sh`, `lib/agent_monitor_platform.sh`, `lib/agent_retry_pause.sh` deleted. (4) Inline `python3 -c` JSON parses in any remaining bash file removed. (5) m126–m138 resilience arc tests run green. |
| **Depends on** | m09 |
| **Files changed** | `scripts/supervisor-parity-check.sh`, `lib/agent.sh` (rewrite), `lib/agent_monitor*.sh` (delete), `lib/agent_retry*.sh` (delete), `internal/state/legacy_reader.go` (delete — m03's "REMOVE IN m05" debt; deferred to m10 since it's a one-cycle window), `.github/workflows/go-build.yml` (add parity job), `docs/go-migration.md` (Phase 2 retro) |
| **Stability after this milestone** | **Stable. Phase 2 closed.** Production runs through Go supervisor; bash supervisor files removed. The next-wedge entry checklist for Phase 3 fires. |
| **Dogfooding stance** | **This IS the cutover.** Once parity gate green and m10 lands, the Tekhton working copy can swap to the new binary. The user controls the rollout cadence — but the bash supervisor is gone from the source tree, so older Tekhton CLIs that try to run against the post-m10 source will fail loudly (no `lib/agent_monitor.sh` to source). |

---

## Design

### Parity test design

`scripts/supervisor-parity-check.sh` is the gate. It runs each scenario twice — once against `git rev-parse HEAD~1` (last bash supervisor commit) and once against HEAD (Go supervisor) — and compares observable outputs.

**Scenario matrix:**

| # | Name | Setup | Compared outputs |
|---|------|-------|------------------|
| 1 | Happy path | Fake agent emits 3 turns, exits 0 | Stage artifact files, causal events, exit code |
| 2 | Transient retry | Fake agent fails attempt 1 (ErrUpstreamTransient), succeeds attempt 2 | Causal `retry_attempt` + `retry_backoff` events, final result |
| 3 | Retry exhausted | Fake agent fails 3 attempts | `retry_exhausted` causal event, AgentResultV1.Outcome |
| 4 | Quota pause | Mock 429 with Retry-After: 10, then 200 | `quota_pause_entered`, `quota_tick`, `quota_pause_exited` causal events; pause duration ≥ 10s |
| 5 | Activity timeout (no override) | Fake agent silent, no file writes | `activity_timeout_fired`, agent killed, exit code reflects SIGTERM |
| 6 | Activity timeout (fsnotify override) | Fake agent silent on stdout, writes one file every 2s | `activity_timer_overridden` events, agent runs to completion |
| 7 | SIGINT mid-run | Send SIGINT after 1s | Clean shutdown, partial state file, final causal event flagging interruption |
| 8 | OOM | Fake agent exits with sentinel OOM marker | `ErrUpstreamOOM` classification, retry with 15s floor |
| 9 | Fatal error | Fake agent exits with non-transient marker | No retry; immediate failure return |
| 10 | Turn exhausted | Fake agent uses MaxTurns and exits cleanly | `Outcome: turn_exhausted`, no retry, orchestrate continuation signaled |
| 11 | Windows process tree kill | (Windows runner only) Fake agent spawns 3 children, gets SIGINT | Zero remaining child PIDs after 2s |
| 12 | Resilience arc end-to-end | Run a fixture project through the full m126–m138 arc | Same RUN_SUMMARY.json + DIAGNOSIS.md output |

**Comparison rules:**

- Stage artifact files: byte-identical except for timestamps, run IDs, and the `proto` field on causal events.
- Causal events: filter `ts` and any field in an `IGNORE_FIELDS` allowlist; assert event types and order match.
- Exit codes and `AgentResultV1.Outcome`: identical.

The script writes a per-scenario report under `.tekhton/parity_report/m10/` showing diffs. Any diff outside the allowlist fails the gate.

### Bash cutover

`lib/agent.sh` rewrite:

```bash
# Before: ~250 lines invoking _invoke_and_monitor + _run_with_retry
# After: ~60 lines that build the request envelope and shell to tekhton supervise

run_agent() {
    local label="$1" model="$2" prompt_file="$3"
    shift 3
    local max_turns="${MAX_TURNS:-100}"
    local timeout="${AGENT_TIMEOUT:-3600}"
    local activity_to="${AGENT_ACTIVITY_TIMEOUT:-300}"

    local request
    request=$(jq -n \
        --arg proto "tekhton.agent.request.v1" \
        --arg run_id "$RUN_ID" \
        --arg label "$label" \
        --arg model "$model" \
        --arg prompt_file "$prompt_file" \
        --arg working_dir "$PROJECT_DIR" \
        --argjson max_turns "$max_turns" \
        --argjson timeout "$timeout" \
        --argjson activity_to "$activity_to" \
        '{proto:$proto, run_id:$run_id, label:$label, model:$model,
          prompt_file:$prompt_file, working_dir:$working_dir,
          max_turns:$max_turns, timeout_secs:$timeout,
          activity_timeout_secs:$activity_to}')

    local result
    result=$(echo "$request" | tekhton supervise)
    local rc=$?

    # Map AgentResultV1 fields back to the V3 _RWR_* globals expected by callers
    _RWR_EXIT=$(echo "$result"     | jq -r .exit_code)
    _RWR_TURNS=$(echo "$result"    | jq -r .turns_used)
    _RWR_OUTCOME=$(echo "$result"  | jq -r .outcome)
    _RWR_LAST_EVENT_ID=$(echo "$result" | jq -r '.last_event_id // ""')

    return $rc
}
```

The `_RWR_*` globals stay because Phase 4 hasn't ported `lib/orchestrate.sh` yet; preserving them avoids a cross-Phase rewrite.

### Files deleted

| File | Lines | Replaced by |
|------|-------|-------------|
| `lib/agent_monitor.sh` | ~301 | `internal/supervisor/run.go` + `decoder.go` + `ringbuf.go` |
| `lib/agent_monitor_helpers.sh` | ~150 | absorbed into `run.go` |
| `lib/agent_monitor_platform.sh` | ~80 | `internal/supervisor/reaper_*.go` |
| `lib/agent_retry.sh` | ~120 | `internal/supervisor/retry.go` |
| `lib/agent_retry_pause.sh` | ~60 | `internal/supervisor/quota.go` integration |
| `internal/state/legacy_reader.go` | ~80 | (m03 marker honored — no V3 markdown state files in production after m04 + 6 milestones) |

Wedge audit (m04) is extended with a new check: `python3 -c.*json` patterns in `lib/` should match nothing.

### Phase 2 retrospective

`docs/go-migration.md` adds a Phase 2 section:

- **Phase 2 summary.** What landed in m05–m10. Supervisor wedge proven.
- **What worked.** Build-tagged platform files. fsnotify activity override. Typed errors with `errors.Is`.
- **What needed adjustment.** (Real findings from the work.)
- **Phase 3 inputs.** The re-evaluation point (m11) reads this section.

### Phase 3 entry checklist

- [ ] Parity gate green for 5 consecutive CI runs.
- [ ] No bash file under `lib/` matches `agent_monitor` or `agent_retry`.
- [ ] No bash file under `lib/` or `stages/` contains `python3 -c.*json`.
- [ ] `tests/run_tests.sh` produces output identical to HEAD~1 modulo allowlist.
- [ ] `m126`–`m138` resilience arc tests pass against the V4 codebase.
- [ ] Self-host check passes on all three platforms.
- [ ] `docs/go-migration.md` Phase 2 section complete.

m11 cannot start until every item is checked.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `scripts/supervisor-parity-check.sh` | Create | 12-scenario parity gate. ~250 lines. |
| `lib/agent.sh` | Modify | Rewrite as a `tekhton supervise` shim. ~60 lines (was ~250). |
| `lib/agent_monitor.sh` | Delete | Whole file. |
| `lib/agent_monitor_helpers.sh` | Delete | Whole file. |
| `lib/agent_monitor_platform.sh` | Delete | Whole file. |
| `lib/agent_retry.sh` | Delete | Whole file. |
| `lib/agent_retry_pause.sh` | Delete | Whole file. |
| `internal/state/legacy_reader.go` | Delete | m03's REMOVE IN m05 debt. |
| `.github/workflows/go-build.yml` | Modify | Add `parity-check` CI job (gates merge). |
| `scripts/wedge-audit.sh` | Modify | Add `python3 -c.*json` pattern. |
| `docs/go-migration.md` | Modify | Phase 2 retrospective + Phase 3 entry checklist. |

---

## Acceptance Criteria

- [ ] `scripts/supervisor-parity-check.sh` exits 0 against the 12-scenario matrix; per-scenario reports show diffs only in the timestamp/run-id allowlist.
- [ ] `bash tests/run_tests.sh` produces output identical to HEAD~1 modulo the allowlist.
- [ ] m126–m138 resilience arc tests pass against the V4 codebase (rerun the existing test files; they should not need modification).
- [ ] `lib/agent.sh` is ≤ 80 lines, calls only `tekhton supervise`, and continues to populate `_RWR_*` globals for downstream `lib/orchestrate.sh` consumers.
- [ ] `git ls-files lib/agent_monitor* lib/agent_retry*` returns no files.
- [ ] `grep -rn 'python3 -c.*json' lib/ stages/` returns no matches.
- [ ] `internal/state/legacy_reader.go` is deleted; `internal/state/snapshot.go` no longer dispatches to it; resume against a V3 markdown state file now produces a clear error directing the user to migrate via the V4 migration tool.
- [ ] CI parity job runs on every PR and gates merge to `feature/GoWedges` and `main`.
- [ ] Self-host check passes on `linux/amd64`, `darwin/amd64`, `windows/amd64`.
- [ ] Coverage for `internal/supervisor` ≥ 80% (locked at the m04 bar).
- [ ] `docs/go-migration.md` Phase 2 section + Phase 3 entry checklist all checked off.

## Watch For

- **The cutover is the riskiest single moment in V4.** Do not merge m10 to `main` without the parity gate green for 5 consecutive runs across at least 24 hours. Flake-free.
- **`_RWR_*` globals stay until Phase 4.** Don't refactor them out here — they're the contract with `lib/orchestrate.sh`. Phase 4's orchestrate port is the moment to delete them.
- **Legacy markdown state reader deletion.** This was promised in m05 but lands in m10 (the supervisor wedge took precedence in our planning). Communicated explicitly because anyone relying on V3 state files now must run the V4 migration tool first.
- **The python3 -c removal is non-trivial.** A handful of bash files inline `python3 -c "import json; …"` for one-off parses. Audit comprehensively (the wedge-audit script catches stragglers but humans should grep too) — these existed precisely because bash had no JSON, and now Go does, but the bash side still does too via `jq`. Don't introduce `jq` dependencies that weren't already there.
- **Windows runner CI.** The parity-check job needs a Windows runner step for scenario #11. `windows-latest` GitHub-hosted runners support this; use them sparingly (cost, queue time).
- **Feature flag opportunity?** It's tempting to add a `TEKHTON_SUPERVISOR=bash|go` flag for safe rollback. Don't. The bash files are deleted in this milestone — there's no bash supervisor to fall back TO. The parity gate is the safety net; if it fails, m10 doesn't merge.
- **Don't add new features to `lib/agent.sh`.** Pure shim. Any behavior change goes in `internal/supervisor`.

## Seeds Forward

- **m11 Phase 3 re-evaluation:** the input. m11 reads `docs/go-migration.md` Phase 2 section and decides Path (a) Ship of Theseus continues vs Path (b) parallel `tekhton run` entry point.
- **Phase 4 orchestrate port:** `lib/orchestrate.sh` is the next-largest bash file. Now that the supervisor it calls is Go, the orchestrate port can use `internal/supervisor.Retry` directly without a CLI hop.
- **Phase 5 deprecation:** `lib/agent.sh` itself will eventually be deleted when the orchestrate port lands. The shim is transitional.
- **Future provider abstraction (V5):** `internal/supervisor` is now the natural seam for V5's multi-provider work. Each provider plugs in as an `AgentRunner` implementation; the request/response envelopes stay stable.
- **Causal log + state are now both Go-owned.** Phase 4's orchestrate port can call `internal/causal` and `internal/state` directly without subprocess hops. The 2-hop bash → Go → Go pattern collapses to 1-hop.
