# Milestone 89: Rolling Test Audit Sampler
<!-- milestone-meta
id: "89"
status: "done"
-->

## Overview

The M20 per-run audit is scoped to `_AUDIT_TEST_FILES` — tests written or
modified by the tester this run. A stale test that nobody touches never enters
that set and is never re-scrutinized.

M88 closes this gap for *symbol-level* drift (renamed/removed symbols) with a
deterministic shell check. This milestone closes the complementary gap at the
*LLM rubric* level: scope alignment, assertion honesty, and naming quality
issues that the shell cannot catch deterministically.

The mechanism is a rolling sampler: each pipeline run, a small K-file sample
of "least-recently-audited" test files from the full suite is appended to
`_AUDIT_TEST_FILES` before the audit agent is invoked. The agent already runs;
its input context grows by K files. No new agent calls, no new stages.

Across ~ceil(N/K) runs, every test file in a project with N tests gets
re-evaluated. For K=3 and a typical project with 30 test files, the full suite
rotates through in ~10 runs. The audit agent never sees more than `K` extra
files per run and the token cost is bounded.

## Design Decisions

### 1. JSONL audit history, same pattern as task_history.jsonl

Each entry records `{"ts": "...", "file": "tests/test_foo.py"}` when a file was
last audited. The sampler reads this file, finds test files absent from the
history or with the oldest timestamps, and selects K of them. Pruning follows
the `_prune_task_history` pattern: keep the last `TEST_AUDIT_HISTORY_MAX_RECORDS`
entries. Stored at `${REPO_MAP_CACHE_DIR}/test_audit_history.jsonl`.

### 2. Sample K oldest, not random

Deterministic selection (oldest-last-audited first) ensures every file
eventually gets audited — pure random sampling can leave files unaudited
indefinitely. Files never seen in history (new files, files predating M89) are
treated as having been audited at epoch 0 (oldest possible) and sampled first.

### 3. Sampled files are clearly distinguished in audit context

The context block passed to the audit agent labels sampled files separately from
tester-modified files:

```
## Test Files Under Audit (modified this run)
- tests/test_new_feature.py

## Test Files Under Audit (freshness sample)
- tests/test_legacy_auth.py
- tests/test_old_migration.py
```

This tells the agent to apply scope-alignment scrutiny to the sampled files
(they may be stale) without assuming recent coder changes caused any issues.

### 4. History update is best-effort, non-blocking

Audit history writes are append-only JSONL with atomic file operations (same
`echo >> file` pattern as `record_task_file_association`). A write failure
warns but never blocks the pipeline.

### 5. Sampler is independent of REPO_MAP_ENABLED

Unlike M88 (requires indexer), the sampler is pure shell — it only needs
`_discover_all_test_files()` (already exists in `test_audit.sh`) and a JSONL
file. It works in any project regardless of indexer configuration.

### 6. Sampler skips when tester wrote no tests

If `_AUDIT_TEST_FILES` is empty (tester ran but wrote no new test files), the
sampler still populates up to K files so the audit agent has something to
evaluate. This handles the case where the coder refactored and the tester only
ran existing tests without creating new ones.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Shell files modified | 1 | `lib/test_audit.sh` |
| Config modified | 1 | `lib/config_defaults.sh` — 2 new keys |
| Shell tests added | 1 | `tests/test_audit_sampler.sh` |
| New data file (runtime) | 1 | `${REPO_MAP_CACHE_DIR}/test_audit_history.jsonl` |

## Implementation Plan

### Step 1 — lib/test_audit.sh: audit history management

Add `_TEST_AUDIT_HISTORY_FILE` resolution (analogous to `_TASK_HISTORY_FILE`):

```bash
_TEST_AUDIT_HISTORY_FILE=""

_ensure_test_audit_history_file() {
    if [[ -n "$_TEST_AUDIT_HISTORY_FILE" ]]; then return; fi
    local cache_dir="${REPO_MAP_CACHE_DIR:-${PROJECT_DIR}/.claude/index}"
    mkdir -p "${PROJECT_DIR}/${cache_dir}" 2>/dev/null || true
    _TEST_AUDIT_HISTORY_FILE="${PROJECT_DIR}/${cache_dir}/test_audit_history.jsonl"
}
```

