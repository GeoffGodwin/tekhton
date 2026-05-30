package detect

import (
	"context"
	"testing"
)

func TestWorkspacesDetector_PnpmWorkspace(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"pnpm-workspace.yaml":           "packages:\n  - 'packages/*'\n",
		"packages/api/package.json":     `{}`,
		"packages/web/package.json":     `{}`,
		"packages/shared/package.json":  `{}`,
		"packages/api/.gitkeep":         "",
		"packages/web/.gitkeep":         "",
		"packages/shared/.gitkeep":      "",
	})
	r, err := WorkspacesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(r.Findings) == 0 {
		t.Fatal("expected at least one workspace finding")
	}
	row := r.Findings[0]
	if row["type"] != "pnpm-workspace" {
		t.Errorf("type: got %q, want pnpm-workspace", row["type"])
	}
	subs := splitCSV(row["subprojects"])
	if len(subs) != 3 {
		t.Errorf("subprojects: got %d, want 3 (%v)", len(subs), subs)
	}
}

func TestWorkspacesDetector_NoWorkspace(t *testing.T) {
	dir := writeFixture(t, map[string]string{"README.md": "# x\n"})
	r, _ := WorkspacesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 0 {
		t.Errorf("expected no workspaces; got %v", r.Findings)
	}
}

func TestWorkspacesDetector_GoWork(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"go.work": "go 1.22\n\nuse (\n\t./svc-a\n\t./svc-b\n)\n",
	})
	r, _ := WorkspacesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 1 || r.Findings[0]["type"] != "go-workspace" {
		t.Fatalf("expected go-workspace finding; got %v", r.Findings)
	}
	subs := splitCSV(r.Findings[0]["subprojects"])
	if len(subs) != 2 {
		t.Errorf("expected 2 subprojects; got %v", subs)
	}
}
