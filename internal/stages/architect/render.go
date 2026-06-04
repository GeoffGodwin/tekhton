package architect

import (
	"fmt"

	"github.com/geoffgodwin/tekhton/internal/drift"
	"github.com/geoffgodwin/tekhton/internal/prompt"
)

// renderArchitectPrompt builds the architect template variables (matching
// stages/architect.sh:26-62) and renders the architect prompt.
//
// The cached *_CONTENT variables are populated by the bash dispatcher's
// context_cache preload before the Go stage runs, so prompt.EnvVars()
// already carries the wrapped content. We only need to fill the per-run
// observation count + any explicit empty-state fallbacks.
func renderArchitectPrompt(cfg config) (string, error) {
	vars := prompt.EnvVars()

	if vars["DRIFT_LOG_CONTENT"] == "" {
		vars["DRIFT_LOG_CONTENT"] = "(No drift log found)"
	}
	if vars["ARCHITECTURE_LOG_CONTENT"] == "" {
		vars["ARCHITECTURE_LOG_CONTENT"] = "(No architecture decision log found)"
	}
	if vars["ARCHITECTURE_CONTENT"] == "" {
		vars["ARCHITECTURE_CONTENT"] = "(No architecture file found)"
	}

	obs, err := unresolvedDriftCountErr(cfg)
	if err == nil {
		vars["DRIFT_OBSERVATION_COUNT"] = fmt.Sprintf("%d", obs)
	} else if vars["DRIFT_OBSERVATION_COUNT"] == "" {
		vars["DRIFT_OBSERVATION_COUNT"] = "0"
	}

	return prompt.Render(cfg.PromptsDir, "architect", vars)
}

func unresolvedDriftCountErr(cfg config) (int, error) {
	l := drift.NewLog(cfg.DriftLogFile)
	return l.CountUnresolved()
}
