package detect

import (
	"context"
	"path/filepath"
	"regexp"
	"strings"
)

// CommandsDetector ports lib/detect_commands.sh::detect_commands,
// detect_entry_points, and detect_project_type. The bash detector calls
// detect_ci_config internally to inject CI-derived commands; the Go port
// invokes the same internal helper from ci.go so CommandsDetector runs
// independently of CIDetector. The detector emits three row kinds in its
// Result.Findings:
//
//	kind=command       type, command, source, confidence
//	kind=entry_point   path
//	kind=project_type  value
//
// The engine demuxes these in Summary.attach.
type CommandsDetector struct{}

// Name returns the canonical detector name.
func (CommandsDetector) Name() string { return "commands" }

// Run executes command, entry-point, and project-type detection.
// Read-only: every operation is a file existence check or content read.
func (CommandsDetector) Run(_ context.Context, in *Input) (*Result, error) {
	dir := in.ProjectDir
	r := &Result{Detector: "commands"}

	cmds := detectCommands(dir)
	for _, c := range cmds {
		r.Findings = append(r.Findings, map[string]string{
			"kind":       "command",
			"type":       c.Type,
			"command":    c.Command,
			"source":     c.Source,
			"confidence": c.Confidence,
		})
	}

	eps := detectEntryPoints(dir)
	for _, ep := range eps {
		r.Findings = append(r.Findings, map[string]string{
			"kind": "entry_point",
			"path": ep,
		})
	}

	pt := detectProjectType(dir, in.Languages, in.Frameworks, eps)
	r.Findings = append(r.Findings, map[string]string{
		"kind":  "project_type",
		"value": pt,
	})
	return r, nil
}

// detectCommands ports lib/detect_commands.sh::detect_commands. Confidence
// rank for dedup: high > medium > low. The first emitted entry for each
// type wins among those tied for the highest confidence.
func detectCommands(dir string) []Command {
	raw := detectCommandsRaw(dir)
	if len(raw) == 0 {
		return nil
	}
	best := make(map[string]int)
	for _, c := range raw {
		r := confRank(c.Confidence)
		if r > best[c.Type] {
			best[c.Type] = r
		}
	}
	emitted := make(map[string]bool)
	var out []Command
	for _, c := range raw {
		if emitted[c.Type] {
			continue
		}
		if confRank(c.Confidence) != best[c.Type] {
			continue
		}
		out = append(out, c)
		emitted[c.Type] = true
	}
	return out
}

func confRank(c string) int {
	switch c {
	case "high":
		return 3
	case "medium":
		return 2
	case "low":
		return 1
	}
	return 0
}

// detectCommandsRaw collects commands from CI, Makefile/Taskfile/justfile,
// package managers, and pre-commit hooks (in that priority order).
func detectCommandsRaw(dir string) []Command {
	var out []Command
	out = append(out, injectCICommands(dir)...)
	out = append(out, detectMakefileCommands(dir)...)
	out = append(out, detectPackageCommands(dir)...)
	out = append(out, detectPrecommitLinters(dir)...)
	return out
}

// injectCICommands ports lib/detect_commands.sh::_inject_ci_commands.
// Calls into ci.go internals so the loop runs in registration order
// without depending on CIDetector having run yet.
func injectCICommands(dir string) []Command {
	var out []Command
	for _, ci := range detectCIConfig(dir) {
		conf := ci.Confidence
		if conf == "" {
			conf = "high"
		}
		if ci.Build != "" {
			out = append(out, Command{Type: "build", Command: ci.Build, Source: ci.System + " CI", Confidence: conf})
		}
		if ci.Test != "" {
			out = append(out, Command{Type: "test", Command: ci.Test, Source: ci.System + " CI", Confidence: conf})
		}
		if ci.Lint != "" {
			out = append(out, Command{Type: "analyze", Command: ci.Lint, Source: ci.System + " CI", Confidence: conf})
		}
	}
	return out
}

