package intake

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ====================================================================
// Operator-facing strings.
//
// CHANGE WITH EXTREME CARE — operators have email filters / dashboards
// that key off the exact line text. The verdict_test.go regression
// tests assert byte identity for the critical strings; the
// helpers-only `TestBashTextParity` test cross-checks against the bash
// shim files. Edit both sides together if you ever need to change one.
// ====================================================================
const (
	MsgTweaksApplied        = "Intake: tweaks applied. Review required (INTAKE_CONFIRM_TWEAKS=true)."
	MsgTweaksRejected       = "Tweaks rejected by user. Saving state."
	MsgTweaksRejectedReason = "Intake tweaks rejected — edit milestone and re-run"
	MsgTweaksProceeding     = "Intake: tweaks applied. Proceeding."
	MsgSplitRecommended     = "The PM agent recommends splitting this milestone."
	MsgSplitOptions         = "Options: [s]plit now, [c]ontinue anyway, [q]uit"
	MsgSplitDeclined        = "Pipeline paused by user."
	MsgSplitDeclinedReason  = "Intake recommended split — user chose to quit"
	MsgSplitContinue        = "Continuing without split."
	MsgSplitNotAvailable    = "Split not available (not in milestone mode or split_milestone not loaded)."
	MsgNeedsClarity         = "Intake: needs clarification."
	MsgClarifyAborted       = "Clarification aborted. Saving state."
	MsgClarifyAbortedReason = "Intake needs human clarification"
	MsgClarifyCompleteWritten = "Intake: questions written to %s."
	MsgClarifyCompleteHalt  = "Cannot collect answers in --complete mode (autonomous). Saving state."
	MsgClarifyCompleteReasonFmt = "Intake needs human clarification — answer %s and re-run"
	MsgClarifyRecorded      = "Clarifications recorded. Proceeding."
	MsgClarifyNoQuestions   = "Intake: NEEDS_CLARITY but no questions found in report. Proceeding cautiously."
	MsgSplitAutoTrying      = "Intake: auto-splitting milestone %s..."
	MsgSplitAutoSuccess     = "Intake: milestone split successfully."
	MsgSplitAutoFailed      = "Intake: auto-split failed. Escalating to human."
	MsgSplitHeader          = "Intake: Split Recommended"
	MsgConfirmTweaksHeader  = "PM Agent tweaked the task. Changes:"
	MsgConfirmTweaksRule    = "────────────────────────────────────────"
	MsgConfirmTweaksPrompt  = "Accept tweaks and continue? [y/n]"
	ClarificationsHeaderFmt = "# Intake Clarifications — %s"
	QuestionPrefix          = "## Q: "
)

// PipelineStateWriter is the seam onto write_pipeline_state(). The verdict
// handler calls it when it needs to halt the pipeline with a resume
// instruction. The bash equivalent writes PIPELINE_STATE.md; the Go-native
// stage port wires this to internal/state.Store.Update.
type PipelineStateWriter func(stage, exitReason, args, task, msg, milestone string) error

// SplitFunc invokes the bash split_milestone helper (or the m36.3 Go port).
// Returns nil on success; non-nil error halts the auto-split branch and
// escalates to the interactive prompt.
type SplitFunc func(milestone, claudeMD string) error

// SwitchFunc invokes the bash _switch_to_sub_milestone helper. Called after
// a successful SplitFunc to switch the active milestone pointer.
type SwitchFunc func(milestone, claudeMD string) error

// ClarifyHandleFunc invokes `tekhton clarify handle --report PATH
// --project-dir DIR`. The default execs the binary; tests inject a fake.
type ClarifyHandleFunc func(ctx context.Context, reportPath, projectDir string) error

// VerdictHandler routes one of TWEAKED / SPLIT_RECOMMENDED / NEEDS_CLARITY.
//
// All operator-visible writes go through Stdout / Stderr (defaulted to
// os.Stdout / os.Stderr) so tests can capture them. User input is read
// from Stdin (defaulted to os.Stdin); the bash equivalent falls back to
// /dev/tty when stdin is not a TTY — the Go port keeps that behaviour via
// the optional TTYReader hook.
type VerdictHandler struct {
	H *Helpers

	// Mode flags — sourced from the calling pipeline env.
	AutoSplit       bool
	ConfirmTweaks   bool
	CompleteMode    bool
	MilestoneMode   bool
	CurrentMs       string
	Task            string
	ProjectRulesFile string

	// Injected dependencies — see type docstrings above.
	PipelineState PipelineStateWriter
	Split         SplitFunc
	Switch        SwitchFunc
	ClarifyHandle ClarifyHandleFunc
	TekhtonBin    string

	// I/O — default to os.Stdin/Stdout/Stderr if nil. TTYReader is the
	// /dev/tty fallback used when Stdin is not a TTY (matches bash
	// `read -r < /dev/tty`); leaving it nil disables the fallback.
	Stdin     io.Reader
	Stdout    io.Writer
	Stderr    io.Writer
	TTYReader io.Reader

	// IsStdinTTY mirrors `[[ -t 0 ]]`. Defaults to false (mirroring CI
	// environments where the bash version falls back to /dev/tty).
	IsStdinTTY bool

	// SizeGuardMinPct is the floor for ApplyTweakMilestone (defaults to 50).
	SizeGuardMinPct int
}

