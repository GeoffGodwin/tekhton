package crawler

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// extractWithHeader is the crawler's bash-parity wrapper around the
// section-extraction logic in lib/detect.sh::_extract_json_keys. The bash
// version emits the section-HEADER line (e.g. `  "dependencies": {`)
// followed by the section body. The m29 Go port (`detect.ExtractJSONKeys`)
// drops the header — that's correct for detect callers but wrong for the
// crawler's parity baseline.
//
// We reimplement here in two passes (collect lines, walk with toggled
// `inSection`) keeping bash's verbatim echo behaviour. The function is
// internal to the crawler so we never tempt detect callers into the
// header-line shape.
func extractWithHeader(path, section string) string {
	body, err := os.ReadFile(path) //nolint:gosec // intentional read of manifest
	if err != nil {
		return ""
	}
	var buf strings.Builder
	inSection := false
	for _, line := range strings.Split(string(body), "\n") {
		if !inSection {
			if strings.Contains(line, section) {
				inSection = true
				// Bash quirk: echo the header line itself before walking
				// the body. Closing-brace detection in the same line
				// still applies (rare in practice — the brace usually
				// sits on the next line).
				if strings.Contains(line, "}") {
					// `"section": {}` collapsed onto one line: include
					// then immediately close.
					buf.WriteString(line)
					buf.WriteByte('\n')
					inSection = false
					continue
				}
				buf.WriteString(line)
				buf.WriteByte('\n')
			}
			continue
		}
		if strings.Contains(line, "}") {
			inSection = false
			continue
		}
		buf.WriteString(line)
		buf.WriteByte('\n')
	}
	return buf.String()
}

// Dependency is one row in dependencies.json's "key_dependencies" array.
// JSON tags match the on-disk artifact shape so `tekhton crawler deps --json`
// emits the same keys downstream consumers expect.
type Dependency struct {
	Name     string `json:"name"`
	Version  string `json:"version"`
	Manifest string `json:"manifest"`
}

// Manifest is one row in dependencies.json's "manifests" array.
type Manifest struct {
	File    string `json:"file"`
	Manager string `json:"manager"`
	Deps    int    `json:"deps"`
	DevDeps int    `json:"dev_deps"`
}

// DependencyGraph is the full dependencies.json payload — manifests
// summary plus the flat key_dependencies list.
type DependencyGraph struct {
	Manifests       []Manifest   `json:"manifests"`
	KeyDependencies []Dependency `json:"key_dependencies"`
}

// parseDependencies orchestrates the seven manifest parsers in the exact
// order lib/crawler_emit.sh::_emit_dependencies_json walked them.
//
// Bash parity note: the JSON emitter handles ROOT manifests only. The
// sub-project sweep (packages/*, apps/*) is performed by
// detectMonorepoSubprojects but only consumed by the markdown view
// generator (still bash, in lib/index_view.sh). Including sub-projects
// here would diverge from the dependencies.json baseline — the bash
// `_emit_dependencies_json` deliberately omits them.
func parseDependencies(projectDir string) (*DependencyGraph, error) {
	g := &DependencyGraph{}
	parseNodeDeps(projectDir, "", g)
	parseCargoDeps(projectDir, "", g)
	parsePythonDeps(projectDir, "", g)
	parseGoDeps(projectDir, "", g)
	parseGemfileDeps(projectDir, "", g)
	parseGradleDeps(projectDir, "", g)
	parsePomDeps(projectDir, "", g)
	return g, nil
}

// detectMonorepoSubprojects mirrors the packages/* + apps/* discovery
// loop in lib/crawler_deps.sh:46-61. Each sub-project is identified by
// the presence of a primary manifest file; the loop caps at five entries
// per parent directory to bound output size.
func detectMonorepoSubprojects(projectDir string) []string {
	var out []string
	for _, parent := range []string{"packages", "apps"} {
		dir := filepath.Join(projectDir, parent)
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		count := 0
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			sub := filepath.Join(dir, e.Name())
			if hasAnyManifest(sub) {
				out = append(out, sub)
				count++
				if count >= 5 {
					break
				}
			}
		}
	}
	sort.Strings(out)
	return out
}

func hasAnyManifest(dir string) bool {
	for _, m := range []string{"package.json", "Cargo.toml", "pyproject.toml", "go.mod"} {
		if _, err := os.Stat(filepath.Join(dir, m)); err == nil {
			return true
		}
	}
	return false
}

// rxNodeDepLine extracts `"name": "version"` JSON-ish lines from
// package.json. Mirrors the bash sed regex:
//   sed -n 's/.*"\([^"]*\)"\s*:.*/\1/p' for the name
//   sed -n 's/.*:\s*"\([^"]*\)".*/\1/p' for the version
var rxNodeDepName = regexp.MustCompile(`"([^"]*)"\s*:`)
var rxNodeDepVer = regexp.MustCompile(`:\s*"([^"]*)"`)

