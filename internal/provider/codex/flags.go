package codex

import (
	"errors"
	"fmt"
	"os"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/provider/tools"
)

// buildExecArgs translates a provider.Request into a codex exec argv slice.
//
// Defaults applied:
//   - --json              newline-delimited JSON output
//   - --sandbox workspace-write  allow file modifications
//   - --skip-git-repo-check      don't require a git repo
//   - --output-last-message <tmpfile>  final agent text capture
//
// The prompt is NOT included in argv — it is piped via stdin and the
// trailing "-" argv form is appended. See runCodex for the wiring.
func buildExecArgs(req *provider.Request) ([]string, error) {
	if req.Prompt == "" {
		return nil, errors.New("codex provider: empty prompt")
	}

	args := []string{
		"exec",
		"--json",
		"--sandbox", "workspace-write",
		"--skip-git-repo-check",
	}

	if req.Model != "" {
		args = append(args, "--model", req.Model)
	}

	cwd := req.ProviderSpecific["codex.cwd"]
	if cwd == "" {
		var err error
		cwd, err = os.Getwd()
		if err != nil {
			return nil, fmt.Errorf("codex provider: getwd: %w", err)
		}
	}
	args = append(args, "--cd", cwd)

	outFile, err := makeOutputLastMessagePath(req)
	if err != nil {
		return nil, fmt.Errorf("codex provider: outfile: %w", err)
	}
	args = append(args, "--output-last-message", outFile)

	// Inline config overrides via -c key=value.
	for k, v := range req.ProviderSpecific {
		if !isInlineConfigKey(k) {
			continue
		}
		args = append(args, "-c", fmt.Sprintf("%s=%s", inlineConfigKey(k), v))
	}

	// Resolve tool set: explicit req.Tools takes precedence over codex.tool_set.
	toolSet := req.Tools
	if len(toolSet) == 0 {
		if name := req.ProviderSpecific["codex.tool_set"]; name != "" {
			switch name {
			case "coder":
				toolSet = tools.CoderTools
			case "reviewer":
				toolSet = tools.ReviewerTools
			case "tester":
				toolSet = tools.TesterTools
			case "intake":
				toolSet = tools.IntakeTools
			}
		}
	}

	extraToolArgs, sandboxOverride, err := translateTools(toolSet)
	if err != nil {
		return nil, err
	}
	if sandboxOverride != "" {
		for i := range args {
			if args[i] == "--sandbox" && i+1 < len(args) {
				args[i+1] = sandboxOverride
				break
			}
		}
	}
	args = append(args, extraToolArgs...)

	// Trailing "-" tells codex to read the prompt from stdin.
	args = append(args, "-")
	return args, nil
}

// makeOutputLastMessagePath returns the path for --output-last-message.
// Defaults to a unique tempfile so concurrent invocations don't collide.
func makeOutputLastMessagePath(req *provider.Request) (string, error) {
	if v := req.ProviderSpecific["codex.output_last_message"]; v != "" {
		return v, nil
	}
	f, err := os.CreateTemp("", "tekhton-codex-last-*.md")
	if err != nil {
		return "", err
	}
	path := f.Name()
	_ = f.Close()
	return path, nil
}

// isInlineConfigKey reports whether k should be emitted as -c <KEY>=<value>.
// Convention: "codex.config.<KEY>" keys are inline config; other "codex." keys
// are provider-internal hints (cwd, output_last_message).
func isInlineConfigKey(k string) bool {
	const prefix = "codex.config."
	return len(k) > len(prefix) && k[:len(prefix)] == prefix
}

func inlineConfigKey(k string) string {
	const prefix = "codex.config."
	return k[len(prefix):]
}
