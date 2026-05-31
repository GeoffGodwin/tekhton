package rules

import (
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/diagnose"
)

func TestUIGateInteractiveReporter_Match(t *testing.T) {
	t.Parallel()
	t.Run("source 1: primary_signal → high", func(t *testing.T) {
		d, ok := UIGateInteractiveReporter{}.Match(&diagnose.Context{
			Stage:         "coder",
			PrimarySignal: "ui_timeout_interactive_report",
		})
		if !ok {
			t.Fatal("want match")
		}
		if d.Confidence != diagnose.ConfidenceHigh {
			t.Fatalf("conf: want high, got %s", d.Confidence)
		}
	})
	t.Run("source 2: classification → high", func(t *testing.T) {
		d, ok := UIGateInteractiveReporter{}.Match(&diagnose.Context{
			Stage:          "coder",
			Classification: "UI_INTERACTIVE_REPORTER",
		})
		if !ok {
			t.Fatal("want match")
		}
		if d.Confidence != diagnose.ConfidenceHigh {
			t.Fatalf("conf: want high, got %s", d.Confidence)
		}
	})
	t.Run("source 3: BUILD_RAW_ERRORS evidence → medium", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".tekhton", "BUILD_RAW_ERRORS.txt"),
			"Serving HTML report at http://localhost:9323\n")
		d, ok := UIGateInteractiveReporter{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "coder"})
		if !ok {
			t.Fatal("want match")
		}
		if d.Confidence != diagnose.ConfidenceMedium {
			t.Fatalf("conf: want medium, got %s", d.Confidence)
		}
	})
	t.Run("source 3: logs dir scan → medium", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".claude", "logs", "tester.log"),
			"running...\nServing HTML report at http://localhost:9323\n")
		_, ok := UIGateInteractiveReporter{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "coder"})
		if !ok {
			t.Fatal("want match")
		}
	})
	t.Run("source 3: ignores .md files (no self-trigger)", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".claude", "logs", "DESIGN.md"),
			"Quote: Serving HTML report at https://...\n")
		_, ok := UIGateInteractiveReporter{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "coder"})
		if ok {
			t.Fatal("must not trigger on agent-authored .md files")
		}
	})
	t.Run("no signal → no match", func(t *testing.T) {
		_, ok := UIGateInteractiveReporter{}.Match(&diagnose.Context{ProjectDir: t.TempDir(), Stage: "coder"})
		if ok {
			t.Fatal("want no match")
		}
	})
}

func TestBuildFixExhausted_Match(t *testing.T) {
	t.Parallel()
	t.Run("source 1: RUN_SUMMARY build_fix_stats → high", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".tekhton", "BUILD_ERRORS.md"), "err\n")
		writeFile(t, filepath.Join(dir, ".claude", "logs", "RUN_SUMMARY.json"),
			`{"build_fix_stats":{"outcome":"exhausted","attempts":3}}`)
		d, ok := BuildFixExhausted{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "coder"})
		if !ok {
			t.Fatal("want match")
		}
		if d.Confidence != diagnose.ConfidenceHigh {
			t.Fatalf("conf: want high, got %s", d.Confidence)
		}
	})
	t.Run("source 2: BUILD_FIX_REPORT.md ≥2 attempts → match", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".tekhton", "BUILD_ERRORS.md"), "err\n")
		writeFile(t, filepath.Join(dir, ".tekhton", "BUILD_FIX_REPORT.md"),
			"## Attempt 1\n- Progress signal: improving\n\n## Attempt 2\n- Progress signal: unchanged\n")
		_, ok := BuildFixExhausted{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "coder"})
		if !ok {
			t.Fatal("want match")
		}
	})
	t.Run("source 3: secondary signal → match", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".tekhton", "BUILD_ERRORS.md"), "err\n")
		_, ok := BuildFixExhausted{}.Match(&diagnose.Context{
			ProjectDir:      dir,
			Stage:           "coder",
			SecondarySignal: "build_fix_budget_exhausted",
		})
		if !ok {
			t.Fatal("want match")
		}
	})
	t.Run("required guard: no build artifacts → no match", func(t *testing.T) {
		dir := t.TempDir()
		_, ok := BuildFixExhausted{}.Match(&diagnose.Context{
			ProjectDir:      dir,
			Stage:           "coder",
			SecondarySignal: "build_fix_budget_exhausted",
		})
		if ok {
			t.Fatal("must not match without build-error artifacts")
		}
	})
}

func TestPreflightInteractiveConfig_Match(t *testing.T) {
	t.Parallel()
	t.Run("source 1: RUN_SUMMARY preflight_ui detected+unpatched → match", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".claude", "logs", "RUN_SUMMARY.json"),
			`{"preflight_ui":{"interactive_config_detected":true,"reporter_auto_patched":false,"interactive_config_file":"playwright.config.js"}}`)
		d, ok := PreflightInteractiveConfig{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "preflight"})
		if !ok {
			t.Fatal("want match")
		}
		if d.Classification != "PREFLIGHT_INTERACTIVE_CONFIG" {
			t.Fatalf("class drift: %s", d.Classification)
		}
	})
	t.Run("source 2: PREFLIGHT_REPORT.md header + fail word → match", func(t *testing.T) {
		dir := t.TempDir()
		// envOr("TEKHTON_DIR", ".tekhton") uses the default ".tekhton" when
		// TEKHTON_DIR is unset. Write the report there so projectFileExists fires.
		writeFile(t, filepath.Join(dir, ".tekhton", "PREFLIGHT_REPORT.md"),
			"### ✗ UI Config (Playwright) — html reporter\nStatus: FAIL — reporter is html\n")
		_, ok := PreflightInteractiveConfig{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "preflight"})
		if !ok {
			t.Fatal("want match from PREFLIGHT_REPORT.md with header + fail word")
		}
	})
	t.Run("source 2: header present but no fail word → no match", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".tekhton", "PREFLIGHT_REPORT.md"),
			"### ✓ UI Config (Playwright) — html reporter\nStatus: pass\n")
		_, ok := PreflightInteractiveConfig{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "preflight"})
		if ok {
			t.Fatal("must not match when header present but no fail word")
		}
	})
	t.Run("source 3a: PrimarySignal == ui_interactive_config_preflight → match", func(t *testing.T) {
		_, ok := PreflightInteractiveConfig{}.Match(&diagnose.Context{
			ProjectDir:    t.TempDir(),
			Stage:         "preflight",
			PrimarySignal: "ui_interactive_config_preflight",
		})
		if !ok {
			t.Fatal("want match from PrimarySignal")
		}
	})
	t.Run("source 3b: LAST_FAILURE_CONTEXT classification → match", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".claude", "LAST_FAILURE_CONTEXT.json"),
			`{"classification":"PREFLIGHT_INTERACTIVE_CONFIG"}`)
		_, ok := PreflightInteractiveConfig{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "preflight"})
		if !ok {
			t.Fatal("want match")
		}
	})
	t.Run("no signal → no match", func(t *testing.T) {
		_, ok := PreflightInteractiveConfig{}.Match(&diagnose.Context{ProjectDir: t.TempDir(), Stage: "preflight"})
		if ok {
			t.Fatal("want no match")
		}
	})
}