// HandleTweaked applies the tweak block from the report. Mirrors
// _intake_handle_tweaked, including the optional INTAKE_CONFIRM_TWEAKS prompt.
func (v *VerdictHandler) HandleTweaked(ctx context.Context, reportPath string) error {
	if v.H == nil {
		return errors.New("intake: VerdictHandler.H not configured")
	}
	tweaks := v.H.ParseTweaks(reportPath)
	// Export the tweaks block so the bash shim's downstream consumers
	// (e.g. the build-fix agent's RESUME_TASK_BLOCK) can read it. The CLI
	// shim re-exports via env; the in-process M36.3 stage will do the
	// same via os.Setenv before invoking the next sub-stage.
	_ = os.Setenv("INTAKE_TWEAKS_BLOCK", tweaks)

	minPct := v.SizeGuardMinPct
	if minPct <= 0 {
		minPct = 50
	}

	if v.MilestoneMode && v.CurrentMs != "" {
		// Bash treats apply failure as non-fatal (`|| true`).
		_ = v.H.ApplyTweakMilestone(tweaks, v.CurrentMs, minPct)
	} else {
		newTask, _ := v.H.ApplyTweakTask(tweaks)
		if newTask != "" {
			v.Task = newTask
		}
	}

	if !v.ConfirmTweaks {
		v.logf(MsgTweaksProceeding)
		return nil
	}

	// Interactive confirmation. CompleteMode short-circuits to "y" — the
	// bash version's `read -r < /dev/tty` fallback would also default to
	// "y" when no TTY is present.
	v.logf(MsgTweaksApplied)
	v.fprintln(v.outOrStdout(), "")
	v.fprintln(v.outOrStdout(), MsgConfirmTweaksHeader)
	v.fprintln(v.outOrStdout(), MsgConfirmTweaksRule)
	v.fprintln(v.outOrStdout(), headLines(tweaks, 40))
	v.fprintln(v.outOrStdout(), MsgConfirmTweaksRule)
	v.fprintln(v.outOrStdout(), "")
	v.logf(MsgConfirmTweaksPrompt)

	choice := v.readChoice("y")
	if !isYes(choice) {
		v.warnf(MsgTweaksRejected)
		_ = v.writeState(ctx, "intake", "tweaks_rejected",
			"--milestone --start-at coder",
			MsgTweaksRejectedReason)
		return ErrHalt
	}

	v.successf(MsgTweaksProceeding)
	return nil
}

// HandleSplitRecommended presents the split recommendation. Auto-splits when
// the configured flags align; otherwise prompts the operator for s/c/q.
func (v *VerdictHandler) HandleSplitRecommended(ctx context.Context, reportPath string) error {
	if v.H == nil {
		return errors.New("intake: VerdictHandler.H not configured")
	}
	v.logf("Intake: split recommended.")

	if v.AutoSplit && v.MilestoneMode && v.CurrentMs != "" && v.Split != nil {
		v.logf(MsgSplitAutoTrying, v.CurrentMs)
		if err := v.Split(v.CurrentMs, v.claudeMD()); err == nil {
			v.successf(MsgSplitAutoSuccess)
			if v.Switch != nil {
				_ = v.Switch(v.CurrentMs, v.claudeMD())
			}
			return nil
		}
		v.warnf(MsgSplitAutoFailed)
	}

	// Interactive escalation.
	v.fprintln(v.outOrStdout(), "")
	v.headerf(MsgSplitHeader)
	v.fprintln(v.outOrStdout(), MsgSplitRecommended)
	v.fprintln(v.outOrStdout(), "")
	if rec := extractSection(readFileBest(reportPath), "## Split Recommendations", []string{"## "}); rec != "" {
		v.fprintln(v.outOrStdout(), headLines(rec, 30))
	}
	v.fprintln(v.outOrStdout(), "")
	v.logf(MsgSplitOptions)

	choice := v.readChoice("c")
	switch strings.ToLower(strings.TrimSpace(choice)) {
	case "s":
		if v.Split != nil && v.MilestoneMode {
			_ = v.Split(v.CurrentMs, v.claudeMD())
			if v.Switch != nil {
				_ = v.Switch(v.CurrentMs, v.claudeMD())
			}
		} else {
			v.warnf(MsgSplitNotAvailable)
		}
		return nil
	case "q":
		v.warnf(MsgSplitDeclined)
		_ = v.writeState(ctx, "intake", "split_declined",
			"--milestone --start-at coder",
			MsgSplitDeclinedReason)
		return ErrHalt
	default:
		v.logf(MsgSplitContinue)
		return nil
	}
}

