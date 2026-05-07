package main

import (
	stderrs "errors"
	"fmt"
	"io"
	"os"
	"strings"

	terr "github.com/geoffgodwin/tekhton/internal/errors"
	"github.com/spf13/cobra"
)

// newDiagnoseCmd wires the m17 diagnose subcommand tree. Each leaf is a
// thin shim over the internal/errors package; bash callers reach this
// through lib/errors.sh's shell shims.
func newDiagnoseCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "diagnose",
		Short: "Diagnose Tekhton failures: classify build errors, agent errors, suggest recovery, redact sensitive output.",
	}
	cmd.AddCommand(newDiagnoseClassifyCmd())
	cmd.AddCommand(newDiagnoseClassifyAgentCmd())
	cmd.AddCommand(newDiagnoseRecoveryCmd())
	cmd.AddCommand(newDiagnoseRedactCmd())
	cmd.AddCommand(newDiagnoseIsTransientCmd())
	return cmd
}

// readInputArg loads the classifier input from --input FILE, a positional
// argument, or stdin when neither is set or the value is "-".
func readInputArg(cmd *cobra.Command, args []string) (string, error) {
	input, _ := cmd.Flags().GetString("input")
	if input == "" && len(args) > 0 {
		input = args[0]
	}
	if input == "" || input == "-" {
		b, err := io.ReadAll(cmd.InOrStdin())
		if err != nil {
			return "", fmt.Errorf("read stdin: %w", err)
		}
		return string(b), nil
	}
	b, err := os.ReadFile(input)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", input, err)
	}
	return string(b), nil
}

func newDiagnoseClassifyCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "classify [<log-file>|-]",
		Short: "Classify a build-error log. Default mode emits the M127 routing token.",
		Long: "classify reads a build-error log and emits one of four classification " +
			"forms. The default mode emits the M127 routing token (one of " +
			"code_dominant|noncode_dominant|mixed_uncertain|unknown_only).",
		Args: cobra.MaximumNArgs(1),
		RunE: runDiagnoseClassify,
	}
	cmd.Flags().String("input", "", "Path to build-error log (use - or omit for stdin).")
	cmd.Flags().String("mode", "routing", "Classifier mode: routing|stats|all|filter-code|annotate")
	cmd.Flags().Bool("has-code", false, "Exit 0 only if explicit code-error evidence exists. No stdout.")
	cmd.Flags().Bool("has-only-noncode", false, "Exit 0 only if all matches are non-code (M127 bypass).")
	cmd.Flags().String("stage", "unknown", "Stage label for --mode annotate.")
	return cmd
}

func runDiagnoseClassify(cmd *cobra.Command, args []string) error {
	raw, err := readInputArg(cmd, args)
	if err != nil {
		return errExitCode{code: exitUsage, err: err}
	}
	hasCode, _ := cmd.Flags().GetBool("has-code")
	hasOnlyNoncode, _ := cmd.Flags().GetBool("has-only-noncode")
	mode, _ := cmd.Flags().GetString("mode")
	stage, _ := cmd.Flags().GetString("stage")
	out := cmd.OutOrStdout()

	switch {
	case hasCode:
		if terr.HasExplicitCodeErrors(raw) {
			return nil
		}
		return errExitCode{code: 1, err: stderrs.New("no explicit code errors")}
	case hasOnlyNoncode:
		if terr.HasOnlyNoncodeErrors(raw) {
			return nil
		}
		return errExitCode{code: 1, err: stderrs.New("not noncode-only")}
	}

	switch mode {
	case "routing", "":
		fmt.Fprintln(out, terr.ClassifyRoutingDecision(raw))
	case "stats":
		for _, r := range terr.ClassifyWithStats(raw) {
			fmt.Fprintln(out, r.FormatStatsLegacy())
		}
	case "all":
		for _, r := range terr.ClassifyAll(raw) {
			fmt.Fprintln(out, r.FormatAllLegacy())
		}
	case "filter-code":
		fmt.Fprint(out, terr.FilterCodeErrors(raw))
	case "annotate":
		fmt.Fprint(out, terr.AnnotateBuildErrors(raw, stage, ""))
	default:
		return errExitCode{code: exitUsage, err: fmt.Errorf("unknown --mode %q", mode)}
	}
	return nil
}

func newDiagnoseClassifyAgentCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "classify-agent",
		Short: "Classify an agent failure (lib/errors.sh::classify_error port).",
		RunE:  runDiagnoseClassifyAgent,
	}
	cmd.Flags().Int("exit", 0, "Process exit code.")
	cmd.Flags().Int("turns", 0, "Turn count.")
	cmd.Flags().Int("files", 0, "Files-changed count.")
	cmd.Flags().Bool("has-summary", false, "Whether the agent produced a summary file.")
	cmd.Flags().String("stderr-file", "", "Path to captured stderr.")
	cmd.Flags().String("output-file", "", "Path to last agent output lines.")
	return cmd
}

func runDiagnoseClassifyAgent(cmd *cobra.Command, _ []string) error {
	exit, _ := cmd.Flags().GetInt("exit")
	turns, _ := cmd.Flags().GetInt("turns")
	files, _ := cmd.Flags().GetInt("files")
	hasSummary, _ := cmd.Flags().GetBool("has-summary")
	stderrPath, _ := cmd.Flags().GetString("stderr-file")
	outputPath, _ := cmd.Flags().GetString("output-file")

	stderrTxt, err := readOptionalFile(stderrPath)
	if err != nil {
		return errExitCode{code: exitUsage, err: err}
	}
	outputTxt, err := readOptionalFile(outputPath)
	if err != nil {
		return errExitCode{code: exitUsage, err: err}
	}

	a := terr.ClassifyAgent(terr.AgentClassifyOptions{
		ExitCode: exit, Turns: turns, FileChanges: files,
		Stderr: stderrTxt, LastOutput: outputTxt, HasSummary: hasSummary,
	})
	fmt.Fprintln(cmd.OutOrStdout(), a.FormatLegacy())
	return nil
}

func readOptionalFile(path string) (string, error) {
	if path == "" {
		return "", nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", fmt.Errorf("read %s: %w", path, err)
	}
	return string(b), nil
}

func newDiagnoseRecoveryCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "recovery <category> [subcategory] [context]",
		Short: "Suggest a recovery hint for a (category, subcategory) pair.",
		Args:  cobra.RangeArgs(1, 3),
		RunE: func(cmd *cobra.Command, args []string) error {
			cat := args[0]
			sub := ""
			ctx := ""
			if len(args) > 1 {
				sub = args[1]
			}
			if len(args) > 2 {
				ctx = args[2]
			}
			fmt.Fprintln(cmd.OutOrStdout(), terr.SuggestRecovery(cat, sub, ctx))
			return nil
		},
	}
	return cmd
}

func newDiagnoseRedactCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "redact [text]",
		Short: "Redact sensitive patterns (API keys, tokens, headers).",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			var input string
			if len(args) == 1 && args[0] != "-" {
				input = args[0]
			} else {
				b, err := io.ReadAll(cmd.InOrStdin())
				if err != nil {
					return errExitCode{code: exitUsage, err: err}
				}
				input = string(b)
			}
			fmt.Fprintln(cmd.OutOrStdout(), strings.TrimRight(terr.Redact(input), "\n"))
			return nil
		},
	}
	return cmd
}

func newDiagnoseIsTransientCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "is-transient <category> [subcategory]",
		Short: "Exit 0 when (category, subcategory) is transient, 1 otherwise.",
		Args:  cobra.RangeArgs(1, 2),
		RunE: func(cmd *cobra.Command, args []string) error {
			cat := args[0]
			sub := ""
			if len(args) > 1 {
				sub = args[1]
			}
			if terr.IsTransient(cat, sub) {
				return nil
			}
			return errExitCode{code: 1, err: stderrs.New("not transient")}
		},
	}
	return cmd
}
