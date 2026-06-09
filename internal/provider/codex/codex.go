// Package codex is the OpenAI Codex CLI provider implementation.
//
// V5 m07 — Scaffold: factory, flag builder, exec invocation, exit-code
// interpretation. JSON event parsing (m08), tool translation (m09),
// streaming events (m10), and auth/retry (m11) are not implemented here.
//
// The three ProviderSpecific keys this package recognises:
//
//	codex.cwd                  — working directory (defaults to process cwd)
//	codex.output_last_message  — path for --output-last-message (defaults to tempfile)
//	codex.config.<KEY>         — emitted as -c <KEY>=<value>
package codex

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"

	"github.com/geoffgodwin/tekhton/internal/provider"
)

// Compile-time assertion.
var _ provider.Provider = (*Provider)(nil)

// Provider implements provider.Provider against the OpenAI Codex CLI.
//
// V5 m07 — Scaffold only. RunAgent invokes the binary and returns a
// basic Result based on exit code. JSON event parsing comes in m08.
type Provider struct {
	BinaryPath string // Path to the codex executable. Defaults to "codex" resolved via PATH.
}

// New constructs a Codex provider with the default binary lookup.
// Returns an error if the codex binary isn't on PATH. The error surfaces
// early so misconfigured pipelines fail at construction time.
func New() (*Provider, error) {
	path, err := exec.LookPath("codex")
	if err != nil {
		return nil, fmt.Errorf("codex provider: binary not found on PATH: %w", err)
	}
	return &Provider{BinaryPath: path}, nil
}

// NewWithBinary is the test-seam constructor — substitutes a stub binary
// (e.g. /bin/echo) for the real codex CLI.
func NewWithBinary(path string) *Provider {
	return &Provider{BinaryPath: path}
}

// Name returns the provider's canonical name.
func (p *Provider) Name() string { return "codex" }

// RunAgent translates req into a codex exec invocation, runs it, and
// returns a Result whose Outcome is derived from the exit code.
//
// V5 m07: TurnsUsed and NullRun stay at their zero values; m08 fills
// them in from the JSON event stream. LastReportPath is set to the
// --output-last-message path so the caller owns its lifecycle.
func (p *Provider) RunAgent(ctx context.Context, req *provider.Request) (*provider.Result, error) {
	if req == nil {
		return nil, errors.New("codex provider: nil request")
	}
	args, err := buildExecArgs(req)
	if err != nil {
		return nil, fmt.Errorf("codex provider: build args: %w", err)
	}

	// Extract the --output-last-message path embedded by buildExecArgs so
	// we can propagate it to the caller (unblocks m08) and clean it up on
	// the process-level error path (prevents tempfile leaks).
	var outPath string
	for i, a := range args {
		if a == "--output-last-message" && i+1 < len(args) {
			outPath = args[i+1]
			break
		}
	}

	_, _, exitCode, runErr := runCodex(ctx, p.BinaryPath, args, req.Prompt, req.Timeout)
	if runErr != nil {
		// Process-level error (binary not found, permission denied, etc.).
		// The tempfile won't be read — remove it to avoid leaking it.
		if outPath != "" {
			_ = os.Remove(outPath)
		}
		return nil, fmt.Errorf("codex provider: invoke: %w", runErr)
	}
	return &provider.Result{
		Outcome:        interpretExitCode(exitCode),
		ExitCode:       exitCode,
		LastReportPath: outPath,
	}, nil
}
