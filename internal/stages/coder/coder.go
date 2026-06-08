// Package coder implements the Tekhton coder stage (m39.4 port).
//
// RunStage is the entry point registered in
// internal/stagerunner.DefaultStageDefs[proto.StageCoder].GoImpl. It mirrors
// the bash run_stage_coder body at stages/coder.sh line-for-line, composing
// the three m39.1-m39.3 sub-packages (prerun, scout, buildfix) with the
// orchestration-level concerns ported here:
//
//   - 14 context-block assembly (context_blocks.go)
//   - null-run + auto-split + turn-exhaustion escalation (null_run.go)
//   - M14 CONTINUATION_ENABLED loop (continuation.go)
//   - git-state-to-markdown CODER_SUMMARY.md synthesizer (reconstruct.go)
//
// The orchestrator delegates load-bearing pipeline plumbing (build gate,
// completion gate, render_prompt) to the legacy `tekhton ...` subprocess
// shims when in the production code path, keeping the m25 wedge-pattern
// decoupling intact. Tests substitute fake Deps so every branch can be
// driven without subprocess hops.
package coder

import (
	"context"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
)

// stageProvider is the package-level provider seam. Production code sets it
// via SetProvider before running the pipeline; tests inject a fake.
var stageProvider provider.Provider

// SetProvider replaces the package-level provider. Returns the previous value
// so callers can defer-restore.
func SetProvider(p provider.Provider) provider.Provider {
	prev := stageProvider
	stageProvider = p
	return prev
}

// RunStage is the Go-native entry point. The signature matches
// stagerunner.StageImpl so DefaultStageDefs[StageCoder] can register it
// directly: `GoImpl: coder.RunStage`.
//
// The body is intentionally minimal — it constructs an orchestrator from
// the request envelope and delegates to Run. Tests that exercise the body
// drive the orchestrator directly via newOrchestrator(req); RunStage is
// the production dispatch entry.
func RunStage(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	o := newOrchestrator(req)
	return o.Run(ctx)
}
