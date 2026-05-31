package rules

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/diagnose"
)

func TestBuildFailure_Match(t *testing.T) {
	t.Parallel()
	type tc struct {
		name      string
		setup     func(t *testing.T, dir string)
		causal    string
		wantMatch bool
		wantConf  diagnose.Confidence
		wantClass string
	}
	cases := []tc{
		{
			name: "non-empty errors file → match",
			setup: func(t *testing.T, dir string) {
				writeFile(t, filepath.Join(dir, ".tekhton", "BUILD_ERRORS.md"), "boom\n")
			},
			wantMatch: true,
			wantConf:  diagnose.ConfidenceHigh,
			wantClass: "BUILD_FAILURE",
		},
		{
			name:      "no errors file → no match",
			setup:     func(*testing.T, string) {},
			wantMatch: false,
		},
		{
			name: "empty errors file → no match",
			setup: func(t *testing.T, dir string) {
				writeFile(t, filepath.Join(dir, ".tekhton", "BUILD_ERRORS.md"), "")
			},
			wantMatch: false,
		},
	}
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			c.setup(t, dir)
			d, ok := BuildFailure{}.Match(&diagnose.Context{
				ProjectDir:   dir,
				Stage:        "coder",
				CausalEvents: c.causal,
			})
			if ok != c.wantMatch {
				t.Fatalf("match: want %v got %v", c.wantMatch, ok)
			}
			if ok && d.Confidence != c.wantConf {
				t.Errorf("confidence: want %s got %s", c.wantConf, d.Confidence)
			}
			if ok && d.Classification != c.wantClass {
				t.Errorf("classification: want %s got %s", c.wantClass, d.Classification)
			}
		})
	}
}

func TestMaxTurns_Match(t *testing.T) {
	t.Parallel()
	type tc struct {
		name      string
		ctx       *diagnose.Context
		wantMatch bool
		wantClass string
		wantConf  diagnose.Confidence
	}
	cases := []tc{
		{
			name:      "secondary AGENT_SCOPE/max_turns → MAX_TURNS_EXHAUSTED",
			ctx:       &diagnose.Context{Stage: "coder", SecondaryCategory: "AGENT_SCOPE", SecondarySubcategory: "max_turns"},
			wantMatch: true,
			wantClass: "MAX_TURNS_EXHAUSTED",
			wantConf:  diagnose.ConfidenceHigh,
		},
		{
			name:      "exit_reason fallback",
			ctx:       &diagnose.Context{Stage: "coder", ExitReason: "complete_loop_max_attempts"},
			wantMatch: true,
			wantClass: "MAX_TURNS_EXHAUSTED",
		},
		{
			name:      "notes fallback",
			ctx:       &diagnose.Context{Stage: "coder", Notes: "max_turns hit"},
			wantMatch: true,
			wantClass: "MAX_TURNS_EXHAUSTED",
		},
		{
			name: "v2 schema + non-AGENT primary → MAX_TURNS_ENV_ROOT",
			ctx: &diagnose.Context{
				Stage:                "coder",
				SchemaVersion:        2,
				PrimaryCategory:      "ENVIRONMENT",
				PrimarySubcategory:   "test_infra",
				PrimarySignal:        "playwright_browser_missing",
				SecondaryCategory:    "AGENT_SCOPE",
				SecondarySubcategory: "max_turns",
			},
			wantMatch: true,
			wantClass: "MAX_TURNS_ENV_ROOT",
			wantConf:  diagnose.ConfidenceHigh,
		},
		{
			name:      "no signal → no match",
			ctx:       &diagnose.Context{Stage: "coder"},
			wantMatch: false,
		},
	}
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			d, ok := MaxTurns{}.Match(c.ctx)
			if ok != c.wantMatch {
				t.Fatalf("match: want %v got %v", c.wantMatch, ok)
			}
			if ok && d.Classification != c.wantClass {
				t.Errorf("class: want %s got %s", c.wantClass, d.Classification)
			}
			if ok && c.wantConf != "" && d.Confidence != c.wantConf {
				t.Errorf("conf: want %s got %s", c.wantConf, d.Confidence)
			}
		})
	}
}

