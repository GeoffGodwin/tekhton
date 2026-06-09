<!-- milestone-meta
id: "09"
status: "todo"
-->

# m09 (V5) — Codex Tool Schema Translator

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | V5 Phase 1, Milestone 9 — third of the Codex provider arc. m07-m08 established the invocation + JSON event decode for Codex. m09 lands the tool-schema translator: converting Tekhton's canonical `provider.ToolSchema` (from m03) to whatever Codex CLI consumes for tool restriction. The audit established that Codex's primary built-in is `shell` (a.k.a. `container.exec`) with JSON Schema parameter validation following OpenAI Responses API conventions. m09 surfaces three integration points: (1) passing the tool set via `-c key=value` inline config or via `--output-schema` for response shape validation, (2) the per-stage tool restriction (CoderTools vs ReviewerTools vs IntakeTools) from m03's canonical set, and (3) graceful handling when a Tekhton ToolSchema doesn't map cleanly to a Codex equivalent — fall back to the broader `shell` tool with a runtime guardrail. |
| **Gap** | At m08 close, `(*codex.Provider).RunAgent` invokes `codex exec --json --sandbox workspace-write [...]` with no tool restriction. The CLI's built-in `shell` tool is available; whatever tools the agent uses are whatever Codex defaults to. Tekhton's m03 ToolSchema (Read, Write, Edit, Bash, Glob, Grep + per-stage subsets) doesn't yet inform Codex. For reviewer/intake/security stages that should be read-only, this is a real safety concern — a misbehaving agent could `Write` to source files during a Reviewer pass. We need to translate Tekhton's tool spec into Codex's tool restriction mechanism. The audit identified that Codex restricts tools via inline config keys (e.g., `-c tools.shell.allowed_commands=["read","grep"]` shape — see the protocol's `permissions.rs` and `network_policy.rs`) and via the `--sandbox` mode. For read-only stages, `--sandbox read-only` is the right baseline; for code-modifying stages, `workspace-write`. For the finer-grained Read/Write/Edit/Bash split, Codex's permissions config layer is the surface. |
| **m09 fills** | (1) `internal/provider/codex/tools.go` — `translateTools([]provider.ToolSchema) ([]string, []string, error)` returning two slices: the `-c key=value` config arg list, and any `--sandbox` mode override. Maps Tekhton's BehaviorHints to Codex semantics: `Reads=true && !ModifiesFiles && !ExecutesShell` → `--sandbox read-only`; `ModifiesFiles=true` → `--sandbox workspace-write`; `ExecutesShell=true` → keep `workspace-write` AND surface in `-c` config. (2) `internal/provider/codex/tool_map.go` — explicit mapping table: Tekhton tool name → Codex equivalent. `Read` → Codex's read primitive, `Bash` → `shell`, etc. The table is small (6 entries matching the m03 canonical set). (3) Buildargs in `flags.go` (m07) updates to consume the translator output: pass through the inline config args and override the default sandbox mode based on the tool set. (4) Per-stage routing: when `req.ProviderSpecific["codex.tool_set"]` is set (`"coder"`, `"reviewer"`, `"tester"`, `"intake"`), apply the corresponding `tools.CoderTools` / `tools.ReviewerTools` / `tools.TesterTools` / `tools.IntakeTools` set automatically. (5) Tests + recorded translation fixtures. |
| **Depends on** | m07, m08 |
| **Files changed** | `internal/provider/codex/tools.go` (~160 LOC), `internal/provider/codex/tool_map.go` (~80 LOC), `internal/provider/codex/flags.go` (modify — wire tool args, ~30 LOC delta), `internal/provider/codex/tools_test.go` (~180 LOC), `internal/provider/codex/testdata/tool_translations/*.json` (recorded fixtures), `VERSION` |

---

## Design

### Sequencing note

m09 lands after m08 because the translator's behavior changes
`buildExecArgs` (from m07) which is now responsible for both event
parsing input (m08) and tool restriction (m09). Coupling these two
changes into a single milestone risks two unrelated regressions
landing together. Better: m08 first (decoder + outcome), m09 second
(tool args layered on top of stable m07/m08 invocation surface).

