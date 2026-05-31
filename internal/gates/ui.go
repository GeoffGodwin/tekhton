package gates

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"time"
)

// UIPhase ports lib/gates_ui.sh::_run_ui_test_phase. Replaces the m31.1
// bash-shim placeholder (UIBashShim) with a native implementation:
//
//   - Skip when UI_TEST_CMD unset or UI_VALIDATION_ENABLED=false.
//   - Run #1 with the deterministic non-interactive env profile.
//   - On exit 0 → Pass.
//   - On `interactive_report` timeout signature, skip M54 remediation AND
//     the generic retry; attempt the hardened rerun once (timeout = base *
//     UI_GATE_ENV_RETRY_TIMEOUT_FACTOR, clamped to [1, base]).
//   - On any other failure, attempt one M54 remediation re-run then one
//     generic retry.
//   - On terminal failure, write BUILD_RAW_ERRORS.txt + UI_TEST_ERRORS.md
//   - append a ## UI Test Failures section to BUILD_ERRORS.md, then
//     append the structured ## UI Gate Diagnosis block to both files.
//
// Construct via NewUIPhase (which reads ambient env) or set fields directly
// for tests.
type UIPhase struct {
	// Cmd is UI_TEST_CMD. Empty → Skip.
	Cmd string

	// Timeout is UI_TEST_TIMEOUT (default 120s in bash; assembler applies
	// the default at the env seam so we keep zero == "no timeout" here).
	Timeout time.Duration

	// Enabled mirrors UI_VALIDATION_ENABLED (default true).
	Enabled bool

	// HardenedRetryEnabled mirrors UI_GATE_ENV_RETRY_ENABLED (default true).
	// When false the hardened rerun is skipped even on interactive_report
	// signature; the gate fails immediately.
	HardenedRetryEnabled bool

	// HardenedRetryFactor mirrors UI_GATE_ENV_RETRY_TIMEOUT_FACTOR (default
	// 0.5). Clamped to (0, 1] inside HardenedTimeout.
	HardenedRetryFactor float64

	// PreflightInteractive mirrors PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED.
	// When true, the FIRST run uses the hardened env (M131).
	PreflightInteractive bool

	// Framework is the detected UI framework. Drives DeterministicEnvList.
	Framework Framework

	// Runner abstracts subprocess exec. Each invocation must inject the
	// deterministic env list into the subprocess env (production wiring
	// uses UIEnvRunner, which prepends KEY=VALUE pairs to os.Environ).
	Runner UICommandRunner

	// Remediator is the M54 auto-remediation hook (shared with the build
	// gate's other phases). nil disables remediation.
	Remediator Remediator

	// Errors owns the BUILD_ERRORS.md / UI_TEST_ERRORS.md / BUILD_RAW_ERRORS.txt
	// write surface.
	Errors ErrorsWriter

	// Logger receives one info line per branch decision. nil silences.
	Logger func(format string, args ...interface{})

	// Now overrides the wall-clock for tests. Defaults to time.Now.
	Now func() time.Time

	// CmdAvailable returns true when the first token of Cmd is on PATH.
	// nil falls back to checkUITestCmdAvailable.
	CmdAvailable func(cmd string) bool
}

// UICommandRunner is the UI-aware CommandRunner variant. Each invocation
// passes the deterministic env list separately so the runner can inject
// it into the subprocess env (the bash side used `env <KEY=VAL>... timeout
// $T bash -c "$UI_TEST_CMD"`; Go's exec.Cmd.Env carries the same semantics).
type UICommandRunner interface {
	Run(ctx context.Context, cmd string, env []string, timeout time.Duration) (output []byte, exitCode int, err error)
}

// ErrUITestFailed is the sentinel for UIPhase terminal failure. Wrapped in
// PhaseError by BuildGate.Run so callers can recover both the phase name
// and the cause via errors.As.
var ErrUITestFailed = errors.New("ui test phase failed")

// Name implements Phase.
func (p *UIPhase) Name() string { return "ui_test" }

