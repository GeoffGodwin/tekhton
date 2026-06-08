package docs

import "github.com/geoffgodwin/tekhton/internal/provider"

// config holds the per-invocation provider seam for the docs stage.
// m02 — added to satisfy the per-stage config.Provider acceptance criterion.
type config struct {
	// Provider is the agent backend injected by the runner. Must be non-nil
	// before RunAgent is reached; nil panics on first call so wiring gaps
	// surface immediately.
	Provider provider.Provider
}

// loadConfig builds the stage config from the package-level seam.
func loadConfig() config {
	return config{
		Provider: stageProvider,
	}
}
