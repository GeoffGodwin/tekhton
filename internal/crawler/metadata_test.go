package crawler

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestExtractScanMetadataFromMetaJSON(t *testing.T) {
	dir := t.TempDir()
	indexDir := filepath.Join(dir, ".claude", "index")
	if err := os.MkdirAll(indexDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `{
  "schema_version": 1,
  "scan_commit": "abc1234",
  "scan_date": "2026-05-30T12:00:00Z",
  "file_count": 42,
  "total_lines": 999
}
`
	if err := os.WriteFile(filepath.Join(indexDir, "meta.json"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	indexFile := filepath.Join(dir, "PROJECT_INDEX.md")
	// Empty PROJECT_INDEX.md — meta.json should win regardless.
	if err := os.WriteFile(indexFile, []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		field string
		want  string
	}{
		{"Scan-Commit", "abc1234"},
		{"Last-Scan", "2026-05-30T12:00:00Z"},
		{"File-Count", "42"},
		{"Total-Lines", "999"},
	}
	for _, tc := range tests {
		got, err := ExtractScanMetadata(indexFile, tc.field)
		if err != nil {
			t.Fatalf("ExtractScanMetadata(%s): %v", tc.field, err)
		}
		if got != tc.want {
			t.Errorf("ExtractScanMetadata(%s) = %q, want %q", tc.field, got, tc.want)
		}
	}
}

func TestExtractScanMetadataLegacyFallback(t *testing.T) {
	dir := t.TempDir()
	indexFile := filepath.Join(dir, "PROJECT_INDEX.md")
	// Legacy HTML-comment header only — no .claude/index/meta.json.
	body := "# Project Index\n" +
		"<!-- Scan-Commit: deadbeef -->\n" +
		"<!-- Last-Scan: 2024-01-01 -->\n" +
		"\n" +
		"## Files\n"
	if err := os.WriteFile(indexFile, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := ExtractScanMetadata(indexFile, "Scan-Commit")
	if err != nil {
		t.Fatal(err)
	}
	if got != "deadbeef" {
		t.Errorf("legacy Scan-Commit = %q, want %q", got, "deadbeef")
	}
	got, _ = ExtractScanMetadata(indexFile, "Last-Scan")
	if got != "2024-01-01" {
		t.Errorf("legacy Last-Scan = %q, want %q", got, "2024-01-01")
	}
}

func TestExtractScanMetadataPrefersStructured(t *testing.T) {
	dir := t.TempDir()
	indexDir := filepath.Join(dir, ".claude", "index")
	if err := os.MkdirAll(indexDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(indexDir, "meta.json"),
		[]byte(`{"scan_commit":"struct123"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	indexFile := filepath.Join(dir, "PROJECT_INDEX.md")
	if err := os.WriteFile(indexFile, []byte("<!-- Scan-Commit: legacy456 -->"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, _ := ExtractScanMetadata(indexFile, "Scan-Commit")
	if got != "struct123" {
		t.Errorf("structured should win: got %q, want %q", got, "struct123")
	}
}

func TestExtractScanMetadataMissingAll(t *testing.T) {
	dir := t.TempDir()
	indexFile := filepath.Join(dir, "PROJECT_INDEX.md")
	if err := os.WriteFile(indexFile, []byte("no scan metadata\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := ExtractScanMetadata(indexFile, "Scan-Commit")
	if err != nil {
		t.Fatal(err)
	}
	if got != "" {
		t.Errorf("missing → expected empty, got %q", got)
	}
}

func TestExtractScanMetadataUnknownField(t *testing.T) {
	_, err := ExtractScanMetadata("anything", "Bogus-Field")
	if !errors.Is(err, ErrMetadataFieldUnknown) {
		t.Errorf("expected ErrMetadataFieldUnknown, got %v", err)
	}
}

func TestIsManifestFile(t *testing.T) {
	tests := []struct {
		path string
		want bool
	}{
		{"package.json", true},
		{"Cargo.toml", true},
		{"go.mod", true},
		{"pyproject.toml", true},
		{"Gemfile", true},
		{"pom.xml", true},
		{"build.gradle", true},
		{"build.gradle.kts", true},
		{"App.csproj", true},
		{"Web.sln", true},
		{"src/Cargo.toml", true},        // basename match
		{"deeply/nested/go.mod", true},  // basename match
		{"README.md", false},
		{"main.go", false},
		{"requirements.txt", true},      // listed in bash case
		{"package.json.bak", false},     // not exact match
		{"PACKAGE.JSON", false},         // bash case is case-sensitive
	}
	for _, tc := range tests {
		if got := IsManifestFile(tc.path); got != tc.want {
			t.Errorf("IsManifestFile(%q) = %v, want %v", tc.path, got, tc.want)
		}
	}
}

func TestIsConfigFile(t *testing.T) {
	tests := []struct {
		path string
		want bool
	}{
		{".eslintrc.json", true},
		{".eslintrc", true},
		{"Dockerfile", true},
		{"docker-compose.yml", true},
		{"docker-compose.override.yml", true},
		{".gitignore", true},
		{".gitattributes", true},
		{"main.go", false},
		{"README.md", false},
		{"config.yaml", true},     // *.yaml
		{"config.yml", true},      // *.yml
		{"config.json", true},     // *.json
		{"config.toml", true},     // *.toml
		{"foo.cfg", true},
		{"foo.conf", true},
		{"foo.ini", true},
		{".env", true},            // *.env (matches via configExtensions)
		{".env.example", true},    // .env.* arm
		{".prettierrc", true},
		{"jest.config.js", true},
		{"vite.config.ts", true},
	}
	for _, tc := range tests {
		if got := IsConfigFile(tc.path); got != tc.want {
			t.Errorf("IsConfigFile(%q) = %v, want %v", tc.path, got, tc.want)
		}
	}
}

func TestExtractSampledFilesFromManifest(t *testing.T) {
	dir := t.TempDir()
	samplesDir := filepath.Join(dir, ".claude", "index", "samples")
	if err := os.MkdirAll(samplesDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := `{
  "samples": [
    {"original":"README.md","stored":"README.md.txt","chars":100},
    {"original":"src/main.go","stored":"src__main.go.txt","chars":200}
  ],
  "total_chars": 300,
  "budget_chars": 5000
}
`
	if err := os.WriteFile(filepath.Join(samplesDir, "manifest.json"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	indexFile := filepath.Join(dir, "PROJECT_INDEX.md")
	if err := os.WriteFile(indexFile, []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	got := ExtractSampledFiles(indexFile)
	want := []string{"README.md", "src/main.go"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i, w := range want {
		if got[i] != w {
			t.Errorf("got[%d]=%q, want %q", i, got[i], w)
		}
	}
}

func TestExtractSampledFilesLegacyFallback(t *testing.T) {
	dir := t.TempDir()
	indexFile := filepath.Join(dir, "PROJECT_INDEX.md")
	body := "# Project Index\n" +
		"\n" +
		"### README.md\n" +
		"some content\n" +
		"### `src/main.go`\n" +
		"more content\n"
	if err := os.WriteFile(indexFile, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	got := ExtractSampledFiles(indexFile)
	want := []string{"README.md", "src/main.go"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i, w := range want {
		if got[i] != w {
			t.Errorf("got[%d]=%q, want %q", i, got[i], w)
		}
	}
}

func TestStripAllSpaces(t *testing.T) {
	tests := map[string]string{
		"  abc  ":     "abc",
		"a b\tc":      "abc",
		"\n\rxxxx\n":  "xxxx",
		"":            "",
	}
	for in, want := range tests {
		if got := stripAllSpaces(in); got != want {
			t.Errorf("stripAllSpaces(%q) = %q, want %q", in, got, want)
		}
	}
}