func parseNodeDeps(dir, prefix string, g *DependencyGraph) {
	path := filepath.Join(dir, "package.json")
	if _, err := os.Stat(path); err != nil {
		return
	}
	label := "package.json"
	if prefix != "" {
		label = prefix + "/package.json"
	}

	depsText := extractWithHeader(path, `"dependencies"`)
	devText := extractWithHeader(path, `"devDependencies"`)
	dc := countDepLines(depsText)
	ddc := countDepLines(devText)

	g.Manifests = append(g.Manifests, Manifest{
		File: label, Manager: "npm", Deps: dc, DevDeps: ddc,
	})

	// Merge dependencies then devDependencies into key_dependencies.
	for _, block := range []string{depsText, devText} {
		for _, line := range strings.Split(block, "\n") {
			if line == "" {
				continue
			}
			nameM := rxNodeDepName.FindStringSubmatch(line)
			verM := rxNodeDepVer.FindStringSubmatch(line)
			if nameM == nil {
				continue
			}
			ver := ""
			if verM != nil {
				ver = verM[1]
			}
			g.KeyDependencies = append(g.KeyDependencies, Dependency{
				Name: nameM[1], Version: ver, Manifest: label,
			})
		}
	}
}

// countDepLines counts non-blank lines containing a ':' character.
// Mirrors the bash `grep -c ':' || true` heuristic — used solely for
// the manifests array's deps / dev_deps counters.
func countDepLines(s string) int {
	if s == "" {
		return 0
	}
	count := 0
	for _, line := range strings.Split(s, "\n") {
		if strings.Contains(line, ":") {
			count++
		}
	}
	return count
}

// rxCargoSimple matches `crate = "version"` lines.
var rxCargoSimple = regexp.MustCompile(`^([a-zA-Z0-9_-]+)[ \t]*=[ \t]*"([^"]+)"`)

// rxCargoTable matches `crate = { … }` table form. Versions are extracted
// separately via rxCargoTableVersion.
var rxCargoTable = regexp.MustCompile(`^([a-zA-Z0-9_-]+)[ \t]*=`)
var rxCargoTableVersion = regexp.MustCompile(`version\s*=\s*"([^"]*)"`)

func parseCargoDeps(dir, prefix string, g *DependencyGraph) {
	path := filepath.Join(dir, "Cargo.toml")
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	label := "Cargo.toml"
	if prefix != "" {
		label = prefix + "/Cargo.toml"
	}

	var dc, ddc int
	section := ""
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case strings.HasPrefix(line, "[dependencies]"):
			section = "deps"
			continue
		case strings.HasPrefix(line, "[dev-dependencies]"):
			section = "dev"
			continue
		case strings.HasPrefix(line, "["):
			section = ""
			continue
		}
		if section == "" || line == "" {
			continue
		}
		var crate, ver string
		if m := rxCargoSimple.FindStringSubmatch(line); m != nil {
			crate, ver = m[1], m[2]
		} else if m := rxCargoTable.FindStringSubmatch(line); m != nil {
			crate = m[1]
			if v := rxCargoTableVersion.FindStringSubmatch(line); v != nil {
				ver = v[1]
			} else {
				ver = "workspace"
			}
		} else {
			continue
		}
		if section == "deps" {
			dc++
		} else {
			ddc++
		}
		g.KeyDependencies = append(g.KeyDependencies, Dependency{
			Name: crate, Version: ver, Manifest: "Cargo.toml",
		})
	}
	g.Manifests = append(g.Manifests, Manifest{
		File: label, Manager: "cargo", Deps: dc, DevDeps: ddc,
	})
}

// rxPyConstraint extracts the version constraint trailing the package
// name in a quoted requirement string. Ports the bash sed pattern.
var rxPyConstraint = regexp.MustCompile(`^[ \t]*"[a-zA-Z0-9_-]*([^"]*)"`)
var rxPyPkgName = regexp.MustCompile(`^[ \t]*"([a-zA-Z0-9_-]+)`)

func parsePythonDeps(dir, prefix string, g *DependencyGraph) {
	path := filepath.Join(dir, "pyproject.toml")
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	label := "pyproject.toml"
	if prefix != "" {
		label = prefix + "/pyproject.toml"
	}

	var pdc int
	inDeps := false
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		// Mirrors bash: `^dependencies[[:space:]]*=` opens the array.
		if !inDeps && rxPyDepsOpen.MatchString(line) {
			inDeps = true
			continue
		}
		if inDeps && strings.HasPrefix(strings.TrimLeft(line, " \t"), "]") {
			inDeps = false
			continue
		}
		if !inDeps || line == "" {
			continue
		}
		nameM := rxPyPkgName.FindStringSubmatch(line)
		if nameM == nil {
			continue
		}
		pkg := nameM[1]
		constraint := ""
		if m := rxPyConstraint.FindStringSubmatch(line); m != nil {
			constraint = m[1]
		}
		if constraint == "" {
			constraint = "any"
		}
		pdc++
		g.KeyDependencies = append(g.KeyDependencies, Dependency{
			Name: pkg, Version: constraint, Manifest: "pyproject.toml",
		})
	}
	g.Manifests = append(g.Manifests, Manifest{
		File: label, Manager: "pip", Deps: pdc, DevDeps: 0,
	})
}

