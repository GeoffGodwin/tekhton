package finalize

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/manifest"
)

// MarkDone is the Go body of _hook_mark_done. The bash hook called
// mark_milestone_done in lib/milestone_ops.sh which (in DAG mode) updated
// the manifest entry's status to "done". Pure Go because the manifest
// subsystem is already Go-owned (m13 — internal/manifest).
//
// Idempotent: if status is already "done" the call is a no-op.
type MarkDone struct {
	// MilestoneDir overrides the default milestone directory.
	MilestoneDir string

	// ManifestFile overrides the default manifest name within MilestoneDir.
	ManifestFile string
}

// Name implements Hook.
func (h *MarkDone) Name() string { return "_hook_mark_done" }

// Run marks the active milestone as done in the manifest, persisting via
// manifest.Save (which is atomic — tmpfile + os.Rename). Gated by the same
// triple gate as clear_state and cleanup_milestone.
func (h *MarkDone) Run(_ context.Context, in *Input) error {
	if !shouldRunOnCompletion(in) {
		return nil
	}
	milestoneDir := h.MilestoneDir
	if milestoneDir == "" {
		milestoneDir = filepath.Join(in.ProjectDir, ".claude", "milestones")
	}
	manifestName := h.ManifestFile
	if manifestName == "" {
		if name, ok := os.LookupEnv("MILESTONE_MANIFEST"); ok && name != "" {
			manifestName = name
		} else {
			manifestName = "MANIFEST.cfg"
		}
	}
	manifestPath := filepath.Join(milestoneDir, manifestName)
	if _, err := os.Stat(manifestPath); err != nil {
		// No manifest = inline / no DAG. Skip silently like bash.
		return nil
	}
	m, err := manifest.Load(manifestPath)
	if err != nil {
		return fmt.Errorf("mark_done: load manifest: %w", err)
	}
	id, entry := resolveMilestone(m, in.Milestone)
	if entry == nil {
		return nil
	}
	if entry.Status == "done" {
		return nil
	}
	if err := m.SetStatus(id, "done"); err != nil {
		if errors.Is(err, manifest.ErrUnknownID) {
			return nil
		}
		return fmt.Errorf("mark_done: set status: %w", err)
	}
	if err := m.Save(); err != nil {
		return fmt.Errorf("mark_done: save manifest: %w", err)
	}
	return nil
}
