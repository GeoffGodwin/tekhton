// Package main — `tekhton intake ...` Cobra shim.
//
// LIFETIME: m36.2 → m36.3 only. The bash shim files (lib/intake_helpers.sh +
// lib/intake_verdict_handlers.sh) exec these subcommands so stages/intake.sh
// keeps working while the intake stage itself is still bash. M36.3 ports the
// stage to Go, then DELETES this file together with the two bash files. There
// is intentionally no operator-facing surface here — every subcommand is
// Hidden and exists purely as a transition seam.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/intake"
	"github.com/spf13/cobra"
)

// newIntakeCmd wires `tekhton intake helpers ...` and `tekhton intake verdict
// ...`. The parent is Hidden — operators see nothing under `tekhton --help`.
func newIntakeCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "intake",
		Short:  "Intake helpers transition shim (m36.2; deleted in m36.3)",
		Hidden: true,
	}
	c.AddCommand(newIntakeHelpersCmd(), newIntakeVerdictCmd())
	return c
}

// helpersFromEnv constructs an intake.Helpers from environment variables the
// bash shim sets. Mirrors the per-call env that lib/intake_helpers.sh expects.
func helpersFromEnv() *intake.Helpers {
	clarFile := os.Getenv("CLARIFICATIONS_FILE")
	if clarFile == "" {
		clarFile = ".tekhton/CLARIFICATIONS.md"
	}
	msDir := os.Getenv("MILESTONE_DIR")
	if msDir == "" {
		msDir = ".claude/milestones"
	}
	rules := os.Getenv("PROJECT_RULES_FILE")
	if rules == "" {
		rules = "CLAUDE.md"
	}
	dag := true
	if v := os.Getenv("MILESTONE_DAG_ENABLED"); v != "" {
		dag = v == "true"
	}
	return &intake.Helpers{
		ProjectDir:         os.Getenv("PROJECT_DIR"),
		SessionDir:         os.Getenv("TEKHTON_SESSION_DIR"),
		MilestoneDir:       msDir,
		ProjectRulesFile:   rules,
		ClarificationsFile: clarFile,
		DagEnabled:         dag,
	}
}

// --- helpers subcommands -----------------------------------------------------

func newIntakeHelpersCmd() *cobra.Command {
	c := &cobra.Command{Use: "helpers", Hidden: true}
	c.AddCommand(
		newIntakeContentHashCmd(),
		newIntakeShouldSkipCmd(),
		newIntakeSaveHashCmd(),
		newIntakeParseVerdictCmd(),
		newIntakeParseConfidenceCmd(),
		newIntakeParseTweaksCmd(),
		newIntakeParseQuestionsCmd(),
		newIntakeMilestoneContentCmd(),
		newIntakeApplyTweakMilestoneCmd(),
		newIntakeApplyTweakTaskCmd(),
		newIntakeAddPMMetadataCmd(),
	)
	return c
}

func newIntakeContentHashCmd() *cobra.Command {
	c := &cobra.Command{
		Use: "content-hash", Hidden: true,
		Short: "Read stdin, print SHA-256 hex digest",
		RunE: func(cmd *cobra.Command, _ []string) error {
			data, err := io.ReadAll(cmd.InOrStdin())
			if err != nil {
				return err
			}
			fmt.Fprintln(cmd.OutOrStdout(), helpersFromEnv().ContentHash(string(data)))
			return nil
		},
	}
	return c
}

func newIntakeShouldSkipCmd() *cobra.Command {
	var hash string
	c := &cobra.Command{
		Use: "should-skip", Hidden: true,
		Short: "Exit 0 when --hash matches the saved hash; 1 otherwise",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if helpersFromEnv().ShouldSkip(hash) {
				return nil
			}
			cmd.SilenceUsage = true
			cmd.SilenceErrors = true
			os.Exit(1)
			return nil
		},
	}
	c.Flags().StringVar(&hash, "hash", "", "hash to test")
	_ = c.MarkFlagRequired("hash")
	return c
}

