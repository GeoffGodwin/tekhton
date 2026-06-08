package tester

import (
	"github.com/geoffgodwin/tekhton/internal/prompt"
)

// renderTesterPrompt renders the tester (or tester_resume) prompt
// template against the calling shell's environment. Mirrors the bash
// dispatch in stages/tester.sh:64-153 — the context-building (architecture,
// repo map, baseline summary, UI guidance) is done by the legacy bash
// pre-stage before invoking the binary, so every {{VAR}} the prompt
// references is already in os.Environ by the time RunStage runs.
func renderTesterPrompt(cfg *config, promptName string) (string, error) {
	vars := promptVarsFromEnv()
	// Stage-specific overrides — TASK is special-cased by internal/prompt
	// (untrusted-input wrapping), but we still need it in the map so the
	// engine sees the value when the bash side hasn't exported it.
	if vars["TASK"] == "" {
		vars["TASK"] = cfg.Task
	}
	return prompt.Render(cfg.PromptsDir, promptName, vars)
}

// promptVarsFromEnv returns a map view of os.Environ. Pulled into its
// own helper so the dispatch.go TDD branch can reuse it.
func promptVarsFromEnv() map[string]string {
	return prompt.EnvVars()
}

