// rules_test.go — cross-rule priority assertions and the 15-baseline parity
// gate that replays every internal/diagnose/testdata/fixtures_v3/<scenario>/
// through the engine + Registry and asserts the verdict matches the
// captured v3 baseline byte-for-byte. This is the load-bearing test of m32.2.

package rules

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/diagnose"
)

// fixturesRoot returns the absolute path to the fixtures directory inside
// the sibling internal/diagnose package — tests run with cwd=internal/diagnose/rules,
// so the path walks one level up.
func fixturesRoot(t *testing.T) string {
	t.Helper()
	// ../testdata/fixtures_v3 resolves to internal/diagnose/testdata/...
	return filepath.Join("..", "testdata", "fixtures_v3")
}

// materializeFixture mirrors the helper used by internal/diagnose/engine_test.go.
// Copies the fixture's `inputs/` tree into a per-test temp dir using the bash
// conventions (.claude/, .tekhton/) so the engine's ReadContext + rules find
// every file.
func materializeFixture(t *testing.T, fixtureDir string) string {
	t.Helper()
	dst := t.TempDir()
	src := filepath.Join(fixtureDir, "inputs")
	err := filepath.Walk(src, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, _ := filepath.Rel(src, path)
		if rel == "." {
			return nil
		}
		target := filepath.Join(dst, mapFixturePath(rel))
		if info.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		return os.WriteFile(target, body, 0o644)
	})
	if err != nil {
		t.Fatalf("materialize: %v", err)
	}
	return dst
}

func mapFixturePath(rel string) string {
	switch {
	case rel == "PIPELINE_STATE.md":
		return filepath.Join(".claude", "PIPELINE_STATE.md")
	case rel == "RUN_SUMMARY.json":
		return filepath.Join(".claude", "logs", "RUN_SUMMARY.json")
	case rel == "CAUSAL_LOG.jsonl":
		return filepath.Join(".claude", "logs", "CAUSAL_LOG.jsonl")
	case rel == "LAST_FAILURE_CONTEXT.json":
		return filepath.Join(".claude", "LAST_FAILURE_CONTEXT.json")
	case rel == "BUILD_ERRORS.md":
		return filepath.Join(".tekhton", "BUILD_ERRORS.md")
	case rel == "BUILD_FIX_REPORT.md":
		return filepath.Join(".tekhton", "BUILD_FIX_REPORT.md")
	case rel == "REVIEWER_REPORT.md":
		return filepath.Join(".tekhton", "REVIEWER_REPORT.md")
	case rel == "SECURITY_REPORT.md":
		return filepath.Join(".tekhton", "SECURITY_REPORT.md")
	case rel == "CLARIFICATIONS.md":
		return filepath.Join(".tekhton", "CLARIFICATIONS.md")
	case rel == "pipeline.conf":
		return filepath.Join(".claude", "pipeline.conf")
	case rel == "QUOTA_PAUSED":
		return filepath.Join(".claude", "QUOTA_PAUSED")
	case strings.HasPrefix(rel, ".claude/"):
		return rel
	case strings.HasPrefix(rel, "agent_logs/"):
		name := strings.TrimPrefix(rel, "agent_logs/")
		return filepath.Join(".claude", "logs", name)
	}
	return rel
}

func readExpected(t *testing.T, fixtureDir, file string) map[string]string {
	t.Helper()
	body, err := os.ReadFile(filepath.Join(fixtureDir, "expected", file))
	if err != nil {
		t.Fatalf("read expected/%s: %v", file, err)
	}
	out := map[string]string{}
	for _, line := range strings.Split(string(body), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		out[k] = v
	}
	return out
}

