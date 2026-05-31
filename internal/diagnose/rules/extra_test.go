package rules

import (
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/diagnose"
)

func TestMixedClassification_Match(t *testing.T) {
	t.Parallel()
	t.Run("MIXED_UNCERTAIN classification → match (low conf)", func(t *testing.T) {
		d, ok := MixedClassification{}.Match(&diagnose.Context{
			Stage:          "coder",
			Classification: "MIXED_UNCERTAIN",
		})
		if !ok {
			t.Fatal("want match")
		}
		if d.Confidence != diagnose.ConfidenceLow {
			t.Fatalf("conf must be low (this rule is intentionally low-confidence), got %s", d.Confidence)
		}
		if d.Classification != "MIXED_UNCERTAIN_CLASSIFICATION" {
			t.Fatalf("class drift: %s", d.Classification)
		}
	})
	t.Run("primary_signal mixed_uncertain_classification → match", func(t *testing.T) {
		_, ok := MixedClassification{}.Match(&diagnose.Context{
			Stage:         "coder",
			PrimarySignal: "mixed_uncertain_classification",
		})
		if !ok {
			t.Fatal("want match")
		}
	})
	t.Run("LAST_FAILURE_CONTEXT signal match → match", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".claude", "LAST_FAILURE_CONTEXT.json"),
			`{"primary_cause":{"signal":"mixed_uncertain_classification"}}`)
		_, ok := MixedClassification{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "coder"})
		if !ok {
			t.Fatal("want match")
		}
	})
	t.Run("no signal → no match", func(t *testing.T) {
		_, ok := MixedClassification{}.Match(&diagnose.Context{Stage: "coder"})
		if ok {
			t.Fatal("want no match")
		}
	})
}

func TestTurnExhaustion_Match(t *testing.T) {
	t.Parallel()
	t.Run("AGENT_SCOPE/max_turns → match", func(t *testing.T) {
		_, ok := TurnExhaustion{}.Match(&diagnose.Context{
			Stage:                 "tester",
			AgentErrorCategory:    "AGENT_SCOPE",
			AgentErrorSubcategory: "max_turns",
		})
		if !ok {
			t.Fatal("want match")
		}
	})
	t.Run("other category → no match", func(t *testing.T) {
		_, ok := TurnExhaustion{}.Match(&diagnose.Context{
			Stage:                 "tester",
			AgentErrorCategory:    "UPSTREAM",
			AgentErrorSubcategory: "max_turns",
		})
		if ok {
			t.Fatal("want no match")
		}
	})
}

func TestSplitDepth_Match(t *testing.T) {
	// Cannot t.Parallel — uses t.Setenv so the rule reads a known
	// MILESTONE_MAX_SPLIT_DEPTH default (parent shells often override it).
	t.Setenv("MILESTONE_MAX_SPLIT_DEPTH", "3")
	t.Run("split_depth >= MAX → match", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".claude", "logs", "RUN_SUMMARY.json"),
			`{"split_depth":3}`)
		_, ok := SplitDepth{}.Match(&diagnose.Context{
			ProjectDir: dir,
			Stage:      "coder",
			SplitDepth: 3,
		})
		if !ok {
			t.Fatal("want match")
		}
	})
	t.Run("no summary file → no match", func(t *testing.T) {
		_, ok := SplitDepth{}.Match(&diagnose.Context{
			ProjectDir: t.TempDir(),
			Stage:      "coder",
			SplitDepth: 5,
		})
		if ok {
			t.Fatal("want no match (rule requires summary file)")
		}
	})
}

func TestTransientError_Match(t *testing.T) {
	t.Parallel()
	t.Run("UPSTREAM category → match", func(t *testing.T) {
		d, ok := TransientError{}.Match(&diagnose.Context{
			Stage:              "coder",
			AgentErrorCategory: "UPSTREAM",
		})
		if !ok {
			t.Fatal("want match")
		}
		if d.Confidence != diagnose.ConfidenceMedium {
			t.Fatalf("conf must be medium, got %s", d.Confidence)
		}
	})
	t.Run("transient=true → match", func(t *testing.T) {
		_, ok := TransientError{}.Match(&diagnose.Context{
			Stage:               "coder",
			AgentErrorTransient: "true",
		})
		if !ok {
			t.Fatal("want match")
		}
	})
	t.Run("neither → no match", func(t *testing.T) {
		_, ok := TransientError{}.Match(&diagnose.Context{Stage: "coder"})
		if ok {
			t.Fatal("want no match")
		}
	})
}

func TestTestAuditFailure_Match(t *testing.T) {
	// Cannot t.Parallel — uses t.Setenv.
	t.Run("Verdict: NEEDS_WORK in report → match", func(t *testing.T) {
		t.Setenv("TEST_AUDIT_REPORT_FILE", ".tekhton/TEST_AUDIT_REPORT.md")
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".tekhton", "TEST_AUDIT_REPORT.md"),
			"# Audit\n\nVerdict: NEEDS_WORK\n")
		_, ok := TestAuditFailure{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "tester"})
		if !ok {
			t.Fatal("want match")
		}
	})
	t.Run("PASS verdict → no match", func(t *testing.T) {
		t.Setenv("TEST_AUDIT_REPORT_FILE", ".tekhton/TEST_AUDIT_REPORT.md")
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".tekhton", "TEST_AUDIT_REPORT.md"),
			"Verdict: PASS\n")
		_, ok := TestAuditFailure{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "tester"})
		if ok {
			t.Fatal("want no match")
		}
	})
	t.Run("env var unset → no match", func(t *testing.T) {
		t.Setenv("TEST_AUDIT_REPORT_FILE", "")
		_, ok := TestAuditFailure{}.Match(&diagnose.Context{Stage: "tester"})
		if ok {
			t.Fatal("want no match")
		}
	})
}
