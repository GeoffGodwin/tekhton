package crawler

import (
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// rxTestFileFull mirrors the bash regex
//
//	\.(test|spec)\.[^.]+$|_test\.[^.]+$|test_[^/]+\.[^.]+$
//
// — applied against the *full* repo-relative path (not just the basename).
// That detail matters: a fixture file named plan_test_template.md is a
// test file by the bash rule and must remain one under Go.
var rxTestFileFull = regexp.MustCompile(`\.(test|spec)\.[^.]+$|_test\.[^.]+$|test_[^/]+\.[^.]+$`)

// InventoryEntry is one row in inventory.jsonl — flat path / dir / lines
// / size-category record. JSON tags match the on-disk shape.
type InventoryEntry struct {
	Path  string `json:"path"`
	Dir   string `json:"dir"`
	Lines int    `json:"lines"`
	Size  string `json:"size"`
}

// Inventory is the full file inventory for inventory.jsonl.
type Inventory struct {
	Entries []InventoryEntry `json:"entries"`
}

// ConfigEntry is one row in configs.json — config file path + purpose hint.
type ConfigEntry struct {
	Path    string `json:"path"`
	Purpose string `json:"purpose"`
}

// ConfigInventory is the configs.json payload.
type ConfigInventory struct {
	Entries []ConfigEntry `json:"configs"`
}

// TestDir is one row in tests.json's test_dirs array.
type TestDir struct {
	Path      string `json:"path"`
	FileCount int    `json:"file_count"`
}

// TestStructure is the tests.json payload.
type TestStructure struct {
	TestDirs      []TestDir `json:"test_dirs"`
	TestFileCount int       `json:"test_file_count"`
	Frameworks    []string  `json:"frameworks"`
	Coverage      []string  `json:"coverage"`
}

// listTrackedFiles ports lib/crawler.sh::_list_tracked_files — git ls-files
// when available, find-based walk otherwise. Output is a sorted slice of
// repo-relative paths.
func listTrackedFiles(projectDir string) []string {
	if files, ok := gitTrackedFiles(projectDir); ok {
		return files
	}
	return findTrackedFiles(projectDir)
}

func gitTrackedFiles(projectDir string) ([]string, bool) {
	// `git -C dir rev-parse --git-dir` to confirm we're in a repo.
	if err := exec.Command("git", "-C", projectDir, "rev-parse", "--git-dir").Run(); err != nil {
		return nil, false
	}
	out, err := exec.Command("git", "-C", projectDir, "ls-files").Output()
	if err != nil {
		return nil, true
	}
	var files []string
	for _, line := range strings.Split(string(out), "\n") {
		if line != "" {
			files = append(files, line)
		}
	}
	return files, true
}

func findTrackedFiles(projectDir string) []string {
	excludes := make(map[string]struct{})
	for _, ex := range crawlExcludeDirs() {
		excludes[ex] = struct{}{}
	}
	var out []string
	_ = filepath.WalkDir(projectDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(projectDir, path)
		rel = filepath.ToSlash(rel)
		if rel == "." {
			return nil
		}
		for _, seg := range strings.Split(rel, "/") {
			if _, skip := excludes[seg]; skip {
				if d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
		}
		if d.IsDir() {
			return nil
		}
		out = append(out, rel)
		return nil
	})
	sort.Strings(out)
	return out
}

// buildFileInventory walks the provided file list and counts lines per
// file. Mirrors lib/crawler_inventory.sh's xargs+wc batching but uses
// individual reads — the perf difference is negligible against typical
// project sizes and the Go-side code is simpler.
func buildFileInventory(projectDir string, files []string) *Inventory {
	inv := &Inventory{}
	for _, f := range files {
		if f == "" {
			continue
		}
		full := filepath.Join(projectDir, f)
		st, err := os.Stat(full)
		if err != nil || st.IsDir() {
			continue
		}
		lines := countLines(full)
		dir := pathDir(f)
		inv.Entries = append(inv.Entries, InventoryEntry{
			Path:  f,
			Dir:   dir,
			Lines: lines,
			Size:  sizeCategory(lines),
		})
	}
	return inv
}

// pathDir mirrors bash `dir="${f%/*}"; [[ "$dir" == "$f" ]] && dir="."`
// — returns "." for top-level files.
func pathDir(f string) string {
	idx := strings.LastIndexByte(f, '/')
	if idx < 0 {
		return "."
	}
	return f[:idx]
}

// sizeCategory ports the bash if/elif ladder for the size column.
func sizeCategory(lines int) string {
	switch {
	case lines < 50:
		return "tiny"
	case lines < 200:
		return "small"
	case lines < 500:
		return "medium"
	case lines < 1000:
		return "large"
	default:
		return "huge"
	}
}

// countLines mirrors `wc -l < file` — counts newline bytes in the file.
// Returns 0 for empty or unreadable files (matches bash's `... || 0`).
func countLines(path string) int {
	f, err := os.Open(path)
	if err != nil {
		return 0
	}
	defer f.Close()
	count := 0
	buf := make([]byte, 64*1024)
	for {
		n, err := f.Read(buf)
		for i := 0; i < n; i++ {
			if buf[i] == '\n' {
				count++
			}
		}
		if err != nil {
			break
		}
	}
	return count
}

// buildConfigInventory walks the file list, retains only configuration
// files (per configPurpose's lookup), and emits sorted (path, purpose)
// rows. Sort order matches bash `sort` on the input list.
func buildConfigInventory(files []string) *ConfigInventory {
	out := &ConfigInventory{}
	sorted := append([]string(nil), files...)
	sort.Strings(sorted)
	for _, f := range sorted {
		if f == "" {
			continue
		}
		if purpose := configPurpose(f); purpose != "" {
			out.Entries = append(out.Entries, ConfigEntry{Path: f, Purpose: purpose})
		}
	}
	return out
}

// configPurpose ports the bash case statement in
// lib/crawler_inventory.sh::_config_purpose verbatim. Glob arms (.eslintrc*,
// jest.config*, etc.) are matched via path.Match against the basename.
func configPurpose(f string) string {
	base := filepath.Base(f)
	// Literal arms first — fast path.
	if p, ok := configPurposeLiterals[base]; ok {
		return p
	}
	for _, entry := range configPurposeGlobs {
		if matched, _ := filepath.Match(entry.pattern, base); matched {
			return entry.purpose
		}
	}
	// .github/* and .circleci/* catch-all at the bottom of the case.
	if strings.HasPrefix(f, ".github/") {
		return "GitHub configuration"
	}
	if strings.HasPrefix(f, ".circleci/") {
		return "CircleCI configuration"
	}
	return ""
}

// configPurposeLiterals is the literal-match arms of the bash case.
var configPurposeLiterals = map[string]string{
	".gitignore":     "Git ignore rules",
	".gitattributes": "Git attributes",
	".editorconfig":  "Editor configuration",
	".dockerignore":  "Docker ignore rules",
	"Makefile":       "Make build system",
	"makefile":       "Make build system",
	"CMakeLists.txt": "CMake build system",
	".env.example":   "Environment variable template",
	".env.template":  "Environment variable template",
	".env.sample":    "Environment variable template",
	"pyproject.toml": "Python project configuration",
	"setup.py":       "Python package setup",
	"setup.cfg":      "Python package setup",
	"package.json":   "Node.js package manifest",
	"Cargo.toml":     "Rust crate manifest",
	"go.mod":         "Go module definition",
	"Gemfile":        "Ruby dependencies",
	"pubspec.yaml":   "Dart/Flutter package manifest",
	"composer.json":  "PHP package manifest",
	"pom.xml":        "Maven build configuration",
	"renovate.json":  "Renovate dependency updater",
	".gitlab-ci.yml": "GitLab CI pipeline",
	"Jenkinsfile":    "Jenkins pipeline",
	".travis.yml":    "Travis CI configuration",
	"tox.ini":        "Python tox test runner",
	".flake8":        "Python flake8 linter",
	"ruff.toml":      "Python Ruff linter",
	".ruff.toml":     "Python Ruff linter",
	"clippy.toml":    "Rust Clippy linter",
	"rustfmt.toml":   "Rust formatter",
	".rustfmt.toml":  "Rust formatter",
	".shellcheckrc":  "ShellCheck configuration",
	"nginx.conf":     "Web server configuration",
	"apache.conf":    "Web server configuration",
	"fly.toml":       "Fly.io deployment",
	"vercel.json":    "Vercel deployment",
	"netlify.toml":   "Netlify deployment",
}

// configPurposeGlobs handles the glob arms (* in the bash case patterns).
// Order matches the bash case order; first match wins.
var configPurposeGlobs = []struct {
	pattern string
	purpose string
}{
	{".eslintrc*", "ESLint configuration"},
	{".eslintignore", "ESLint configuration"},
	{".prettierrc*", "Prettier code formatter"},
	{".prettierignore", "Prettier code formatter"},
	{"tsconfig*.json", "TypeScript configuration"},
	{"jest.config*", "Test framework configuration"},
	{"vitest.config*", "Test framework configuration"},
	{"webpack.config*", "Webpack bundler configuration"},
	{"vite.config*", "Vite build configuration"},
	{"rollup.config*", "Rollup bundler configuration"},
	{"babel.config*", "Babel transpiler configuration"},
	{".babelrc*", "Babel transpiler configuration"},
	{"Dockerfile*", "Docker container definition"},
	{"docker-compose*", "Docker Compose orchestration"},
	{"build.gradle*", "Gradle build configuration"},
	{"*.csproj", ".NET project file"},
	{"*.sln", ".NET solution file"},
	{".renovaterc*", "Renovate dependency updater"},
	{".yamllint*", "YAML linter"},
}

// buildTestStructure emits the tests.json payload. Mirrors the
// detection rules in lib/crawler_inventory_emitters.sh::_emit_tests_json.
func buildTestStructure(projectDir string, files []string) *TestStructure {
	out := &TestStructure{}

	// Test directories: top-level dirs matching tests/spec/__tests__/e2e/integration/cypress.
	dirs := topLevelDirs(files)
	for _, d := range dirs {
		if isTestDirName(d) {
			cnt := countFilesIn(files, d+"/")
			out.TestDirs = append(out.TestDirs, TestDir{Path: d + "/", FileCount: cnt})
		}
	}

	// Test file count: matches *.test.* / *.spec.* / *_test.* / test_*.*
	for _, f := range files {
		if isTestFile(f) {
			out.TestFileCount++
		}
	}

	// Framework detection from package.json + python markers + Cargo + go tests.
	if pkg := readIfExists(filepath.Join(projectDir, "package.json")); pkg != "" {
		for _, name := range []string{"jest", "vitest", "mocha", "cypress", "playwright"} {
			if strings.Contains(pkg, `"`+name+`"`) {
				out.Frameworks = append(out.Frameworks, name)
			}
		}
	}
	if hasPytestMarker(projectDir) {
		out.Frameworks = append(out.Frameworks, "pytest")
	}
	if _, err := os.Stat(filepath.Join(projectDir, "Cargo.toml")); err == nil {
		out.Frameworks = append(out.Frameworks, "cargo-test")
	}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			out.Frameworks = append(out.Frameworks, "go-test")
			break
		}
	}

	// Coverage detection.
	if anyExist(projectDir, ".nycrc", ".nycrc.json") {
		out.Coverage = append(out.Coverage, "nyc")
	}
	if anyExist(projectDir, ".coveragerc", "coverage.xml") {
		out.Coverage = append(out.Coverage, "python-coverage")
	}
	for _, f := range files {
		if strings.Contains(f, "codecov") || strings.Contains(f, "coveralls") {
			out.Coverage = append(out.Coverage, "ci-coverage")
			break
		}
	}
	return out
}