func newIntakeSaveHashCmd() *cobra.Command {
	var hash string
	c := &cobra.Command{
		Use: "save-hash", Hidden: true,
		Short: "Save --hash to the session content-hash file",
		RunE: func(_ *cobra.Command, _ []string) error {
			return helpersFromEnv().SaveHash(hash)
		},
	}
	c.Flags().StringVar(&hash, "hash", "", "hash to save")
	_ = c.MarkFlagRequired("hash")
	return c
}

func newIntakeParseVerdictCmd() *cobra.Command {
	var report string
	c := &cobra.Command{
		Use: "parse-verdict", Hidden: true,
		Short: "Print the verdict from --report (PASS|TWEAKED|SPLIT_RECOMMENDED|NEEDS_CLARITY)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			fmt.Fprintln(cmd.OutOrStdout(), helpersFromEnv().ParseVerdict(report))
			return nil
		},
	}
	c.Flags().StringVar(&report, "report", "", "path to INTAKE_REPORT.md")
	_ = c.MarkFlagRequired("report")
	return c
}

func newIntakeParseConfidenceCmd() *cobra.Command {
	var report string
	c := &cobra.Command{
		Use: "parse-confidence", Hidden: true,
		Short: "Print the confidence score from --report (0..100)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			fmt.Fprintln(cmd.OutOrStdout(), helpersFromEnv().ParseConfidence(report))
			return nil
		},
	}
	c.Flags().StringVar(&report, "report", "", "path to INTAKE_REPORT.md")
	_ = c.MarkFlagRequired("report")
	return c
}

func newIntakeParseTweaksCmd() *cobra.Command {
	var report string
	c := &cobra.Command{
		Use: "parse-tweaks", Hidden: true,
		Short: "Print the tweaked content block from --report",
		RunE: func(cmd *cobra.Command, _ []string) error {
			body := helpersFromEnv().ParseTweaks(report)
			if body != "" {
				fmt.Fprintln(cmd.OutOrStdout(), body)
			}
			return nil
		},
	}
	c.Flags().StringVar(&report, "report", "", "path to INTAKE_REPORT.md")
	_ = c.MarkFlagRequired("report")
	return c
}

func newIntakeParseQuestionsCmd() *cobra.Command {
	var report string
	c := &cobra.Command{
		Use: "parse-questions", Hidden: true,
		Short: "Print the questions block from --report",
		RunE: func(cmd *cobra.Command, _ []string) error {
			body := helpersFromEnv().ParseQuestions(report)
			if body != "" {
				fmt.Fprintln(cmd.OutOrStdout(), body)
			}
			return nil
		},
	}
	c.Flags().StringVar(&report, "report", "", "path to INTAKE_REPORT.md")
	_ = c.MarkFlagRequired("report")
	return c
}

func newIntakeMilestoneContentCmd() *cobra.Command {
	var ms, task string
	c := &cobra.Command{
		Use: "milestone-content", Hidden: true,
		Short: "Print the active milestone body or task string",
		RunE: func(cmd *cobra.Command, _ []string) error {
			h := helpersFromEnv()
			milestoneMode := os.Getenv("MILESTONE_MODE") == "true"
			if ms == "" {
				ms = os.Getenv("_CURRENT_MILESTONE")
			}
			if task == "" {
				task = os.Getenv("TASK")
			}
			body, err := h.MilestoneContent(milestoneMode, ms, task)
			if err != nil {
				return err
			}
			// Bash callers rely on the absence of a trailing newline when the
			// body itself does not end in one; preserve that.
			fmt.Fprint(cmd.OutOrStdout(), body)
			if body != "" && !strings.HasSuffix(body, "\n") {
				fmt.Fprintln(cmd.OutOrStdout())
			}
			return nil
		},
	}
	c.Flags().StringVar(&ms, "milestone", "", "milestone id/number (defaults to _CURRENT_MILESTONE)")
	c.Flags().StringVar(&task, "task", "", "task string (defaults to TASK)")
	return c
}