### Goal 1 — `translateTools` translator

**File:** `internal/provider/codex/tools.go`.

```go
package codex

import (
    "fmt"

    "github.com/geoffgodwin/tekhton/internal/provider"
)

// translateTools converts a Tekhton ToolSchema slice into Codex CLI
// invocation arguments. Returns:
//   - extraArgs: -c key=value config overrides for tool restriction
//   - sandboxOverride: a sandbox mode string ("read-only" |
//     "workspace-write" | ""); empty means use the default
//
// The translation derives Codex semantics from Tekhton's
// BehaviorHints:
//   ModifiesFiles=true OR ExecutesShell=true → "workspace-write"
//   Reads=true and others false              → "read-only"
//
// Per-tool granularity (Read vs Write vs Edit vs Bash vs Glob vs
// Grep) is expressed via Codex's permissions config layer. The
// tool_map.go table maps each Tekhton name to its Codex permission
// key.
func translateTools(tools []provider.ToolSchema) (extraArgs []string, sandboxOverride string, err error) {
    if len(tools) == 0 {
        // No tools specified — use Codex's defaults.
        return nil, "", nil
    }

    // Validate each input.
    for _, t := range tools {
        if err := provider.ValidateToolSchema(t); err != nil {
            return nil, "", fmt.Errorf("codex: invalid tool %q: %w", t.Name, err)
        }
    }

    // Derive sandbox mode from aggregate BehaviorHints.
    var (
        anyModifies bool
        anyShell    bool
        anyReads    bool
    )
    for _, t := range tools {
        if t.BehaviorHints.ModifiesFiles { anyModifies = true }
        if t.BehaviorHints.ExecutesShell  { anyShell = true }
        if t.BehaviorHints.Reads          { anyReads = true }
    }

    switch {
    case anyModifies || anyShell:
        sandboxOverride = "workspace-write"
    case anyReads:
        sandboxOverride = "read-only"
    }

    // Build per-tool permission entries via the mapping table.
    allowed := make([]string, 0, len(tools))
    for _, t := range tools {
        codexName, ok := codexToolName(t.Name)
        if !ok {
            // Unknown tool — surface as a -c entry that grants the
            // catch-all `shell` permission. The runtime check in m11
            // will warn about unmapped tools.
            allowed = append(allowed, "shell")
            continue
        }
        allowed = append(allowed, codexName)
    }
    extraArgs = []string{
        "-c", fmt.Sprintf("tools.allowed=%s", joinAllowed(allowed)),
    }
    return extraArgs, sandboxOverride, nil
}

func joinAllowed(names []string) string {
    // Codex's inline config expects a TOML/JSON-style array literal.
    // Quote each name and join with commas inside brackets.
    parts := make([]string, 0, len(names))
    for _, n := range names {
        parts = append(parts, fmt.Sprintf("%q", n))
    }
    return "[" + joinComma(parts) + "]"
}
```

### Goal 2 — Tool mapping table

**File:** `internal/provider/codex/tool_map.go`.

```go
package codex

// codexToolMap maps Tekhton canonical tool names to Codex's tool
// permission keys. Used by translateTools to build the -c
// tools.allowed=[...] inline config arg.
//
// The Codex CLI doesn't expose Read/Write/Edit as separate tools —
// they're all expressed through the shell tool's allowed_commands.
// The mapping below translates Tekhton semantics to Codex's coarser
// permission categories.
var codexToolMap = map[string]string{
    "Read":  "fs_read",     // Codex's filesystem read permission key
    "Write": "fs_write",    // Filesystem write permission key
    "Edit":  "fs_write",    // Edit = read + write; mapped to write (read is implied)
    "Bash":  "shell",       // Full shell exec
    "Glob":  "fs_read",     // Pattern matching is read-only
    "Grep":  "fs_read",     // Content search is read-only
}

// codexToolName returns the Codex permission key for a Tekhton
// canonical tool name. Returns ("", false) for unknown names so
// translateTools can route to a safe default.
func codexToolName(tekhtonName string) (string, bool) {
    v, ok := codexToolMap[tekhtonName]
    return v, ok
}
```