Add `_record_audit_history FILES`:
```bash
_record_audit_history() {
    local files="$1"
    _ensure_test_audit_history_file
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local safe_f
        safe_f=$(printf '%s' "$f" | sed 's/\\/\\\\/g; s/"/\\"/g')
        echo "{\"ts\":\"${ts}\",\"file\":\"${safe_f}\"}" \
            >> "$_TEST_AUDIT_HISTORY_FILE" 2>/dev/null || true
    done <<< "$files"
    _prune_audit_history
}
```

Add `_prune_audit_history`:
- Keep last `TEST_AUDIT_HISTORY_MAX_RECORDS` lines (default: 500)
- Same atomic `tail -n N > tmp && mv tmp original` pattern as `_prune_task_history`

### Step 2 — lib/test_audit.sh: sampler

Add `_sample_unaudited_test_files`:

```bash
_sample_unaudited_test_files() {
    local k="${TEST_AUDIT_ROLLING_SAMPLE_K:-3}"
    _ensure_test_audit_history_file

    # Get all test files in the project
    local all_tests
    all_tests=$(_discover_all_test_files)
    [[ -z "$all_tests" ]] && return

    # Build set of already-in-audit-files to avoid duplicates
    local current_set="${_AUDIT_TEST_FILES:-}"

    # Read history: most-recently-audited file per path
    # (history may have duplicates — last entry for a path wins)
    declare -A last_seen
    if [[ -f "$_TEST_AUDIT_HISTORY_FILE" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local f ts
            f=$(echo "$line" | sed 's/.*"file":"\([^"]*\)".*/\1/')
            ts=$(echo "$line" | sed 's/.*"ts":"\([^"]*\)".*/\1/')
            last_seen["$f"]="$ts"
        done < "$_TEST_AUDIT_HISTORY_FILE"
    fi

    # Score each test file: epoch for unseen, ISO timestamp for seen
    # Sort ascending (oldest first), take K, skip already-included
    local sampled=0
    local sample_list=""
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # Skip if already in this run's audit set
        if echo "$current_set" | grep -qxF "$f" 2>/dev/null; then
            continue
        fi
        [[ "$sampled" -ge "$k" ]] && break
        sample_list="${sample_list}${f}
"
        sampled=$((sampled + 1))
    done < <(
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            echo "${last_seen[$f]:-0000-00-00T00:00:00Z} $f"
        done <<< "$all_tests" | sort | awk '{print $2}'
    )

    # Append sampled files to global
    if [[ -n "$sample_list" ]]; then
        export _AUDIT_SAMPLE_FILES="$sample_list"
    fi
}
```

### Step 3 — lib/test_audit.sh: integrate into run_test_audit()

In `run_test_audit()`, after `_collect_audit_context`, add the sampler call:

```bash
# Rolling freshness sample
if [[ "${TEST_AUDIT_ROLLING_ENABLED:-true}" == "true" ]]; then
    _sample_unaudited_test_files
fi
```

Update `TEST_AUDIT_CONTEXT` assembly to label the two groups separately:

```
## Test Files Under Audit (modified this run)
<_AUDIT_TEST_FILES>

## Test Files Under Audit (freshness sample — may be stale)
<_AUDIT_SAMPLE_FILES>
```

The agent prompt already instructs scope-alignment checks; the "may be stale"
label primes the agent to look for drift rather than assuming recency.

After `_route_audit_verdict` succeeds (PASS or CONCERNS), record audit history
for all files that were audited (both modified and sampled):

```bash
_record_audit_history "${_AUDIT_TEST_FILES}
${_AUDIT_SAMPLE_FILES:-}"
```

History is recorded only on non-NEEDS_WORK verdicts. If the audit triggers
rework, history is recorded after the rework cycle resolves.

### Step 4 — lib/config_defaults.sh

Add two keys adjacent to `TEST_AUDIT_*`:

```bash
: "${TEST_AUDIT_ROLLING_ENABLED:=true}"
: "${TEST_AUDIT_ROLLING_SAMPLE_K:=3}"
: "${TEST_AUDIT_HISTORY_MAX_RECORDS:=500}"
```

Add clamp in the validation block:
```bash
_clamp_config_value TEST_AUDIT_ROLLING_SAMPLE_K 20
_clamp_config_value TEST_AUDIT_HISTORY_MAX_RECORDS 2000
```

### Step 5 — Shell tests

Create `tests/test_audit_sampler.sh`:

- `test_sampler_returns_k_files` — pool of 10 test files, empty history, assert
  `_AUDIT_SAMPLE_FILES` contains exactly K=3 entries