func newIntakeApplyTweakMilestoneCmd() *cobra.Command {
	var contentFile, ms string
	c := &cobra.Command{
		Use: "apply-tweak-milestone", Hidden: true,
		Short: "Apply --content-file to milestone --ms with size-guard + backup",
		RunE: func(cmd *cobra.Command, _ []string) error {
			data, err := os.ReadFile(contentFile)
			if err != nil {
				return err
			}
			minPct := 50
			if v := os.Getenv("INTAKE_TWEAK_MIN_SIZE_PCT"); v != "" {
				if n, err := strconv.Atoi(v); err == nil && n >= 0 && n <= 100 {
					minPct = n
				}
			}
			err = helpersFromEnv().ApplyTweakMilestone(string(data), ms, minPct)
			if errors.Is(err, intake.ErrTweakRejected) {
				cmd.SilenceUsage = true
				cmd.SilenceErrors = true
				os.Exit(1)
			}
			return err
		},
	}
	c.Flags().StringVar(&contentFile, "content-file", "", "file with tweaked milestone content")
	c.Flags().StringVar(&ms, "ms", "", "milestone id/number")
	_ = c.MarkFlagRequired("content-file")
	_ = c.MarkFlagRequired("ms")
	return c
}

func newIntakeApplyTweakTaskCmd() *cobra.Command {
	var contentFile string
	c := &cobra.Command{
		Use: "apply-tweak-task", Hidden: true,
		Short: "Apply --content-file as the new TASK; print the new task string",
		RunE: func(cmd *cobra.Command, _ []string) error {
			data, err := os.ReadFile(contentFile)
			if err != nil {
				return err
			}
			newTask, err := helpersFromEnv().ApplyTweakTask(string(data))
			if err != nil {
				return err
			}
			fmt.Fprintln(cmd.OutOrStdout(), newTask)
			return nil
		},
	}
	c.Flags().StringVar(&contentFile, "content-file", "", "file with tweaked task content")
	_ = c.MarkFlagRequired("content-file")
	return c
}

func newIntakeAddPMMetadataCmd() *cobra.Command {
	var msFile string
	c := &cobra.Command{
		Use: "add-pm-metadata", Hidden: true,
		Short: "Stamp the <!-- PM-tweaked: YYYY-MM-DD --> comment in --ms-file",
		RunE: func(_ *cobra.Command, _ []string) error {
			return helpersFromEnv().AddPMMetadata(msFile)
		},
	}
	c.Flags().StringVar(&msFile, "ms-file", "", "milestone file to annotate")
	_ = c.MarkFlagRequired("ms-file")
	return c
}

// --- verdict subcommands -----------------------------------------------------

func newIntakeVerdictCmd() *cobra.Command {
	c := &cobra.Command{Use: "verdict", Hidden: true}
	c.AddCommand(
		newIntakeVerdictTweakedCmd(),
		newIntakeVerdictSplitRecommendedCmd(),
		newIntakeVerdictNeedsClarityCmd(),
	)
	return c
}

// verdictFromEnv wires a VerdictHandler from the calling pipeline env. The
// PipelineState seam writes a tab-separated sentinel file at
// $TEKHTON_INTAKE_STATE_OUT (typically <SessionDir>/intake_state_out.tsv) so
// the bash shim can read it and call write_pipeline_state with the original
// V3 field order. Sentinel pattern (not exec'ing back into bash) keeps the
// shim self-contained and lets unit tests assert on the file contents.
func verdictFromEnv() *intake.VerdictHandler {
	h := helpersFromEnv()
	autoSplit := os.Getenv("INTAKE_AUTO_SPLIT") == "true"
	confirm := os.Getenv("INTAKE_CONFIRM_TWEAKS") == "true"
	complete := os.Getenv("COMPLETE_MODE") == "true"
	msMode := os.Getenv("MILESTONE_MODE") == "true"
	rules := os.Getenv("PROJECT_RULES_FILE")
	if rules == "" {
		rules = "CLAUDE.md"
	}
	return &intake.VerdictHandler{
		H:                h,
		AutoSplit:        autoSplit,
		ConfirmTweaks:    confirm,
		CompleteMode:     complete,
		MilestoneMode:    msMode,
		CurrentMs:        os.Getenv("_CURRENT_MILESTONE"),
		Task:             os.Getenv("TASK"),
		ProjectRulesFile: rules,
		PipelineState:    intakeStateSentinel(os.Getenv("TEKHTON_INTAKE_STATE_OUT")),
		Split:            shimSplit,
		Switch:           shimSwitch,
		ClarifyHandle:    nil, // defaults to exec `tekhton clarify handle`
		TekhtonBin:       os.Getenv("TEKHTON_BIN"),
		Stdin:            os.Stdin,
		Stdout:           os.Stdout,
		Stderr:           os.Stderr,
		IsStdinTTY:       isTTY(os.Stdin),
	}
}