### Goal 3 — Per-stage tool set wiring via ProviderSpecific

`req.ProviderSpecific["codex.tool_set"]` accepts one of `"coder"`,
`"reviewer"`, `"tester"`, `"intake"` and resolves to the
corresponding per-stage tool set from `internal/provider/tools/`:

```go
// In flags.go, before calling translateTools:
toolSet := req.Tools
if name := req.ProviderSpecific["codex.tool_set"]; name != "" && len(toolSet) == 0 {
    switch name {
    case "coder":
        toolSet = tools.CoderTools
    case "reviewer":
        toolSet = tools.ReviewerTools
    case "tester":
        toolSet = tools.TesterTools
    case "intake":
        toolSet = tools.IntakeTools
    }
}
extraArgs, sandboxOverride, err := translateTools(toolSet)
```

### Goal 4 — `buildExecArgs` integration

Modify `flags.go` (from m07) to consume the translator output:

```go
// Within buildExecArgs:
extraArgs, sandboxOverride, err := translateTools(toolSet)
if err != nil {
    return nil, err
}
// Override the default sandbox if the translator said so.
if sandboxOverride != "" {
    // Find and replace the --sandbox value in the existing args.
    for i := range args {
        if args[i] == "--sandbox" && i+1 < len(args) {
            args[i+1] = sandboxOverride
            break
        }
    }
}
// Append tool config args.
args = append(args, extraArgs...)
// ... continue with the trailing "-" marker
```

### Goal 5 — Tests + recorded fixtures

**File:** `internal/provider/codex/tools_test.go`.

Six scenarios:

1. Empty tool set → no extra args, no sandbox override
2. `tools.CoderTools` → `-c tools.allowed=["fs_read","fs_write","fs_write","shell","fs_read","fs_read"]` (with `Edit` deduplicating to fs_write) AND `--sandbox workspace-write`
3. `tools.ReviewerTools` (Read/Glob/Grep/Bash) → `-c tools.allowed=["fs_read","fs_read","fs_read","shell"]` AND `--sandbox workspace-write` (because Bash present)
4. `tools.IntakeTools` (Read/Glob/Grep only) → `-c tools.allowed=["fs_read","fs_read","fs_read"]` AND `--sandbox read-only`
5. Invalid ToolSchema (empty Name) → error
6. Unknown tool name → falls back to `shell` (catch-all) with `workspace-write` sandbox

