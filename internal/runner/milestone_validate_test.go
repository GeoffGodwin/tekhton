package runner

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// TestValidateMilestoneExistsRejectsPhantom covers the M27→M28 dogfood
// regression: the operator invoked `--milestone 28` against a MANIFEST that
// ended at m27, and the pipeline ran for 2h+ on an empty task instead of
// failing fast. validateAndDefault must return ErrMilestoneNotFound before
// any expensive setup begins.
func TestValidateMilestoneExistsRejectsPhantom(t *testing.T) {
	proj := t.TempDir()
	mDir := filepath.Join(proj, ".claude", "milestones")
	if err := os.MkdirAll(mDir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifestContent := "# Tekhton Milestone Manifest v1\n" +
		"# id|title|status|depends_on|file|parallel_group\n" +
		"m23|TUI Ops Port|todo||m23-tui-ops-port.md|phase5\n" +
		"m24|Notes Port|todo|m23|m24-notes-port.md|phase5\n"
	if err := os.WriteFile(filepath.Join(mDir, "MANIFEST.cfg"), []byte(manifestContent), 0o644); err != nil {
		t.Fatal(err)
	}

	r := New(&fakePipeline{})
	req := &proto.RunRequestV1{
		ProjectDir:  proj,
		TekhtonHome: t.TempDir(),
		Mode:        proto.RunModeMilestone,
		Milestone:  "m28",
	}
	err := r.validateAndDefault(req)
	if err == nil {
		t.Fatal("want ErrMilestoneNotFound for non-existent m28; got nil")
	}
	if !errors.Is(err, ErrMilestoneNotFound) {
		t.Fatalf("want ErrMilestoneNotFound; got %v", err)
	}
	// The error message must include the frontier suggestion so operators can
	// see at a glance which milestone they probably meant.
	if !strings.Contains(err.Error(), "m23") {
		t.Errorf("error message should include frontier suggestion m23; got: %v", err)
	}
}

func TestValidateMilestoneExistsAcceptsKnown(t *testing.T) {
	proj := t.TempDir()
	mDir := filepath.Join(proj, ".claude", "milestones")
	if err := os.MkdirAll(mDir, 0o755); err != nil {
		t.Fatal(err)
	}
	manifestContent := "# Tekhton Milestone Manifest v1\n" +
		"# id|title|status|depends_on|file|parallel_group\n" +
		"m23|TUI Ops Port|todo||m23-tui-ops-port.md|phase5\n"
	if err := os.WriteFile(filepath.Join(mDir, "MANIFEST.cfg"), []byte(manifestContent), 0o644); err != nil {
		t.Fatal(err)
	}

	r := New(&fakePipeline{})
	req := &proto.RunRequestV1{
		ProjectDir:  proj,
		TekhtonHome: t.TempDir(),
		Mode:        proto.RunModeMilestone,
		Milestone:  "m23",
	}
	if err := r.validateAndDefault(req); err != nil {
		t.Fatalf("want nil for known milestone m23; got %v", err)
	}
}

// TestValidateMilestoneExistsSkipsWithoutManifest covers the graceful path:
// tests and standalone callers that don't set up a real project directory
// should not start failing because of the new check.
func TestValidateMilestoneExistsSkipsWithoutManifest(t *testing.T) {
	r := New(&fakePipeline{})
	req := &proto.RunRequestV1{
		ProjectDir:  t.TempDir(), // exists but has no MANIFEST.cfg
		TekhtonHome: t.TempDir(),
		Mode:        proto.RunModeMilestone,
		Milestone:   "m99",
	}
	if err := r.validateAndDefault(req); err != nil {
		t.Fatalf("want nil when MANIFEST.cfg missing; got %v", err)
	}
}

// TestValidateMilestoneExistsSkipsNonMilestoneMode confirms task / human runs
// never trip the check even when --milestone is empty.
func TestValidateMilestoneExistsSkipsNonMilestoneMode(t *testing.T) {
	r := New(&fakePipeline{})
	req := &proto.RunRequestV1{
		ProjectDir:  t.TempDir(),
		TekhtonHome: t.TempDir(),
		Mode:        proto.RunModeTask,
		Task:        "do a thing",
	}
	if err := r.validateAndDefault(req); err != nil {
		t.Fatalf("want nil for task mode; got %v", err)
	}
}