// Run implements Phase. Skip-or-Pass-or-Fail per the M126/M54/generic-retry
// branches described above.
func (p *UIPhase) Run(ctx context.Context, in *PhaseInput) PhaseResult {
	if p == nil || p.Cmd == "" || !p.Enabled {
		return PhaseResult{Status: StatusSkip}
	}
	available := p.CmdAvailable
	if available == nil {
		available = checkUITestCmdAvailable
	}
	if !available(p.Cmd) {
		p.log("[build gate] UI_TEST_CMD command not found; skipping UI test gate.")
		return PhaseResult{Status: StatusSkip}
	}
	runner := p.Runner
	if runner == nil {
		runner = UIEnvRunner{}
	}
	timeout := effectiveTimeout(p.Timeout, in.Remaining)

	// Run #1 — normal-run deterministic env (or hardened, if M131 escalated).
	normalEnv := DeterministicEnvList(p.Framework, false, p.PreflightInteractive)
	out, exit, err := runner.Run(ctx, p.Cmd, normalEnv, timeout)
	if err != nil {
		return PhaseResult{Status: StatusFail, Err: err}
	}
	if exit == 0 {
		p.log("UI tests passed.")
		return PhaseResult{Status: StatusPass}
	}

	output := string(out)
	signature := TimeoutSignature(exit, output)
	hardenedAttempted := false

	if signature == "interactive_report" {
		// M126: skip M54 remediation AND generic retry; same hang would
		// recur. Only the hardened rerun has a chance of breaking the loop.
		p.log("UI tests timed out with interactive-report signature; skipping remediation and generic retry.")
		if p.HardenedRetryEnabled {
			hardenedAttempted = true
			hardenedTO := HardenedTimeout(p.Timeout, retryFactor(p.HardenedRetryFactor))
			if hardenedTO > in.Remaining && in.Remaining > 0 {
				hardenedTO = in.Remaining
			}
			hardenedEnv := DeterministicEnvList(p.Framework, true, p.PreflightInteractive)
			out2, exit2, err2 := runner.Run(ctx, p.Cmd, hardenedEnv, hardenedTO)
			if err2 != nil {
				return PhaseResult{Status: StatusFail, Err: err2}
			}
			if exit2 == 0 {
				p.log("UI tests passed after deterministic reporter hardening.")
				return PhaseResult{Status: StatusPass}
			}
			out = out2
			exit = exit2
			output = string(out)
		}
	} else {
		// M54 remediation — one retry.
		if p.Remediator != nil && p.Remediator.TryRemediate(ctx, output, "build_gate_ui_test") {
			out2, exit2, err2 := runner.Run(ctx, p.Cmd, normalEnv, timeout)
			if err2 != nil {
				return PhaseResult{Status: StatusFail, Err: err2}
			}
			out = out2
			exit = exit2
			output = string(out)
		}
		// Generic flakiness retry — one retry.
		if exit != 0 {
			out2, exit2, err2 := runner.Run(ctx, p.Cmd, normalEnv, timeout)
			if err2 != nil {
				return PhaseResult{Status: StatusFail, Err: err2}
			}
			out = out2
			exit = exit2
			output = string(out)
		}
	}

	if exit == 0 {
		p.log("UI tests passed.")
		return PhaseResult{Status: StatusPass}
	}

	// Terminal failure path.
	now := time.Now
	if p.Now != nil {
		now = p.Now
	} else if in.Now != nil {
		now = in.Now
	}
	if p.Errors != nil {
		p.Errors.WriteUIFailure(in.StageLabel, p.Cmd, output, exit, now())
		normalApplied := "no"
		hardenedApplied := "no"
		hardenedAttemptedStr := "no"
		if p.Framework == FrameworkPlaywright {
			normalApplied = "yes"
			if hardenedAttempted {
				hardenedApplied = "yes"
				hardenedAttemptedStr = "yes"
			}
		}
		block := RenderDiagnosis(DiagnosisInput{
			Signature:         signature,
			NormalApplied:     normalApplied,
			HardenedApplied:   hardenedApplied,
			HardenedAttempted: hardenedAttemptedStr,
		})
		p.Errors.WriteUIDiagnosis(block)
	}
	return PhaseResult{Status: StatusFail, Err: ErrUITestFailed}
}

// log writes a one-line info message when Logger is set.
func (p *UIPhase) log(format string, args ...interface{}) {
	if p == nil || p.Logger == nil {
		return
	}
	p.Logger(format, args...)
}

// retryFactor returns the user-supplied factor, falling back to the bash
// default 0.5 when zero or negative.
func retryFactor(f float64) float64 {
	if f <= 0 {
		return 0.5
	}
	return f
}

// checkUITestCmdAvailable mirrors the bash command-availability guard:
//
//   - The first whitespace-separated token of UI_TEST_CMD is treated as the
//     binary name.
//   - npx / npm are always treated as available (they resolve at runtime).
//   - Any other binary must be on PATH via exec.LookPath; otherwise the
//     gate skips with a warning.
func checkUITestCmdAvailable(cmd string) bool {
	bin := strings.Fields(cmd)
	if len(bin) == 0 {
		return false
	}
	first := bin[0]
	if first == "npx" || first == "npm" {
		return true
	}
	_, err := exec.LookPath(first)
	return err == nil
}
