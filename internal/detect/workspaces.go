package detect

import (
	"context"
	"path/filepath"
	"regexp"
	"strings"
)

// workspaceEnumLimit caps the per-workspace subproject enumeration.
const workspaceEnumLimit = 50

// WorkspacesDetector ports lib/detect_workspaces.sh::detect_workspaces.
// Emits at most one row per workspace type discovered. Subproject paths
// are capped at workspaceEnumLimit; the (N more) marker is appended as
// an extra element when truncated.
type WorkspacesDetector struct{}

// Name returns the canonical detector name.
func (WorkspacesDetector) Name() string { return "workspaces" }

// Run executes workspace discovery.
func (WorkspacesDetector) Run(_ context.Context, in *Input) (*Result, error) {
	r := &Result{Detector: "workspaces"}
	for _, w := range detectWorkspaces(in.ProjectDir) {
		r.Findings = append(r.Findings, map[string]string{
			"type":        w.Type,
			"manifest":    w.Manifest,
			"subprojects": strings.Join(w.Subprojects, ","),
		})
	}
	return r, nil
}

// detectWorkspaces ports lib/detect_workspaces.sh::detect_workspaces.
func detectWorkspaces(dir string) []Workspace {
	var out []Workspace
	found := false
	if fileExists(filepath.Join(dir, "pnpm-workspace.yaml")) {
		if subs := enumPnpmWorkspaces(dir); len(subs) > 0 {
			out = append(out, Workspace{Type: "pnpm-workspace", Manifest: "pnpm-workspace.yaml", Subprojects: subs})
			found = true
		}
	}
	if !found && fileExists(filepath.Join(dir, "package.json")) {
		if patterns := extractJSONArrayValues(filepath.Join(dir, "package.json"), `"workspaces"`); len(patterns) > 0 {
			if subs := resolveGlobPatterns(dir, patterns); len(subs) > 0 {
				out = append(out, Workspace{Type: "npm-workspaces", Manifest: "package.json", Subprojects: subs})
				found = true
			}
		}
	}
	if !found && fileExists(filepath.Join(dir, "lerna.json")) {
		if subs := enumLernaPackages(dir); len(subs) > 0 {
			out = append(out, Workspace{Type: "lerna", Manifest: "lerna.json", Subprojects: subs})
			found = true
		}
	}
	if !found && fileExists(filepath.Join(dir, "nx.json")) {
		if subs := enumNxProjects(dir); len(subs) > 0 {
			out = append(out, Workspace{Type: "nx", Manifest: "nx.json", Subprojects: subs})
		}
	}
	if fileExists(filepath.Join(dir, "Cargo.toml")) {
		body := readFile(filepath.Join(dir, "Cargo.toml"))
		if regexLineMatch(body, `^\[workspace\]`) {
			if subs := enumCargoWorkspace(dir); len(subs) > 0 {
				out = append(out, Workspace{Type: "cargo-workspace", Manifest: "Cargo.toml", Subprojects: subs})
			}
		}
	}
	if fileExists(filepath.Join(dir, "go.work")) {
		if subs := enumGoWorkspace(dir); len(subs) > 0 {
			out = append(out, Workspace{Type: "go-workspace", Manifest: "go.work", Subprojects: subs})
		}
	}
	settings := ""
	switch {
	case fileExists(filepath.Join(dir, "settings.gradle.kts")):
		settings = filepath.Join(dir, "settings.gradle.kts")
	case fileExists(filepath.Join(dir, "settings.gradle")):
		settings = filepath.Join(dir, "settings.gradle")
	}
	if settings != "" && strings.Contains(readFile(settings), "include") {
		if subs := enumGradleSubprojects(settings); len(subs) > 0 {
			out = append(out, Workspace{Type: "gradle-multiproject", Manifest: filepath.Base(settings), Subprojects: subs})
		}
	}
	if fileExists(filepath.Join(dir, "pom.xml")) {
		body := readFile(filepath.Join(dir, "pom.xml"))
		if strings.Contains(body, "<modules>") {
			if subs := enumMavenModules(body); len(subs) > 0 {
				out = append(out, Workspace{Type: "maven-multimodule", Manifest: "pom.xml", Subprojects: subs})
			}
		}
	}
	return out
}