// detectMakefileCommands ports _detect_makefile_commands.
func detectMakefileCommands(dir string) []Command {
	var out []Command
	if fileExists(filepath.Join(dir, "Makefile")) {
		body := readFile(filepath.Join(dir, "Makefile"))
		if regexLineMatch(body, `^test:`) {
			out = append(out, Command{Type: "test", Command: "make test", Source: "Makefile test target", Confidence: "high"})
		}
		if regexLineMatch(body, `^lint:`) {
			out = append(out, Command{Type: "analyze", Command: "make lint", Source: "Makefile lint target", Confidence: "high"})
		}
		if regexLineMatch(body, `^build:`) {
			out = append(out, Command{Type: "build", Command: "make build", Source: "Makefile build target", Confidence: "high"})
		}
	}

	taskfile := ""
	if fileExists(filepath.Join(dir, "Taskfile.yaml")) {
		taskfile = filepath.Join(dir, "Taskfile.yaml")
	} else if fileExists(filepath.Join(dir, "Taskfile.yml")) {
		taskfile = filepath.Join(dir, "Taskfile.yml")
	}
	if taskfile != "" {
		body := readFile(taskfile)
		if strings.Contains(body, "test:") {
			out = append(out, Command{Type: "test", Command: "task test", Source: "Taskfile test target", Confidence: "high"})
		}
		if strings.Contains(body, "lint:") {
			out = append(out, Command{Type: "analyze", Command: "task lint", Source: "Taskfile lint target", Confidence: "high"})
		}
		if strings.Contains(body, "build:") {
			out = append(out, Command{Type: "build", Command: "task build", Source: "Taskfile build target", Confidence: "high"})
		}
	}

	if fileExists(filepath.Join(dir, "justfile")) {
		body := readFile(filepath.Join(dir, "justfile"))
		if regexLineMatch(body, `^test`) {
			out = append(out, Command{Type: "test", Command: "just test", Source: "justfile test recipe", Confidence: "high"})
		}
		if regexLineMatch(body, `^lint`) {
			out = append(out, Command{Type: "analyze", Command: "just lint", Source: "justfile lint recipe", Confidence: "high"})
		}
		if regexLineMatch(body, `^build`) {
			out = append(out, Command{Type: "build", Command: "just build", Source: "justfile build recipe", Confidence: "high"})
		}
	}
	return out
}

// detectPackageCommands ports _detect_package_commands.
func detectPackageCommands(dir string) []Command {
	var out []Command
	out = append(out, packageJSONCommands(dir)...)
	if fileExists(filepath.Join(dir, "Cargo.toml")) {
		out = append(out,
			Command{Type: "test", Command: "cargo test", Source: "Cargo.toml present", Confidence: "high"},
			Command{Type: "build", Command: "cargo build", Source: "Cargo.toml present", Confidence: "high"},
			Command{Type: "analyze", Command: "cargo clippy", Source: "Cargo.toml present", Confidence: "medium"})
	}
	out = append(out, pythonCommands(dir)...)
	if fileExists(filepath.Join(dir, "go.mod")) {
		out = append(out,
			Command{Type: "test", Command: "go test ./...", Source: "go.mod present", Confidence: "high"},
			Command{Type: "build", Command: "go build ./...", Source: "go.mod present", Confidence: "high"},
			Command{Type: "analyze", Command: "go vet ./...", Source: "go.mod present", Confidence: "high"})
	}
	out = append(out, gemfileCommands(dir)...)
	out = append(out, gradleMavenCommands(dir)...)
	if firstMatch(dir, "*.csproj") != "" || firstMatch(dir, "*.sln") != "" {
		out = append(out,
			Command{Type: "test", Command: "dotnet test", Source: ".csproj present", Confidence: "high"},
			Command{Type: "build", Command: "dotnet build", Source: ".csproj present", Confidence: "high"})
	}
	out = append(out, pubspecCommands(dir)...)
	if fileExists(filepath.Join(dir, "mix.exs")) {
		out = append(out,
			Command{Type: "test", Command: "mix test", Source: "mix.exs present", Confidence: "high"},
			Command{Type: "build", Command: "mix compile", Source: "mix.exs present", Confidence: "high"})
	}
	if fileExists(filepath.Join(dir, "tests/run_tests.sh")) {
		out = append(out, Command{Type: "test", Command: "bash tests/run_tests.sh", Source: "tests/run_tests.sh exists", Confidence: "high"})
	}
	return out
}

// detectPrecommitLinters ports _detect_precommit_linters.
func detectPrecommitLinters(dir string) []Command {
	p := filepath.Join(dir, ".pre-commit-config.yaml")
	if !fileExists(p) {
		return nil
	}
	body := readFile(p)
	var out []Command
	if strings.Contains(body, "eslint") {
		out = append(out, Command{Type: "analyze", Command: "npx eslint .", Source: ".pre-commit-config.yaml", Confidence: "high"})
	}
	if strings.Contains(body, "ruff") {
		out = append(out, Command{Type: "analyze", Command: "ruff check .", Source: ".pre-commit-config.yaml", Confidence: "high"})
	}
	if strings.Contains(body, "black") {
		out = append(out, Command{Type: "format", Command: "black .", Source: ".pre-commit-config.yaml", Confidence: "high"})
	}
	if strings.Contains(body, "prettier") {
		out = append(out, Command{Type: "format", Command: "npx prettier --check .", Source: ".pre-commit-config.yaml", Confidence: "high"})
	}
	if strings.Contains(body, "shellcheck") {
		out = append(out, Command{Type: "analyze", Command: "shellcheck", Source: ".pre-commit-config.yaml", Confidence: "high"})
	}
	if strings.Contains(body, "mypy") {
		out = append(out, Command{Type: "analyze", Command: "mypy .", Source: ".pre-commit-config.yaml", Confidence: "high"})
	}
	return out
}

// regexLineMatch returns true when body contains a line matching pattern.
// Mirrors `grep -q '^pat'` semantics.
func regexLineMatch(body, pattern string) bool {
	rx := regexp.MustCompile(pattern)
	for _, line := range strings.Split(body, "\n") {
		if rx.MatchString(line) {
			return true
		}
	}
	return false
}
