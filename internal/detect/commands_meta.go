package detect

import (
	"path/filepath"
	"regexp"
	"strings"
)

// entryPointCandidates mirrors the bash candidate list in
// lib/detect_commands.sh::detect_entry_points (relative paths).
var entryPointCandidates = []string{
	"main.py", "app.py", "manage.py",
	"index.ts", "index.js", "src/index.ts", "src/index.js", "src/main.ts", "src/main.js",
	"src/main.rs",
	"cmd/main.go", "main.go",
	"lib/main.dart",
	"Program.cs",
	"App.java", "src/main/java/App.java",
	"app/Main.hs",
	"lib/index.rb", "config.ru",
	"Makefile",
	"docker-compose.yml", "docker-compose.yaml", "Dockerfile",
}

// detectEntryPoints ports lib/detect_commands.sh::detect_entry_points.
// Returns entries in their bash emission order (candidate list order,
// followed by cmd/*/main.go pattern matches sorted by directory name).
func detectEntryPoints(dir string) []string {
	var out []string
	for _, c := range entryPointCandidates {
		if fileExists(filepath.Join(dir, c)) {
			out = append(out, c)
		}
	}
	cmdDir := filepath.Join(dir, "cmd")
	if st, err := statSafe(cmdDir); err == nil && st.IsDir() {
		entries, _ := readDirNames(cmdDir)
		for _, name := range entries {
			mainGo := filepath.Join(cmdDir, name, "main.go")
			if fileExists(mainGo) {
				out = append(out, filepath.ToSlash(filepath.Join("cmd", name, "main.go")))
			}
		}
	}
	return out
}

// detectProjectType ports lib/detect_commands.sh::detect_project_type.
// Bash function accepts pre-computed languages/frameworks/entry_points to
// avoid redundant calls; the Go port follows the same order so the result
// is bit-equivalent for the same project.
func detectProjectType(dir string, langs []Language, fws []Framework, entryPoints []string) string {
	frameworksText := frameworksAsLines(fws)

	if matchesAny(frameworksText, `flutter`, `swiftui`) {
		return "mobile-app"
	}
	if fileExists(filepath.Join(dir, "pubspec.yaml")) && strings.Contains(readFile(filepath.Join(dir, "pubspec.yaml")), "flutter:") {
		return "mobile-app"
	}
	if regexMatchAny(frameworksText, `next\.js|react|vue|angular|svelte`) {
		return "web-app"
	}
	if dirExists(filepath.Join(dir, "src", "pages")) ||
		dirExists(filepath.Join(dir, "pages")) ||
		dirExists(filepath.Join(dir, "src", "routes")) {
		return "web-app"
	}
	if regexMatchAny(frameworksText, `express|fastify|django|flask|fastapi|rails|spring-boot|asp\.net|actix|axum|gin`) {
		return "api-service"
	}
	if fileExists(filepath.Join(dir, "package.json")) {
		body := readFile(filepath.Join(dir, "package.json"))
		if regexMatchAny(body, `"phaser"|"pixi"|"three"|"babylon"`) {
			return "web-game"
		}
	}
	epText := strings.Join(entryPoints, "\n")
	if regexMatchAny(epText, `cmd/.*/main\.go|src/main\.rs`) {
		if fileExists(filepath.Join(dir, "Cargo.toml")) {
			body := readFile(filepath.Join(dir, "Cargo.toml"))
			if regexMatchAny(body, `clap|structopt|argh`) {
				return "cli-tool"
			}
		}
		if fileExists(filepath.Join(dir, "go.mod")) {
			body := readFile(filepath.Join(dir, "go.mod"))
			if regexMatchAny(body, `cobra|urfave/cli`) {
				return "cli-tool"
			}
		}
	}
	if primary := primaryLanguage(langs); primary == "shell" {
		return "cli-tool"
	}
	if len(entryPoints) == 0 && len(langs) > 0 {
		if fileExists(filepath.Join(dir, "Cargo.toml")) && strings.Contains(readFile(filepath.Join(dir, "Cargo.toml")), "[lib]") {
			return "library"
		}
		if fileExists(filepath.Join(dir, "package.json")) {
			body := readFile(filepath.Join(dir, "package.json"))
			if strings.Contains(body, `"main"`) && !strings.Contains(body, `"start"`) {
				return "library"
			}
		}
	}
	return "custom"
}

// frameworksAsLines reassembles Framework rows into the bash pipe-delimited
// format detect_project_type compares against (only `name` matters here).
func frameworksAsLines(fws []Framework) string {
	var b strings.Builder
	for _, f := range fws {
		b.WriteString(f.Name)
		b.WriteByte('|')
		b.WriteString(f.Language)
		b.WriteByte('|')
		b.WriteString(f.Evidence)
		b.WriteByte('\n')
	}
	return b.String()
}

// matchesAny returns true when any literal needle appears in haystack.
func matchesAny(haystack string, needles ...string) bool {
	for _, n := range needles {
		if strings.Contains(haystack, n) {
			return true
		}
	}
	return false
}

func regexMatchAny(body, pattern string) bool {
	rx := regexp.MustCompile(pattern)
	return rx.MatchString(body)
}

func primaryLanguage(langs []Language) string {
	if len(langs) == 0 {
		return ""
	}
	return langs[0].Name
}
