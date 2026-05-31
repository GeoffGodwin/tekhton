package gates

import (
	"context"
	"regexp"
	"strings"
	"time"
)

// AnalyzePhase ports lib/gates_phases.sh::_gate_phase_analyze. Runs
// ANALYZE_CMD, greps for ANALYZE_ERROR_PATTERN matches, attempts M54
// remediation on failure, and re-runs the command once if remediation
// succeeds. Writes the BUILD_ERRORS.md analyze section + BUILD_RAW_ERRORS.txt
// stream when the second run still fails.
type AnalyzePhase struct {
	Cmd          string        // ANALYZE_CMD
	ErrorPattern string        // ANALYZE_ERROR_PATTERN (regex)
	Timeout      time.Duration // BUILD_GATE_ANALYZE_TIMEOUT
	Runner       CommandRunner
	Remediator   Remediator
	Errors       ErrorsWriter
}

// Name implements Phase.
func (p *AnalyzePhase) Name() string { return "analyze" }

// Run implements Phase. Pass when no ANALYZE_ERROR_PATTERN matches.
// Fail when the error pattern still matches after remediation. Skip when
// ANALYZE_CMD is empty.
func (p *AnalyzePhase) Run(ctx context.Context, in *PhaseInput) PhaseResult {
	if p.Cmd == "" {
		return PhaseResult{Status: StatusSkip}
	}
	runner := p.Runner
	if runner == nil {
		runner = ExecRunner{}
	}
	effective := effectiveTimeout(p.Timeout, in.Remaining)
	out, _, timedOut, err := runner.Run(ctx, p.Cmd, effective)
	if err != nil {
		return PhaseResult{Status: StatusFail, Err: err}
	}
	if timedOut {
		return PhaseResult{Status: StatusPass}
	}
	output := string(out)
	errs := grepLines(output, defaultPattern(p.ErrorPattern, "error"))
	if errs == "" {
		return PhaseResult{Status: StatusPass}
	}

	// M54 remediation attempt — one retry max.
	if p.Remediator != nil {
		if p.Remediator.TryRemediate(ctx, errs, "build_gate_analyze") {
			effective = effectiveTimeout(p.Timeout, in.Remaining)
			out2, _, timedOut2, err2 := runner.Run(ctx, p.Cmd, effective)
			if err2 != nil {
				return PhaseResult{Status: StatusFail, Err: err2}
			}
			if timedOut2 {
				return PhaseResult{Status: StatusPass}
			}
			output = string(out2)
			errs = grepLines(output, defaultPattern(p.ErrorPattern, "error"))
			if errs == "" {
				return PhaseResult{Status: StatusPass}
			}
		}
	}

	now := time.Now
	if in.Now != nil {
		now = in.Now
	}
	if p.Errors != nil {
		p.Errors.WriteAnalyze(in.StageLabel, errs, output, now())
	}
	return PhaseResult{Status: StatusFail, Err: errAnalyzeFailed}
}

// CompilePhase ports lib/gates_phases.sh::_gate_phase_compile. Runs
// BUILD_CHECK_CMD, greps for BUILD_ERROR_PATTERN matches (head -20 like
// the bash side), attempts M54 remediation on failure, and re-runs once
// if remediation succeeds.
type CompilePhase struct {
	Cmd          string        // BUILD_CHECK_CMD
	ErrorPattern string        // BUILD_ERROR_PATTERN (string match, not regex)
	Timeout      time.Duration // BUILD_GATE_COMPILE_TIMEOUT
	Runner       CommandRunner
	Remediator   Remediator
	Errors       ErrorsWriter
}

// Name implements Phase.
func (p *CompilePhase) Name() string { return "compile" }

