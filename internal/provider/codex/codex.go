// Package codex is the OpenAI Codex CLI provider implementation.
//
// V5 m07 — Scaffold: factory, flag builder, exec invocation, exit-code
// interpretation. V5 m08 — JSON event decoder, item taxonomy, outcome
// mapping. V5 m10 — streaming events, provider.Event emission parity.
//
// The three ProviderSpecific keys this package recognises:
//
//	codex.cwd                  — working directory (defaults to process cwd)
//	codex.output_last_message  — path for --output-last-message (defaults to tempfile)
//	codex.config.<KEY>         — emitted as -c <KEY>=<value>
package codex

import (
	"bytes"
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
type Provider struct {
	BinaryPath string // Path to the codex executable. Defaults to "codex" resolved via PATH.
	cachedTier string // m13 — set on first Tier() call after auth resolution.
}

// New constructs a Codex provider with the default binary lookup.
// Returns an error if the codex binary isn't on PATH.
func New() (*Provider, error) {
	path, err := exec.LookPath("codex")
	if err != nil {
		return nil, fmt.Errorf("codex provider: binary not found on PATH: %w", err)
	}
	return &Provider{BinaryPath: path}, nil
}

// NewWithBinary is the test-seam constructor — substitutes a stub binary.
func NewWithBinary(path string) *Provider {
	return &Provider{BinaryPath: path}
}

// Name returns the provider's canonical name.
func (p *Provider) Name() string { return "codex" }

// Tier returns the cost tier based on the available auth source.
// Caches the result after first discovery so the auth-file stat
// doesn't repeat per invocation.
//
// Resolution order mirrors resolveAuth:
//  1. stored OAuth at ~/.codex/auth.json → TierSubscription
//  2. CODEX_API_KEY env var              → TierAPI
//  3. neither available                  → TierUnknown
func (p *Provider) Tier() string {
	if p.cachedTier != "" {
		return p.cachedTier
	}
	if authPath := storedAuthPath(); fileExists(authPath) {
		p.cachedTier = provider.TierSubscription
		return p.cachedTier
	}
	if os.Getenv("CODEX_API_KEY") != "" {
		p.cachedTier = provider.TierAPI
		return p.cachedTier
	}
	return provider.TierUnknown
}

// RunAgent translates req into a codex exec invocation, runs it, and
// returns a Result. When req.EventChan is non-nil the streaming path
// (m10) is used and provider.Events are emitted as Codex writes JSONL;
// when nil the blocking path (m07) is used.
//
// m11: resolveAuth is called to determine env overrides for auth. Errors
// from resolveAuth are not fatal — the subprocess handles auth naturally
// (OAuth via ~/.codex/auth.json, or process-inherited CODEX_API_KEY).
func (p *Provider) RunAgent(ctx context.Context, req *provider.Request) (*provider.Result, error) {
	if req == nil {
		return nil, errors.New("codex provider: nil request")
	}
	args, err := buildExecArgs(req)
	if err != nil {
		return nil, fmt.Errorf("codex provider: build args: %w", err)
	}

	// m11: resolve auth; apply env overrides only when an explicit API key
	// was provided. Errors are non-fatal: OAuth and process-env paths need
	// no override (codex reads them directly).
	envOverrides, _, _ := resolveAuth(req)

	// Extract the --output-last-message path so we can propagate it
	// and clean it up on process-level errors.
	var outPath string
	for i, a := range args {
		if a == "--output-last-message" && i+1 < len(args) {
			outPath = args[i+1]
			break
		}
	}

	var (
		stdout   []byte
		events   []Event
		exitCode int
		runErr   error
	)

	if req.EventChan != nil {
		// m10 — streaming path: emit events incrementally.
		stdout, events, _, exitCode, runErr = runCodexStreaming(
			ctx, p.BinaryPath, args, req.Prompt, req.EventChan, req.Timeout, envOverrides,
		)
	} else {
		// m07 — blocking path: callers that don't need live events.
		stdout, _, exitCode, runErr = runCodex(ctx, p.BinaryPath, args, req.Prompt, req.Timeout, envOverrides)
		if runErr == nil {
			events, _ = decodeStream(bytes.NewReader(stdout))
		}
	}

	if runErr != nil {
		// Process-level error — clean up the tempfile to prevent leaks.
		if outPath != "" {
			_ = os.Remove(outPath)
		}
		return nil, fmt.Errorf("codex provider: invoke: %w", runErr)
	}

	result, _ := deriveOutcome(events, exitCode)
	result.LastReportPath = outPath

	return &provider.Result{
		Outcome:          result.Outcome,
		TurnsUsed:        result.TurnsUsed,
		ExitCode:         exitCode,
		ErrorCategory:    result.ErrorCategory,
		ErrorSubcategory: result.ErrorSubcategory,
		ErrorMessage:     result.ErrorMessage,
		LastReportPath:   result.LastReportPath,
		NullRun:          result.NullRun,
		RawProviderData:  stdout,
	}, nil
}
