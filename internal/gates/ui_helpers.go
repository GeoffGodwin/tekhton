package gates

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Framework is the detected UI test framework. Mirrors the bash
// _ui_detect_framework helper's return value vocabulary.
type Framework string

// Framework values. M126 only branches on FrameworkPlaywright; everything
// else short-circuits to FrameworkNone. m31.2 keeps the vocabulary closed so
// the m57 adapter framework can add Cypress / Vitest / Jest without breaking
// existing call sites.
const (
	FrameworkPlaywright Framework = "playwright"
	FrameworkNone       Framework = "none"
)

// FrameworkDetectInput carries the env + filesystem signals needed by
// DetectFramework. Sourced from os.Getenv at the CLI seam; tests construct
// the struct directly so they don't need to mutate process env.
type FrameworkDetectInput struct {
	ForceNonInteractive bool   // TEKHTON_UI_GATE_FORCE_NONINTERACTIVE == "1"
	UIFramework         string // UI_FRAMEWORK
	UITestCmd           string // UI_TEST_CMD
	ProjectDir          string // PROJECT_DIR (used to look up playwright.config.*)
}

// playwrightCmdRe matches `playwright` as a word-boundary token in
// UI_TEST_CMD. The bash regex was
// `(^|[[:space:]/])playwright([[:space:]]|$)`; Go regexp does not support
// POSIX character classes inside `[...]`, so the leading / trailing classes
// translate to ` \t\n\v\f\r` plus `/` (leading) / end-of-string (trailing).
var playwrightCmdRe = regexp.MustCompile(`(^|[ \t\n\v\f\r/])playwright([ \t\n\v\f\r]|$)`)

// DetectFramework reads env + filesystem to infer the UI framework.
// Priority order matches lib/gates_ui_helpers.sh:_ui_detect_framework:
//
//  0. TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 → playwright (M130)
//  1. UI_FRAMEWORK env → if "playwright", return playwright
//  2. UI_TEST_CMD word-boundary regex → playwright
//  3. playwright.config.{ts,js,mjs,cjs} in PROJECT_DIR → playwright
//  4. otherwise → none
func DetectFramework(in FrameworkDetectInput) Framework {
	if in.ForceNonInteractive {
		return FrameworkPlaywright
	}
	if in.UIFramework == "playwright" {
		return FrameworkPlaywright
	}
	if in.UITestCmd != "" && playwrightCmdRe.MatchString(in.UITestCmd) {
		return FrameworkPlaywright
	}
	if in.ProjectDir != "" {
		for _, ext := range []string{"ts", "js", "mjs", "cjs"} {
			p := filepath.Join(in.ProjectDir, "playwright.config."+ext)
			if _, err := os.Stat(p); err == nil {
				return FrameworkPlaywright
			}
		}
	}
	return FrameworkNone
}

// DeterministicEnvList returns KEY=VALUE pairs to inject into the
// UI_TEST_CMD subprocess. Pure function — no side effects.
//
// hardened forces the most aggressive non-interactive profile. M131:
// preflightInteractive (PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1) escalates
// to the hardened profile on the FIRST gate run, not just retry — so a
// project with a known-bad reporter config never burns a UI_TEST_TIMEOUT.
//
// Returns nil for non-playwright frameworks (no env injection).
func DeterministicEnvList(fw Framework, hardened, preflightInteractive bool) []string {
	if preflightInteractive {
		hardened = true
	}
	if fw != FrameworkPlaywright {
		return nil
	}
	out := []string{"PLAYWRIGHT_HTML_OPEN=never"}
	if hardened {
		out = append(out, "CI=1")
	}
	return out
}

// TimeoutSignature classifies the UI-gate timeout flavor for M126 routing.
// Pure function — no side effects, no logging.
//
// Returns one of:
//   - "interactive_report"  exit 124 + Playwright HTML-report markers present
//   - "generic_timeout"     exit 124 without those markers
//   - "none"                any other exit code
func TimeoutSignature(exitCode int, output string) string {
	if exitCode != 124 {
		return "none"
	}
	if strings.Contains(output, "Serving HTML report at") ||
		strings.Contains(output, "Press Ctrl+C to quit") {
		return "interactive_report"
	}
	return "generic_timeout"
}

// HardenedTimeout computes the hardened-rerun timeout. Clamped to [1, base].
// factor==0 or factor<0 clamps to 1 (timeout 0 means "no timeout" to the
// timeout(1) utility, which would be wrong); factor>=1 clamps to base.
//
// Mirrors the bash _ui_hardened_timeout awk computation.
func HardenedTimeout(base time.Duration, factor float64) time.Duration {
	if base <= 0 {
		return time.Second
	}
	computed := time.Duration(math.Round(float64(base) * factor))
	if computed < time.Second {
		computed = time.Second
	}
	if computed > base {
		computed = base
	}
	return computed
}

// DiagnosisInput carries the fields needed to render the ## UI Gate
// Diagnosis block.
type DiagnosisInput struct {
	Signature         string // "interactive_report" | "generic_timeout" | "none"
	NormalApplied     string // "yes" or "no" — was the normal-run env applied
	HardenedApplied   string // "yes" or "no" — was the hardened env applied
	HardenedAttempted string // "yes" or "no" — was the hardened rerun attempted
}

// RenderDiagnosis builds the ## UI Gate Diagnosis markdown block. The
// caller appends it to UI_TEST_ERRORS_FILE and/or BUILD_ERRORS_FILE.
//
// Byte-identical to the bash _ui_write_gate_diagnosis heredoc.
func RenderDiagnosis(in DiagnosisInput) string {
	envLabel := "no"
	if in.HardenedApplied == "yes" {
		envLabel = "yes (hardened)"
	} else if in.NormalApplied == "yes" {
		envLabel = "yes (normal)"
	}

	var action string
	switch in.Signature {
	case "interactive_report":
		action = "Command stays alive serving the HTML report; configure the gate to disable report serving (PLAYWRIGHT_HTML_OPEN=never) or pass --reporter=line to UI_TEST_CMD."
	case "generic_timeout":
		action = "Increase UI_TEST_TIMEOUT only after confirming the command is non-interactive and any required dev server is healthy."
	default:
		action = "UI tests failed without a recognized timeout signature; inspect the captured output for the underlying assertion or runtime error."
	}

	var b strings.Builder
	b.WriteString("\n## UI Gate Diagnosis\n")
	fmt.Fprintf(&b, "- Timeout class: %s\n", in.Signature)
	fmt.Fprintf(&b, "- Deterministic env applied: %s\n", envLabel)
	fmt.Fprintf(&b, "- Hardened rerun attempted: %s\n", in.HardenedAttempted)
	fmt.Fprintf(&b, "- Suggested action: %s\n", action)
	return b.String()
}