Recorded fixtures under `testdata/tool_translations/`:
- `coder.json` — expected `extraArgs` and `sandboxOverride` for the coder set
- `reviewer.json`, `tester.json`, `intake.json`, `empty.json`, `unknown.json`

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/provider/codex/tools.go` | Create | `translateTools` translator. ~160 LOC. |
| `internal/provider/codex/tool_map.go` | Create | Tekhton → Codex name mapping table. ~80 LOC. |
| `internal/provider/codex/flags.go` | Modify | Consume translator output, apply sandbox override + extra args. |
| `internal/provider/codex/tools_test.go` | Create | Six-scenario table-driven tests. ~180 LOC. |
| `internal/provider/codex/testdata/tool_translations/*.json` | Create | Six recorded fixtures. |
| `VERSION` | Modify | Bump on close. |

---

## Acceptance Criteria

- [ ] `internal/provider/codex/tools.go::translateTools` exists with the signature `func translateTools(tools []provider.ToolSchema) (extraArgs []string, sandboxOverride string, err error)`. Verified by `go doc`.
- [ ] `translateTools(tools.CoderTools)` returns a non-empty `extraArgs` slice AND `sandboxOverride = "workspace-write"`. Verified by `TestTranslateTools/coder`.
- [ ] `translateTools(tools.IntakeTools)` returns `sandboxOverride = "read-only"` (no Bash/Write/Edit present). Verified by `TestTranslateTools/intake`.
- [ ] `translateTools(tools.ReviewerTools)` returns `sandboxOverride = "workspace-write"` (Bash present even though Write/Edit are not). Verified by `TestTranslateTools/reviewer`.
- [ ] `translateTools([]ToolSchema{})` returns `(nil, "", nil)` — empty tool set means use Codex defaults. Verified.
- [ ] `translateTools` returns an error for a ToolSchema with empty `Name`. Verified.
- [ ] An unknown tool name maps to `"shell"` (catch-all) — does NOT fail the translation. Verified by `TestTranslateTools/unknown_tool`.
- [ ] `buildExecArgs` consumes `translateTools` output and emits the resulting `-c tools.allowed=...` entry in argv. Verified by an integration `TestBuildExecArgs_WithTools` row.
- [ ] `buildExecArgs` replaces the default `--sandbox workspace-write` with `--sandbox read-only` when the tool set is read-only. Verified.
- [ ] `req.ProviderSpecific["codex.tool_set"]="intake"` resolves to `tools.IntakeTools` when `req.Tools` is empty. Verified.
- [ ] Explicit `req.Tools` takes precedence over `codex.tool_set` resolution. Verified.
- [ ] No regression in m07 / m08 tests.
- [ ] `golangci-lint run ./internal/provider/codex/...` and `go vet` clean.
- [ ] Full suite passes.

## Watch For

- **Codex's tool model is COARSER than Tekhton's.** `Read` / `Glob` /
  `Grep` all map to `fs_read`. `Edit` maps to `fs_write` (since edit
  implies write capability). The deduplication in the `-c` argv is
  intentional — Codex's allowed list doesn't need duplicates, but
  we emit them for byte-identical mapping until we know Codex
  collapses them. If the fixture tests fail because Codex's allowed
  list rejects duplicates, dedupe in `joinAllowed`.
- **The sandbox override is aggregate, not per-tool.** A tool set
  containing ANY shell-executing tool sets `workspace-write`. There's
  no way today to express "Bash but only for git commands" via
  Codex's CLI flags. That granularity would require Codex config
  file changes (out of m09 scope).
- **`req.ProviderSpecific["codex.tool_set"]` is a convenience, NOT
  a contract.** When stages migrate to Codex (m12), they MAY use this
  key or MAY populate `req.Tools` directly. The translator handles
  both paths identically.
- **Don't expand `codexToolMap` without an audit.** Adding a new
  Tekhton tool means updating both `internal/provider/tools/canonical.go`
  (m03) AND `codexToolMap` (m09). Forgetting the latter means the
  new tool falls back to `shell` (over-permissioned). The `unknown`
  fallback exists for forward-compat, not as an excuse to skip the
  map update.
- **The fixtures lock the wire format.** Don't hand-edit
  `testdata/tool_translations/coder.json` to make a test pass. If
  the translator's output diverged from the fixture, the translator
  changed — fix the translator OR update the fixture deliberately
  with a commit-message explanation.
- **`--sandbox read-only` does NOT prevent network access.** Codex's
  sandbox covers filesystem only. Network restriction is a separate
  config layer (`network_policy.rs` in the protocol). m09 doesn't
  enforce network policy; that's a future enhancement.

## Seeds Forward

- **m10 — Streaming events.** When Codex emits a `McpToolCall` item,
  m10 needs to surface it as `provider.EventToolCall`. The tool
  name in the event will be Codex's name (e.g., `shell`), not
  Tekhton's (`Bash`). m10's event mapper inverts this milestone's
  mapping table to surface the Tekhton-name in the emitted event.
- **m11 — Auth + retry.** No direct interaction.
- **m12 — Per-stage provider selection.** The stages config in
  `pipeline.conf` will populate `req.ProviderSpecific["codex.tool_set"]`
  per stage. m09's tool-set resolution is the receiver of that
  config flow.
- **Per-tool Codex extensions:** future Codex CLI versions may
  expose finer-grained permissions (per-file-path, per-command).
  The translator's structure supports adding richer `-c` entries
  without changing the public signature. Track as a Drift
  Observation if a richer Codex permission API surfaces.
- **Network policy translation:** a future arc could surface
  network-allowlist needs from BehaviorHints and emit
  `-c network_policy.allowed=[...]` entries. Out of m09 scope.
