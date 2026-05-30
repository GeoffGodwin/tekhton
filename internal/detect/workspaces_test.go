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

func TestWorkspacesDetector_Lerna(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"lerna.json":                  `{"packages":["packages/*"]}` + "\n",
		"packages/core/package.json":  `{}`,
		"packages/utils/package.json": `{}`,
	})
	r, _ := WorkspacesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) == 0 {
		t.Fatal("expected lerna workspace finding")
	}
	row := r.Findings[0]
	if row["type"] != "lerna" {
		t.Errorf("type: got %q, want lerna", row["type"])
	}
	subs := splitCSV(row["subprojects"])
	if len(subs) != 2 {
		t.Errorf("subprojects: got %d, want 2 (%v)", len(subs), subs)
	}
}

func TestWorkspacesDetector_Nx(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"nx.json":                          `{"version":2}` + "\n",
		"apps/frontend/project.json":       `{"name":"frontend"}` + "\n",
		"libs/shared/project.json":         `{"name":"shared"}` + "\n",
	})
	r, _ := WorkspacesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) == 0 {
		t.Fatal("expected nx workspace finding")
	}
	row := r.Findings[0]
	if row["type"] != "nx" {
		t.Errorf("type: got %q, want nx", row["type"])
	}
	subs := splitCSV(row["subprojects"])
	if len(subs) < 2 {
		t.Errorf("expected at least 2 nx subprojects; got %v", subs)
	}
}

func TestWorkspacesDetector_CargoWorkspace(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"Cargo.toml": "[workspace]\nmembers = [\n  \"crates/core\",\n  \"crates/cli\",\n]\n",
		"crates/core/Cargo.toml": `[package]` + "\nname = \"core\"\n",
		"crates/cli/Cargo.toml":  `[package]` + "\nname = \"cli\"\n",
	})
	r, _ := WorkspacesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) == 0 {
		t.Fatal("expected cargo-workspace finding")
	}
	row := r.Findings[0]
	if row["type"] != "cargo-workspace" {
		t.Errorf("type: got %q, want cargo-workspace", row["type"])
	}
	subs := splitCSV(row["subprojects"])
	if len(subs) != 2 {
		t.Errorf("subprojects: got %d, want 2 (%v)", len(subs), subs)
	}
}

func TestWorkspacesDetector_GradleMultiproject(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"settings.gradle": "include ':api', ':web'\n",
	})
	r, _ := WorkspacesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) == 0 {
		t.Fatal("expected gradle-multiproject finding")
	}
	row := r.Findings[0]
	if row["type"] != "gradle-multiproject" {
		t.Errorf("type: got %q, want gradle-multiproject", row["type"])
	}
	subs := splitCSV(row["subprojects"])
	if len(subs) != 2 {
		t.Errorf("subprojects: got %d, want 2 (%v)", len(subs), subs)
	}
}

func TestWorkspacesDetector_MavenMultimodule(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"pom.xml": `<project>
  <modules>
    <module>service-a</module>
    <module>service-b</module>
    <module>service-c</module>
  </modules>
</project>
`,
	})
	r, _ := WorkspacesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) == 0 {
		t.Fatal("expected maven-multimodule finding")
	}
	row := r.Findings[0]
	if row["type"] != "maven-multimodule" {
		t.Errorf("type: got %q, want maven-multimodule", row["type"])
	}
	subs := splitCSV(row["subprojects"])
	if len(subs) != 3 {
		t.Errorf("subprojects: got %d, want 3 (%v)", len(subs), subs)
	}
}

func TestWorkspacesDetector_CargoTomlWithoutWorkspace(t *testing.T) {
	// A Cargo.toml without a [workspace] section must NOT produce a cargo-workspace finding.
	dir := writeFixture(t, map[string]string{
		"Cargo.toml": "[package]\nname = \"my-app\"\nversion = \"0.1.0\"\n",
	})
	r, _ := WorkspacesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	for _, row := range r.Findings {
		if row["type"] == "cargo-workspace" {
			t.Errorf("unexpected cargo-workspace finding for single-crate Cargo.toml: %v", row)
		}
	}
}