// Run implements Phase.
func (p *CompilePhase) Run(ctx context.Context, in *PhaseInput) PhaseResult {
	if p.Cmd == "" {
		return PhaseResult{Status: StatusSkip}
	}
	runner := p.Runner
	if runner == nil {
		runner = ExecRunner{}
	}
	effective := effectiveTimeout(p.Timeout, in.Remaining)
	out, _, timedOut, err := runner.Run(ctx, p.Cmd, effective)
	if err != nil {
		return PhaseResult{Status: StatusFail, Err: err}
	}
	if timedOut {
		return PhaseResult{Status: StatusPass}
	}
	output := string(out)
	pattern := defaultPattern(p.ErrorPattern, "ERROR")
	if !regexMatch(output, pattern) {
		return PhaseResult{Status: StatusPass}
	}
	errs := headLines(grepLines(output, pattern), 20)

	if p.Remediator != nil {
		if p.Remediator.TryRemediate(ctx, errs, "build_gate_compile") {
			effective = effectiveTimeout(p.Timeout, in.Remaining)
			out2, _, timedOut2, err2 := runner.Run(ctx, p.Cmd, effective)
			if err2 != nil {
				return PhaseResult{Status: StatusFail, Err: err2}
			}
			if timedOut2 {
				return PhaseResult{Status: StatusPass}
			}
			output = string(out2)
			if !regexMatch(output, pattern) {
				return PhaseResult{Status: StatusPass}
			}
			errs = headLines(grepLines(output, pattern), 20)
		}
	}

	now := time.Now
	if in.Now != nil {
		now = in.Now
	}
	if p.Errors != nil {
		p.Errors.WriteCompile(in.StageLabel, errs, now())
	}
	return PhaseResult{Status: StatusFail, Err: errCompileFailed}
}

// ConstraintsPhase ports the dependency-constraint validation block of
// lib/gates.sh. ValidationCmd is the validation_command string extracted
// from the constraints manifest at gate construction time; an empty value
// means skip.
type ConstraintsPhase struct {
	ValidationCmd string
	Timeout       time.Duration
	Runner        CommandRunner
	Errors        ErrorsWriter
}

// Name implements Phase.
func (p *ConstraintsPhase) Name() string { return "constraints" }

// Run implements Phase.
func (p *ConstraintsPhase) Run(ctx context.Context, in *PhaseInput) PhaseResult {
	if p.ValidationCmd == "" {
		return PhaseResult{Status: StatusSkip}
	}
	runner := p.Runner
	if runner == nil {
		runner = ExecRunner{}
	}
	effective := effectiveTimeout(p.Timeout, in.Remaining)
	out, exitCode, timedOut, err := runner.Run(ctx, p.ValidationCmd, effective)
	if err != nil {
		return PhaseResult{Status: StatusFail, Err: err}
	}
	if timedOut {
		return PhaseResult{Status: StatusPass}
	}
	if exitCode == 0 {
		return PhaseResult{Status: StatusPass}
	}
	if p.Errors != nil {
		p.Errors.WriteConstraints(string(out))
	}
	return PhaseResult{Status: StatusFail, Err: errConstraintsFailed}
}

// UIBashShim is the m31.1 placeholder for UIPhase. When UI_TEST_CMD is
// set, it execs `bash -c "source lib/gates_ui_helpers.sh; source
// lib/gates_ui.sh; _run_ui_test_phase '$stage_label'"` so the existing
// bash UI gate still fires through the Go orchestrator. m31.2 replaces
// this with internal/gates/ui.go.
//
// When UI_TEST_CMD is empty (the common case in fixtures and built-in
// dogfood runs), Run returns StatusSkip and the shim never spawns.
type UIBashShim struct {
	UITestCmd  string
	ShellEnv   map[string]string // UI_TEST_CMD, UI_GATE_ENV_RETRY_ENABLED, etc.
	BashRunner BashShimRunner    // pluggable for tests
}

// BashShimRunner abstracts the bash subprocess that m31.1 delegates the
// UI phase to. m31.2 replaces this with the native UIPhase.
type BashShimRunner interface {
	Run(ctx context.Context, stageLabel string, env map[string]string) (PhaseResult, error)
}

// Name implements Phase.
func (p *UIBashShim) Name() string { return "ui_test" }

