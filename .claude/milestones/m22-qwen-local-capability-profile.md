<!-- milestone-meta
id: "22"
status: "todo"
-->

# m22 — qwen-local Capability Profile: Turn, Context, and Format Adaptation for 32B-Class Models

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | The local fallback only matters if it works in practice. m17/m18 proved the qwen-local plumbing (codex-sibling provider, chat wire API, tool-loop smoke test), but every prompt, turn budget, and context window assumption in the pipeline is Claude-tuned. Qwen2.5-Coder-32B at Q4 on the operator's RTX 4090 has a smaller usable context, weaker long-horizon planning, and less reliable structured output than the models the budgets were calibrated against. Without adaptation, qwen-local runs will burn turn budgets, overflow context, and produce malformed envelopes — making the free tier a trap instead of a hedge. DESIGN_v5.md's pre-computed provider profiles cover this; none of it is implemented. |
| **Gap** | (1) No per-provider request adaptation exists: `internal/provider/local/local.go` delegates to codex with endpoint config only — `MaxTurns`, prompt content, and context budget pass through Claude-calibrated values. (2) Context sizing (`CONTEXT_BUDGET_PCT`, `MILESTONE_WINDOW_*`, repo-map token budget) has no provider dimension — a 128k-Claude window assumption meets a much smaller practical local window. (3) No structured-output reinforcement for models that drift out of JSON/tool-call format. (4) No calibration record: the operator has no way to capture "what worked on my hardware" as config rather than folklore. |
| **m22 fills** | A minimal, deterministic profile layer — not the full DESIGN_v5 calibration subsystem. (1) `internal/provider/profile.go`: a `Profile{MaxTurnsFactor, ContextBudgetPct, MaxPromptChars, FormatReinforcement}` struct with a hardcoded conservative default for `qwen-local`, overridable via `.claude/provider_profiles/<name>.conf` (flat key=value). (2) The supervise bridge / stage dispatch applies the resolved provider's profile to the outgoing request: scales `MaxTurns`, clamps prompt size (with a logged truncation note), and prepends the format-reinforcement preamble to the request prompt content when set. (3) Plumbs a provider-aware `CONTEXT_BUDGET_PCT` override into the bash context layer via the env contract (`TEKHTON_PROVIDER_CONTEXT_PCT`) — the consuming reads live in `lib/context.sh:100,150` (`check_context_budget`), NOT `lib/context_budget.sh`, which never reads the key — so prompt assembly shrinks before rendering rather than truncating after. (4) `docs/v5-polyglot.md` gains a calibration guide for Qwen2.5-Coder-32B/RTX-4090-class hardware with the measured starting values. |
| **Depends on** | m17, m18, m19 |
| **Files changed** | `internal/provider/profile.go` (new), `internal/provider/profile_test.go` (new), `internal/runner/supervise_bridge.go`, `internal/runner/provider_chain.go`, `internal/runner/env.go`, `internal/config/defaults.go`, `lib/context.sh` (env-contract read), `templates/pipeline.conf.example`, `docs/v5-polyglot.md`, `docs/v4-env-contract.md`, `tests/test_qwen_local_smoke.sh` |

---

## Design

### Sequencing note

Depends on m19's supervise bridge: the profile is applied where the
provider is resolved, which after m19 is one seam instead of three.
This milestone is **not** June-15-blocking (codex is the primary
fallback); schedule it after m19–m21 if the deadline squeezes.

### Goal 1 — `provider.Profile`

```go
// Profile captures per-provider request adaptation. Zero value = no
// adaptation (Claude/Codex default).
type Profile struct {
    MaxTurnsFactor      float64 // scales req.MaxTurns; 0 means 1.0
    ContextBudgetPct    int     // overrides CONTEXT_BUDGET_PCT; 0 = inherit
    MaxPromptChars      int     // hard clamp on rendered prompt; 0 = none
    FormatReinforcement string  // block prepended to request prompt content; "" = none
}
```

`ProfileFor(name string) Profile`: returns the built-in default for the
name (`qwen-local` → conservative: MaxTurnsFactor 1.5, ContextBudgetPct
25, MaxPromptChars sized to ~24k tokens at `CHARS_PER_TOKEN`,
FormatReinforcement = short "respond only with valid tool calls / JSON"
block), then merges `.claude/provider_profiles/<name>.conf` overrides if
present (flat `KEY=value`, same parsing discipline as pipeline.conf).
Unknown keys warn, never fail. Claude and codex built-ins are zero
profiles.

### Goal 2 — application at the seam

In the supervise bridge and stage dispatch (the two places a resolved
provider receives a request after m19): apply `ProfileFor(p.Name())`
before invocation. For chains, the profile of the provider actually
being attempted applies — i.e. application happens inside
`Chain.RunAgent`'s per-provider loop, not once up front. Turn scaling
rounds up; clamping logs one line with original/clamped sizes;
reinforcement prepends without altering the rendered prompt file on
disk (request-level, byte-for-byte prompt files preserved for parity).

### Goal 3 — provider-aware context budget (pre-render)