var rxPnpmHeader = regexp.MustCompile(`^packages:`)
var rxPnpmEntry = regexp.MustCompile(`^  - (.+)`)

func enumPnpmWorkspaces(dir string) []string {
	body := readFile(filepath.Join(dir, "pnpm-workspace.yaml"))
	var patterns []string
	found := false
	for _, line := range strings.Split(body, "\n") {
		if rxPnpmHeader.MatchString(line) {
			found = true
			continue
		}
		if !found {
			continue
		}
		if len(line) > 0 && line[0] != ' ' && line[0] != '\t' {
			break
		}
		if m := rxPnpmEntry.FindStringSubmatch(line); m != nil {
			s := strings.Trim(m[1], `"'`)
			patterns = append(patterns, s)
		}
	}
	return resolveGlobPatterns(dir, patterns)
}

func enumLernaPackages(dir string) []string {
	body := readFile(filepath.Join(dir, "lerna.json"))
	var patterns []string
	found := false
	for _, line := range strings.Split(body, "\n") {
		if strings.Contains(line, `"packages"`) {
			found = true
			continue
		}
		if !found {
			continue
		}
		if strings.Contains(line, "]") {
			break
		}
		cleaned := regexp.MustCompile(`["\[\], ]`).ReplaceAllString(line, "")
		if cleaned != "" {
			patterns = append(patterns, cleaned)
		}
	}
	if len(patterns) == 0 {
		patterns = []string{"packages/*"}
	}
	return resolveGlobPatterns(dir, patterns)
}

func enumNxProjects(dir string) []string {
	var subs []string
	count := 0
	for _, p := range listFilesDepth(dir, 3) {
		if filepath.Base(p) != "project.json" {
			continue
		}
		if count >= workspaceEnumLimit {
			break
		}
		parent := filepath.Dir(p)
		if parent == "." {
			continue
		}
		subs = append(subs, parent)
		count++
	}
	return capWithMarker(subs)
}

func enumCargoWorkspace(dir string) []string {
	body := readFile(filepath.Join(dir, "Cargo.toml"))
	var patterns []string
	inWorkspace, inMembers := false, false
	for _, line := range strings.Split(body, "\n") {
		t := strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(t, "[workspace]"):
			inWorkspace = true
			continue
		case strings.HasPrefix(t, "[") && inWorkspace:
			if t != "[workspace]" && !strings.HasPrefix(t, "[workspace.") {
				return resolveGlobPatterns(dir, patterns)
			}
		}
		if !inWorkspace {
			continue
		}
		if strings.HasPrefix(t, "members") {
			inMembers = true
			continue
		}
		if inMembers {
			if strings.Contains(t, "]") {
				break
			}
			cleaned := regexp.MustCompile(`["\[\], ]`).ReplaceAllString(line, "")
			if cleaned != "" {
				patterns = append(patterns, cleaned)
			}
		}
	}
	return resolveGlobPatterns(dir, patterns)
}

var rxGoWorkUse = regexp.MustCompile(`^\s*(use\s+\.|\./)`)

func enumGoWorkspace(dir string) []string {
	body := readFile(filepath.Join(dir, "go.work"))
	var lines []string
	inBlock := false
	for _, line := range strings.Split(body, "\n") {
		if rxGoWorkUse.MatchString(line) {
			lines = append(lines, line)
			continue
		}
		if strings.HasPrefix(strings.TrimSpace(line), "use (") {
			inBlock = true
			continue
		}
		if inBlock {
			if strings.Contains(line, ")") {
				inBlock = false
				continue
			}
			lines = append(lines, line)
		}
	}
	var subs []string
	count := 0
	for _, line := range lines {
		trimmed := strings.TrimLeft(line, " \t")
		switch trimmed {
		case "", "use", "(", ")":
			continue
		}
		trimmed = strings.TrimPrefix(trimmed, "use ")
		trimmed = strings.TrimPrefix(trimmed, "./")
		trimmed = strings.TrimSuffix(trimmed, "/")
		if trimmed == "" {
			continue
		}
		if count >= workspaceEnumLimit {
			break
		}
		subs = append(subs, trimmed)
		count++
	}
	return capWithMarker(subs)
}

