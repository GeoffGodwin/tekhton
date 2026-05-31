package gates

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestDetectFramework_ForceNonInteractive verifies the M130 priority-0 hook:
// TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 short-circuits to playwright
// regardless of any other signal.
func TestDetectFramework_ForceNonInteractive(t *testing.T) {
	got := DetectFramework(FrameworkDetectInput{
		ForceNonInteractive: true,
		// Every other signal points away from playwright; force still wins.
		UIFramework: "vitest",
		UITestCmd:   "vitest run",
		ProjectDir:  t.TempDir(),
	})
	if got != FrameworkPlaywright {
		t.Errorf("DetectFramework with ForceNonInteractive=true = %q, want %q", got, FrameworkPlaywright)
	}
}

// TestDetectFramework_PriorityOrder verifies the priority cascade beyond P0.
func TestDetectFramework_PriorityOrder(t *testing.T) {
	emptyDir := t.TempDir()

	// P1: UI_FRAMEWORK == "playwright".
	if got := DetectFramework(FrameworkDetectInput{UIFramework: "playwright", ProjectDir: emptyDir}); got != FrameworkPlaywright {
		t.Errorf("P1: UI_FRAMEWORK=playwright -> %q, want playwright", got)
	}

	// P2: UI_TEST_CMD word-boundary regex.
	for _, cmd := range []string{"playwright test", "npx playwright test", "node_modules/.bin/playwright"} {
		if got := DetectFramework(FrameworkDetectInput{UITestCmd: cmd, ProjectDir: emptyDir}); got != FrameworkPlaywright {
			t.Errorf("P2: UI_TEST_CMD=%q -> %q, want playwright", cmd, got)
		}
	}
	// Negative — "playwright" inside another word should not match.
	if got := DetectFramework(FrameworkDetectInput{UITestCmd: "myplaywrightclone test", ProjectDir: emptyDir}); got != FrameworkNone {
		t.Errorf("P2 negative: substring 'playwright' inside another word -> %q, want none", got)
	}

	// P3: playwright.config.* file present.
	for _, ext := range []string{"ts", "js", "mjs", "cjs"} {
		dir := t.TempDir()
		_ = os.WriteFile(filepath.Join(dir, "playwright.config."+ext), []byte(""), 0o644)
		if got := DetectFramework(FrameworkDetectInput{ProjectDir: dir}); got != FrameworkPlaywright {
			t.Errorf("P3: playwright.config.%s -> %q, want playwright", ext, got)
		}
	}

	// P4: no signals at all → none.
	if got := DetectFramework(FrameworkDetectInput{ProjectDir: emptyDir}); got != FrameworkNone {
		t.Errorf("P4: no signals -> %q, want none", got)
	}
}

// TestDeterministicEnvList_Matrix asserts the M126 env-list parity.
func TestDeterministicEnvList_Matrix(t *testing.T) {
	tests := []struct {
		name                 string
		fw                   Framework
		hardened             bool
		preflightInteractive bool
		want                 []string
	}{
		{"playwright_normal", FrameworkPlaywright, false, false, []string{"PLAYWRIGHT_HTML_OPEN=never"}},
		{"playwright_hardened", FrameworkPlaywright, true, false, []string{"PLAYWRIGHT_HTML_OPEN=never", "CI=1"}},
		{"playwright_preflight_escalates", FrameworkPlaywright, false, true, []string{"PLAYWRIGHT_HTML_OPEN=never", "CI=1"}},
		{"none_returns_nil", FrameworkNone, false, false, nil},
		{"none_hardened_still_nil", FrameworkNone, true, true, nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := DeterministicEnvList(tc.fw, tc.hardened, tc.preflightInteractive)
			if !envListEq(got, tc.want) {
				t.Errorf("got %v, want %v", got, tc.want)
			}
		})
	}
}

// TestTimeoutSignature_TruthTable.
func TestTimeoutSignature_TruthTable(t *testing.T) {
	tests := []struct {
		name     string
		exitCode int
		output   string
		want     string
	}{
		{"interactive_html_report", 124, "Serving HTML report at http://localhost:9323. Press Ctrl+C to quit.", "interactive_report"},
		{"interactive_ctrl_c_only", 124, "Press Ctrl+C to quit", "interactive_report"},
		{"generic_124", 124, "Test timeout exceeded", "generic_timeout"},
		{"non_124_with_marker", 0, "Serving HTML report at http://localhost:9323", "none"},
		{"non_124_assertion", 1, "AssertionError", "none"},
		{"non_124_negative", -1, "kill", "none"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := TimeoutSignature(tc.exitCode, tc.output); got != tc.want {
				t.Errorf("TimeoutSignature(%d, %q) = %q, want %q", tc.exitCode, tc.output, got, tc.want)
			}
		})
	}
}

