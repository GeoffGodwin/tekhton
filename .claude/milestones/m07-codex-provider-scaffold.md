<!-- milestone-meta
id: "07"
status: "todo"
-->

# m07 (V5) — Codex Provider Scaffold (Invocation, Flag Builder, Exit Codes)

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | V5 Phase 1, Milestone 7 — start of the Codex provider arc (m07–m12). m01-m06 shipped the `provider.Provider` seam, ToolSchema infrastructure, and reliability fixes around finalize hygiene. m07 lands the scaffolding for Codex: the `internal/provider/codex/` package skeleton, `New()` factory, `Name()` returning `"codex"`, the flag-builder that translates `*provider.Request` to a `codex exec` command line, the actual `exec.CommandContext` invocation, and exit-code interpretation. m07 does NOT implement JSON event parsing (m08), does NOT translate tools (m09), does NOT emit streaming events (m10), and does NOT handle auth/rate-limit/retry (m11). m07's only deliverable: invoking the Codex CLI successfully and returning a basic `*provider.Result` with the right `Outcome` based on exit code alone. The full event-driven outcome refinement comes in m08. This split keeps each milestone scope tight and lets the m01 parity-test pattern apply per layer. |
| **Gap** | After m06 closes, `internal/provider/claude/` is the only Provider implementation. The `provider.Provider` interface exists with one method (`RunAgent`). Nothing exists under `internal/provider/codex/`. To start the polyglot path, we need the basic mechanical wiring: locate the `codex` binary, build the right `codex exec` argv, run it with `exec.CommandContext`, capture stdout/stderr, interpret the exit code, and return a `*provider.Result`. The audit established the flag set (`--json`, `--output-last-message`, `--model`, `--sandbox`, `--cd`, `--skip-git-repo-check`, `-c key=value`) and the invocation shape (`codex exec [flags] [PROMPT]` or stdin via `-`). |
| **m07 fills** | (1) `internal/provider/codex/codex.go` — `Provider` struct with a `BinaryPath` field defaulting to `codex` (resolved via `exec.LookPath`); `New()` factory; `Name() string { return "codex" }`; `RunAgent` skeleton that calls into a helper to invoke the binary and returns a basic `*provider.Result`. (2) `internal/provider/codex/flags.go` — `buildExecArgs(*provider.Request)` translating Tekhton's Request to a `codex exec` argv slice. Defaults: `--json`, `--sandbox workspace-write`, `--skip-git-repo-check`, `--output-last-message <tmpfile>`. Model from `req.Model`. Cwd from `req.ProviderSpecific["codex.cwd"]` or process cwd. (3) `internal/provider/codex/exec.go` — `runCodex(ctx, args, prompt, timeout)` that invokes `exec.CommandContext`, pipes the prompt via stdin (using `-` argv form), captures stdout (JSONL — but raw for now, m08 parses it), captures stderr, and returns `(stdoutBytes, stderrBytes, exitCode, error)`. (4) `internal/provider/codex/exit_codes.go` — `interpretExitCode(code int) provider.Outcome` mapping basic exit codes to `OutcomeSuccess` / `OutcomeUpstreamError` / `OutcomeUnknown`. m08 refines this with event-driven outcome derivation. (5) Tests: `codex_test.go` for the factory and `Name()`, `flags_test.go` table-driven for the flag builder, `exec_test.go` with a stub binary (`bin/echo` standing in for `codex` in tests). |
| **Depends on** | m06 (final V5 reliability fix) |
| **Files changed** | `internal/provider/codex/codex.go` (~140 LOC), `internal/provider/codex/flags.go` (~120 LOC), `internal/provider/codex/exec.go` (~100 LOC), `internal/provider/codex/exit_codes.go` (~60 LOC), `internal/provider/codex/codex_test.go` (~100 LOC), `internal/provider/codex/flags_test.go` (~140 LOC), `internal/provider/codex/exec_test.go` (~120 LOC), `VERSION` |

### V5 Phase 1 Codex arc context