func TestReviewLoop_Match(t *testing.T) {
	t.Parallel()
	t.Run("exit_stage=review with rejection in report", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".tekhton", "REVIEWER_REPORT.md"), "Verdict: CHANGES_REQUIRED\n")
		d, ok := ReviewLoop{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "review", ReviewCycles: 3})
		if !ok {
			t.Fatal("want match")
		}
		if d.Classification != "REVIEW_REJECTION_LOOP" {
			t.Fatalf("class drift: %s", d.Classification)
		}
	})
	t.Run("3 rejections in causal log without state=review", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".tekhton", "REVIEWER_REPORT.md"), "Verdict: CHANGES_REQUIRED\n")
		causal := `{"type":"verdict","stage":"reviewer","verdict":"CHANGES_REQUIRED"}
{"type":"verdict","stage":"reviewer","verdict":"CHANGES_REQUIRED"}
{"type":"verdict","stage":"reviewer","verdict":"CHANGES_REQUIRED"}
`
		_, ok := ReviewLoop{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "coder", CausalEvents: causal})
		if !ok {
			t.Fatal("want match for 3-rejection causal log")
		}
	})
	t.Run("no rejections → no match", func(t *testing.T) {
		_, ok := ReviewLoop{}.Match(&diagnose.Context{Stage: "coder"})
		if ok {
			t.Fatal("want no match")
		}
	})
}

func TestSecurityHalt_Match(t *testing.T) {
	t.Parallel()
	t.Run("HALT in report → match", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".tekhton", "SECURITY_REPORT.md"), "Verdict: HALT\n")
		_, ok := SecurityHalt{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "security"})
		if !ok {
			t.Fatal("want match")
		}
	})
	t.Run("missing report → no match", func(t *testing.T) {
		_, ok := SecurityHalt{}.Match(&diagnose.Context{ProjectDir: t.TempDir(), Stage: "security"})
		if ok {
			t.Fatal("want no match")
		}
	})
}

func TestIntakeClarity_Match(t *testing.T) {
	t.Parallel()
	t.Run("unchecked items + intake stage → match", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".tekhton", "CLARIFICATIONS.md"),
			"# Clarifications\n\n- [ ] Q1?\n- [ ] Q2?\n")
		_, ok := IntakeClarity{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "intake"})
		if !ok {
			t.Fatal("want match")
		}
	})
	t.Run("empty clarifications → no match", func(t *testing.T) {
		_, ok := IntakeClarity{}.Match(&diagnose.Context{ProjectDir: t.TempDir(), Stage: "intake"})
		if ok {
			t.Fatal("want no match")
		}
	})
}

func TestQuotaExhausted_Match(t *testing.T) {
	t.Parallel()
	t.Run("QUOTA_PAUSED marker present → match", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".claude", "QUOTA_PAUSED"), "")
		d, ok := QuotaExhausted{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "coder"})
		if !ok {
			t.Fatal("want match")
		}
		if d.Classification != "QUOTA_EXHAUSTED" {
			t.Fatalf("class drift: %s", d.Classification)
		}
	})
	t.Run("no marker → no match", func(t *testing.T) {
		_, ok := QuotaExhausted{}.Match(&diagnose.Context{ProjectDir: t.TempDir(), Stage: "coder"})
		if ok {
			t.Fatal("want no match")
		}
	})
}

func TestStuckLoop_Match(t *testing.T) {
	t.Parallel()
	t.Run("attempt >= MAX → match", func(t *testing.T) {
		_, ok := StuckLoop{}.Match(&diagnose.Context{Stage: "coder", PipelineAttempt: 5})
		if !ok {
			t.Fatal("want match")
		}
	})
	t.Run("attempt < MAX → no match", func(t *testing.T) {
		_, ok := StuckLoop{}.Match(&diagnose.Context{Stage: "coder", PipelineAttempt: 2})
		if ok {
			t.Fatal("want no match")
		}
	})
}

func TestUnknown_Match(t *testing.T) {
	t.Parallel()
	t.Run("always matches", func(t *testing.T) {
		d, ok := Unknown{}.Match(&diagnose.Context{Stage: "finalize"})
		if !ok {
			t.Fatal("Unknown must always match")
		}
		if d.Classification != "UNKNOWN" || d.Confidence != diagnose.ConfidenceLow {
			t.Fatalf("emit drift: %+v", d)
		}
	})
	t.Run("nil context safe", func(t *testing.T) {
		_, ok := Unknown{}.Match(nil)
		if !ok {
			t.Fatal("Unknown must match nil context too")
		}
	})
}

// writeFile is a per-test helper that creates parent dirs and writes body.
func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
