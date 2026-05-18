package finalize

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/geoffgodwin/tekhton/internal/manifest"
)

// ArchiveMilestone is the Go body of _hook_archive_milestone. The bash hook
// appended a completed milestone's body to MILESTONE_ARCHIVE.md and removed
// it from the inline CLAUDE.md (when in inline mode). The Go port supports
// the DAG mode (default) which reads the milestone .md file directly from
// the milestone directory and appends to the archive — no CLAUDE.md
// mutation required because DAG manifests track status outside CLAUDE.md.
//
// Inline mode is not ported in m21 — by V4 every milestone set is DAG
// (.claude/milestones/MANIFEST.cfg is fresh for V4 per CLAUDE.md). If a
// project still runs inline milestones the hook returns early with no
// effect, which matches the bash behavior of "do nothing when no manifest
// exists" in DAG-disabled projects.
type ArchiveMilestone struct {
	// ArchiveFile overrides the default MILESTONE_ARCHIVE.md location.
	ArchiveFile string

	// MilestoneDir overrides the milestone directory (default
	// .claude/milestones).
	MilestoneDir string

	// ManifestFile overrides the default manifest name within MilestoneDir.
	ManifestFile string

	// Now overrides time.Now for deterministic archive headers in tests.
	Now func() time.Time
}

// Name implements Hook.
func (h *ArchiveMilestone) Name() string { return "_hook_archive_milestone" }

// Run appends the milestone body to MILESTONE_ARCHIVE.md when the run
// succeeded AND was a milestone run AND the disposition is terminal AND
// the milestone is present in the manifest with status=done. Returns nil
// (no error) when any gate fails — the chain semantics require successful
// no-ops for skip conditions.
func (h *ArchiveMilestone) Run(_ context.Context, in *Input) error {
	if !shouldRunOnCompletion(in) {
		return nil
	}
	milestoneDir := h.MilestoneDir
	if milestoneDir == "" {
		milestoneDir = filepath.Join(in.ProjectDir, ".claude", "milestones")
	}
	manifestPath := filepath.Join(milestoneDir, h.manifestName())
	if _, err := os.Stat(manifestPath); err != nil {
		// No manifest = inline mode or no DAG. Skip silently like bash.
		return nil
	}
	m, err := manifest.Load(manifestPath)
	if err != nil {
		return fmt.Errorf("archive_milestone: load manifest: %w", err)
	}
	id, entry := resolveMilestone(m, in.Milestone)
	if entry == nil {
		return nil
	}
	if entry.Status != "done" {
		// archive only after mark_done has run; if mark_done failed we
		// don't try to archive — that's the bash behavior too.
		return nil
	}
	src := filepath.Join(milestoneDir, entry.File)
	body, err := os.ReadFile(src)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("archive_milestone: read %s: %w", src, err)
	}

	archive := h.ArchiveFile
	if archive == "" {
		// MILESTONE_ARCHIVE_FILE convention: .tekhton/MILESTONE_ARCHIVE.md.
		// Bash defaulted to a project-relative path resolved from env;
		// preserve that resolution rule.
		if path, ok := os.LookupEnv("MILESTONE_ARCHIVE_FILE"); ok && path != "" {
			archive = absoluteUnder(in.ProjectDir, path)
		} else {
			archive = filepath.Join(in.ProjectDir, ".tekhton", "MILESTONE_ARCHIVE.md")
		}
	}
	if err := os.MkdirAll(filepath.Dir(archive), 0o755); err != nil {
		return fmt.Errorf("archive_milestone: mkdir archive dir: %w", err)
	}
	if err := h.ensureArchiveHeader(archive); err != nil {
		return err
	}
	now := h.Now
	if now == nil {
		now = time.Now
	}
	date := now().UTC().Format("2006-01-02")
	initiative := "V4" // V4 era; bash version detected this from initiative table

	var buf strings.Builder
	buf.WriteString("\n---\n\n")
	buf.WriteString(fmt.Sprintf("## Archived: %s — %s — %s\n\n", date, initiative, id))
	buf.Write(body)
	if !strings.HasSuffix(string(body), "\n") {
		buf.WriteString("\n")
	}
	f, err := os.OpenFile(archive, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("archive_milestone: open archive: %w", err)
	}
	defer f.Close()
	if _, err := f.WriteString(buf.String()); err != nil {
		return fmt.Errorf("archive_milestone: append archive: %w", err)
	}
	return nil
}

func (h *ArchiveMilestone) manifestName() string {
	if h.ManifestFile != "" {
		return h.ManifestFile
	}
	if name, ok := os.LookupEnv("MILESTONE_MANIFEST"); ok && name != "" {
		return name
	}
	return "MANIFEST.cfg"
}

// ensureArchiveHeader creates the archive file with the canonical header
// when it doesn't yet exist. Mirrors the bash heredoc that wrote the
// "# Milestone Archive" preamble on first archival.
func (h *ArchiveMilestone) ensureArchiveHeader(path string) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	content := "# Milestone Archive\n\n" +
		"Completed milestone definitions archived from CLAUDE.md.\n" +
		"See git history for the commit that completed each milestone.\n"
	return os.WriteFile(path, []byte(content), 0o644)
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