| Milestone | Concern addressed |
|-----------|------------------|
| **m07** | **Scaffold: package skeleton, factory, flag builder, exec invocation, exit-code interpretation. NO JSON parsing yet.** |
| m08 | JSON event decoder + Item taxonomy + outcome mapping refinement |
| m09 | ToolSchema → Codex tool format translator |
| m10 | Streaming events (provider.Event emission parity with Claude) |
| m11 | Auth (CODEX_API_KEY) + rate-limit detection + retry |
| m12 | Per-stage provider selection + end-to-end dogfood |

---

## Design

### Sequencing note

m07 ships the mechanical scaffolding without depending on JSON parsing.
After m07, a `codex.New().RunAgent(ctx, req)` call will succeed-or-fail
based purely on the exit code — the returned `*provider.Result` will
have `Outcome` set, but `TurnsUsed`, `LastReportPath`, and other
event-derived fields will be empty/zero. m08 fills them in.

### Goal 1 — Provider struct + factory

**File:** `internal/provider/codex/codex.go`.

```go
package codex

import (
    "context"
    "errors"
    "fmt"
    "os/exec"

    "github.com/geoffgodwin/tekhton/internal/provider"
)

// Provider implements provider.Provider against the OpenAI Codex CLI.
//
// V5 m07 — Scaffold only. RunAgent invokes the binary and returns a
// basic Result based on exit code. JSON event parsing comes in m08.
type Provider struct {
    BinaryPath string  // Path to the codex executable. Defaults to "codex" (resolved via PATH).
}

// New constructs a Codex provider with the default binary lookup.
// Returns an error if the codex binary isn't on PATH and BinaryPath
// override isn't supplied. The error surfaces early so misconfigured
// pipelines fail at runner-construction time, not at first agent call.
func New() (*Provider, error) {
    path, err := exec.LookPath("codex")
    if err != nil {
        return nil, fmt.Errorf("codex provider: binary not found on PATH: %w", err)
    }
    return &Provider{BinaryPath: path}, nil
}

// NewWithBinary is the test-seam constructor used by unit tests to
// substitute a stub binary (e.g., bin/echo) for the real codex CLI.
func NewWithBinary(path string) *Provider {
    return &Provider{BinaryPath: path}
}

func (p *Provider) Name() string { return "codex" }

func (p *Provider) RunAgent(ctx context.Context, req *provider.Request) (*provider.Result, error) {
    if req == nil {
        return nil, errors.New("codex provider: nil request")
    }
    args, err := buildExecArgs(req)
    if err != nil {
        return nil, fmt.Errorf("codex provider: build args: %w", err)
    }
    _, _, exitCode, runErr := runCodex(ctx, p.BinaryPath, args, req.Prompt, req.Timeout)
    if runErr != nil && exitCode == 0 {
        // Process-level error (binary not found, permission denied, etc.).
        // Distinguish from exit-code-based failures.
        return nil, fmt.Errorf("codex provider: invoke: %w", runErr)
    }
    return &provider.Result{
        Outcome:  interpretExitCode(exitCode),
        ExitCode: exitCode,
    }, nil
}
```

### Goal 2 — Flag builder

**File:** `internal/provider/codex/flags.go`.

