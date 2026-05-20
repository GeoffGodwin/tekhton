package finalize

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/manifest"
)

// CleanupMilestone is the Go body of _hook_cleanup_milestone. When a
// milestone run completes successfully and the manifest entry is marked
// done, the hook removes the milestone source file from the working tree.
// Git history is the canonical record of completed milestones — keeping
// stale .md files in .claude/milestones/ once they're done just bloats
// the working tree.
//
// This replaces the pre-cleanup ArchiveMilestone hook, which appended
// completed milestones to .tekhton/MILESTONE_ARCHIVE.md. That archive
// pattern grew to ~40k lines of accumulated content with no consumer —
// the file is gone and the runtime no longer maintains it.
type CleanupMilestone struct {
	// MilestoneDir overrides the milestone directory (default
	// .claude/milestones).
	MilestoneDir string

	// ManifestFile overrides the default manifest name within MilestoneDir.
	ManifestFile string
}

// Name implements Hook.
func (h *CleanupMilestone) Name() string { return "_hook_cleanup_milestone" }

// Run deletes the milestone file when the run succeeded AND was a
// milestone run AND the disposition is terminal AND the milestone is
// present in the manifest with status=done. Returns nil (no error) when
// any gate fails — chain semantics require successful no-ops for skip
// conditions.
func (h *CleanupMilestone) Run(_ context.Context, in *Input) error {
	if !shouldRunOnCompletion(in) {
		return nil
	}
	milestoneDir := h.MilestoneDir
	if milestoneDir == "" {
		milestoneDir = filepath.Join(in.ProjectDir, ".claude", "milestones")
	}
	manifestPath := filepath.Join(milestoneDir, h.manifestName())
	if _, err := os.Stat(manifestPath); err != nil {
		// No manifest = inline mode or no DAG. Skip silently.
		return nil
	}
	m, err := manifest.Load(manifestPath)
	if err != nil {
		return fmt.Errorf("cleanup_milestone: load manifest: %w", err)
	}
	_, entry := resolveMilestone(m, in.Milestone)
	if entry == nil {
		return nil
	}
	if entry.Status != "done" {
		// Cleanup only after mark_done has run; if mark_done failed we
		// don't touch the file.
		return nil
	}
	src := filepath.Join(milestoneDir, entry.File)
	if err := os.Remove(src); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			// Already removed (e.g. manual cleanup, idempotent re-run).
			return nil
		}
		return fmt.Errorf("cleanup_milestone: remove %s: %w", src, err)
	}
	return nil
}

func (h *CleanupMilestone) manifestName() string {
	if h.ManifestFile != "" {
		return h.ManifestFile
	}
	if name, ok := os.LookupEnv("MILESTONE_MANIFEST"); ok && name != "" {
		return name
	}
	return "MANIFEST.cfg"
}

// resolveMilestone matches the input milestone identifier against the
// manifest either by ID (m21) or by numeric display name (21). Returns
// the canonical ID and entry, or empty/nil if not present.
func resolveMilestone(m *manifest.Manifest, key string) (string, *manifest.Entry) {
	if e, ok := m.Get(key); ok {
		return key, e
	}
	wrapped := "m" + key
	if e, ok := m.Get(wrapped); ok {
		return wrapped, e
	}
	if strings.HasPrefix(key, "m") {
		bare := strings.TrimPrefix(key, "m")
		if e, ok := m.Get(bare); ok {
			return bare, e
		}
	}
	return "", nil
}