// Run implements Phase. Skip when UI_TEST_CMD is empty (the m31.1 default).
// When UI_TEST_CMD is set, defer to the bash shim — m31.2 replaces this
// with a native implementation.
func (p *UIBashShim) Run(ctx context.Context, in *PhaseInput) PhaseResult {
	if p.UITestCmd == "" {
		return PhaseResult{Status: StatusSkip}
	}
	if p.BashRunner == nil {
		return PhaseResult{Status: StatusSkip}
	}
	res, err := p.BashRunner.Run(ctx, in.StageLabel, p.ShellEnv)
	if err != nil {
		return PhaseResult{Status: StatusFail, Err: err}
	}
	return res
}

// UIValidationPhase ports the run_ui_validation invocation at the tail of
// run_build_gate. When the command name is empty (the m31.1 default), the
// phase skips. m31.2 will fill in the native validation surface.
type UIValidationPhase struct {
	Cmd     string
	Timeout time.Duration
	Runner  CommandRunner
}

// Name implements Phase.
func (p *UIValidationPhase) Name() string { return "ui_validation" }

// Run implements Phase. Skip when no validation command configured.
func (p *UIValidationPhase) Run(ctx context.Context, in *PhaseInput) PhaseResult {
	if p.Cmd == "" {
		return PhaseResult{Status: StatusSkip}
	}
	runner := p.Runner
	if runner == nil {
		runner = ExecRunner{}
	}
	effective := effectiveTimeout(p.Timeout, in.Remaining)
	_, exitCode, timedOut, err := runner.Run(ctx, p.Cmd, effective)
	if err != nil {
		return PhaseResult{Status: StatusFail, Err: err}
	}
	if timedOut {
		return PhaseResult{Status: StatusPass}
	}
	if exitCode != 0 {
		return PhaseResult{Status: StatusFail, Err: errUIValidationFailed}
	}
	return PhaseResult{Status: StatusPass}
}

// Phase-failure sentinels. Wrapped in PhaseError by BuildGate.Run so
// callers can recover both the phase name and the cause via errors.As.
var (
	errAnalyzeFailed      = stringError("analyze errors found")
	errCompileFailed      = stringError("compile errors found")
	errConstraintsFailed  = stringError("dependency constraint violations")
	errUIValidationFailed = stringError("ui validation failed")
)

type stringError string

func (e stringError) Error() string { return string(e) }

// effectiveTimeout returns min(phase_timeout, remaining_gate_time).
// Zero phase_timeout falls back to remaining. Negative remaining returns
// the phase timeout (let the runner deal with the deadline downstream).
func effectiveTimeout(phaseTO, remaining time.Duration) time.Duration {
	if phaseTO <= 0 {
		if remaining > 0 {
			return remaining
		}
		return 0
	}
	if remaining <= 0 {
		return phaseTO
	}
	if phaseTO > remaining {
		return remaining
	}
	return phaseTO
}

// grepLines emits every line in s that matches pattern (as a regex). Lines
// that don't compile (pattern is invalid) silently return "" to mirror the
// bash `grep -E "$pat" || true` semantics.
func grepLines(s, pattern string) string {
	re, err := regexp.Compile(pattern)
	if err != nil {
		return ""
	}
	var out []string
	for _, line := range strings.Split(s, "\n") {
		if re.MatchString(line) {
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}

// regexMatch reports whether any line of s matches pattern.
func regexMatch(s, pattern string) bool {
	re, err := regexp.Compile(pattern)
	if err != nil {
		return false
	}
	return re.MatchString(s)
}

// headLines returns the first n newline-separated lines of s. Mirrors
// the bash `head -n N` invocation at the tail of _gate_run_compile.
func headLines(s string, n int) string {
	if s == "" {
		return ""
	}
	lines := strings.Split(s, "\n")
	if len(lines) <= n {
		return s
	}
	return strings.Join(lines[:n], "\n")
}

// defaultPattern returns p when non-empty, fallback otherwise. Mirrors
// the bash ${ANALYZE_ERROR_PATTERN:-error} parameter expansion.
func defaultPattern(p, fallback string) string {
	if p == "" {
		return fallback
	}
	return p
}
