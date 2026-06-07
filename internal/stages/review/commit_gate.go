package review

import (
	"fmt"
	"os"
	"path/filepath"
)

// tripCommitGate ports lib/common.sh::trip_commit_gate verbatim. Writes the
// `.final_check_result` sentinel so _hook_commit refuses to commit the
// pipeline's synthesized state. First reason wins (idempotent).
//
// The bash version resolves the sentinel to an absolute path under PROJECT_DIR
// when the env TEKHTON_DIR is relative — same here.
func tripCommitGate(cfg *config, reason string) error {
	if reason == "" {
		reason = "synthesize_fallback"
	}
	dir := cfg.TekhtonDir
	if dir == "" {
		dir = ".tekhton"
	}
	sentinel := filepath.Join(dir, ".final_check_result")
	if !filepath.IsAbs(sentinel) && cfg.ProjectDir != "" {
		sentinel = filepath.Join(cfg.ProjectDir, sentinel)
	}
	sentinelDir := filepath.Dir(sentinel)
	if err := os.MkdirAll(sentinelDir, 0o755); err != nil {
		return fmt.Errorf("trip_commit_gate: mkdir %s: %w", sentinelDir, err)
	}
	// First reason wins — if the sentinel already has content, leave it.
	if fi, err := os.Stat(sentinel); err == nil && fi.Size() > 0 {
		return nil
	}
	body := fmt.Sprintf("1\n# %s\n", reason)
	return os.WriteFile(sentinel, []byte(body), 0o644)
}
