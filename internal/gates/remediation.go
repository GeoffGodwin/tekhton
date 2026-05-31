package gates

import (
	"context"
	"os/exec"
)

// Remediator is the M54 auto-remediation hook. Phases call TryRemediate
// with the captured error stream; a return of true means a fix was applied
// and the phase should re-run once. Implementations are responsible for
// (1) classifying the errors (currently via internal/errors.ClassifyAll)
// and (2) running any "safe" remediation commands the classifier mapped
// the failure to.
//
// The production implementation shells out to bash `attempt_remediation`
// from lib/remediation.sh (still bash post-m31.1; ports in a later
// milestone). Tests substitute a deterministic fake.
type Remediator interface {
	TryRemediate(ctx context.Context, errors string, phaseLabel string) bool
}

// BashRemediator delegates to lib/remediation.sh's attempt_remediation
// function via a one-shot bash subprocess. It reads the BUILD_GATE_*
// timeouts from the env contract; m31.1 keeps this thin since the
// remediation registry itself stays bash.
type BashRemediator struct {
	// TekhtonHome is the dir whose lib/remediation.sh + lib/errors.sh +
	// classifier shims will be sourced. Empty disables the remediator
	// (TryRemediate returns false).
	TekhtonHome string

	// Bash is the bash binary path. Defaults to "bash".
	Bash string

	// Stderr inherits the subprocess's stderr. Defaults to os.Stderr.
	Stderr interface{ Write([]byte) (int, error) }
}

// TryRemediate implements Remediator. Returns true only when the bash
// subprocess exits 0 (signalling at least one remediation was applied
// successfully). Any other outcome (non-zero exit, command not found,
// missing tekhton home) returns false.
func (r *BashRemediator) TryRemediate(ctx context.Context, errs, phaseLabel string) bool {
	if r == nil || r.TekhtonHome == "" || errs == "" {
		return false
	}
	bash := r.Bash
	if bash == "" {
		bash = "bash"
	}
	// shellcheck-clean one-liner: source the libs, classify, attempt
	// remediation. Reads $ERRORS_STREAM + $PHASE_LABEL from the env so
	// the error stream never crosses a shell-arg boundary (newlines,
	// quotes, $).
	const script = `set -euo pipefail
TEKHTON_HOME="${TEKHTON_HOME:?}"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/errors.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/remediation.sh"
command -v attempt_remediation >/dev/null 2>&1 || exit 1
classifications=$(classify_build_errors_all "${ERRORS_STREAM:-}")
[[ -z "$classifications" ]] && exit 1
attempt_remediation "$classifications" "${PHASE_LABEL:?}"`
	c := exec.CommandContext(ctx, bash, "-c", script)
	c.Env = append([]string{}, envPlus(
		"TEKHTON_HOME="+r.TekhtonHome,
		"ERRORS_STREAM="+errs,
		"PHASE_LABEL="+phaseLabel,
	)...)
	if r.Stderr != nil {
		c.Stderr = writerAdapter{w: r.Stderr}
	}
	err := c.Run()
	return err == nil
}

// envPlus appends k=v pairs to a copy of os.Environ(). Keeps the bash
// subprocess's PATH/HOME intact so package-manager lookups still work.
func envPlus(extra ...string) []string {
	base := osEnviron()
	out := make([]string, 0, len(base)+len(extra))
	out = append(out, base...)
	out = append(out, extra...)
	return out
}

// osEnviron is a package-level shim so tests can stub the environment
// without monkey-patching os.Environ globally.
var osEnviron = func() []string {
	return defaultEnviron()
}

// writerAdapter lets us pass an interface{ Write([]byte) (int, error) }
// to os/exec.Cmd.Stderr (which wants io.Writer). Tests pin Stderr to a
// bytes.Buffer; production wires os.Stderr.
type writerAdapter struct{ w interface{ Write([]byte) (int, error) } }

// Write implements io.Writer.
func (a writerAdapter) Write(b []byte) (int, error) { return a.w.Write(b) }