// HandleNeedsClarity writes the question list to CLARIFICATIONS.md and either
// halts (CompleteMode) or shells to `tekhton clarify handle`.
func (v *VerdictHandler) HandleNeedsClarity(ctx context.Context, reportPath string) error {
	if v.H == nil {
		return errors.New("intake: VerdictHandler.H not configured")
	}
	if _, err := os.Stat(reportPath); os.IsNotExist(err) {
		v.warnf("Intake: report file not found: %s", reportPath)
		return nil
	}
	v.logf(MsgNeedsClarity)
	questions := v.H.ParseQuestions(reportPath)
	if strings.TrimSpace(questions) == "" {
		v.warnf(MsgClarifyNoQuestions)
		return nil
	}

	// Write the structured "## Q: ..." block to CLARIFICATIONS.md.
	if err := v.appendClarifications(questions); err != nil {
		return err
	}

	if v.CompleteMode {
		clarFile := v.H.ClarificationsFile
		if clarFile == "" {
			clarFile = ".tekhton/CLARIFICATIONS.md"
		}
		v.warnf(MsgClarifyCompleteWritten, clarFile)
		v.warnf(MsgClarifyCompleteHalt)
		_ = v.writeState(ctx, "intake", "needs_clarity",
			"--milestone --start-at coder",
			fmt.Sprintf(MsgClarifyCompleteReasonFmt, clarFile))
		return ErrHalt
	}

	// Synthesize a tiny intake-clarify report and shell to clarify handle.
	intakeReport, err := v.writeIntakeClarifyReport(questions)
	if err != nil {
		return err
	}
	handle := v.ClarifyHandle
	if handle == nil {
		handle = defaultClarifyHandle(v.TekhtonBin)
	}
	if err := handle(ctx, intakeReport, v.H.ProjectDir); err != nil {
		v.warnf(MsgClarifyAborted)
		_ = v.writeState(ctx, "intake", "needs_clarity",
			"--milestone --start-at coder",
			MsgClarifyAbortedReason)
		return ErrHalt
	}
	v.successf(MsgClarifyRecorded)
	return nil
}

// ErrHalt signals that the caller (the bash shim or M36.3 stage) should
// terminate the pipeline. The bash version called `exit 1` directly; the Go
// version returns this sentinel so callers can write state, surface a
// diagnostic, then exit on their own terms.
var ErrHalt = errors.New("intake: halt requested")

// --- helpers ----------------------------------------------------------------

func (v *VerdictHandler) appendClarifications(questions string) error {
	clarPath := v.H.ClarificationsFile
	if !filepath.IsAbs(clarPath) && v.H.ProjectDir != "" {
		clarPath = filepath.Join(v.H.ProjectDir, clarPath)
	}
	if clarPath == "" {
		return errors.New("intake: ClarificationsFile not configured")
	}
	if err := os.MkdirAll(filepath.Dir(clarPath), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(clarPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()

	var buf strings.Builder
	buf.WriteString("\n")
	buf.WriteString(fmt.Sprintf(ClarificationsHeaderFmt, timestamp()) + "\n")
	buf.WriteString("\n")
	sc := bufio.NewScanner(strings.NewReader(questions))
	for sc.Scan() {
		line := sc.Text()
		text := stripQuestionTags(line)
		if text == "" {
			continue
		}
		buf.WriteString(QuestionPrefix + text + "\n")
		buf.WriteString("\n")
	}
	if _, err := f.WriteString(buf.String()); err != nil {
		return err
	}
	return nil
}

func (v *VerdictHandler) writeIntakeClarifyReport(questions string) (string, error) {
	if v.H.SessionDir == "" {
		return "", errors.New("intake: SessionDir not configured")
	}
	if err := os.MkdirAll(v.H.SessionDir, 0o755); err != nil {
		return "", err
	}
	intakeReport := filepath.Join(v.H.SessionDir, "intake_clarify_report.md")
	var buf strings.Builder
	buf.WriteString("# Intake Clarifications\n\n## Clarification Required\n")
	sc := bufio.NewScanner(strings.NewReader(questions))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "- ") {
			line = strings.TrimPrefix(line, "- ")
		}
		if line == "" {
			continue
		}
		buf.WriteString("- [BLOCKING] " + line + "\n")
	}
	if err := os.WriteFile(intakeReport, []byte(buf.String()), 0o644); err != nil {
		return "", err
	}
	return intakeReport, nil
}