// TestHardenedTimeout_Clamping covers the edge cases called out in the
// milestone Watch For: factor==0 must clamp to 1 (not 0), factor>=1 clamps
// to base.
func TestHardenedTimeout_Clamping(t *testing.T) {
	base := 60 * time.Second
	tests := []struct {
		name   string
		factor float64
		want   time.Duration
	}{
		{"half", 0.5, 30 * time.Second},
		{"quarter", 0.25, 15 * time.Second},
		{"factor_zero_clamps_to_1s", 0, time.Second},
		{"factor_negative_clamps_to_1s", -0.5, time.Second},
		{"factor_greater_than_one_clamps_to_base", 2.0, base},
		{"factor_exactly_one_returns_base", 1.0, base},
		{"factor_very_small_clamps_to_1s", 0.001, time.Second},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := HardenedTimeout(base, tc.factor); got != tc.want {
				t.Errorf("HardenedTimeout(%v, %v) = %v, want %v", base, tc.factor, got, tc.want)
			}
		})
	}
	// Zero base → 1s fallback.
	if got := HardenedTimeout(0, 0.5); got != time.Second {
		t.Errorf("HardenedTimeout(0, 0.5) = %v, want 1s", got)
	}
}

// TestRenderDiagnosis_ByteEquality asserts the diagnosis block matches the
// bash _ui_write_gate_diagnosis heredoc byte-for-byte. The bash heredoc
// emits a leading blank line, four `- ` bullets, and trailing newline.
func TestRenderDiagnosis_ByteEquality(t *testing.T) {
	got := RenderDiagnosis(DiagnosisInput{
		Signature:         "interactive_report",
		NormalApplied:     "yes",
		HardenedApplied:   "yes",
		HardenedAttempted: "yes",
	})
	want := "\n## UI Gate Diagnosis\n" +
		"- Timeout class: interactive_report\n" +
		"- Deterministic env applied: yes (hardened)\n" +
		"- Hardened rerun attempted: yes\n" +
		"- Suggested action: Command stays alive serving the HTML report; configure the gate to disable report serving (PLAYWRIGHT_HTML_OPEN=never) or pass --reporter=line to UI_TEST_CMD.\n"
	if got != want {
		t.Errorf("Diagnosis block mismatch:\n--- got ---\n%s\n--- want ---\n%s", got, want)
	}
}

// TestRenderDiagnosis_GenericTimeoutAction verifies the generic_timeout
// branch picks the second action string.
func TestRenderDiagnosis_GenericTimeoutAction(t *testing.T) {
	got := RenderDiagnosis(DiagnosisInput{
		Signature:         "generic_timeout",
		NormalApplied:     "yes",
		HardenedAttempted: "no",
	})
	if !strings.Contains(got, "Increase UI_TEST_TIMEOUT only after confirming") {
		t.Errorf("expected generic_timeout suggested-action string, got:\n%s", got)
	}
	if !strings.Contains(got, "- Timeout class: generic_timeout\n") {
		t.Errorf("expected Timeout class line, got:\n%s", got)
	}
	if !strings.Contains(got, "- Hardened rerun attempted: no\n") {
		t.Errorf("expected Hardened rerun line, got:\n%s", got)
	}
}

// TestRenderDiagnosis_NoneSignatureAction verifies the default branch
// (unknown signature) emits the inspect-output suggested action.
func TestRenderDiagnosis_NoneSignatureAction(t *testing.T) {
	got := RenderDiagnosis(DiagnosisInput{
		Signature:         "none",
		NormalApplied:     "no",
		HardenedAttempted: "no",
	})
	if !strings.Contains(got, "without a recognized timeout signature") {
		t.Errorf("expected unknown-signature action, got:\n%s", got)
	}
	// EnvLabel must be "no" when neither normal nor hardened applied.
	if !strings.Contains(got, "- Deterministic env applied: no\n") {
		t.Errorf("expected 'Deterministic env applied: no', got:\n%s", got)
	}
}

// TestRenderDiagnosis_NormalAppliedLabel asserts the env-label cascade.
func TestRenderDiagnosis_NormalAppliedLabel(t *testing.T) {
	got := RenderDiagnosis(DiagnosisInput{
		Signature:         "generic_timeout",
		NormalApplied:     "yes",
		HardenedApplied:   "no",
		HardenedAttempted: "no",
	})
	if !strings.Contains(got, "- Deterministic env applied: yes (normal)\n") {
		t.Errorf("expected 'yes (normal)' label, got:\n%s", got)
	}
}

// envListEq compares two string slices for set equality (order matters here
// because the bash side emitted lines in a fixed sequence and the parity
// scenario asserts exact byte equivalence after a `join`).
func envListEq(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