// intakeStateSentinel returns a PipelineStateWriter that writes a TSV row to
// the sentinel path. Empty path → no-op (in-process callers like the M36.3
// stage wire a real writer instead).
func intakeStateSentinel(path string) intake.PipelineStateWriter {
	if path == "" {
		return nil
	}
	return func(stage, exitReason, args, task, msg, milestone string) error {
		row := strings.Join([]string{stage, exitReason, args, task, msg, milestone}, "\t") + "\n"
		// Append so multiple verdict cycles within a run accumulate; the bash
		// shim reads the last line.
		f, err := openAppend(path)
		if err != nil {
			return err
		}
		defer f.Close()
		_, err = f.WriteString(row)
		return err
	}
}

func openAppend(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
}

func newIntakeVerdictTweakedCmd() *cobra.Command {
	var report string
	c := &cobra.Command{
		Use: "tweaked", Hidden: true,
		Short: "Handle TWEAKED verdict — apply tweaks, optionally confirm",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runVerdict(cmd.Context(), report, func(v *intake.VerdictHandler) error {
				return v.HandleTweaked(cmd.Context(), report)
			})
		},
	}
	c.Flags().StringVar(&report, "report", "", "path to INTAKE_REPORT.md")
	_ = c.MarkFlagRequired("report")
	return c
}

func newIntakeVerdictSplitRecommendedCmd() *cobra.Command {
	var report string
	c := &cobra.Command{
		Use: "split-recommended", Hidden: true,
		Short: "Handle SPLIT_RECOMMENDED verdict",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runVerdict(cmd.Context(), report, func(v *intake.VerdictHandler) error {
				return v.HandleSplitRecommended(cmd.Context(), report)
			})
		},
	}
	c.Flags().StringVar(&report, "report", "", "path to INTAKE_REPORT.md")
	_ = c.MarkFlagRequired("report")
	return c
}

func newIntakeVerdictNeedsClarityCmd() *cobra.Command {
	var report string
	c := &cobra.Command{
		Use: "needs-clarity", Hidden: true,
		Short: "Handle NEEDS_CLARITY verdict",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runVerdict(cmd.Context(), report, func(v *intake.VerdictHandler) error {
				return v.HandleNeedsClarity(cmd.Context(), report)
			})
		},
	}
	c.Flags().StringVar(&report, "report", "", "path to INTAKE_REPORT.md")
	_ = c.MarkFlagRequired("report")
	return c
}

func runVerdict(_ context.Context, report string, fn func(*intake.VerdictHandler) error) error {
	if report == "" {
		return errExitCode{code: exitUsage, err: fmt.Errorf("--report is required")}
	}
	v := verdictFromEnv()
	err := fn(v)
	if errors.Is(err, intake.ErrHalt) {
		// Halt is the bash equivalent of `exit 1`; surface it via exit code
		// so the bash shim's `if ! tekhton intake verdict ...; then ... fi`
		// fires its halt branch and writes pipeline state.
		return errExitCode{code: 1, err: fmt.Errorf("intake: halt requested")}
	}
	return err
}

// shimSplit / shimSwitch are nil seams for m36.2 — the bash shim handles
// split_milestone / _switch_to_sub_milestone in its own caller scope when the
// CLI returns non-zero. Once m36.3 inverts the call direction these become
// real Go calls to the manifest subsystem.
func shimSplit(_, _ string) error  { return errors.New("intake: split via Go shim not yet wired (m36.2)") }
func shimSwitch(_, _ string) error { return nil }

// isTTY reports whether f is connected to a terminal. Returns false on any
// stat error — the bash `[[ -t 0 ]]` test has the same semantic.
func isTTY(f *os.File) bool {
	info, err := f.Stat()
	if err != nil {
		return false
	}
	return (info.Mode() & os.ModeCharDevice) != 0
}