```go
package codex

import (
    "errors"
    "fmt"
    "os"
    "path/filepath"

    "github.com/geoffgodwin/tekhton/internal/provider"
)

// buildExecArgs translates a Tekhton provider.Request into a codex exec
// argv slice. The defaults match the Codex CLI's automation-friendly
// configuration: --json for newline-delimited JSON output, --sandbox
// workspace-write for file modifications, --skip-git-repo-check so
// non-git directories don't block, --output-last-message for the final
// agent text capture.
//
// Per-Request overrides come via req.ProviderSpecific["codex.<key>"]
// entries (see codex.NewWithProviderSpecific for the mapping).
//
// The prompt is NOT included in argv — it's piped via stdin and the
// trailing "-" argv form is used. See runCodex for the wiring.
func buildExecArgs(req *provider.Request) ([]string, error) {
    if req.Prompt == "" {
        return nil, errors.New("codex provider: empty prompt")
    }

    args := []string{
        "exec",
        "--json",
        "--sandbox", "workspace-write",
        "--skip-git-repo-check",
    }

    // Model override.
    if req.Model != "" {
        args = append(args, "--model", req.Model)
    }

    // Working directory.
    cwd := req.ProviderSpecific["codex.cwd"]
    if cwd == "" {
        var err error
        cwd, err = os.Getwd()
        if err != nil {
            return nil, fmt.Errorf("codex provider: getwd: %w", err)
        }
    }
    args = append(args, "--cd", cwd)

    // Output last message destination — needed for Result.LastReportPath.
    outFile, err := makeOutputLastMessagePath(req)
    if err != nil {
        return nil, fmt.Errorf("codex provider: outfile: %w", err)
    }
    args = append(args, "--output-last-message", outFile)

    // Inline config overrides via -c key=value.
    for k, v := range req.ProviderSpecific {
        if !isInlineConfigKey(k) {
            continue
        }
        args = append(args, "-c", fmt.Sprintf("%s=%s",
            inlineConfigKey(k), v))
    }

    // Trailing "-" tells codex to read the prompt from stdin.
    args = append(args, "-")
    return args, nil
}

// makeOutputLastMessagePath returns the path the codex CLI will write
// the agent's final message to. Defaults to a tempfile so concurrent
// invocations don't trample each other.
func makeOutputLastMessagePath(req *provider.Request) (string, error) {
    if v := req.ProviderSpecific["codex.output_last_message"]; v != "" {
        return v, nil
    }
    f, err := os.CreateTemp("", "tekhton-codex-last-*.md")
    if err != nil {
        return "", err
    }
    path := f.Name()
    _ = f.Close()
    return path, nil
}

// isInlineConfigKey returns true if a ProviderSpecific key should be
// emitted as `-c key=value`. Convention: keys prefixed with
// "codex.config." are inline config; other "codex." keys are
// provider-internal hints (cwd, output_last_message).
func isInlineConfigKey(k string) bool {
    const prefix = "codex.config."
    return len(k) > len(prefix) && k[:len(prefix)] == prefix
}

func inlineConfigKey(k string) string {
    const prefix = "codex.config."
    return k[len(prefix):]
}
```

### Goal 3 — Exec invocation

**File:** `internal/provider/codex/exec.go`.

```go
package codex

import (
    "bytes"
    "context"
    "fmt"
    "os/exec"
    "strings"
    "time"
)

// runCodex invokes the codex binary with the given argv, feeds the
// prompt via stdin, and returns captured stdout/stderr bytes and the
// process exit code.
//
// timeout (0 = no timeout) applies to the whole invocation. The
// context cancellation propagates via exec.CommandContext — Codex
// receives SIGTERM on context cancel, with WaitDelay enforcing
// SIGKILL escalation if Codex doesn't exit promptly.
//
// The returned error is non-nil ONLY for process-level failures
// (binary missing, permission denied, fork failure, etc.). A non-zero
// exit code is NOT an error — the caller inspects exitCode to decide
// outcome. Same contract as exec.CommandContext.
func runCodex(parent context.Context, bin string, args []string, prompt string, timeout time.Duration) (stdout, stderr []byte, exitCode int, err error) {
    ctx := parent
    if timeout > 0 {
        var cancel context.CancelFunc
        ctx, cancel = context.WithTimeout(parent, timeout)
        defer cancel()
    }

    cmd := exec.CommandContext(ctx, bin, args...)
    cmd.Stdin = strings.NewReader(prompt)
    var outBuf, errBuf bytes.Buffer
    cmd.Stdout = &outBuf
    cmd.Stderr = &errBuf

    // WaitDelay gives Codex 5s to respond to SIGTERM before SIGKILL.
    cmd.WaitDelay = 5 * time.Second

    if err := cmd.Run(); err != nil {
        if exitErr, ok := err.(*exec.ExitError); ok {
            // Non-zero exit code — not a process-level error.
            return outBuf.Bytes(), errBuf.Bytes(), exitErr.ExitCode(), nil
        }
        // Process-level failure (binary missing, fork failed, etc.).
        return outBuf.Bytes(), errBuf.Bytes(), -1, fmt.Errorf("exec: %w", err)
    }
    return outBuf.Bytes(), errBuf.Bytes(), 0, nil
}
```

