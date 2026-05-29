package detect

import (
	"context"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// LanguagesDetector ports detect_languages, detect_frameworks, and the
// non-side-effect parts of detect_ui_framework from lib/detect.sh as a
// single Detector. It is the foundational detector — Engine.Run
// dispatches it first, and downstream detectors (m29.2: commands,
// services, infrastructure) consume the populated Input.Languages /
// Input.Frameworks.
//
// The detector emits two row kinds in its Result.Findings:
//
//	kind=language     name, confidence, manifest
//	kind=framework    name, language, evidence
//
// The engine demuxes these via languagesFromResult / frameworksFromResult.
type LanguagesDetector struct{}

// Name returns the canonical detector name (used by Engine.Run to enforce
// the languages-first invariant).
func (LanguagesDetector) Name() string { return "languages" }

// Run executes the three-pass language + framework detection.
// Read-only: every operation is a file existence check or a content read.
func (LanguagesDetector) Run(_ context.Context, in *Input) (*Result, error) {
	dir := in.ProjectDir
	manifests := detectManifests(dir)
	counts := countSourceFiles(dir)
	langs := mergeAndScore(manifests, counts)
	if len(langs) == 0 {
		langs = claudeMDFallback(dir)
	}
	frameworks := detectFrameworks(dir)

	r := &Result{Detector: "languages"}
	for _, l := range langs {
		r.Findings = append(r.Findings, map[string]string{
			"kind":       "language",
			"name":       l.Name,
			"confidence": l.Confidence,
			"manifest":   l.Manifest,
		})
	}
	for _, f := range frameworks {
		r.Findings = append(r.Findings, map[string]string{
			"kind":     "framework",
			"name":     f.Name,
			"language": f.Language,
			"evidence": f.Evidence,
		})
	}
	return r, nil
}

// detectExcludeDirs mirrors _DETECT_EXCLUDE_DIRS in lib/detect.sh:13.
// Order preserved so future bash↔Go drift is grep-able.
var detectExcludeDirs = []string{
	"node_modules", ".git", "__pycache__", ".dart_tool", "build", "dist",
	".next", "vendor", "third_party", ".bundle", ".gradle", "target",
	".build", "Pods", ".pub-cache", ".cargo",
}

// detectManifests mirrors the manifest-detection block in lib/detect.sh:27-71.
func detectManifests(dir string) map[string]string {
	out := make(map[string]string)

	if fileExists(filepath.Join(dir, "package.json")) {
		if fileExists(filepath.Join(dir, "tsconfig.json")) || hasSourceFiles(dir, "ts", "tsx") {
			out["typescript"] = "package.json"
		} else {
			out["javascript"] = "package.json"
		}
	}
	if fileExists(filepath.Join(dir, "Cargo.toml")) {
		out["rust"] = "Cargo.toml"
	}
	if fileExists(filepath.Join(dir, "go.mod")) {
		out["go"] = "go.mod"
	}
	if fileExists(filepath.Join(dir, "pyproject.toml")) {
		out["python"] = "pyproject.toml"
	}
	if fileExists(filepath.Join(dir, "requirements.txt")) {
		if _, ok := out["python"]; !ok {
			out["python"] = "requirements.txt"
		}
	}
	if fileExists(filepath.Join(dir, "setup.py")) {
		if _, ok := out["python"]; !ok {
			out["python"] = "setup.py"
		}
	}
	if fileExists(filepath.Join(dir, "Pipfile")) {
		if _, ok := out["python"]; !ok {
			out["python"] = "Pipfile"
		}
	}
	if fileExists(filepath.Join(dir, "Gemfile")) {
		out["ruby"] = "Gemfile"
	}
	if fileExists(filepath.Join(dir, "composer.json")) {
		out["php"] = "composer.json"
	}
	if fileExists(filepath.Join(dir, "pubspec.yaml")) {
		out["dart"] = "pubspec.yaml"
	}
	if fileExists(filepath.Join(dir, "Package.swift")) {
		out["swift"] = "Package.swift"
	}
	if fileExists(filepath.Join(dir, "mix.exs")) {
		out["elixir"] = "mix.exs"
	}
	if fileExists(filepath.Join(dir, "stack.yaml")) {
		out["haskell"] = "stack.yaml"
	} else if fileExists(filepath.Join(dir, "cabal.project")) {
		out["haskell"] = "cabal.project"
	}

	gradle := fileExists(filepath.Join(dir, "build.gradle")) ||
		fileExists(filepath.Join(dir, "build.gradle.kts"))
	if gradle {
		if hasSourceFiles(dir, "kt", "kts") {
			out["kotlin"] = "build.gradle"
		} else {
			out["java"] = "build.gradle"
		}
	} else if fileExists(filepath.Join(dir, "pom.xml")) {
		out["java"] = "pom.xml"
	}

	cs := firstMatch(dir, "*.csproj")
	sln := firstMatch(dir, "*.sln")
	switch {
	case cs != "":
		out["csharp"] = filepath.Base(cs)
	case sln != "":
		out["csharp"] = "*.sln"
	}
	return out
}

// extensionToLanguage mirrors the case statement in _count_source_files.
var extensionToLanguage = map[string]string{
	"ts": "typescript", "tsx": "typescript",
	"js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
	"py": "python", "pyw": "python",
	"rs":   "rust",
	"go":   "go",
	"java": "java",
	"kt":   "kotlin", "kts": "kotlin",
	"rb":    "ruby",
	"php":   "php",
	"dart":  "dart",
	"swift": "swift",
	"cs":    "csharp",
	"ex":    "elixir", "exs": "elixir",
	"hs": "haskell", "lhs": "haskell",
	"lua": "lua",
	"sh":  "shell", "bash": "shell",
	"c": "c", "h": "c",
	"cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hxx": "cpp",
}

// countSourceFiles walks the project at depth ≤ 2 (matching bash
// _find_source_files semantics) and counts files by mapped language.
func countSourceFiles(dir string) map[string]int {
	counts := make(map[string]int)
	for _, name := range findSourceFiles(dir) {
		idx := strings.LastIndex(name, ".")
		if idx < 0 {
			continue
		}
		ext := name[idx+1:]
		if lang, ok := extensionToLanguage[ext]; ok {
			counts[lang]++
		}
	}
	return counts
}

// mergeAndScore mirrors the awk-confidence + sort block in
// lib/detect.sh:82-104.
func mergeAndScore(manifests map[string]string, counts map[string]int) []Language {
	all := make(map[string]struct{})
	for k := range manifests {
		all[k] = struct{}{}
	}
	for k := range counts {
		all[k] = struct{}{}
	}
	var raw []Language
	for lang := range all {
		m := manifests[lang]
		c := counts[lang]
		conf := "low"
		mani := m
		if mani == "" {
			mani = "none"
		}
		switch {
		case m != "" && c > 0:
			conf = "high"
		case m != "" || c >= 5:
			conf = "medium"
		}
		// lib/detect.sh:96-98 — skip languages with no manifest and <3
		// source files (likely vendored noise).
		if m == "" && c < 3 {
			continue
		}
		raw = append(raw, Language{Name: lang, Confidence: conf, Manifest: mani})
	}
	rankOf := func(c string) int {
		switch c {
		case "high":
			return 1
		case "medium":
			return 2
		default:
			return 3
		}
	}
	sort.SliceStable(raw, func(i, j int) bool {
		ri, rj := rankOf(raw[i].Confidence), rankOf(raw[j].Confidence)
		if ri != rj {
			return ri < rj
		}
		// Within same rank, fall back to whole-row alphabetical ordering —
		// matches GNU sort's last-resort whole-line tiebreaker after k1/k3.
		return raw[i].Name < raw[j].Name
	})
	return raw
}

// detectFrameworks ports detect_frameworks (lib/detect.sh:247-323).
// Emission order matches the bash sequence of if-blocks.
func detectFrameworks(dir string) []Framework {
	var out []Framework
	if fileExists(filepath.Join(dir, "package.json")) {
		deps := extractJSONKeys(filepath.Join(dir, "package.json"),
			`"dependencies"`, `"devDependencies"`)
		hasNext := containsDep(deps, `"next"`)
		if hasNext {
			out = append(out, Framework{Name: "next.js", Language: "node", Evidence: `"next" in package.json dependencies`})
		}
		if containsDep(deps, `"react"`) && !hasNext {
			out = append(out, Framework{Name: "react", Language: "node", Evidence: `"react" in package.json dependencies`})
		}
		if containsDep(deps, `"vue"`) {
			out = append(out, Framework{Name: "vue", Language: "node", Evidence: `"vue" in package.json dependencies`})
		}
		if containsDep(deps, `"@angular/core"`) {
			out = append(out, Framework{Name: "angular", Language: "node", Evidence: `"@angular/core" in package.json dependencies`})
		}
		if containsDep(deps, `"svelte"`) {
			out = append(out, Framework{Name: "svelte", Language: "node", Evidence: `"svelte" in package.json dependencies`})
		}
		if containsDep(deps, `"express"`) {
			out = append(out, Framework{Name: "express", Language: "node", Evidence: `"express" in package.json dependencies`})
		}
		if containsDep(deps, `"fastify"`) {
			out = append(out, Framework{Name: "fastify", Language: "node", Evidence: `"fastify" in package.json dependencies`})
		}
	}

	if fileExists(filepath.Join(dir, "pyproject.toml")) {
		body := readFile(filepath.Join(dir, "pyproject.toml"))
		lower := strings.ToLower(body)
		if strings.Contains(lower, "django") {
			out = append(out, Framework{Name: "django", Language: "python", Evidence: "django in pyproject.toml"})
		}
		if strings.Contains(lower, "flask") {
			out = append(out, Framework{Name: "flask", Language: "python", Evidence: "flask in pyproject.toml"})
		}
		if strings.Contains(lower, "fastapi") {
			out = append(out, Framework{Name: "fastapi", Language: "python", Evidence: "fastapi in pyproject.toml"})
		}
	} else if fileExists(filepath.Join(dir, "requirements.txt")) {
		body := readFile(filepath.Join(dir, "requirements.txt"))
		if reqHasLinePrefix(body, "django") {
			out = append(out, Framework{Name: "django", Language: "python", Evidence: "django in requirements.txt"})
		}
		if reqHasLinePrefix(body, "flask") {
			out = append(out, Framework{Name: "flask", Language: "python", Evidence: "flask in requirements.txt"})
		}
		if reqHasLinePrefix(body, "fastapi") {
			out = append(out, Framework{Name: "fastapi", Language: "python", Evidence: "fastapi in requirements.txt"})
		}
	}

	if fileExists(filepath.Join(dir, "Gemfile")) && strings.Contains(readFile(filepath.Join(dir, "Gemfile")), "'rails'") {
		out = append(out, Framework{Name: "rails", Language: "ruby", Evidence: `"rails" in Gemfile`})
	}

	gradle := ""
	if fileExists(filepath.Join(dir, "build.gradle.kts")) {
		gradle = filepath.Join(dir, "build.gradle.kts")
	} else if fileExists(filepath.Join(dir, "build.gradle")) {
		gradle = filepath.Join(dir, "build.gradle")
	}
	if gradle != "" {
		if strings.Contains(readFile(gradle), "spring-boot") {
			out = append(out, Framework{Name: "spring-boot", Language: "java", Evidence: "spring-boot in build.gradle"})
		}
	} else if fileExists(filepath.Join(dir, "pom.xml")) {
		if strings.Contains(readFile(filepath.Join(dir, "pom.xml")), "spring-boot") {
			out = append(out, Framework{Name: "spring-boot", Language: "java", Evidence: "spring-boot in pom.xml"})
		}
	}

	if csproj := firstMatch(dir, "*.csproj"); csproj != "" {
		if strings.Contains(readFile(csproj), "Microsoft.AspNetCore") {
			out = append(out, Framework{Name: "asp.net", Language: "csharp", Evidence: "Microsoft.AspNetCore in .csproj"})
		}
	}

	if fileExists(filepath.Join(dir, "pubspec.yaml")) && strings.Contains(readFile(filepath.Join(dir, "pubspec.yaml")), "flutter:") {
		out = append(out, Framework{Name: "flutter", Language: "dart", Evidence: "flutter in pubspec.yaml"})
	}
	if fileExists(filepath.Join(dir, "Package.swift")) && strings.Contains(readFile(filepath.Join(dir, "Package.swift")), "SwiftUI") {
		out = append(out, Framework{Name: "swiftui", Language: "swift", Evidence: "SwiftUI in Package.swift"})
	}

	if fileExists(filepath.Join(dir, "Cargo.toml")) {
		body := readFile(filepath.Join(dir, "Cargo.toml"))
		if strings.Contains(body, "actix-web") {
			out = append(out, Framework{Name: "actix", Language: "rust", Evidence: "actix-web in Cargo.toml"})
		}
		if strings.Contains(body, "axum") {
			out = append(out, Framework{Name: "axum", Language: "rust", Evidence: "axum in Cargo.toml"})
		}
	}
	if fileExists(filepath.Join(dir, "go.mod")) && strings.Contains(readFile(filepath.Join(dir, "go.mod")), "github.com/gin-gonic/gin") {
		out = append(out, Framework{Name: "gin", Language: "go", Evidence: "gin-gonic/gin in go.mod"})
	}
	return out
}

// claudeMDFallback mirrors the lib/detect.sh:107-161 CLAUDE.md fallback.
// Only invoked when file-based detection produced zero languages.
func claudeMDFallback(dir string) []Language {
	path := filepath.Join(dir, "CLAUDE.md")
	if !fileExists(path) {
		return nil
	}
	body := readFile(path)
	if body == "" {
		return nil
	}
	known := []string{
		"TypeScript", "JavaScript", "Python", "Go", "Rust",
		"Java", "Kotlin", "Swift", "Dart", "Ruby", "PHP",
		"C#", "Elixir", "Haskell",
	}
	knownLower := make(map[string]string, len(known))
	for _, k := range known {
		key := strings.ToLower(k)
		if key == "c#" {
			key = "csharp"
		}
		knownLower[strings.ToLower(k)] = key
	}

	names := claudeMDStrategy1(body, known)
	if len(names) == 0 {
		names = claudeMDStrategy2(body, known)
	}
	if len(names) == 0 {
		names = claudeMDStrategy3(body, known)
	}
	seen := make(map[string]bool)
	var out []Language
	for _, n := range names {
		key := knownLower[strings.ToLower(n)]
		if key == "" {
			continue
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, Language{Name: key, Confidence: "low", Manifest: "CLAUDE.md"})
	}
	return out
}

func claudeMDStrategy1(body string, known []string) []string {
	rxHeader := regexp.MustCompile(`(?i)^\s*\*\*Languages(:|\*\*)`)
	rxBullet := regexp.MustCompile(`^\s*-\s+(\S+)`)
	rxKnown := regexp.MustCompile(`(?i)^(` + strings.Join(known, "|") + `)$`)
	var out []string
	in := false
	for _, line := range strings.Split(body, "\n") {
		if rxHeader.MatchString(line) {
			in = true
			continue
		}
		if !in {
			continue
		}
		m := rxBullet.FindStringSubmatch(line)
		if m == nil {
			in = false
			continue
		}
		first := m[1]
		if rxKnown.MatchString(first) {
			out = append(out, first)
		}
	}
	return out
}

func claudeMDStrategy2(body string, known []string) []string {
	rxBullet := regexp.MustCompile(`(?i)^\s*-\s+(` + strings.Join(known, "|") + `)\b`)
	var out []string
	in := false
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "#") && strings.Contains(strings.ToLower(line), "project identity") {
			in = true
			continue
		}
		if !in {
			continue
		}
		if strings.HasPrefix(line, "##") {
			break
		}
		m := rxBullet.FindStringSubmatch(line)
		if m != nil {
			out = append(out, m[1])
		}
	}
	return out
}

func claudeMDStrategy3(body string, known []string) []string {
	rx := regexp.MustCompile(`(?i)\b(` + strings.Join(known, "|") + `)\b`)
	matches := rx.FindAllString(body, -1)
	seen := make(map[string]struct{})
	var out []string
	for _, m := range matches {
		k := strings.ToLower(m)
		if _, ok := seen[k]; ok {
			continue
		}
		seen[k] = struct{}{}
		out = append(out, m)
	}
	sort.Strings(out)
	return out
}

// findSourceFiles enumerates files at depth ≤ 2 relative to dir,
// excluding detectExcludeDirs. Prefers git ls-files when available,
// matching bash _find_source_files priority.
func findSourceFiles(dir string) []string {
	if isGitRepo(dir) {
		out, err := exec.Command("git", "-C", dir, "ls-files").Output()
		if err == nil {
			var result []string
			for _, line := range strings.Split(string(out), "\n") {
				if line == "" {
					continue
				}
				if pathHasExcludedSegment(line) {
					continue
				}
				if depth(line) > 2 {
					continue
				}
				result = append(result, line)
			}
			return result
		}
	}
	return walkFallback(dir)
}
