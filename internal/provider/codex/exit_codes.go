package codex

import "github.com/geoffgodwin/tekhton/internal/provider"

// interpretExitCode maps codex exec exit codes to provider.Outcome.
//
// V5 m07 — coarse mapping based on exit code alone:
//
//	0   → OutcomeSuccess
//	1   → OutcomeUpstreamError  (catch-all failure)
//	124 → OutcomeTimeout        (GNU timeout(1) signal)
//	137 → OutcomeAborted        (SIGKILL — timeout enforcer)
//	143 → OutcomeAborted        (SIGTERM — context cancellation)
//	*   → OutcomeUnknown
//
// m08 refines this using the JSON event stream to produce richer
// categorisation. m07's mapping is the fallback for when the stream
// doesn't yield a clear outcome.
func interpretExitCode(code int) provider.Outcome {
	switch code {
	case 0:
		return provider.OutcomeSuccess
	case 1:
		return provider.OutcomeUpstreamError
	case 124:
		return provider.OutcomeTimeout
	case 137, 143:
		return provider.OutcomeAborted
	default:
		return provider.OutcomeUnknown
	}
}