Post-render clamping is a backstop; the real fix is shrinking assembly.
When the resolved profile for the stage's first-choice provider sets
`ContextBudgetPct`, the runner exports `TEKHTON_PROVIDER_CONTEXT_PCT`
into the stage env (producer: `internal/runner/env.go::AsKV` per the V4
env contract). The bash-side consumers are the `CONTEXT_BUDGET_PCT`
reads in `lib/context.sh:100,150` (`check_context_budget`) — change
those to `${TEKHTON_PROVIDER_CONTEXT_PCT:-${CONTEXT_BUDGET_PCT:-50}}`.
(`lib/context_budget.sh` never reads the key — don't patch it.) Decide
explicitly whether `lib/milestone_window_build.sh:41` (the milestone
window's own budget read) participates; if it stays on the base
budget, say so in the doc. Document the new variable in
`docs/v4-env-contract.md`'s table.

### Goal 4 — calibration documentation + smoke extension

`docs/v5-polyglot.md`: a "Calibrating qwen-local" section — the
hardware reference point (RTX 4090 24GB, Q4_K_M 32B, ~30k usable
context at acceptable throughput), the three knobs, how to write the
override file, symptoms table (malformed tool calls → reinforcement;
mid-task amnesia → lower context pct; chronic MaxTurns exhaustion →
raise factor). Extend `tests/test_qwen_local_smoke.sh` with a profile
assertion: when an override file sets `MAX_PROMPT_CHARS=1000`, the
smoke run logs the clamp line (skip-gated like the rest of the smoke).

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/provider/profile.go` | Create | Profile struct, built-in defaults, override-file merge. |
| `internal/provider/profile_test.go` | Create | Defaults, merge precedence, malformed-file tolerance. |
| `internal/runner/supervise_bridge.go` | Modify | Apply profile to outgoing requests. |
| `internal/runner/provider_chain.go` | Modify | Per-provider profile application inside the attempt loop. |
| `internal/runner/env.go` | Modify | Export `TEKHTON_PROVIDER_CONTEXT_PCT` when profile sets it. |
| `lib/context.sh` | Modify | `check_context_budget` reads (`:100,150`) gain provider-override precedence. |
| `internal/config/defaults.go` | Modify | Register the new env key in the contract table. |
| `templates/pipeline.conf.example` | Modify | Pointer to provider_profiles override mechanism. |
| `docs/v5-polyglot.md` | Modify | Calibration guide for 32B-class local models. |
| `docs/v4-env-contract.md` | Modify | New contract variable row. |
| `tests/test_qwen_local_smoke.sh` | Modify | Profile clamp assertion (skip-gated). |

---

## Acceptance Criteria

- [ ] `ProfileFor("qwen-local")` returns the documented conservative defaults; `ProfileFor("claude")` and `ProfileFor("codex")` return zero profiles (table test).
- [ ] An override file `.claude/provider_profiles/qwen-local.conf` setting `MAX_TURNS_FACTOR=2.0` changes the applied factor; a malformed line warns and is skipped without failing the run (test asserts both).
- [ ] A request with `MaxTurns=20` dispatched to a provider whose profile has `MaxTurnsFactor=1.5` reaches the provider with `MaxTurns=30` (bridge test with fake provider).
- [ ] A rendered prompt larger than `MaxPromptChars` is clamped in the request and a log line records original and clamped char counts; the prompt file on disk is unchanged (byte-compare in test).
- [ ] `FormatReinforcement` text appears at the start of the request prompt content the provider receives (`provider.Request` has a single combined prompt — there is no separate system-prompt channel), and only for providers whose profile sets it.
- [ ] In a chain `codex,qwen-local`, a fallthrough to qwen-local applies qwen-local's profile, and the codex attempt did not (two-fake-provider chain test).
- [ ] With the profile setting `ContextBudgetPct=25`, the stage env contains `TEKHTON_PROVIDER_CONTEXT_PCT=25` and `check_context_budget` in `lib/context.sh` honors it over `CONTEXT_BUDGET_PCT` (shim-boundary or bash unit test).
- [ ] `scripts/audit-bash-env.sh` passes with the new contract variable.
- [ ] All new tests pass; no regression in `go test ./...`, `bash tests/run_tests.sh`, `tests/test_qwen_local_smoke.sh` (self-skipping rules preserved).
- [ ] `docs/v5-polyglot.md` calibration section and `docs/v4-env-contract.md` row exist.

## Watch For

- **Scope discipline:** this is the minimal profile layer, NOT DESIGN_v5's automated calibration runs, capability detection, or prompt-based tool injection for non-tool models. Those need their own milestones; resist building them here.
- **Parity invariant:** prompt files on disk must remain byte-identical for identical inputs (Non-Negotiable rule 6). All adaptation is request-level.
- **Turn-scaling interactions:** `MILESTONE_ACTIVITY_TIMEOUT_MULTIPLIER` and continuation logic key off MaxTurns-adjacent values; verify scaled turns don't break turn-exhaustion continuation accounting (`lib/turns.sh`).
- **Chain ordering surprise:** profiles apply per attempted provider — RUN_SUMMARY turn counts may differ between providers for the same stage; the metrics collectors must not assume one budget per stage run.
- **Pre-render budget vs fallthrough:** `TEKHTON_PROVIDER_CONTEXT_PCT` is exported from the *first-choice* provider's profile, but a chain fallthrough to qwen-local executes against a prompt assembled at the first provider's budget — only the request-level clamp protects that case. This is accepted for m22; do not try to re-render mid-chain.
- **Don't tune blind:** the doc's starting values are hypotheses; mark them as such and tell the operator to record measured overrides in the override file, which is gitignored project-side state.

## Seeds Forward

- **Full calibration subsystem (DESIGN_v5):** the override-file format is the storage target a future `tekhton calibrate --provider qwen-local` writes into.
- **Prompt-based tool injection:** `FormatReinforcement` is the thin edge of supporting models without native tool calling.
- **Multi-local-model support:** the profile mechanism is name-keyed, so a future `llama-local` or second endpoint reuses it unchanged.
