package prerun

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// TestParity_Fixtures exercises every scenario under
// testdata/prerun/<scenario>/. For each fixture it constructs a Run
// invocation that drives the scenario, records every log/warn/success/emit
// call, and diffs the captured sequence against bash_baseline.txt.
//
// Diff semantics: the baseline file's `#`-prefixed lines are documentation
// (inputs + expected result fields) — they're stripped before the diff.
// Each remaining baseline line is a "TAG: message" entry the Go path is
// expected to emit, in order. Whitespace at end of line is stripped on
// both sides. The match is positional (line N of baseline must equal line
// N of captured) — not a multiset match — so message-order drift fails red.
func TestParity_Fixtures(t *testing.T) {
	scenarios := []struct {
		name    string
		runFunc func(context.Context, *recordingDeps) *Result
		assert  func(*testing.T, *Result, *recordingDeps)
	}{
		{
			name:    "clean-baseline",
			runFunc: runCleanBaselineScenario,
			assert: func(t *testing.T, res *Result, _ *recordingDeps) {
				if res.Status != StatusClean {
					t.Fatalf("status = %q, want clean", res.Status)
				}
				if res.Attempts != 0 {
					t.Fatalf("attempts = %d, want 0", res.Attempts)
				}
				if res.BaselineReCaptured {
					t.Fatalf("BaselineReCaptured = true, want false")
				}
			},
		},
		{
			name:    "fix-succeeds",
			runFunc: runFixSucceedsScenario,
			assert: func(t *testing.T, res *Result, _ *recordingDeps) {
				if res.Status != StatusFixed {
					t.Fatalf("status = %q, want fixed", res.Status)
				}
				if res.Attempts != 1 {
					t.Fatalf("attempts = %d, want 1", res.Attempts)
				}
				if !res.BaselineReCaptured {
					t.Fatalf("BaselineReCaptured = false, want true")
				}
				if res.FinalFails != 0 {
					t.Fatalf("FinalFails = %d, want 0", res.FinalFails)
				}
			},
		},
		{
			name:    "fix-exhausts",
			runFunc: runFixExhaustsScenario,
			assert: func(t *testing.T, res *Result, _ *recordingDeps) {
				if res.Status != StatusFixFailed {
					t.Fatalf("status = %q, want fix_failed", res.Status)
				}
				if res.Attempts != 1 {
					t.Fatalf("attempts = %d, want 1", res.Attempts)
				}
				if res.BaselineReCaptured {
					t.Fatalf("BaselineReCaptured = true, want false")
				}
				if res.AbortReason != "max_attempts" {
					t.Fatalf("AbortReason = %q, want max_attempts", res.AbortReason)
				}
			},
		},
	}

	for _, sc := range scenarios {
		t.Run(sc.name, func(t *testing.T) {
			rec := &recordingDeps{}
			res := sc.runFunc(context.Background(), rec)
			sc.assert(t, res, rec)

			captured := capturedSequence(rec)
			baseline := loadBaseline(t, sc.name)

			if err := diffSequences(baseline, captured); err != nil {
				t.Fatalf("parity diff failed: %v\nbaseline:\n%s\ncaptured:\n%s",
					err, strings.Join(baseline, "\n"), strings.Join(captured, "\n"))
			}
		})
	}
}

// capturedSequence flattens the recording fake's log/warn/success/emit
// streams into the same TAG: message shape the baseline files use. The
// order matters — Go's log helpers are called in source-order, so a single
// append-only slice would mis-interleave the streams. We rebuild the
// sequence by reconstructing it from the per-stream slices in the order
// Run is documented to emit them. (Run never emits two same-tag calls
// back-to-back without an intervening different-tag call, so the
// reconstruction is unambiguous.)
//
// Implementation: we use a single combined slice in the recording fake
// instead. See `combined` field below — populated by the wrappers in
// scenario runners.
func capturedSequence(rec *recordingDeps) []string {
	return rec.combined
}

