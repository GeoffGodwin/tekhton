package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/geoffgodwin/tekhton/internal/prompt"
	"github.com/spf13/cobra"
)

// newPromptCmd wires `tekhton prompt …` subcommands. The bash shim in
// lib/prompts.sh execs `prompt render` instead of doing awk + sed inline; the
// rendered output goes to stdout and the exit code is the only signal a bash
// caller needs.
//
// Exit codes:
//
//	0                — success (stdout = rendered template)
//	exitNotFound (1) — template file not present in --prompts-dir
//	exitUsage   (64) — caller-side argument or vars-file decode error
func newPromptCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "prompt",
		Short: "Tekhton agent-prompt template engine.",
	}
	c.AddCommand(newPromptRenderCmd())
	return c
}

func newPromptRenderCmd() *cobra.Command {
	var (
		template   string
		promptsDir string
		varsFile   string
	)
	c := &cobra.Command{
		Use:   "render",
		Short: "Render <template>.prompt.md with {{VAR}} and {{IF:VAR}} substitutions.",
		Long: "Reads <template>.prompt.md from --prompts-dir (or $TEKHTON_PROMPTS_DIR,\n" +
			"or $TEKHTON_HOME/prompts) and writes the rendered template to stdout.\n" +
			"Variable values come from --vars-file (a flat JSON {string: string} map)\n" +
			"if supplied; otherwise from the process environment so the bash shim can\n" +
			"export each placeholder name and exec straight through.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if template == "" {
				return errExitCode{code: exitUsage, err: errors.New("prompt render: --template is required")}
			}
			dir, err := resolvePromptsDir(promptsDir)
			if err != nil {
				return errExitCode{code: exitUsage, err: err}
			}
			vars, err := loadPromptVars(varsFile)
			if err != nil {
				return errExitCode{code: exitUsage, err: err}
			}
			out, err := prompt.Render(dir, template, vars)
			if err != nil {
				if errors.Is(err, prompt.ErrTemplateNotFound) {
					return errExitCode{code: exitNotFound, err: err}
				}
				return err
			}
			// prompt.Render guarantees a single trailing newline; write the bytes
			// verbatim so the bash shim's `$(tekhton prompt render …)` capture
			// receives the same shape as the legacy `$(render_prompt …)` did.
			if _, err := io.WriteString(cmd.OutOrStdout(), out); err != nil {
				return err
			}
			return nil
		},
	}
	c.Flags().StringVar(&template, "template", "", "Template name without the .prompt.md suffix (required).")
	c.Flags().StringVar(&promptsDir, "prompts-dir", "", "Override $TEKHTON_PROMPTS_DIR / $TEKHTON_HOME/prompts.")
	c.Flags().StringVar(&varsFile, "vars-file", "", "JSON {string: string} of variable values; default = process env.")
	return c
}

// resolvePromptsDir picks the prompts directory in priority order:
//
//	--prompts-dir > $TEKHTON_PROMPTS_DIR > $TEKHTON_HOME/prompts
//
// Returns a non-empty path or an explanatory error.
func resolvePromptsDir(flagVal string) (string, error) {
	if flagVal != "" {
		return flagVal, nil
	}
	if env := os.Getenv("TEKHTON_PROMPTS_DIR"); env != "" {
		return env, nil
	}
	if home := os.Getenv("TEKHTON_HOME"); home != "" {
		return home + "/prompts", nil
	}
	return "", errors.New("prompt render: --prompts-dir, $TEKHTON_PROMPTS_DIR, or $TEKHTON_HOME required")
}

// loadPromptVars returns the variable map. With path == "" the process
// environment (os.Environ) is used directly — the bash shim exports every
// referenced placeholder before exec, so the calling shell's variables flow
// through naturally. With a path set, the file is parsed as a flat JSON
// {string: string} object.
func loadPromptVars(path string) (map[string]string, error) {
	if path == "" {
		return prompt.EnvVars(), nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("prompt render: read vars-file: %w", err)
	}
	out := map[string]string{}
	if len(raw) == 0 {
		return out, nil
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("prompt render: parse vars-file as {string:string}: %w", err)
	}
	return out, nil
}