func (v *VerdictHandler) writeState(_ context.Context, stage, exitReason, args, msg string) error {
	if v.PipelineState == nil {
		return nil
	}
	return v.PipelineState(stage, exitReason, args, v.Task, msg, v.CurrentMs)
}

func (v *VerdictHandler) claudeMD() string {
	if v.ProjectRulesFile != "" {
		return v.ProjectRulesFile
	}
	return "CLAUDE.md"
}

func (v *VerdictHandler) readChoice(fallback string) string {
	in := v.Stdin
	if v.IsStdinTTY && in != nil {
		// Read from stdin when it's a TTY.
		line, err := readLine(in)
		if err == nil && line != "" {
			return line
		}
	} else if v.TTYReader != nil {
		line, err := readLine(v.TTYReader)
		if err == nil && line != "" {
			return line
		}
	} else if in != nil {
		// Non-TTY but with a stdin source — read it (test pattern).
		line, err := readLine(in)
		if err == nil && line != "" {
			return line
		}
	}
	return fallback
}

func readLine(r io.Reader) (string, error) {
	br := bufio.NewReader(r)
	line, err := br.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	return strings.TrimRight(line, "\r\n"), nil
}

func isYes(s string) bool {
	s = strings.TrimSpace(s)
	return len(s) == 1 && (s[0] == 'y' || s[0] == 'Y')
}

func headLines(s string, n int) string {
	if n <= 0 {
		return ""
	}
	var out []string
	count := 0
	for _, line := range strings.Split(s, "\n") {
		out = append(out, line)
		count++
		if count >= n {
			break
		}
	}
	return strings.Join(out, "\n")
}

func stripQuestionTags(line string) string {
	t := strings.TrimSpace(line)
	if t == "" {
		return ""
	}
	if strings.HasPrefix(t, "- ") {
		t = strings.TrimSpace(strings.TrimPrefix(t, "- "))
	}
	for _, prefix := range []string{"[BLOCKING]", "[NON_BLOCKING]"} {
		if strings.HasPrefix(t, prefix) {
			t = strings.TrimSpace(strings.TrimPrefix(t, prefix))
		}
	}
	return t
}

func readFileBest(p string) string {
	data, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return string(data)
}

// timestamp is the source of `date '+%Y-%m-%d %H:%M:%S'`. Pinned in tests
// by overriding the var.
var timestamp = defaultTimestamp

func (v *VerdictHandler) outOrStdout() io.Writer {
	if v.Stdout != nil {
		return v.Stdout
	}
	return os.Stdout
}

func (v *VerdictHandler) errOrStderr() io.Writer {
	if v.Stderr != nil {
		return v.Stderr
	}
	return os.Stderr
}

func (v *VerdictHandler) fprintln(w io.Writer, s string) { fmt.Fprintln(w, s) }

func (v *VerdictHandler) logf(format string, a ...any) {
	fmt.Fprintln(v.errOrStderr(), fmt.Sprintf(format, a...))
}

func (v *VerdictHandler) warnf(format string, a ...any) {
	fmt.Fprintln(v.errOrStderr(), fmt.Sprintf(format, a...))
}

func (v *VerdictHandler) successf(format string, a ...any) {
	fmt.Fprintln(v.errOrStderr(), fmt.Sprintf(format, a...))
}

func (v *VerdictHandler) headerf(format string, a ...any) {
	fmt.Fprintln(v.outOrStdout(), fmt.Sprintf(format, a...))
}

// defaultClarifyHandle execs `<bin> clarify handle --report PATH
// --project-dir DIR`. Exit-status non-zero is returned as an error so the
// caller can route to the saving-state branch.
func defaultClarifyHandle(bin string) ClarifyHandleFunc {
	if bin == "" {
		bin = "tekhton"
	}
	return func(ctx context.Context, reportPath, projectDir string) error {
		cmd := exec.CommandContext(ctx, bin, "clarify", "handle",
			"--report", reportPath, "--project-dir", projectDir)
		cmd.Stdin = os.Stdin
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		return cmd.Run()
	}
}