### Goal 4 — Exit code interpretation

**File:** `internal/provider/codex/exit_codes.go`.

```go
package codex

import "github.com/geoffgodwin/tekhton/internal/provider"

// interpretExitCode maps codex exec exit codes to provider.Outcome.
//
// V5 m07 — coarse mapping based on exit code alone:
//   0   → OutcomeSuccess
//   1   → OutcomeUpstreamError (catch-all failure)
//   124 → OutcomeTimeout      (GNU timeout(1) signal)
//   137 → OutcomeAborted      (SIGKILL — usually our timeout enforcer)
//   143 → OutcomeAborted      (SIGTERM — context cancellation)
//   *   → OutcomeUnknown
//
// m08 refines this by consuming the JSON event stream to produce
// richer outcome categorization (UpstreamError vs ContextWindowExceeded
// vs UsageLimitExceeded, etc.). m07's mapping is the fallback for
// when the event stream doesn't yield a clear outcome.
func interpretExitCode(code int) provider.Outcome {
    switch code {
    case 0:
        return provider.OutcomeSuccess
    case 1:
        return provider.OutcomeUpstreamError
    case 124:
        return provider.OutcomeTimeout
    case 137, 143:
        return provider.OutcomeAborted
    default:
        return provider.OutcomeUnknown
    }
}
```

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/provider/codex/codex.go` | Create | `Provider`, `New()`, `NewWithBinary()`, `Name()`, `RunAgent()` skeleton. ~140 LOC. |
| `internal/provider/codex/flags.go` | Create | `buildExecArgs`, `makeOutputLastMessagePath`, helpers. ~120 LOC. |
| `internal/provider/codex/exec.go` | Create | `runCodex` wrapping `exec.CommandContext`. ~100 LOC. |
| `internal/provider/codex/exit_codes.go` | Create | `interpretExitCode`. ~60 LOC. |
| `internal/provider/codex/codex_test.go` | Create | Factory + Name tests. ~100 LOC. |
| `internal/provider/codex/flags_test.go` | Create | Table-driven flag-builder tests. ~140 LOC. |
| `internal/provider/codex/exec_test.go` | Create | Exec wrapper tests using `bin/echo` as a stub binary. ~120 LOC. |
| `VERSION` | Modify | Bump on close. |

---

## Acceptance Criteria

- [ ] `internal/provider/codex/codex.go` exports `Provider`, `New()`, `NewWithBinary(path)`, and `(*Provider).Name()` returning `"codex"`. Verified by `go doc ./internal/provider/codex`.
- [ ] `var _ provider.Provider = (*codex.Provider)(nil)` compiles (Provider satisfies the interface).
- [ ] `New()` returns an error when `codex` is not on PATH. Verified by `TestNew_BinaryMissing` (uses an empty PATH).
- [ ] `buildExecArgs` always emits `--json --sandbox workspace-write --skip-git-repo-check`. Verified by `TestBuildExecArgs/defaults_present`.
- [ ] `buildExecArgs` includes `--model X` when `req.Model = "X"`, and omits the flag when `req.Model == ""`. Verified by `TestBuildExecArgs/model_override`.
- [ ] `buildExecArgs` appends `-` as the final argv element (stdin prompt marker). Verified by `TestBuildExecArgs/stdin_marker`.
- [ ] `buildExecArgs` translates `req.ProviderSpecific["codex.config.<KEY>"]` to `-c <KEY>=<value>` entries. Verified by `TestBuildExecArgs/inline_config`.
- [ ] `runCodex` returns `(stdout, stderr, exitCode, nil)` when the stub binary exits with a non-zero code; the error is reserved for process-level failures. Verified by `TestRunCodex/exit_nonzero`.
- [ ] `runCodex` honors context cancellation — a cancelled context terminates the subprocess. Verified by `TestRunCodex/context_cancel`.
- [ ] `interpretExitCode(0) == OutcomeSuccess`, `(1) == OutcomeUpstreamError`, `(124) == OutcomeTimeout`, `(137) == OutcomeAborted`, `(143) == OutcomeAborted`. Verified by `TestInterpretExitCode/table`.
- [ ] `(*Provider).RunAgent` returns a non-nil `*provider.Result` with `Outcome` set, `ExitCode` set, even when the underlying binary exits non-zero. Verified by a `RunAgent`-level integration test using the stub binary.
- [ ] `internal/provider/codex/` does NOT import `internal/provider/claude/` — providers are independent. Verified by `go list -deps`.
- [ ] No regression in `internal/provider/...`, `internal/stages/...`, `internal/runner/...` tests.
- [ ] `golangci-lint run ./internal/provider/codex/...` and `go vet` clean.
- [ ] Full suite passes.

## Watch For

- **m07 ships scaffolding, NOT event parsing.** `Result.TurnsUsed`,
  `Result.LastReportPath`, `Result.NullRun` all stay at their zero
  values until m08 fills them. Don't preemptively populate them with
  guesses — that masks m08's actual work.
- **The `-` trailing argv is the stdin-prompt marker.** Codex CLI
  reads the prompt from stdin when this is the last positional arg.
  Don't append it conditionally — every invocation in m07's scope
  uses stdin (we never embed the prompt directly in argv to avoid
  argv length and quoting headaches).
- **`exec.CommandContext` + `WaitDelay` is the cancellation contract.**
  Cancel the context → Codex gets SIGTERM, then SIGKILL after 5s
  WaitDelay if it didn't exit. Match what the Claude supervisor
  does to keep timeout semantics consistent across providers.
- **`exit code != error`.** A non-zero exit (1, 124, 137, 143) is NOT
  a Go-level error from `runCodex`; it's a captured result. Process
  errors (binary missing, fork failure) ARE Go-level errors. The
  distinction matches `exec.CommandContext`'s shape and lets the
  caller distinguish "Codex ran and failed" from "we couldn't run
  Codex at all."
- **`req.ProviderSpecific` is the escape hatch for Codex-only knobs.**
  Tekhton's cross-provider Request fields stay narrow; per-provider
  config flows through this map. Document the recognized keys in
  the package doc comment (`codex.cwd`, `codex.output_last_message`,
  `codex.config.<KEY>`).
- **Don't add auth handling to m07.** `CODEX_API_KEY`, OAuth, etc.
  are m11. m07 assumes the operator's environment has whatever
  auth state Codex needs. Tests use a stub binary that doesn't
  require auth.

## Seeds Forward

- **m08 — Event decoder.** Consumes the stdout JSONL stream that
  m07 captures. Refines `interpretExitCode`'s coarse mapping with
  event-derived outcome categorization (CodexErrorInfo →
  provider.Outcome). Populates `Result.TurnsUsed`,
  `Result.LastReportPath`, etc.
- **m09 — Tool schema.** Adds `--output-schema` flag wiring and
  inline `tools` config to constrain Codex's tool surface.
- **m10 — Streaming events.** m07's `runCodex` captures stdout into
  a byte buffer; m10 wraps it with a streaming JSONL decoder that
  emits `provider.Event` to `req.EventChan` as the stream arrives.
- **m11 — Auth.** Codex provider gains awareness of `CODEX_API_KEY`,
  `~/.codex/auth.json`, and the precedence rules.
- **Codex-only enhancements (post-MVP):** `--profile` support,
  `--image` for visual milestones, `--output-schema` for stricter
  agent contract enforcement. Out of MVP scope; the seam supports
  them via `req.ProviderSpecific`.