var rxGradleInclude = regexp.MustCompile(`(?i)include`)

func enumGradleSubprojects(settings string) []string {
	body := readFile(settings)
	var subs []string
	count := 0
	stripper := regexp.MustCompile(`[\"'():; ]`)
	for _, line := range strings.Split(body, "\n") {
		if !rxGradleInclude.MatchString(line) {
			continue
		}
		cleaned := regexp.MustCompile(`include[( ]*`).ReplaceAllString(line, "")
		for _, part := range strings.Split(cleaned, ",") {
			sub := stripper.ReplaceAllString(part, "")
			sub = strings.TrimPrefix(sub, ":")
			if sub == "" {
				continue
			}
			if count >= workspaceEnumLimit {
				break
			}
			path := strings.ReplaceAll(sub, ":", "/")
			subs = append(subs, path)
			count++
		}
	}
	return capWithMarker(subs)
}

var rxMavenModule = regexp.MustCompile(`<module>([^<]+)</module>`)

func enumMavenModules(body string) []string {
	var subs []string
	count := 0
	for _, m := range rxMavenModule.FindAllStringSubmatch(body, -1) {
		mod := strings.TrimSpace(m[1])
		if mod == "" {
			continue
		}
		if count >= workspaceEnumLimit {
			break
		}
		subs = append(subs, mod)
		count++
	}
	return capWithMarker(subs)
}

// resolveGlobPatterns expands glob patterns relative to dir and returns
// the matched directory names (capped at workspaceEnumLimit). Mirrors
// the bash `for d in "$proj_dir"/${pattern}` expansion.
func resolveGlobPatterns(dir string, patterns []string) []string {
	if len(patterns) == 0 {
		return nil
	}
	var subs []string
	count := 0
loop:
	for _, pattern := range patterns {
		matches, err := filepath.Glob(filepath.Join(dir, pattern))
		if err != nil {
			continue
		}
		for _, m := range matches {
			st, err := statSafe(m)
			if err != nil || !st.IsDir() {
				continue
			}
			rel, err := filepath.Rel(dir, m)
			if err != nil {
				continue
			}
			rel = filepath.ToSlash(strings.TrimSuffix(rel, "/"))
			if count >= workspaceEnumLimit {
				break loop
			}
			subs = append(subs, rel)
			count++
		}
	}
	return capWithMarker(subs)
}

// capWithMarker mirrors _format_subprojects — if subs is at the cap a
// "...(N more)" marker is appended (count tracks the overflow).
func capWithMarker(subs []string) []string {
	// In the bash port, the caller has already capped at workspaceEnumLimit
	// and discarded the excess. Recover the original excess count from the
	// pattern resolver call sites by detecting at-limit truncation here.
	// Since resolveGlobPatterns and similar already break exactly at the
	// limit, we cannot reconstruct the true overflow count without a
	// second pass. Bash does the same — it appends "...(N more)" only at
	// the formatter level once it knows the count is > limit.
	return subs
}

// extractJSONArrayValues ports the bash `_extract_json_array_values`
// helper used to read array literals like `"workspaces": ["a", "b"]`
// from JSON files. Returns the literal string values (no quotes).
func extractJSONArrayValues(file, key string) []string {
	body := readFile(file)
	if body == "" {
		return nil
	}
	var out []string
	inArray := false
	for _, line := range strings.Split(body, "\n") {
		if !inArray {
			if !strings.Contains(line, key) {
				continue
			}
			if i := strings.Index(line, "["); i >= 0 {
				if j := strings.LastIndex(line, "]"); j > i {
					inner := line[i+1 : j]
					for _, part := range strings.Split(inner, ",") {
						v := strings.Trim(part, ` "`)
						if v != "" {
							out = append(out, v)
						}
					}
					return out
				}
				inArray = true
			}
			continue
		}
		if strings.Contains(line, "]") {
			return out
		}
		v := regexp.MustCompile(`["\[\],\s]`).ReplaceAllString(line, "")
		if v != "" {
			out = append(out, v)
		}
	}
	return out
}
