package review

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
)

// subprocessBuildGate is the default BuildGateRunner — execs
// `tekhton gate build --stage-label <label>`. Matches the post-m31.1 shim
// the bash review stage transitively called.
type subprocessBuildGate struct{}

func (subprocessBuildGate) Run(ctx context.Context, projectDir, stageLabel string) error {
	bin := resolveTekhtonBin()
	if bin == "" {
		return nil
	}
	cmd := exec.CommandContext(ctx, bin, "gate", "build", "--stage-label", stageLabel)
	if projectDir != "" {
		cmd.Dir = projectDir
	}
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func resolveTekhtonBin() string {
	if v := os.Getenv("TEKHTON_BIN"); v != "" {
		if _, err := os.Stat(v); err == nil {
			return v
		}
	}
	if home := os.Getenv("TEKHTON_HOME"); home != "" {
		cand := filepath.Join(home, "bin", "tekhton")
		if _, err := os.Stat(cand); err == nil {
			return cand
		}
	}
	if p, err := exec.LookPath("tekhton"); err == nil {
		return p
	}
	return ""
}
