package cleanup

import "github.com/geoffgodwin/tekhton/internal/provider"

// config holds the per-invocation provider seam for the cleanup stage.
// m02 — added to satisfy the per-stage config.Provider acceptance criterion.
type config struct {
	// Provider is the agent backend injected by the runner. Must be non-nil
	// before invokeAgent is reached; nil panics on first RunAgent call so the
	// wiring gap surfaces immediately.
	Provider provider.Provider
}

// loadConfig builds the stage config from the package-level seam.
func loadConfig() config {
	return config{
		Provider: stageProvider,
	}
}