var rxPyDepsOpen = regexp.MustCompile(`^dependencies[ \t]*=`)

func parseGoDeps(dir, prefix string, g *DependencyGraph) {
	path := filepath.Join(dir, "go.mod")
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	label := "go.mod"
	if prefix != "" {
		label = prefix + "/go.mod"
	}

	var gdc int
	inRequire := false
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "require") && strings.Contains(line, "(") {
			inRequire = true
			continue
		}
		if strings.HasPrefix(line, ")") {
			inRequire = false
			continue
		}
		if !inRequire || strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		gdc++
		g.KeyDependencies = append(g.KeyDependencies, Dependency{
			Name: fields[0], Version: fields[1], Manifest: "go.mod",
		})
	}
	g.Manifests = append(g.Manifests, Manifest{
		File: label, Manager: "go", Deps: gdc, DevDeps: 0,
	})
}

// rxGemLine matches `gem 'name'` or `gem "name"` (with optional version
// as second quoted argument). Bash sed equivalent:
//   gem[[:space:]]*['"]([^'"]*)['"]
var rxGemName = regexp.MustCompile(`gem[ \t]+['"]([^'"]+)['"]`)
var rxGemVer = regexp.MustCompile(`gem[ \t]+['"][^'"]+['"][ \t]*,[ \t]*['"]([^'"]+)['"]`)

func parseGemfileDeps(dir, prefix string, g *DependencyGraph) {
	path := filepath.Join(dir, "Gemfile")
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	label := "Gemfile"
	if prefix != "" {
		label = prefix + "/Gemfile"
	}

	var rdc int
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		// bash: `[[:space:]]*gem[[:space:]]`
		trimmed := strings.TrimLeft(line, " \t")
		if !strings.HasPrefix(trimmed, "gem ") && !strings.HasPrefix(trimmed, "gem\t") {
			continue
		}
		nameM := rxGemName.FindStringSubmatch(line)
		if nameM == nil {
			continue
		}
		ver := ""
		if v := rxGemVer.FindStringSubmatch(line); v != nil {
			ver = v[1]
		}
		if ver == "" {
			ver = "any"
		}
		rdc++
		g.KeyDependencies = append(g.KeyDependencies, Dependency{
			Name: nameM[1], Version: ver, Manifest: "Gemfile",
		})
	}
	g.Manifests = append(g.Manifests, Manifest{
		File: label, Manager: "bundler", Deps: rdc, DevDeps: 0,
	})
}

// rxGradleScope matches lines containing implementation / api / testImplementation / compileOnly.
var rxGradleScope = regexp.MustCompile(`implementation|api|testImplementation|compileOnly`)
var rxGradleDep = regexp.MustCompile(`['"]([^'"]+)['"]`)

func parseGradleDeps(dir, prefix string, g *DependencyGraph) {
	var path string
	for _, candidate := range []string{"build.gradle.kts", "build.gradle"} {
		p := filepath.Join(dir, candidate)
		if _, err := os.Stat(p); err == nil {
			path = p
		}
	}
	if path == "" {
		return
	}
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	label := filepath.Base(path)
	if prefix != "" {
		label = prefix + "/" + label
	}

	var gdc int
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if !rxGradleScope.MatchString(line) {
			continue
		}
		depM := rxGradleDep.FindStringSubmatch(line)
		if depM == nil {
			continue
		}
		gdc++
		g.KeyDependencies = append(g.KeyDependencies, Dependency{
			Name: depM[1], Version: "", Manifest: label,
		})
	}
	g.Manifests = append(g.Manifests, Manifest{
		File: label, Manager: "gradle", Deps: gdc, DevDeps: 0,
	})
}

var rxPomGroup = regexp.MustCompile(`<groupId>(.*)</groupId>`)
var rxPomArtifact = regexp.MustCompile(`<artifactId>(.*)</artifactId>`)

func parsePomDeps(dir, prefix string, g *DependencyGraph) {
	path := filepath.Join(dir, "pom.xml")
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	label := "pom.xml"
	if prefix != "" {
		label = prefix + "/pom.xml"
	}

	var mdc int
	group, artifact := "", ""
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimLeft(scanner.Text(), " \t")
		if m := rxPomGroup.FindStringSubmatch(line); m != nil {
			group = m[1]
			continue
		}
		if m := rxPomArtifact.FindStringSubmatch(line); m != nil {
			artifact = m[1]
			if group != "" {
				mdc++
				g.KeyDependencies = append(g.KeyDependencies, Dependency{
					Name: group + ":" + artifact, Version: "", Manifest: "pom.xml",
				})
				group, artifact = "", ""
			}
		}
	}
	g.Manifests = append(g.Manifests, Manifest{
		File: label, Manager: "maven", Deps: mdc, DevDeps: 0,
	})
}
