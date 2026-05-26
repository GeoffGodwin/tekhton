<!-- milestone-meta
id: "27"
status: "todo"
-->

# m27 — Bash Subprocess Hardening + Env Audit Gates

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 5 — consumer-side closeout of the env-contract arc m26 opened. m26 fixed the *producer*: a single typed `StageEnvV1` populated from `pipeline.conf` + run-request flags, delivered identically to every stage and finalize subprocess. But the bash files those subprocesses run are still littered with unguarded reads (`"$MILESTONE_MODE"`, `"$ANALYZE_CMD"`, `"$CLAUDE_CODER_MODEL"`, …) that crash under `set -u` if any field in the contract is missing or zero-valued. Today the only thing keeping these crashes off CI is the fact that legacy bash always source-loaded `pipeline.conf`, so the globals always existed in the legacy entry path. Now that `tekhton run` (Go) is the only entry point for `--milestone` / `--auto-advance` runs, the contract is the only thing standing between the user and a stage subprocess that exits 1 mid-run. m27 hardens every bash consumer and adds two CI gates that prevent regression. |
| **Gap** | At m26 close, `${VAR:-default}` patches landed only on the trip sites we hit during dogfooding (`intake_helpers.sh:191,224`; `finalize_commit.sh:47`; `intake_verdict_handlers.sh:73,107`; `orchestrate_save.sh:31`; `orchestrate_iteration.sh:161`; `stages/architect.sh:67`; `stages/coder.sh:450`; `hooks_final_checks.sh:23`). A `grep -rnE '(^|[^:_])\$[A-Z_][A-Z0-9_]*\b' lib/ stages/` returns hundreds of matches; manual triage during the m26 dogfood found at least 40 more sites that read contract globals without a default. No CI gate exists to (a) catch a new bash file landing an unguarded read, or (b) catch a regression where a stage subprocess hits `set -u` for any reason. Per-incident reactive fixes are the wrong shape — the audit/parity infrastructure is what closes the gap for good. |
| **m27 fills** | (1) `scripts/audit-bash-env.sh` (new): a fast grep-based audit that scans `lib/` + `stages/` for unguarded reads of every key in a known-globals allowlist (every `StageEnvV1` field name + every `pipeline.conf` key from `internal/config/defaults.go`). Output is a per-file punch list of unguarded sites. Fails with exit 1 if any match. (2) `tests/test_stage_env_setu.sh` (new): a slow parity gate that runs `tekhton run --milestone m27fix --no-tui --dry-run` against `tests/testdata/env_contract/` and `grep -c 'unbound variable'` on stderr — fails if non-zero. The fixture is a minimal project that exercises every bash code path the V4 dogfood touches (intake, coder, security, review, tester, finalize). (3) The defensive `${VAR:-default}` sweep across the matches the new audit script surfaces. Mechanical — each site uses the contract-defined default value (`MILESTONE_MODE` defaults to `false`, `CODER_MAX_TURNS` to `40`, etc.) so behavior matches the legacy bash defaults. (4) `make dogfood` extends to invoke both gates so they run on every CI / pre-release pass. (5) Update `scripts/wedge-audit.sh` to assert `scripts/audit-bash-env.sh` exists and is wired into `make dogfood` — keeps a future cleanup pass from accidentally removing the gate. (6) Document the contract usage in each touched bash file's header comment (one-line "Expects: env vars from `internal/runner/env.go` StageEnvV1 contract"). (7) `VERSION` bumps to `4.27.0` on close. |
| **Depends on** | m26 |
| **Files changed** | `scripts/audit-bash-env.sh`, `scripts/wedge-audit.sh`, `tests/test_stage_env_setu.sh`, `tests/testdata/env_contract/`, ~40 files under `lib/` and `stages/` (defensive `${VAR:-default}` sweep — exact list emitted by the audit script's first run), `Makefile`, `docs/v4-env-contract.md`. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m16 | Config loader Go package. Defines the set of pipeline.conf keys and their defaults — the source of truth for the audit allowlist. |
| m21 | First Go→bash subprocess bridge (finalize). Established the per-hook `set -u` exposure that m26 + m27 close. |
| m22 | First fully-ported Phase 5 subsystem (preflight). No bash bodies left in preflight, so no audit work — sets the "fully ported = gate-exempt" rule. |
| m26 | Producer-side env contract. Every stage and finalize subprocess receives the full contract identically. |
| **m27** | **Consumer-side hardening + audit/parity gates. Future regressions caught at CI time, not at user-run time.** |

---

## Design

### Sequencing note

m27 lands immediately after m26 — both should be in flight as a pair. Reason: m26 alone leaves the bash side trusting that the contract is always populated. If a future milestone removes a field from `StageEnvV1` (intentionally or by accident), m27's audit catches it; without m27, the regression surfaces as a user-facing crash. The gates are the safety net for the contract.

Land m27 before m23 / m24 / m25 for the same reason m26 needed to. Each of those milestones ports bash to Go. Without m27's audit, a port that leaves a bash trip site behind ships unnoticed.

### Goal 1 — `scripts/audit-bash-env.sh`

```bash
#!/usr/bin/env bash
# audit-bash-env.sh — grep-based audit for unguarded reads of contract env vars.
#
# A "contract var" is any key in:
#   - internal/proto/stage_env.go StageEnvV1 (runtime flags + log channel)
#   - internal/config/defaults.go (every pipeline.conf default)
#
# An "unguarded read" is "$VAR" or "${VAR}" (no `:-default`, no `:?error`).
#
# Exits 1 if any match found, listing path:line:matched-line.
set -euo pipefail

readonly ALLOWLIST_FILE="${1:-scripts/audit-bash-env-allowlist.txt}"
readonly SCAN_DIRS=("lib" "stages")

# Allowlist of (file, var) pairs that are *intentionally* unguarded —
# e.g. a var that the bash file itself sets at the top before any read.
# Format: one "lib/foo.sh:VAR_NAME" per line.

# Resolve the keys to audit from the Go source of truth.
keys=$(grep -hE '^\s+\w+\s+[A-Z][a-zA-Z]*\s+`' internal/proto/stage_env.go \
       | awk '{print $1}' | tr -d '`,' \
       && go run ./cmd/tekhton config defaults --emit shell \
            | grep -oE '^[A-Z][A-Z0-9_]*' )

# For each key, scan for unguarded reads. Skip allowlisted (file, key) pairs.
exit_code=0
while read -r key; do
    pattern='\$\{?'"$key"'\}?\b'
    while read -r match; do
        if ! grep -qxF "${match%%:*}:${key}" "$ALLOWLIST_FILE" 2>/dev/null; then
            # Ignore matches that immediately have :- or :? (guarded).
            if ! echo "$match" | grep -qE ':-|:\?'; then
                echo "$match" >&2
                exit_code=1
            fi
        fi
    done < <(grep -rEn "$pattern" "${SCAN_DIRS[@]}" || true)
done <<< "$keys"

exit "$exit_code"
```

Key properties:
- **Source-of-truth driven.** The audit's key list comes from Go (`StageEnvV1` fields + `config defaults`), not a hand-maintained list. New fields in the contract automatically join the audit.
- **Allowlist, not blocklist.** Sites that *intentionally* read a contract var without a default (e.g. a defensive `if [[ -z "${VAR:-}" ]]; then return 1; fi` — `VAR` is the read, the guard comes before in a different form) go in `scripts/audit-bash-env-allowlist.txt`. Each allowlist entry needs a one-line comment explaining *why*.
- **Fast.** `grep -rEn` across `lib/` + `stages/` finishes in <100ms on this codebase. Suitable for pre-commit hook or every `make dogfood`.

### Goal 2 — `tests/test_stage_env_setu.sh` parity gate

The slow gate runs a real (but minimal) pipeline pass and asserts no `set -u` crashes leak through. Fixture at `tests/testdata/env_contract/`:

```
tests/testdata/env_contract/
├── .claude/
│   ├── pipeline.conf            # Minimal but complete config (every key from defaults).
│   ├── agents/
│   │   ├── coder.md             # Stub agent role files.
│   │   ├── reviewer.md
│   │   └── tester.md
│   └── milestones/
│       ├── MANIFEST.cfg         # Single milestone entry.
│       └── m27fix.md            # Tiny noop milestone — "print hello".
├── CLAUDE.md
└── README.md
```

The test script:

```bash
#!/usr/bin/env bash
set -euo pipefail
fixture="${PWD}/tests/testdata/env_contract"
log=$(mktemp)
trap 'rm -f "$log"' EXIT

# --dry-run prevents actual agent invocation; we are gating the env, not the agents.
(cd "$fixture" && \
 TEKHTON_HOME="${PWD}/../../.." \
 bin/tekhton run --milestone m27fix --no-tui --dry-run) \
    >"$log" 2>&1 || true

if grep -q 'unbound variable' "$log"; then
    echo "FAIL: stage subprocess hit set -u — contract regression detected." >&2
    grep -n 'unbound variable' "$log" >&2
    exit 1
fi

# Also check for the secondary symptom: command-not-found from missing source.
if grep -qE ': command not found' "$log"; then
    echo "FAIL: subprocess reached an undefined function — sourcing regression." >&2
    grep -nE ': command not found' "$log" >&2
    exit 1
fi

echo "PASS: stage env contract clean across all subprocesses."
```

The test is intentionally pessimistic — any single `unbound variable` or `command not found` line on stderr fails it. False positives are preferable to silent regressions.

### Goal 3 — Defensive sweep

Run `scripts/audit-bash-env.sh` once at milestone start. The output is the work list. For each `path:line:matched-line`:

1. Identify the contract var.
2. Look up its default in `internal/config/defaults.go` (or the runtime-flag default in `StageEnvV1`).
3. Replace `"$VAR"` with `"${VAR:-<default>}"` or `"${VAR:-}"` (if no meaningful default and the read is just used for a `==` comparison).
4. Re-run the audit. Site removed from the list.

This is mechanical work, not creative. A small helper `scripts/apply-bash-env-defaults.sh` can do most of it as `sed -i 's/\$VAR\b/\${VAR:-DEFAULT}/g'` per (var, default) pair, with the audit acting as the verifier.

Constraint: do **not** weaken any existing logic. A site that reads `$VAR` and compares against `true` should become `${VAR:-false}` (so the comparison preserves the boolean meaning), not `${VAR:-}`. Each var has a single correct default — documented inline in `internal/runner/env.go` and `internal/config/defaults.go`.

### Goal 4 — `make dogfood` wires both gates

```makefile
dogfood: self-host audit-bash-env test-stage-env-setu
	@printf '\n[dogfood] cutover gate: env contract clean + parity matrix green.\n'

audit-bash-env: ## Run the bash env audit (fast, grep-based).
	@bash scripts/audit-bash-env.sh

test-stage-env-setu: build ## Run the stage-env parity gate (slow, real subprocess).
	@bash tests/test_stage_env_setu.sh
```

Both gates run on every `make dogfood`. CI invokes `make dogfood`, so any contract regression fails the build.

### Goal 5 — `scripts/wedge-audit.sh` extension

`scripts/wedge-audit.sh` already asserts that certain files exist + certain functions don't reappear. Extend it to assert:

- `scripts/audit-bash-env.sh` exists and is executable.
- The `Makefile` `dogfood:` target depends on `audit-bash-env` and `test-stage-env-setu`.

This keeps a future cleanup pass from accidentally removing the gate while everyone is focused on a different milestone.

### Goal 6 — Per-file header documentation

Every bash file that consumes contract vars gets a one-line header comment:

```bash
#!/usr/bin/env bash
# foo.sh — Brief description.
#
# Expects (from internal/runner/env.go StageEnvV1 contract):
#   MILESTONE_MODE, _CURRENT_MILESTONE, TASK, ANALYZE_CMD, TEST_CMD, ...
#
# Sourced by tekhton-legacy.sh or invoked via lib/finalize_shim.sh.
```

The "Expects" list comes from a one-shot grep of each file against the audit's key list. Future maintainers can read the header and know what env they're operating in without spelunking through call sites.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `scripts/audit-bash-env.sh` | Create | Fast grep-based audit; source-of-truth-driven key list. |
| `scripts/audit-bash-env-allowlist.txt` | Create | Allowlisted (file, var) pairs with rationale comments. |
| `scripts/apply-bash-env-defaults.sh` | Create | Helper to apply mechanical `${VAR:-DEFAULT}` sweeps; audit verifies. |
| `tests/test_stage_env_setu.sh` | Create | Slow parity gate — runs minimal pipeline against fixture, asserts no `unbound variable` / `command not found`. |
| `tests/testdata/env_contract/` | Create | Fixture project: pipeline.conf, agent roles, single noop milestone. |
| `scripts/wedge-audit.sh` | Modify | Assert audit script + Makefile targets exist. |
| `Makefile` | Modify | `dogfood:` depends on `audit-bash-env` + `test-stage-env-setu` targets. |
| `lib/*.sh`, `stages/*.sh` | Modify | Defensive `${VAR:-default}` sweep — exact file list emitted by audit on first run; expected ~40 files. |
| `docs/v4-env-contract.md` | Modify | Section on the audit + parity gate; how to add a new contract var (now includes both the producer change in `env.go` and the audit-allowlist regeneration). |
| `.claude/milestones/MANIFEST.cfg` | Modify | Add `m27|Bash Subprocess Hardening + Env Audit Gates|done|m26|m27-bash-env-hardening.md|phase5`. |

---

## Acceptance Criteria

- [ ] `scripts/audit-bash-env.sh` exists, is executable, and exits 0 against the post-sweep tree. Fails with a non-empty punch list on the pre-sweep tree.
- [ ] `scripts/audit-bash-env.sh` derives its key list from `internal/proto/stage_env.go` + `tekhton config defaults --emit shell` — verified by editing a StageEnvV1 field name and re-running; the audit must surface a new unguarded site if one exists.
- [ ] `scripts/audit-bash-env-allowlist.txt` has at most 10 entries at m27 close, each with an inline `#` comment explaining why the site is intentionally unguarded.
- [ ] `tests/test_stage_env_setu.sh` exists, exits 0 against the m27-close tree. Verified by introducing a deliberate `unset MILESTONE_MODE; echo "$MILESTONE_MODE"` in a stage file and confirming the test fails red.
- [ ] `tests/testdata/env_contract/` has a complete fixture: `.claude/pipeline.conf` with every key from `internal/config/defaults.go`, three agent role files, a noop milestone `m27fix.md`, and a CLAUDE.md.
- [ ] `make dogfood` exits 0 and includes both `audit-bash-env` and `test-stage-env-setu` in its dependency chain — verified by `make -n dogfood` showing both invocations.
- [ ] `scripts/wedge-audit.sh` exits 1 if `scripts/audit-bash-env.sh` is missing or non-executable.
- [ ] The defensive sweep is complete: a fresh `scripts/audit-bash-env.sh` run after the sweep returns zero unguarded sites outside the allowlist.
- [ ] Behavior preservation: `bash tests/run_tests.sh` reports zero new failures vs the m26-close baseline. The sweep is mechanical default-injection; no functional change.
- [ ] Every bash file touched by the sweep has a header comment naming the contract vars it reads — verified by `grep -L 'StageEnvV1 contract' <files-touched>` returning nothing.
- [ ] `docs/v4-env-contract.md` "How to add a new bash global" recipe now includes (a) add to StageEnvV1, (b) populate in `EnvBuilder.Compose`, (c) regenerate audit allowlist if needed, (d) extend `test_stage_env_setu.sh` fixture if the new global enables a new code path.
- [ ] `VERSION` reads `4.27.0` on milestone close.
- [ ] `.claude/milestones/MANIFEST.cfg` contains the row `m27|Bash Subprocess Hardening + Env Audit Gates|done|m26|m27-bash-env-hardening.md|phase5`.
- [ ] The implementation run is itself driven by `tekhton run --milestone m27 --complete` — m27 is the fifth dogfooded V4 milestone.

## Watch For

- **The audit must run against the *source-of-truth* key list, not a hand-maintained one.** If anyone adds a hand-maintained list of keys to `audit-bash-env.sh`, it will drift from the producer side and the gate will silently miss new vars. Generate the list at audit-run time from Go source + `config defaults`.
- **The allowlist is a smell, not a feature.** Every entry is a place the contract is being side-stepped. At m27 close target ≤10 entries; review the list on every subsequent milestone close and aim to reduce it. Allowlist growth is a regression signal — the parity test should be catching the same sites the allowlist hides.
- **Mechanical sweep does not mean blind sweep.** A site reading `$MILESTONE_MODE` for a `== true` comparison wants `${MILESTONE_MODE:-false}`; a site reading `$CODER_MAX_TURNS` for `local turns="$CODER_MAX_TURNS"` wants `${CODER_MAX_TURNS:-40}` (the configured default). Each var has *one* correct default, sourced from `internal/config/defaults.go` or the `StageEnvV1` zero value. The `apply-bash-env-defaults.sh` helper makes the mechanical part fast; the human review on each var's default value is non-skippable.
- **`--dry-run` in the parity gate is load-bearing.** Without it, the fixture pipeline would actually invoke agents (and require API access). With it, the runner walks every stage's request-build code path but stops short of agent invocation — exactly the surface we want to exercise. Verify the dry-run path covers intake/coder/security/review/tester request building; if a stage short-circuits before its env is consumed, the gate misses regressions in that stage.
- **The audit catches reads, not writes.** A bash file that *writes* `MILESTONE_MODE=true` and then *reads* it is correct in isolation but masks a missing producer contract. The audit will pass; the parity test catches it by running the real producer side. Both gates are needed; neither alone is sufficient.
- **Don't migrate test_self_host_dry_run_gate into the env-contract test.** That test (m22 closeout fix) has a different shape — it's a CLI gate test, not an env-contract test. Keep them separate so failure modes don't get confused.

## Seeds Forward

- **Phase 5 port milestones (m23 / m24 / m25 / m28+):** Each can rely on the env contract + audit. When porting a bash subsystem, the workflow becomes: (a) check the audit allowlist for sites in that subsystem; (b) port the subsystem to Go; (c) delete the bash files; (d) remove the allowlist entries; (e) parity gate confirms no regression. The audit is the work-tracking tool for the port.
- **CI integration:** Today `make dogfood` is the cutover gate. After m27, both new gates run there. A future milestone could surface them as separate GitHub Actions checks (`audit-bash-env`, `stage-env-setu`) so PR feedback is granular instead of bundled.
- **`tekhton config validate` extension (deferred from m26):** After m27, `validate` can additionally run the audit script — closing the loop between "config says key X exists" and "every bash reader of key X is guarded". Lifts the audit from a CI gate to a developer-loop gate.
- **V5 — Multi-provider env propagation:** `DESIGN_v5.md` requires per-provider env injection (different `CLAUDE_*_MODEL` values per provider). m27's contract + audit pattern is the right shape — the producer side gains a provider dimension, the audit gains per-provider key sets, the parity test gains per-provider fixtures. The audit/parity infrastructure is reusable; only the env builder grows.
- **Documentation sync rule:** Each milestone that adds a new bash file under `lib/` or `stages/` must add the file's header comment (Expects list) and re-run the audit before merge. Codify this in `CLAUDE.md` Rule 11 after m27 lands so it's not just a milestone-local rule.
