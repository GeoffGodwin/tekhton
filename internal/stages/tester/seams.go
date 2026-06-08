package tester

import (
	"context"

	"github.com/geoffgodwin/tekhton/internal/provider"
	innertester "github.com/geoffgodwin/tekhton/internal/tester"
	"github.com/geoffgodwin/tekhton/internal/tester/tdd"
	testaudit "github.com/geoffgodwin/tekhton/internal/test_audit"
)

// MainAgentRunner is the seam for the primary tester agent invocation.
// After m02 this is an alias for provider.Provider so the tester can be
// swapped independently from the package-level stageProvider. Tests
// substitute a recording fake to drive UPSTREAM, null-run, and success
// branches deterministically.
type MainAgentRunner interface {
	Name() string
	RunAgent(ctx context.Context, req *provider.Request) (*provider.Result, error)
}

// TDDRunner is the seam for dispatching to tdd.Run. Production wraps
// tdd.Run directly; tests inject a fake that records the dispatch and
// returns a fixture result. The seam keeps the m38.2 package surface
// decoupled from this stage so the TDD package can evolve independently.
type TDDRunner interface {
	Run(ctx context.Context, req *tdd.Request) (*tdd.Result, error)
}

// FixRunner is the seam for innertester.RunInlineFix. Production wraps
// the function call; tests inject a fake that asserts the conditions
// under which it was called (TesterFixEnabled=true AND MaxDepth>0).
type FixRunner interface {
	Run(ctx context.Context, req *innertester.FixRequest) (*innertester.FixResult, error)
}

// ContinuationRunner is the seam for innertester.RunContinuations.
type ContinuationRunner interface {
	Run(ctx context.Context, req *innertester.ContinuationRequest) (*innertester.ContinuationResult, error)
}

// AuditRunner is the seam for test_audit.Run. Production wraps the
// in-process call; tests inject a fake that records the dispatch.
type AuditRunner interface {
	Run(ctx context.Context, req *testaudit.Request) (*testaudit.AuditResult, error)
}

// StateHaltWriter is the seam for write_pipeline_state when the tester
// records a halt-resume context (UPSTREAM, null-run, partial without
// continuation success, NoReportNoTests).
type StateHaltWriter interface {
	Write(ctx context.Context, stage, exitReason, resumeFlag, task, notes string) error
}

// stageProvider is the package-level provider seam. Production code sets it
// via SetProvider before running the pipeline; tests inject a fake.
var stageProvider provider.Provider

// Package-level seams. Tests overwrite via Set* helpers; the helpers
// return the previous value so callers can defer-restore.
var (
	mainAgentRunner    MainAgentRunner    = defaultMainAgent{}
	tddRunner          TDDRunner          = defaultTDDRunner{}
	fixRunner          FixRunner          = defaultFixRunner{}
	continuationRunner ContinuationRunner = defaultContinuationRunner{}
	auditRunner        AuditRunner        = defaultAuditRunner{}
	stateHaltWriter    StateHaltWriter    = noopStateHaltWriter{}
)

// SetProvider replaces the package-level provider. Returns the previous value
// so callers can defer-restore.
func SetProvider(p provider.Provider) provider.Provider {
	prev := stageProvider
	stageProvider = p
	return prev
}

// SetMainAgentRunner overrides the main-agent seam.
func SetMainAgentRunner(r MainAgentRunner) MainAgentRunner {
	prev := mainAgentRunner
	if r != nil {
		mainAgentRunner = r
	}
	return prev
}

// SetTDDRunner overrides the TDD-dispatch seam.
func SetTDDRunner(r TDDRunner) TDDRunner {
	prev := tddRunner
	if r != nil {
		tddRunner = r
	}
	return prev
}

// SetFixRunner overrides the inline-fix seam.
func SetFixRunner(r FixRunner) FixRunner {
	prev := fixRunner
	if r != nil {
		fixRunner = r
	}
	return prev
}

// SetContinuationRunner overrides the continuation-loop seam.
func SetContinuationRunner(r ContinuationRunner) ContinuationRunner {
	prev := continuationRunner
	if r != nil {
		continuationRunner = r
	}
	return prev
}

// SetAuditRunner overrides the test-audit seam.
func SetAuditRunner(r AuditRunner) AuditRunner {
	prev := auditRunner
	if r != nil {
		auditRunner = r
	}
	return prev
}

// SetStateHaltWriter overrides the pipeline-state seam.
func SetStateHaltWriter(w StateHaltWriter) StateHaltWriter {
	prev := stateHaltWriter
	if w != nil {
		stateHaltWriter = w
	}
	return prev
}

// defaultMainAgent delegates to the package-level stageProvider.
type defaultMainAgent struct{}

func (defaultMainAgent) Name() string { return "default-tester" }

func (defaultMainAgent) RunAgent(ctx context.Context, req *provider.Request) (*provider.Result, error) {
	return stageProvider.RunAgent(ctx, req)
}

// defaultTDDRunner wraps tdd.Run.
type defaultTDDRunner struct{}

func (defaultTDDRunner) Run(ctx context.Context, req *tdd.Request) (*tdd.Result, error) {
	return tdd.Run(ctx, req)
}

// defaultFixRunner wraps innertester.RunInlineFix.
type defaultFixRunner struct{}

func (defaultFixRunner) Run(ctx context.Context, req *innertester.FixRequest) (*innertester.FixResult, error) {
	return innertester.RunInlineFix(ctx, req)
}

// defaultContinuationRunner wraps innertester.RunContinuations.
type defaultContinuationRunner struct{}

func (defaultContinuationRunner) Run(ctx context.Context, req *innertester.ContinuationRequest) (*innertester.ContinuationResult, error) {
	return innertester.RunContinuations(ctx, req)
}

// defaultAuditRunner wraps test_audit.Run.
type defaultAuditRunner struct{}

func (defaultAuditRunner) Run(ctx context.Context, req *testaudit.Request) (*testaudit.AuditResult, error) {
	return testaudit.Run(ctx, req)
}

// noopStateHaltWriter is the default StateHaltWriter — pipeline state
// writes are best-effort in m38.6; the legacy bash dispatcher still has
// the canonical state.Write path. A follow-up arc may swap this for an
// in-process state.Update call once every stage has a Go-native test
// suite that exercises the resume path.
type noopStateHaltWriter struct{}

func (noopStateHaltWriter) Write(_ context.Context, _, _, _, _, _ string) error { return nil }
