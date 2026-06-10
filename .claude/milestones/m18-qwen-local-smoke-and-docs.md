<!-- milestone-meta
id: "18"
status: "todo"
-->

# m18 — qwen-local End-to-End Tool-Loop Smoke Test + Chain Ordering + Operator Runtime Docs

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | A local provider that emits plausible text but silently fails to *call tools* is worse than useless in an unattended pipeline — it reports success while editing nothing. Both research streams that scoped this arc flagged that every local-agent CLI (codex/qwen-code/opencode/aider) can fail exactly this way against a local model: the model says "I'll edit the file" and never emits the tool call. m17 wires `qwen-local` but proves nothing about whether the tool loop actually fires. m18 is the honesty gate plus the operator-facing runtime story. |
| **Gap** | After m17 there is no test that exercises `qwen-local` end-to-end against a real local server. Nothing validates that `PROVIDER=qwen-local` (fully local) or `PROVIDER=qwen-local,codex,claude` (local-first with paid fallback) routes correctly and records `tier_used="local"` in `RUN_SUMMARY`. `--require-tier local` has no test. And there is no operator documentation for standing up the local runtime (Ollama + Qwen2.5-Coder-32B). |
| **m18 fills** | (1) `tests/test_qwen_local_smoke.sh` — a shim-boundary integration test that probes `QWEN_LOCAL_BASE_URL`; when a server is reachable it drives `qwen-local` on a fixture task that MUST modify a known file *and* run a shell command, then asserts the file content changed and the command's marker exists. When no server is reachable it self-skips cleanly (never blocks CI or contributors). (2) A runner/chain test asserting a `qwen-local,codex,claude` chain records `tier_used="local"` when the local provider succeeds. (3) A `--require-tier local` enforcement test (codex/claude rejected with `TIER_LIMIT_EXCEEDED`). (4) Operator runtime docs in `docs/v5-polyglot.md` + `docs/v5-tier-model.md`: Ollama install, `ollama pull qwen2.5-coder:32b`, serving, `wire_api=chat`, the "produces text but no tool calls" troubleshooting entry, and model/quant guidance (32B Q4_K_M as the reliability floor; an RTX-4090-class GPU is sufficient). |
| **Depends on** | m17 |
| **Files changed** | `tests/test_qwen_local_smoke.sh` (CREATE), `tests/fixtures/qwen_local_smoke/` (CREATE — fixture task), `internal/runner/provider_chain_test.go` or `provider_select_test.go` (modify — tier_used + require-tier), `docs/v5-polyglot.md` (modify), `docs/v5-tier-model.md` (modify), `VERSION` |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m15 | Wired the chain + CLI flags + first operator docs |
| m17 | Added the `qwen-local` provider (codex delegation) + config |
| **m18** | **Proves the local tool loop actually fires, and documents the runtime** |

---

## Design

### Goal 1 — End-to-end tool-loop smoke test (the honesty gate)

**File:** `tests/test_qwen_local_smoke.sh`. Follow the self-skipping
shim-boundary pattern from `tests/test_pin_version_validation.sh`.

```bash
# Probe the configured local endpoint; skip cleanly if unreachable.
base="${QWEN_LOCAL_BASE_URL:-http://localhost:11434/v1}"
if ! curl -fsS --max-time 3 "${base%/v1}/" >/dev/null 2>&1 \
     && ! curl -fsS --max-time 3 "$base/models" >/dev/null 2>&1; then
    echo "SKIP: no local server reachable at $base — set up Ollama to run this test"
    exit 0
fi
command -v codex >/dev/null 2>&1 || { echo "SKIP: codex not on PATH"; exit 0; }
```

When reachable, run `tekhton` with `PROVIDER=qwen-local` against a fixture
task whose only correct completion is to **edit a file and run a command**:

- Task: "Append the line `TOOL_LOOP_OK` to `marker.txt`, then run
  `date +%s > ran.txt`."
- Assert AFTER the run: `marker.txt` contains `TOOL_LOOP_OK` **and**
  `ran.txt` exists and is non-empty.

The assertion is on **observable side effects only** — never on model
output text (non-deterministic). The test answers one question: *did the
tool loop fire end-to-end against a local model?*

### Goal 2 — Chain tier recording + `--require-tier local`

Add runner-level tests (stubbed providers, no live server):

- A `NewChain("qwen-local","codex","claude")` where the stubbed
  `qwen-local` returns `OutcomeSuccess` records `tier_used="local"` in the
  result/`RUN_SUMMARY` (the chain records the *winning* provider's tier per
  `docs/v5-tier-model.md`).
- `tekhton run --require-tier local` rejects `codex` (subscription) and
  `claude` (api) with `ErrorSubcategory: TIER_LIMIT_EXCEEDED`, since their
  cost rank exceeds `local`'s.

### Goal 3 — Operator runtime docs

Extend `docs/v5-polyglot.md` with a runnable recipe:

```bash
# 1. Install Ollama, pull a coding-capable model (32B is the floor for
#    reliable agentic tool-calling; Q4_K_M fits a 24GB GPU).
ollama pull qwen2.5-coder:32b
# 2. Ollama serves an OpenAI-compatible endpoint at :11434/v1 automatically.
# 3. Point Tekhton at it (defaults already match Ollama):
#    QWEN_LOCAL_BASE_URL=http://localhost:11434/v1
#    QWEN_LOCAL_MODEL=qwen2.5-coder:32b
# 4. Run local-first with paid fallback:
PROVIDER=qwen-local,codex,claude tekhton run --milestone mNN
# 5. Or fully offline / zero-billing:
PROVIDER=qwen-local tekhton run --milestone mNN
```

Add a troubleshooting entry for the signature local failure: *run reports
success but no files changed* → the model isn't emitting tool calls; check
`wire_api=chat` (not `responses`), use a ≥32B model at ≥4-bit, and confirm
the smoke test passes before trusting the provider in a real run. Update the
`local` tier row in `docs/v5-tier-model.md` to reflect a *shipped* provider
(not "Phase 2 future").

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `tests/test_qwen_local_smoke.sh` | Create | Self-skipping end-to-end tool-loop test; asserts file edit + shell command side effects when a local server is reachable. |
| `tests/fixtures/qwen_local_smoke/` | Create | Minimal fixture project + task for the smoke test. |
| `internal/runner/provider_chain_test.go` | Modify | Assert `tier_used="local"` for a local-winning chain and `TIER_LIMIT_EXCEEDED` for `--require-tier local`. |
| `docs/v5-polyglot.md` | Modify | Local runtime recipe + silent-tool-call troubleshooting. |
| `docs/v5-tier-model.md` | Modify | Update the `local` tier row to "shipped". |
| `VERSION` | Modify | Bump on milestone completion. |

---

## Acceptance Criteria

- [ ] `tests/test_qwen_local_smoke.sh` exits 0 and prints a `SKIP:` line when no server is reachable at `QWEN_LOCAL_BASE_URL` or when `codex` is not on PATH (asserted by running it with no server in CI).
- [ ] When a local server IS reachable, the smoke test drives `qwen-local` on the fixture task and asserts both side effects: `marker.txt` contains `TOOL_LOOP_OK` AND `ran.txt` exists and is non-empty. (Gated; the file documents how to run it locally.)
- [ ] The smoke test asserts only on file/command side effects, never on model output text.
- [ ] A runner test asserts a `qwen-local,codex,claude` chain records `tier_used="local"` when a stubbed `qwen-local` succeeds.
- [ ] A runner test asserts `--require-tier local` (or `TEKHTON_REQUIRE_TIER=local`) rejects `codex` and `claude` with subcategory `TIER_LIMIT_EXCEEDED`.
- [ ] `docs/v5-polyglot.md` contains a copy-pasteable Ollama + `qwen2.5-coder:32b` setup recipe and a troubleshooting entry for the silent no-tool-call failure mode.
- [ ] `docs/v5-tier-model.md`'s `local` row no longer says "V5 Phase 2"/future — it reflects the shipped provider.
- [ ] All new/modified tests pass; no regression in `internal/runner` / `internal/provider` tests; `go vet ./...` and `golangci-lint run` clean.
- [ ] `shellcheck tests/test_qwen_local_smoke.sh` passes with zero warnings.

## Watch For

- **Self-skip is mandatory.** The smoke test must exit 0 with a `SKIP:` message when no local server (or no `codex`) is present, exactly like `tests/test_pin_version_validation.sh`. It cannot block contributors who haven't provisioned Ollama. Putting a live-server requirement in the blocking path would break CI.
- **Assert side effects, not quality.** Local model output is non-deterministic; assert the file changed and the command ran, not what the code says. The test answers "did the tool loop fire," not "was the work good."
- **`codex` on PATH + a running local server** are both required for the live path (qwen-local delegates to codex from m17). Document both prerequisites.
- **Keep the default chain `codex,claude`.** m18 documents local as opt-in. Flipping the default to include `qwen-local` is a *separate* future decision that should wait until the smoke test passes reliably in practice — call that out in the docs, don't do it here.
- **`wire_api=chat`** in every documented config snippet; the Responses API path is the known local breakage source.

## Seeds Forward

- **Default-chain promotion:** reliability data from the smoke test is the evidence needed to decide whether `qwen-local` graduates into the default `PROVIDER` chain.
- **Native qwen-code provider:** if the codex-delegation smoke test is flaky against local Qwen, the same fixture + side-effect assertions validate a dedicated `qwen-code` provider drop-in.
- **Zero-billing CI:** `--require-tier local` + a provisioned local server unlocks fully-offline pipeline runs with no API exposure.
- **Smoke-test harness reuse:** the file-edit + shell-command side-effect fixture is reusable to validate any future local/agent-CLI provider.
