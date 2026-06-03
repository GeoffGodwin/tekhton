package security

import (
	"fmt"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/drift"
)

// HumanActionAppender is the seam onto the canonical HUMAN_ACTION_REQUIRED.md
// writer (drift.HumanAction, owned by the m25 drift package). Escalator
// depends on this interface so tests can swap in a fake without a real file.
type HumanActionAppender interface {
	EnsureFile() error
	Append(source, description string) error
}

// Escalator routes unfixable security findings to the configured policy
// destination. The HumanAction seam is wired by NewEscalator to the standard
// project-dir/.tekhton/HUMAN_ACTION_REQUIRED.md path.
type Escalator struct {
	HumanAction HumanActionAppender
}

// NewEscalator returns an Escalator bound to projectDir's
// HUMAN_ACTION_REQUIRED.md. The HUMAN_ACTION_FILE env override is the bash
// stage's responsibility; this constructor uses the default.
func NewEscalator(projectDir string) *Escalator {
	haPath := filepath.Join(projectDir, ".tekhton", "HUMAN_ACTION_REQUIRED.md")
	return &Escalator{HumanAction: drift.NewHumanAction(haPath)}
}

// NewEscalatorWithPath returns an Escalator bound to a specific
// HUMAN_ACTION_REQUIRED.md path. Used when the bash stage passes
// HUMAN_ACTION_FILE through to the shim.
func NewEscalatorWithPath(haPath string) *Escalator {
	return &Escalator{HumanAction: drift.NewHumanAction(haPath)}
}

// HandleUnfixable applies SECURITY_UNFIXABLE_POLICY to the unfixable findings
// block. Returns (true, nil) for "continue pipeline" branches (escalate,
// waiver, unknown-default-to-escalate, empty-block short-circuit). Returns
// (false, nil) for halt — the caller is responsible for writing pipeline
// state with stage-level context (m35.2's RunStage owns that path).
//
// Mirrors lib/security_helpers.sh::_handle_unfixable_findings. The two
// escalation branches differ in the description prefix the bash writes:
// the explicit "escalate" branch prepends "Unfixable security findings
// require human review:\n"; the unknown-policy default branch prepends just
// "Unfixable security findings:\n". Preserved verbatim.
func (e *Escalator) HandleUnfixable(policy, unfixableBlock, task string) (bool, error) {
	_ = task // present for parity with bash signature; stage-side use only.
	if unfixableBlock == "" {
		return true, nil
	}
	switch policy {
	case "escalate", "":
		return true, e.appendHumanAction(
			"Unfixable security findings require human review:\n" + unfixableBlock,
		)
	case "halt":
		return false, nil
	case "waiver":
		return true, nil
	default:
		return true, e.appendHumanAction(
			"Unfixable security findings:\n" + unfixableBlock,
		)
	}
}

func (e *Escalator) appendHumanAction(desc string) error {
	if err := e.HumanAction.EnsureFile(); err != nil {
		return fmt.Errorf("security escalation: ensure human-action file: %w", err)
	}
	if err := e.HumanAction.Append("security", desc); err != nil {
		return fmt.Errorf("security escalation: append: %w", err)
	}
	return nil
}