func anyExist(dir string, names ...string) bool {
	for _, n := range names {
		if _, err := os.Stat(filepath.Join(dir, n)); err == nil {
			return true
		}
	}
	return false
}

func hasPytestMarker(projectDir string) bool {
	if _, err := os.Stat(filepath.Join(projectDir, "pytest.ini")); err == nil {
		return true
	}
	if _, err := os.Stat(filepath.Join(projectDir, "conftest.py")); err == nil {
		return true
	}
	body := readIfExists(filepath.Join(projectDir, "pyproject.toml"))
	return strings.Contains(body, "pytest")
}

func readIfExists(path string) string {
	b, err := os.ReadFile(path) //nolint:gosec // intentional read of project file
	if err != nil {
		return ""
	}
	return string(b)
}

// topLevelDirs extracts the unique first path-segment for every file
// containing a "/". Matches bash `grep -oE '^[^/]+/' | sort -u`.
func topLevelDirs(files []string) []string {
	seen := make(map[string]struct{})
	for _, f := range files {
		idx := strings.IndexByte(f, '/')
		if idx <= 0 {
			continue
		}
		seen[f[:idx]] = struct{}{}
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// isTestDirName mirrors the bash regex
//
//	^(tests?|spec|__tests__|e2e|integration|cypress)/
//
// (without the trailing slash since topLevelDirs strips it).
func isTestDirName(name string) bool {
	switch strings.ToLower(name) {
	case "tests", "test", "spec", "__tests__", "e2e", "integration", "cypress":
		return true
	}
	return false
}

// isTestFile mirrors the bash regex applied to the full repo-relative
// path (not just the basename). The bash version greps each line of
// `_list_tracked_files` which emits full paths.
func isTestFile(f string) bool {
	return rxTestFileFull.MatchString(f)
}

// countFilesIn returns the number of file paths beginning with prefix.
// Mirrors bash `grep -c "^prefix" || true`.
func countFilesIn(files []string, prefix string) int {
	n := 0
	for _, f := range files {
		if strings.HasPrefix(f, prefix) {
			n++
		}
	}
	return n
}
