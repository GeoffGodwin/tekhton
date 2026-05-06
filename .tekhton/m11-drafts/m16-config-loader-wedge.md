<!-- milestone-meta
id: "16"
status: "todo"
-->

# m16 — Config Loader Wedge

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | Phase 4 — fifth wedge. `lib/config.sh` + `lib/config_defaults.sh` + `lib/config_defaults_ci.sh` (~600 LOC total) load `pipeline.conf`, apply defaults, validate types, and clamp value ranges. Every Go subsystem ported so far reads config through env vars set by bash; m16 makes config first-class Go so the orchestrate loop, prompt engine, and supervisor all read from one source of truth. |
| **Gap** | Config keys are scattered across three bash files. Defaults are bash assignments (`KEY:=default`); validation is inline `case` statements; CI auto-detection (`config_defaults_ci.sh`) re-runs on every shell invocation. Go subsystems re-read env vars instead of consuming a typed config struct. |
| **m16 fills** | (1) `internal/config` package with `Load(path)` returning a typed `Config` struct. (2) `pipeline.conf` format unchanged (KEY=value, comments) — operators continue to author it as today. (3) `tekhton config show` / `tekhton config validate` subcommands. (4) Defaults expressed as Go struct tags or a defaults map. (5) CI auto-detection ports to `internal/config/ci.go`. (6) Go consumers (orchestrate, prompt, dag) take a `*config.Config` parameter instead of reading env vars. |
| **Depends on** | m12 |
| **Files changed** | `internal/config/` (new), `cmd/tekhton/config.go` (new), `lib/config.sh` (shim rewrite), `lib/config_defaults.sh` (shrink — only the keys still used by un-ported bash callers), `lib/config_defaults_ci.sh` (delete after CI logic ports), `scripts/config-parity-check.sh` (new) |
| **Stability after this milestone** | Stable. `pipeline.conf` format unchanged; existing user configs work without edits. |
| **Dogfooding stance** | Cutover within milestone. |

---

## Design

### Goal 1 — Typed config struct

```go
package config

type Config struct {
    Project      Project
    Pipeline     Pipeline
    Models       Models
    Limits       Limits
    Features     Features
    UI           UI
    Quota        Quota
    // ...
}

func Load(path string) (*Config, error)
func (c *Config) Validate() error
```

Group related keys into nested structs (matching the doc-comment groupings
in `lib/config_defaults.sh`). Each field carries struct tags for the conf
key name + default + validation predicate:

```go
type Limits struct {
    MaxReviewCycles int `conf:"MAX_REVIEW_CYCLES" default:"5" min:"1" max:"20"`
    MaxTransientRetries int `conf:"MAX_TRANSIENT_RETRIES" default:"3" min:"0" max:"10"`
    // ...
}
```

### Goal 2 — Bash shim shape

`lib/config.sh::load_config` becomes a 50-line shim that:

1. Calls `tekhton config load --path .claude/pipeline.conf --emit shell`.
2. Sources the resulting shell script (which exports the validated keys).
3. Falls back to bash-only loading if the binary is missing (per the
   wedge pattern's bash-fallback rule).

The Go side emits the same env vars bash callers already read, so
unported stages and helpers see no change.

### Goal 3 — CI auto-detection

`lib/config_defaults_ci.sh` detects CI environments and elevates
`TEKHTON_UI_GATE_FORCE_NONINTERACTIVE`. Ports to
`internal/config/ci.go::DetectCI()` returning a `CIPlatform` enum. The
m138 contract (env-var precedence, opt-out path) is preserved exactly.

### Goal 4 — `tekhton config show / validate`

`tekhton config show` prints the loaded + validated config as JSON or
shell-script-style env-var assignments. `tekhton config validate` exits 0
if the config is valid, 1 + a diagnostic on invalid (out-of-range,
unknown key, type mismatch).

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/config/` | Create | Loader, defaults, CI detection, validation. ~500-700 LOC. |
| `cmd/tekhton/config.go` | Create | `config show / validate / load` subcommands. ~150 LOC. |
| `lib/config.sh` | Modify | Rewrite as ~50-line shim. |
| `lib/config_defaults.sh` | Modify | Shrink — keep only keys still consumed by un-ported bash. |
| `lib/config_defaults_ci.sh` | Delete | Logic moves to `internal/config/ci.go`. |
| `scripts/config-parity-check.sh` | Create | Round-trip parity. ~150 LOC. |

---

## Acceptance Criteria

- [ ] `tekhton config load --path .claude/pipeline.conf --emit shell | source` produces an environment matching the post-`load_config` bash shell environment for every fixture under `tests/fixtures/config/`.
- [ ] `tekhton config validate` rejects unknown keys, out-of-range values, type mismatches with a clear diagnostic.
- [ ] `pipeline.conf` format is unchanged; existing user configs load without edits.
- [ ] `lib/config.sh` is ≤ 60 lines.
- [ ] `lib/config_defaults_ci.sh` is deleted; CI auto-detection runs in Go.
- [ ] `internal/config` coverage ≥ 80%.
- [ ] `scripts/config-parity-check.sh` exits 0 against ~10 fixtures (default config, fully customized, CI environment, missing required keys, invalid types, out-of-range values, unknown key warning, m138 CI override, milestone-mode override stack, edge-case empty values).
- [ ] `bash tests/run_tests.sh` passes; config-related tests (`test_validate_config*.sh`, `test_m138_*.sh`) adapted.

## Watch For

- **Default values are load-bearing.** Every config key in `lib/config_defaults.sh` has a default; getting any of them wrong silently changes pipeline behavior. The fixture set must cover "every key at default".
- **CI auto-detection is m138-specific.** Don't expand its scope; the rule is "elevate `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE` to `1` inside CI when not set in `pipeline.conf`". Replicate exactly.
- **Milestone-mode overrides** apply on top of base config. The override stack (`apply_milestone_overrides()`) ports along with the loader; don't leave it bash-only.
- **Don't introduce a config schema migration.** A future v2 config format (YAML?) is a separate decision.

## Seeds Forward

- **m17 — error taxonomy:** `config.ValidationError` joins the typed error set.
- **In-process callers:** orchestrate (m12), prompt (m15), dag (m14) all eventually take a `*config.Config` parameter directly. m16 introduces the type; the parameter additions land per-package.
- **V5 multi-provider config:** provider blocks (`anthropic.api_key`, `openrouter.api_key`, etc.) extend the `Config` struct at the package boundary V5 sets up. Out of scope for m16.