- `test_sampler_skips_recently_audited` — inject history entries for 7 files,
  assert only the 3 un-historied files are sampled
- `test_sampler_oldest_first` — history with varied timestamps, assert file
  with oldest timestamp is included in sample
- `test_sampler_deduplicates_with_current_set` — file already in
  `_AUDIT_TEST_FILES`; assert it does not appear again in sample
- `test_sampler_disabled` — `TEST_AUDIT_ROLLING_ENABLED=false`; assert
  `_AUDIT_SAMPLE_FILES` is empty
- `test_record_audit_history_appends` — call `_record_audit_history` with 2
  files; assert both appear in JSONL file
- `test_prune_audit_history` — insert `TEST_AUDIT_HISTORY_MAX_RECORDS + 10`
  entries; assert file is pruned to max records

## Files Touched

### Added
- `tests/test_audit_sampler.sh` — shell tests for sampler and history

### Modified
- `lib/test_audit.sh` — `_ensure_test_audit_history_file`, `_record_audit_history`,
  `_prune_audit_history`, `_sample_unaudited_test_files`, integrate into
  `run_test_audit()`; update `TEST_AUDIT_CONTEXT` assembly
- `lib/config_defaults.sh` — `TEST_AUDIT_ROLLING_ENABLED`, `TEST_AUDIT_ROLLING_SAMPLE_K`,
  `TEST_AUDIT_HISTORY_MAX_RECORDS`

## Acceptance Criteria

- [ ] `_sample_unaudited_test_files` returns exactly `TEST_AUDIT_ROLLING_SAMPLE_K`
  files (or fewer if the project has fewer test files than K)
- [ ] Sampled files are distinct from `_AUDIT_TEST_FILES` (no duplicates)
- [ ] Files absent from audit history are selected before files with older timestamps
- [ ] Files with the oldest audit timestamps are selected before more recently audited ones
- [ ] Sampled files appear in `TEST_AUDIT_CONTEXT` under "freshness sample" label,
  separate from modified-this-run files
- [ ] Audit history is updated after a PASS or CONCERNS verdict (not after
  NEEDS_WORK, which may indicate the files need further work)
- [ ] `_record_audit_history` writes valid JSONL entries
- [ ] History is pruned when it exceeds `TEST_AUDIT_HISTORY_MAX_RECORDS`
- [ ] `TEST_AUDIT_ROLLING_ENABLED=false` causes sampler to skip with no side effects
- [ ] **Behavioral:** After M89 is implemented, running the Tekhton pipeline 4+ times
  causes test files not modified in any run to appear at least once in a
  "freshness sample" audit section (verify via run logs)
- [ ] `bash tests/test_audit_sampler.sh` passes
- [ ] `bash tests/run_tests.sh` passes (no regressions)
- [ ] `shellcheck lib/test_audit.sh` reports zero warnings
- [ ] No additional agent turns per run (sampler only enlarges the existing
  audit agent's input context)

## Watch For

- The `declare -A` associative array in `_sample_unaudited_test_files` requires
  Bash 4.0+. The project baseline is Bash 4.3+ so this is safe, but declare it
  local to the function to avoid polluting the global environment. Use
  `local -A last_seen` syntax.
- ISO timestamp sort (`sort` on `YYYY-MM-DDTHH:MM:SSZ` strings) is
  lexicographically correct. No `date` parsing needed.
- The sampler calls `_discover_all_test_files()` which uses `git ls-files`.
  In projects with thousands of test files, this is still fast (sub-second).
  The sort over the result set is O(N log N) but N is test-file count, not
  total file count.
- History records the *file path* as a relative path (matching
  `_discover_all_test_files` output). Ensure the path format is consistent
  between the sampler and the history recorder.

## Seeds Forward

- The audit history JSONL is the foundation for a future health metric: "% of
  test suite audited in the last N runs." Surfaceable in Watchtower.
- M88's `test_map.json` can feed into the sampler as a priority signal: test
  files whose symbol sets changed since their last audit get elevated sampling
  priority, even if their timestamp is recent. This combines both milestones
  into a fully adaptive freshness system.
- `TEST_AUDIT_ROLLING_SAMPLE_K` can become adaptive (like `METRICS_ADAPTIVE_TURNS`):
  increase K when the audit returns CONCERNS findings to accelerate suite coverage.