// loadBaseline reads bash_baseline.txt for the named scenario, strips
// comment lines, and returns the remaining lines.
func loadBaseline(t *testing.T, scenario string) []string {
	t.Helper()
	path := filepath.Join("..", "testdata", "prerun", scenario, "bash_baseline.txt")
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open baseline: %v", err)
	}
	defer f.Close()
	var lines []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimRight(scanner.Text(), " \t")
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		lines = append(lines, line)
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("scan baseline: %v", err)
	}
	return lines
}

func diffSequences(want, got []string) error {
	if len(want) != len(got) {
		return fmt.Errorf("line count mismatch: want %d, got %d", len(want), len(got))
	}
	for i := range want {
		if want[i] != got[i] {
			return fmt.Errorf("line %d mismatch:\n  want: %q\n  got:  %q", i+1, want[i], got[i])
		}
	}
	return nil
}

// ---- scenario runners ----

// recordingDepsWithCombined extends recordingDeps with a combined sink for
// parity testing — the parity test cares about *order*, while the
// orchestrator tests just count.
//
// We can't modify recordingDeps directly without breaking the existing
// tests, so this helper installs combined-stream wrappers around the
// recording fake's hooks. The combined slice ends up on the recording
// struct's `combined` field (declared below via the field added in
// prerun_test.go).

func wireCombinedStream(rec *recordingDeps, deps *Deps) {
	origLog := deps.Log
	origWarn := deps.Warn
	origSuccess := deps.Success
	origEmit := deps.EmitEvent
	deps.Log = func(format string, args ...any) {
		rec.combined = append(rec.combined, "LOG: "+fmt.Sprintf(format, args...))
		if origLog != nil {
			origLog(format, args...)
		}
	}
	deps.Warn = func(format string, args ...any) {
		rec.combined = append(rec.combined, "WARN: "+fmt.Sprintf(format, args...))
		if origWarn != nil {
			origWarn(format, args...)
		}
	}
	deps.Success = func(format string, args ...any) {
		rec.combined = append(rec.combined, "SUCCESS: "+fmt.Sprintf(format, args...))
		if origSuccess != nil {
			origSuccess(format, args...)
		}
	}
	deps.EmitEvent = func(kind, scope, desc string) {
		rec.combined = append(rec.combined, "EMIT: "+kind+"|"+scope+"|"+desc)
		if origEmit != nil {
			origEmit(kind, scope, desc)
		}
	}
}

func runCleanBaselineScenario(ctx context.Context, rec *recordingDeps) *Result {
	rec.testCmdOutput = ""
	rec.testCmdExit = 0
	deps := rec.toDeps()
	wireCombinedStream(rec, deps)
	cfg := &Config{Enabled: true, TestCmd: "go test ./..."}
	res, _ := Run(ctx, cfg, deps)
	return res
}

func runFixSucceedsScenario(ctx context.Context, rec *recordingDeps) *Result {
	rec.testCmdOutput = "FAIL TestFoo"
	rec.testCmdExit = 1
	rec.verifyExits = []int{0}
	rec.verifyOutputs = []string{"PASS"}
	deps := rec.toDeps()
	wireCombinedStream(rec, deps)
	// Force RunAgent to a no-op success so the emit-on-start fires.
	deps.RunAgent = func(_ context.Context, _ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
		return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess}, nil
	}
	cfg := &Config{Enabled: true, TestCmd: "go test ./..."}
	res, _ := Run(ctx, cfg, deps)
	return res
}

func runFixExhaustsScenario(ctx context.Context, rec *recordingDeps) *Result {
	rec.testCmdOutput = "FAIL TestFoo"
	rec.testCmdExit = 1
	rec.verifyExits = []int{1}
	rec.verifyOutputs = []string{"FAIL TestFoo"}
	deps := rec.toDeps()
	wireCombinedStream(rec, deps)
	deps.RunAgent = func(_ context.Context, _ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
		return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess}, nil
	}
	cfg := &Config{Enabled: true, TestCmd: "go test ./..."}
	res, _ := Run(ctx, cfg, deps)
	return res
}