// TestParity_AllFixtures replays every fixture under
// internal/diagnose/testdata/fixtures_v3/ through the engine + Go-native
// registry and asserts Classification / Confidence / Stage / Rule
// match the captured v3 baseline byte-for-byte.
//
// The success-run and no-state fixtures hit special engine short-circuits:
// success-run returns the SUCCESS classification, no-state returns nil from
// ReadContext (no diagnosis emitted). Both paths are exercised here so a
// regression in the short-circuit is caught.
func TestParity_AllFixtures(t *testing.T) {
	root := fixturesRoot(t)
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatalf("read fixtures: %v", err)
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		e := e
		t.Run(e.Name(), func(t *testing.T) {
			// Some rules read env-driven config paths. Reset to defaults so
			// the test doesn't accidentally inherit dev/parent shell state.
			t.Setenv("PIPELINE_STATE_FILE", "")
			t.Setenv("CAUSAL_LOG_FILE", "")
			t.Setenv("MIGRATION_BACKUP_DIR", "")
			t.Setenv("TEKHTON_VERSION", "4.32.0")
			// Parent shell often overrides these; pin to bash defaults so
			// the parity test produces deterministic verdicts.
			t.Setenv("MAX_PIPELINE_ATTEMPTS", "5")
			t.Setenv("MILESTONE_MAX_SPLIT_DEPTH", "3")
			t.Setenv("CODER_MAX_TURNS", "80")
			t.Setenv("BUILD_FIX_MAX_ATTEMPTS", "3")
			t.Setenv("TEST_AUDIT_REPORT_FILE", "")
			t.Setenv("CLARIFICATIONS_FILE", "")
			t.Setenv("REVIEWER_REPORT_FILE", "")
			t.Setenv("SECURITY_REPORT_FILE", "")
			t.Setenv("BUILD_ERRORS_FILE", "")
			t.Setenv("BUILD_RAW_ERRORS_FILE", "")
			t.Setenv("BUILD_FIX_REPORT_FILE", "")
			t.Setenv("TEKHTON_DIR", ".tekhton")

			fixtureDir := filepath.Join(root, e.Name())
			projectDir := materializeFixture(t, fixtureDir)

			eng := diagnose.NewEngine(New())
			var stderr bytes.Buffer
			eng.Logger = &stderr
			ctx := context.Background()
			c, err := eng.ReadContext(ctx, &diagnose.Input{ProjectDir: projectDir})
			if err != nil {
				t.Fatalf("ReadContext: %v", err)
			}
			want := readExpected(t, fixtureDir, "verdict.txt")

			// no-state fixture: ReadContext returns nil, no diagnosis emitted.
			if c == nil {
				if want["classification"] != "" || want["rule"] != "" {
					t.Fatalf("no-state: ReadContext returned nil but baseline expects classification=%q rule=%q",
						want["classification"], want["rule"])
				}
				return
			}

			d := eng.Run(ctx, c)
			if d.Classification != want["classification"] {
				t.Errorf("classification: baseline=%q got=%q", want["classification"], d.Classification)
			}
			if string(d.Confidence) != want["confidence"] {
				t.Errorf("confidence: baseline=%q got=%q", want["confidence"], string(d.Confidence))
			}
			if d.Stage != want["stage"] {
				t.Errorf("stage: baseline=%q got=%q", want["stage"], d.Stage)
			}
			if d.RuleName != want["rule"] {
				t.Errorf("rule: baseline=%q got=%q", want["rule"], d.RuleName)
			}
		})
	}
}

// TestRulePriority_BuildFixExhaustedBeatsBuildFailure verifies the registry
// order is load-bearing: when both rules would match, the earlier-priority
// rule wins. Build-fix-exhausted is more specific than build-failure and
// must fire first.
func TestRulePriority_BuildFixExhaustedBeatsBuildFailure(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, ".tekhton", "BUILD_ERRORS.md"), "err\n")
	writeFile(t, filepath.Join(dir, ".tekhton", "BUILD_FIX_REPORT.md"),
		"## Attempt 1\n- Progress signal: improving\n\n## Attempt 2\n- Progress signal: unchanged\n")
	eng := diagnose.NewEngine(New())
	eng.Logger = io.Discard
	c := &diagnose.Context{ProjectDir: dir, Stage: "coder", Outcome: "failure"}
	d := eng.Run(context.Background(), c)
	if d.Classification != "BUILD_FIX_EXHAUSTED" {
		t.Fatalf("priority drift: want BUILD_FIX_EXHAUSTED, got %s (rule=%s)", d.Classification, d.RuleName)
	}
}

// TestRulePriority_UnknownIsAlwaysLast checks no rule above _rule_unknown
// fires on an empty context, and _rule_unknown picks up the slack.
func TestRulePriority_UnknownIsAlwaysLast(t *testing.T) {
	t.Parallel()
	eng := diagnose.NewEngine(New())
	eng.Logger = io.Discard
	d := eng.Run(context.Background(), &diagnose.Context{Stage: "finalize", Outcome: "failure"})
	if d.RuleName != "_rule_unknown" {
		t.Fatalf("fallback drift: want _rule_unknown, got %s (class=%s)", d.RuleName, d.Classification)
	}
	if d.Classification != "UNKNOWN" {
		t.Fatalf("classification drift: %s", d.Classification)
	}
	if d.Confidence != diagnose.ConfidenceLow {
		t.Fatalf("confidence drift: %s", d.Confidence)
	}
}
