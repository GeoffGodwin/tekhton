package detect

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// TestLanguagesDetector_TypescriptManifest covers the package.json +
// tsconfig.json path that promotes the language from "javascript" to
// "typescript" (lib/detect.sh:27-33).
func TestLanguagesDetector_TypescriptManifest(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "package.json", `{"name":"x"}`)
	writeFile(t, dir, "tsconfig.json", `{}`)
	r, err := (LanguagesDetector{}).Run(context.Background(), &Input{ProjectDir: dir})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	langs := languagesFromResult(r)
	if len(langs) != 1 || langs[0].Name != "typescript" || langs[0].Manifest != "package.json" {
		t.Errorf("expected typescript@package.json; got %+v", langs)
	}
	if langs[0].Confidence != "medium" {
		t.Errorf("expected medium confidence (manifest only); got %q", langs[0].Confidence)
	}
}

// TestLanguagesDetector_GoModOnly_MediumConfidence asserts the
// manifest-only-no-source path is "medium", matching bash.
func TestLanguagesDetector_GoModOnly_MediumConfidence(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "go.mod", "module x\n")
	r, err := (LanguagesDetector{}).Run(context.Background(), &Input{ProjectDir: dir})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	langs := languagesFromResult(r)
	if len(langs) != 1 || langs[0].Name != "go" || langs[0].Confidence != "medium" {
		t.Errorf("expected go@medium; got %+v", langs)
	}
}

// TestLanguagesDetector_FrameworksFromPackageJSON covers the
// detect_frameworks emission of react/vue/express when those deps appear
// in package.json (lib/detect.sh:251-262).
func TestLanguagesDetector_FrameworksFromPackageJSON(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "package.json", `{
  "name": "x",
  "dependencies": {
    "react": "^18.0.0",
    "express": "^4.0.0"
  }
}`)
	r, err := (LanguagesDetector{}).Run(context.Background(), &Input{ProjectDir: dir})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	fws := frameworksFromResult(r)
	names := map[string]bool{}
	for _, f := range fws {
		names[f.Name] = true
	}
	if !names["react"] {
		t.Errorf("expected react framework; got %+v", fws)
	}
	if !names["express"] {
		t.Errorf("expected express framework; got %+v", fws)
	}
}

// TestLanguagesDetector_PythonViaPyproject covers the bare-manifest
// python detection (lib/detect.sh:36).
func TestLanguagesDetector_PythonViaPyproject(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "pyproject.toml", "[project]\nname = \"x\"\n")
	r, err := (LanguagesDetector{}).Run(context.Background(), &Input{ProjectDir: dir})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	langs := languagesFromResult(r)
	if len(langs) != 1 || langs[0].Name != "python" || langs[0].Manifest != "pyproject.toml" {
		t.Errorf("expected python@pyproject.toml; got %+v", langs)
	}
}

// TestLanguagesDetector_NoSignal asserts an empty project yields no rows
// and no CLAUDE.md fallback fires when the file is missing.
func TestLanguagesDetector_NoSignal(t *testing.T) {
	dir := t.TempDir()
	r, err := (LanguagesDetector{}).Run(context.Background(), &Input{ProjectDir: dir})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(r.Findings) != 0 {
		t.Errorf("expected no findings; got %+v", r.Findings)
	}
}

// TestLanguagesDetector_ClaudeMDFallback exercises the strategy-1
// **Languages:** structured list fallback when no manifest is present.
func TestLanguagesDetector_ClaudeMDFallback(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "CLAUDE.md", `# project

**Languages:**
- Python
- TypeScript
`)
	r, err := (LanguagesDetector{}).Run(context.Background(), &Input{ProjectDir: dir})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	langs := languagesFromResult(r)
	names := map[string]string{}
	for _, l := range langs {
		names[l.Name] = l.Manifest
	}
	if names["python"] != "CLAUDE.md" {
		t.Errorf("expected python via CLAUDE.md fallback; got %+v", langs)
	}
	if names["typescript"] != "CLAUDE.md" {
		t.Errorf("expected typescript via CLAUDE.md fallback; got %+v", langs)
	}
}

// TestMergeAndScore_HighConfidence asserts the manifest+source=high rule.
func TestMergeAndScore_HighConfidence(t *testing.T) {
	manifests := map[string]string{"go": "go.mod"}
	counts := map[string]int{"go": 7}
	got := mergeAndScore(manifests, counts)
	if len(got) != 1 || got[0].Confidence != "high" {
		t.Errorf("expected go@high; got %+v", got)
	}
}

// TestMergeAndScore_LowVendoredSkipped asserts the "no manifest + <3
// source files" branch is dropped as vendored noise (lib/detect.sh:96-98).
func TestMergeAndScore_LowVendoredSkipped(t *testing.T) {
	manifests := map[string]string{}
	counts := map[string]int{"go": 2}
	got := mergeAndScore(manifests, counts)
	if len(got) != 0 {
		t.Errorf("expected go skipped as vendored noise; got %+v", got)
	}
}

// TestMergeAndScore_SortByRank asserts rank ordering (high < medium <
// low) then alphabetical tiebreaker on name.
func TestMergeAndScore_SortByRank(t *testing.T) {
	manifests := map[string]string{
		"python":     "pyproject.toml", // manifest only → medium
		"go":         "go.mod",         // manifest only → medium
		"typescript": "package.json",   // high (has source)
	}
	counts := map[string]int{"typescript": 5}
	got := mergeAndScore(manifests, counts)
	if len(got) != 3 {
		t.Fatalf("expected 3 entries; got %+v", got)
	}
	if got[0].Name != "typescript" || got[0].Confidence != "high" {
		t.Errorf("expected typescript@high first; got %+v", got[0])
	}
	if got[1].Name != "go" || got[1].Name >= got[2].Name {
		t.Errorf("expected medium entries sorted alphabetically; got %v %v", got[1].Name, got[2].Name)
	}
}

func writeFile(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
		t.Fatalf("writeFile %s: %v", name, err)
	}
}
