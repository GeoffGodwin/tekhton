<!-- milestone-meta
id: "03"
status: "todo"
-->

# m03 (V5) — Tekhton ToolSchema + Claude Translator

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | V5 Phase 1, Milestone 3. m01 shipped the `provider.Provider` interface with `Request.Tools []ToolSchema` as a placeholder field. m02 migrated every stage to consume Provider — but `Tools` is still empty everywhere because `ToolSchema` is just an empty struct. m03 defines `ToolSchema` properly: a Tekhton-internal representation of an agent tool (name, description, parameters schema, behavior hints) that any provider can translate to its own native tool-use format. Claude's translator ships in this milestone as the reference implementation. After m03 lands, stages CAN populate `Request.Tools` with the canonical Tekhton schema, and the Claude provider will translate to Claude's `tool_use` format on the wire. Stages don't change in m03 — they continue with empty Tools — but the seam now supports tool-using providers for m05-m08 (Codex). |
| **Gap** | At m02 close, `provider.Request.Tools` exists but `provider.ToolSchema` is an empty struct (m01's placeholder). No tool definition can be expressed; the Claude provider passes through an empty tool list to the Claude CLI which falls back to its built-in tool set. That's fine for current operation (Claude knows what tools it has) but creates two problems for the polyglot arc: (1) Codex's tools may not match Claude's built-in set — without a Tekhton-internal schema, we can't express "the coder agent needs Read, Write, Edit, Bash, Glob, Grep" in a provider-agnostic way; (2) local Qwen has no built-in tools at all — the agent loop wrapper we'll build in P5 will need to know what tools are available, which means the prompt template needs to inject them, which means we need a typed schema to drive that injection. m03 defines that schema and proves it works for Claude end-to-end so m04-m08 have the contract to build against. |
| **m03 fills** | (1) `internal/provider/toolschema.go` — `ToolSchema` struct with `Name`, `Description`, `Parameters` (a JSON-schema-shaped object), `BehaviorHints` (provider-specific guidance like "this tool may modify files"). Validation: a helper `ValidateToolSchema(t ToolSchema) error` rejects malformed schemas before they reach a provider. (2) `internal/provider/claude/tools.go` — `translateTools([]ToolSchema) []claude.NativeTool` that converts the Tekhton schema to Claude's native tool-use format. (3) Six Tekhton-canonical tool definitions in `internal/provider/tools/canonical.go`: `Read`, `Write`, `Edit`, `Bash`, `Glob`, `Grep` — matching the set the coder agent currently uses. Stages populate `Request.Tools` with these canonical definitions in m04 (not m03 — m03 ships the schema and translator, m04 wires stages to populate). (4) Comprehensive translator tests covering every field and a Claude round-trip test asserting `claude.translateTools(canonical.CoderTools)` produces a byte-for-byte expected `tool_use` JSON payload. (5) `docs/v5-toolschema.md` — schema reference + per-provider translation notes. |
| **Depends on** | m02 |
| **Files changed** | `internal/provider/toolschema.go` (create, ~120 LOC), `internal/provider/toolschema_test.go` (create, ~100 LOC), `internal/provider/tools/canonical.go` (create, ~150 LOC), `internal/provider/tools/canonical_test.go` (create, ~80 LOC), `internal/provider/claude/tools.go` (create, ~140 LOC), `internal/provider/claude/tools_test.go` (create, ~150 LOC), `internal/provider/claude/testdata/tool_translations/` (create — recorded translation fixtures), `docs/v5-toolschema.md` (create, ~150 LOC), `VERSION` (modify — bump on close) |

### V5 Phase 1 arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m01 | Provider interface (Tools field is `[]ToolSchema` placeholder). |
| m02 | Stages migrated to Provider seam. Tools still empty everywhere. |
| **m03** | **ToolSchema defined. Six canonical tools. Claude translator ships. Stages still don't populate Tools — m04's job.** |
| m04 | (Future) Stages populate Request.Tools with canonical schema. |
| m05-m08 | Codex provider implements its own translator using the same ToolSchema. |

---

## Design

### Sequencing note

m03 lands the schema + Claude translator + canonical tool definitions
WITHOUT changing any stage code. Stages continue to pass empty
`Tools` to `RunAgent` and the Claude provider's translator gracefully
handles the empty case. After m03, the schema is in place and the
translator pattern is documented — m04 (or whichever milestone wires
stages to populate `Tools`) is unblocked.

### Core principle

> ToolSchema is the Tekhton-internal canonical representation of a
> tool. Each provider implementation owns translating that schema
> to its native format. Stages know about ToolSchema only — they
> never see provider-specific tool shapes.

### Goal 1 — `ToolSchema` definition

**File:** `internal/provider/toolschema.go`.

```go
package provider

// ToolSchema is the Tekhton-internal canonical representation of an
// agent tool. Per-provider translators convert this to native tool-use
// formats (Claude's tool_use blocks, Codex's function calling, local
// LLMs' pseudo-tools).
//
// V5 m03 — Defined. m04 wires stages to populate Request.Tools with
// canonical schemas from internal/provider/tools/canonical.go.
type ToolSchema struct {
    // Name is the canonical tool name. Cross-provider — every
    // provider's translator uses this string. Examples: "Read",
    // "Write", "Edit", "Bash".
    Name string

    // Description is a one-line description of the tool's purpose.
    // Used in agent prompts and provider tool-list payloads.
    Description string

    // Parameters is a JSON-schema-shaped object describing the tool's
    // input parameters. The format follows JSON Schema draft 2020-12
    // with a strict subset:
    //   - type: "object" required at the top level
    //   - properties: map of named parameters
    //   - required: array of required parameter names
    //   - additionalProperties: false (enforced)
    Parameters ParameterSchema

    // BehaviorHints carries cross-provider guidance about the tool's
    // behavior — useful for providers that need to inject safety
    // notices, output-size limits, or tool-ordering preferences into
    // their native format.
    BehaviorHints BehaviorHints
}

type ParameterSchema struct {
    Type                 string                       // "object"
    Properties           map[string]ParameterProperty
    Required             []string
    AdditionalProperties bool // false
}

type ParameterProperty struct {
    Type        string // "string" | "integer" | "boolean" | "array"
    Description string
    Items       *ParameterProperty // for type="array"
    Enum        []string           // optional, for restricted-value parameters
}

type BehaviorHints struct {
    ModifiesFiles      bool // True for Write, Edit. Used by providers that emit safety notices.
    Reads              bool // True for Read, Glob, Grep.
    ExecutesShell      bool // True for Bash. Drives provider's exec-permission model.
    MaxOutputBytes     int  // 0 = provider default. Bounds tool result size.
    LongRunning        bool // True if tool may run >60s (Bash with sleep, etc.).
}

// ValidateToolSchema returns an error if the schema is malformed.
// Used by providers before translation to catch caller bugs early.
func ValidateToolSchema(t ToolSchema) error {
    if t.Name == "" {
        return errors.New("toolschema: Name is required")
    }
    if t.Description == "" {
        return errors.New("toolschema: Description is required")
    }
    if t.Parameters.Type != "object" {
        return errors.New("toolschema: Parameters.Type must be 'object'")
    }
    if t.Parameters.AdditionalProperties {
        return errors.New("toolschema: Parameters.AdditionalProperties must be false")
    }
    return nil
}
```

The schema is intentionally narrow — only the JSON Schema subset that
every provider can express. Richer features (anyOf, oneOf, refs) get
added when a concrete provider needs them.

### Goal 2 — Six canonical tools

**File:** `internal/provider/tools/canonical.go`.

Match the coder agent's current tool set: `Read`, `Write`, `Edit`,
`Bash`, `Glob`, `Grep`. Each ships as a package-level `ToolSchema`
constant:

```go
package tools

import "github.com/geoffgodwin/tekhton/internal/provider"

// Read reads the contents of a file from the local filesystem.
var Read = provider.ToolSchema{
    Name:        "Read",
    Description: "Read the contents of a file from the local filesystem. Returns the file contents as a string.",
    Parameters: provider.ParameterSchema{
        Type:                 "object",
        AdditionalProperties: false,
        Required:             []string{"file_path"},
        Properties: map[string]provider.ParameterProperty{
            "file_path": {
                Type:        "string",
                Description: "Absolute path to the file to read.",
            },
            "offset": {
                Type:        "integer",
                Description: "Line number to start reading from (1-indexed). Optional.",
            },
            "limit": {
                Type:        "integer",
                Description: "Number of lines to read. Optional; defaults to 2000.",
            },
        },
    },
    BehaviorHints: provider.BehaviorHints{Reads: true},
}

// Write creates a new file or overwrites an existing one.
var Write = provider.ToolSchema{
    Name:        "Write",
    Description: "Write content to a file, creating it if it doesn't exist or overwriting if it does.",
    Parameters: provider.ParameterSchema{
        Type:                 "object",
        AdditionalProperties: false,
        Required:             []string{"file_path", "content"},
        Properties: map[string]provider.ParameterProperty{
            "file_path": {Type: "string", Description: "Absolute path to write."},
            "content":   {Type: "string", Description: "The content to write."},
        },
    },
    BehaviorHints: provider.BehaviorHints{ModifiesFiles: true},
}

// Edit, Bash, Glob, Grep follow the same pattern...

// CoderTools is the canonical tool set the coder agent uses.
// Stages will reference this slice in m04 when wiring Request.Tools.
var CoderTools = []provider.ToolSchema{Read, Write, Edit, Bash, Glob, Grep}

// ReviewerTools is a read-only subset for the reviewer agent.
var ReviewerTools = []provider.ToolSchema{Read, Glob, Grep, Bash}

// TesterTools matches the coder set — testers can write tests.
var TesterTools = []provider.ToolSchema{Read, Write, Edit, Bash, Glob, Grep}

// IntakeTools is read-only — intake doesn't modify the codebase.
var IntakeTools = []provider.ToolSchema{Read, Glob, Grep}
```

Per-stage tool sets are pre-defined here so m04 can pick the right set
without re-deriving it. The four sets above match observed Claude
behavior across stages.

### Goal 3 — Claude translator

**File:** `internal/provider/claude/tools.go`.

```go
package claude

import (
    "github.com/geoffgodwin/tekhton/internal/provider"
)

// translateTools converts a Tekhton ToolSchema slice to Claude's native
// tool_use input format. Returns an empty slice if input is empty (the
// Claude CLI handles "no tools provided" by using its default tool set).
//
// Format reference: Anthropic's Messages API tool_use block — the
// schema follows JSON Schema draft 2020-12 with strict subset matching
// the Tekhton ToolSchema definition.
func translateTools(in []provider.ToolSchema) ([]claudeNativeTool, error) {
    if len(in) == 0 {
        return nil, nil
    }
    out := make([]claudeNativeTool, 0, len(in))
    for _, t := range in {
        if err := provider.ValidateToolSchema(t); err != nil {
            return nil, fmt.Errorf("claude: translate tool %q: %w", t.Name, err)
        }
        out = append(out, claudeNativeTool{
            Name:        t.Name,
            Description: t.Description,
            InputSchema: translateParameters(t.Parameters),
        })
    }
    return out, nil
}

type claudeNativeTool struct {
    Name        string                 `json:"name"`
    Description string                 `json:"description"`
    InputSchema map[string]interface{} `json:"input_schema"`
}

func translateParameters(p provider.ParameterSchema) map[string]interface{} {
    props := make(map[string]interface{}, len(p.Properties))
    for name, prop := range p.Properties {
        props[name] = translateProperty(prop)
    }
    return map[string]interface{}{
        "type":                 p.Type,
        "properties":           props,
        "required":             p.Required,
        "additionalProperties": p.AdditionalProperties,
    }
}

func translateProperty(p provider.ParameterProperty) map[string]interface{} {
    out := map[string]interface{}{
        "type":        p.Type,
        "description": p.Description,
    }
    if p.Items != nil {
        out["items"] = translateProperty(*p.Items)
    }
    if len(p.Enum) > 0 {
        out["enum"] = p.Enum
    }
    return out
}
```

The translator is pure (no I/O, no allocation beyond the result), so
testing it is straightforward: input a known ToolSchema, assert the
output matches the recorded Claude-format JSON byte-for-byte.

### Goal 4 — Translator tests + recorded fixtures

**File:** `internal/provider/claude/tools_test.go`.

Drive seven scenarios via table-driven tests:

| Scenario | Input | Expected output |
|---|---|---|
| Empty | `[]ToolSchema{}` | `nil` |
| Single tool — Read | `[]ToolSchema{tools.Read}` | recorded fixture `read.json` |
| Single tool — Write | `[]ToolSchema{tools.Write}` | recorded fixture `write.json` |
| Coder set | `tools.CoderTools` | recorded fixture `coder_set.json` |
| Reviewer set | `tools.ReviewerTools` | recorded fixture `reviewer_set.json` |
| Invalid — empty Name | `ToolSchema{Description: "X"}` | error containing "Name is required" |
| Invalid — additional props true | `ToolSchema{Name: "X", Description: "Y", Parameters: {Type: "object", AdditionalProperties: true}}` | error containing "AdditionalProperties must be false" |

Recorded fixtures live in `internal/provider/claude/testdata/tool_translations/`.
Each is the JSON output the translator should produce — these double
as documentation for the wire format.

### Goal 5 — Documentation

**File:** `docs/v5-toolschema.md`.

Documents:
- The ToolSchema struct contract (every field).
- The six canonical tools and which stage uses which set.
- The BehaviorHints semantics (when each hint matters per provider).
- The Claude translator's behavior (how each ToolSchema field maps).
- Future provider responsibilities (a Codex translator must produce
  Codex's native format from the same ToolSchema input).

m04-m08 implementers read this doc first.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/provider/toolschema.go` | Create | `ToolSchema`, `ParameterSchema`, `ParameterProperty`, `BehaviorHints`, `ValidateToolSchema`. ~120 LOC. |
| `internal/provider/toolschema_test.go` | Create | Validation + struct round-trip tests. ~100 LOC. |
| `internal/provider/tools/canonical.go` | Create | Six tool definitions + four per-stage sets. ~150 LOC. |
| `internal/provider/tools/canonical_test.go` | Create | Asserts each canonical tool passes `ValidateToolSchema`. ~80 LOC. |
| `internal/provider/claude/tools.go` | Create | `translateTools`, helpers. ~140 LOC. |
| `internal/provider/claude/tools_test.go` | Create | Seven-scenario table-driven tests. ~150 LOC. |
| `internal/provider/claude/testdata/tool_translations/read.json` | Create | Recorded fixture. |
| `internal/provider/claude/testdata/tool_translations/write.json` | Create | Recorded fixture. |
| `internal/provider/claude/testdata/tool_translations/coder_set.json` | Create | Recorded fixture. |
| `internal/provider/claude/testdata/tool_translations/reviewer_set.json` | Create | Recorded fixture. |
| `docs/v5-toolschema.md` | Create | Schema + per-provider translator contract doc. |
| `VERSION` | Modify | Bump on close per dogfood precedent. |

---

## Acceptance Criteria

- [ ] `internal/provider/toolschema.go` exports `ToolSchema`, `ParameterSchema`, `ParameterProperty`, `BehaviorHints`, `ValidateToolSchema`. Verified by `go doc ./internal/provider | grep -cE 'ToolSchema|ParameterSchema|BehaviorHints'` returning at least 4.
- [ ] `ValidateToolSchema` returns an error when `Name == ""`. Verified by `TestValidateToolSchema/empty_name`.
- [ ] `ValidateToolSchema` returns an error when `Parameters.AdditionalProperties == true`. Verified by `TestValidateToolSchema/additional_props_true`.
- [ ] `internal/provider/tools/canonical.go` exports `Read`, `Write`, `Edit`, `Bash`, `Glob`, `Grep`. Each passes `ValidateToolSchema`. Verified by `TestCanonicalTools_PassValidation`.
- [ ] `internal/provider/tools/canonical.go` exports `CoderTools`, `ReviewerTools`, `TesterTools`, `IntakeTools`. Verified by `go doc`.
- [ ] `internal/provider/claude/tools.go` exports `translateTools` (package-private fine — the tests are in the same package). The function returns `nil, nil` on empty input. Verified by `TestTranslateTools/empty`.
- [ ] `translateTools(tools.CoderTools)` produces the recorded fixture `coder_set.json` byte-for-byte. Verified by `TestTranslateTools/coder_set`.
- [ ] `translateTools` rejects an invalid ToolSchema with a wrapped error. Verified by the validation table rows.
- [ ] No stage code is modified by m03. Verified by `git diff HEAD~ internal/stages/` returning empty.
- [ ] No supervisor code is modified by m03. Verified by `git diff HEAD~ internal/supervisor/` returning empty.
- [ ] `docs/v5-toolschema.md` documents (a) every ToolSchema field, (b) the six canonical tools and their per-stage sets, (c) the BehaviorHints semantics, (d) the Claude translator behavior, (e) the future-provider responsibilities. Verified by `grep -nE '^## ' docs/v5-toolschema.md` returning at least five section headings.
- [ ] No regression in: `internal/provider/...` (m01-existing tests), `internal/stages/...`, `internal/runner/...`, `cmd/tekhton/...`.
- [ ] `golangci-lint run ./internal/provider/...` and `go vet ./internal/provider/...` clean.
- [ ] Full suite passes: `bash tests/run_tests.sh` + `go test ./...`.

## Watch For

- **The recorded fixtures are the wire-format contract.** Don't
  hand-edit them after the fact to make tests pass. If a test fails,
  the translator's output diverged from what Claude expects — fix
  the translator, not the fixture. The fixtures double as
  documentation of what the wire format actually is.
- **`BehaviorHints` is provider-advisory, not provider-mandatory.**
  The Claude translator currently ignores `BehaviorHints` (Claude's
  CLI doesn't expose hooks for those signals). A future Codex
  translator might consume `ModifiesFiles` to inject a safety
  notice; a local-Qwen agent loop might consume `LongRunning` to
  set per-tool timeouts. The hints exist in the schema NOW so
  providers can adopt them without breaking ABI.
- **Don't widen `ParameterSchema` for features one provider needs.**
  The current narrow subset (object + properties + required +
  additionalProperties=false) is the cross-provider common ground.
  Resist the temptation to add `anyOf`, `oneOf`, `$ref` until at
  least two providers need them. The schema's value is in being
  STRICT — a richer schema can express more but means more provider
  translation surface and more places things drift.
- **Stages don't change in m03.** Tempting to wire `tools.CoderTools`
  into `internal/stages/coder/coder.go`'s config so the coder starts
  using the canonical schema. Don't — that's m04's scope, and doing
  it here means m03's parity tests need to extend to cover stage
  behavior changes. m03 ships the schema; m04 wires it.
- **The Claude translator returns nil-on-empty intentionally.** Empty
  `Request.Tools` means "use Claude's default tool set" — the Claude
  CLI handles that. If we instead emitted an empty JSON array, Claude
  would interpret it as "no tools available," which breaks the
  coder. Document this in the translator's doc comment.
- **`Parameters.AdditionalProperties` is enforced false at validation
  time.** This isn't aesthetic — it forces stages and prompt authors
  to declare every parameter the tool consumes. The alternative
  (additional_properties: true) lets prompt authors invent
  parameter names that the tool silently ignores, which is exactly
  the class of bug the schema exists to prevent.

## Seeds Forward

- **m04 — Stages populate Request.Tools.** Each stage's config
  references the appropriate per-stage set (`tools.CoderTools`,
  `tools.ReviewerTools`, etc.). The stage's `invokeXxxAgent` helper
  passes them through to `Provider.RunAgent`. Zero schema work in
  m04 — just wiring.
- **m05-m08 — Codex tool translator.** A `internal/provider/codex/tools.go`
  file ships alongside the Codex envelope translator. Same input
  (ToolSchema), different output format (Codex native).
- **Local Qwen agent loop tools (P5).** Local LLMs need the tool
  schema injected into the prompt text since they don't have native
  tool use. A `internal/provider/qwen/tools.go` would generate the
  prompt-injection text from ToolSchema (likely a JSON dump in a
  pre-defined section the prompt template references). Same input,
  different "translation" target.
- **Tool versioning.** A future arc could add `ToolSchema.Version`
  so providers can express "this tool was introduced in V5.x" or
  "this tool's parameter shape changed between V5.3 and V5.4." Out
  of MVP scope; the schema is forward-compatible.
- **Tool result schema.** Today ToolSchema describes input only.
  Providers communicate tool results as opaque strings. A future
  enhancement could add `ResultSchema` so cross-provider tools
  return structured data (JSON) that downstream agents can parse
  reliably. Out of V5 Phase 1.
