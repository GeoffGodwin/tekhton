package crawler

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSizeCategory(t *testing.T) {
	cases := []struct {
		lines int
		want  string
	}{
		{0, "tiny"}, {49, "tiny"},
		{50, "small"}, {199, "small"},
		{200, "medium"}, {499, "medium"},
		{500, "large"}, {999, "large"},
		{1000, "huge"}, {10000, "huge"},
	}
	for _, c := range cases {
		if got := sizeCategory(c.lines); got != c.want {
			t.Errorf("sizeCategory(%d) = %q, want %q", c.lines, got, c.want)
		}
	}
}

func TestPathDir(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"README.md", "."},
		{"src/main.go", "src"},
		{"a/b/c/d.txt", "a/b/c"},
	}
	for _, c := range cases {
		if got := pathDir(c.in); got != c.want {
			t.Errorf("pathDir(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestIsTestFile(t *testing.T) {
	cases := map[string]bool{
		"foo.test.js":                          true,
		"foo.spec.ts":                          true,
		"helpers_test.go":                      true,
		"test_module.py":                       true,
		"tests/fixtures/plan_test_template.md": true, // matches `test_…\.[^.]+$`
		"src/main.go":                          false,
		"README.md":                            false,
		".testrc":                              false,
		"testfile.go":                          false,
	}
	for in, want := range cases {
		if got := isTestFile(in); got != want {
			t.Errorf("isTestFile(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestIsTestDirName(t *testing.T) {
	for _, name := range []string{"tests", "test", "spec", "__tests__", "e2e", "integration", "cypress"} {
		if !isTestDirName(name) {
			t.Errorf("isTestDirName(%q) should be true", name)
		}
	}
	for _, name := range []string{"src", "lib", "tester"} {
		if isTestDirName(name) {
			t.Errorf("isTestDirName(%q) should be false", name)
		}
	}
}

func TestConfigPurposeLiterals(t *testing.T) {
	cases := map[string]string{
		".gitignore":     "Git ignore rules",
		"package.json":   "Node.js package manifest",
		"Cargo.toml":     "Rust crate manifest",
		"pyproject.toml": "Python project configuration",
		"go.mod":         "Go module definition",
		"main.go":        "",
	}
	for in, want := range cases {
		if got := configPurpose(in); got != want {
			t.Errorf("configPurpose(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestConfigPurposeGlobs(t *testing.T) {
	cases := map[string]string{
		".eslintrc.json":   "ESLint configuration",
		"tsconfig.json":    "TypeScript configuration",
		"jest.config.js":   "Test framework configuration",
		"vite.config.ts":   "Vite build configuration",
		"build.gradle.kts": "Gradle build configuration",
		"Foo.csproj":       ".NET project file",
		"Solution.sln":     ".NET solution file",
		"Dockerfile":       "Docker container definition",
		"Dockerfile.dev":   "Docker container definition",
	}
	for in, want := range cases {
		if got := configPurpose(in); got != want {
			t.Errorf("configPurpose(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestConfigPurposeNestedDirs(t *testing.T) {
	if got := configPurpose(".github/workflows/ci.yml"); got != "GitHub configuration" {
		t.Errorf(".github/* should map to GitHub configuration, got %q", got)
	}
	if got := configPurpose(".circleci/config.yml"); got != "CircleCI configuration" {
		t.Errorf(".circleci/* should map to CircleCI configuration, got %q", got)
	}
}

func TestBuildFileInventoryCounts(t *testing.T) {
	dir := t.TempDir()
	mustWrite := func(rel, body string) {
		full := filepath.Join(dir, rel)
		_ = os.MkdirAll(filepath.Dir(full), 0o755)
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mustWrite("README.md", "hi\nthere\n")
	mustWrite("src/main.go", strings.Repeat("x\n", 250))

	inv := buildFileInventory(dir, []string{"README.md", "src/main.go", "missing.txt"})
	if len(inv.Entries) != 2 {
		t.Fatalf("expected 2 entries (missing file skipped), got %d", len(inv.Entries))
	}
	for _, e := range inv.Entries {
		switch e.Path {
		case "README.md":
			if e.Lines != 2 || e.Size != "tiny" {
				t.Errorf("README: lines=%d size=%s", e.Lines, e.Size)
			}
			if e.Dir != "." {
				t.Errorf("README dir: %q", e.Dir)
			}
		case "src/main.go":
			if e.Lines != 250 || e.Size != "medium" {
				t.Errorf("main.go: lines=%d size=%s", e.Lines, e.Size)
			}
			if e.Dir != "src" {
				t.Errorf("main.go dir: %q", e.Dir)
			}
		}
	}
}

func TestBuildConfigInventorySorting(t *testing.T) {
	files := []string{"package.json", ".gitignore", "tsconfig.json", "main.go"}
	cfg := buildConfigInventory(files)
	// Sort order: alphabetical by input list — .gitignore, package.json, tsconfig.json.
	if len(cfg.Entries) != 3 {
		t.Fatalf("expected 3 config entries (main.go is non-config), got %d", len(cfg.Entries))
	}
	want := []string{".gitignore", "package.json", "tsconfig.json"}
	for i, e := range cfg.Entries {
		if e.Path != want[i] {
			t.Errorf("config[%d].Path = %q, want %q", i, e.Path, want[i])
		}
	}
}
