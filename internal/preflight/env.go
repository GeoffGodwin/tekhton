package preflight

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// EnvCheck ports lib/preflight_checks_env.sh — three sub-checks:
//
//  1. Runtime Version — `.nvmrc` vs `node --version`, etc.
//  2. Port Availability — well-known dev-server ports against UI_TEST_CMD
//  3. Lock File Freshness — manifest mtime vs lock-file mtime
type EnvCheck struct{}

// Name returns the canonical check name. Matches checkOrder.
func (EnvCheck) Name() string { return "env" }

// Run executes the three sub-checks in the same order bash did.
func (EnvCheck) Run(_ context.Context, in *Input) Result {
	var r Result
	r.Findings = append(r.Findings, checkRuntimeVersion(in)...)
	r.Findings = append(r.Findings, checkPorts(in)...)
	r.Findings = append(r.Findings, checkLockFreshness(in)...)
	return r
}

// --- Runtime version ------------------------------------------------------

type runtimeSpec struct {
	label      string
	files      []string
	command    []string
	parseSpec  func(s string) string // turns expected file contents into vN
	parseCli   func(s string) string // turns CLI output into vN
	exactMatch bool                  // when false, *contains* match (rust style)
}

var runtimeSpecs = []runtimeSpec{
	{
		label:    "Node.js",
		files:    []string{".node-version", ".nvmrc"}, // .nvmrc wins if both present (matches bash overwrite order)
		command:  []string{"node", "--version"},
		parseSpec: func(s string) string {
			s = strings.TrimSpace(strings.ReplaceAll(s, "v", ""))
			if idx := strings.Index(s, "."); idx >= 0 {
				return s[:idx]
			}
			return s
		},
		parseCli: func(s string) string {
			s = strings.TrimSpace(strings.ReplaceAll(s, "v", ""))
			if idx := strings.Index(s, "."); idx >= 0 {
				return s[:idx]
			}
			return s
		},
	},
	{
		label:    "Python",
		files:    []string{".python-version"},
		command:  []string{"python3", "--version"},
		parseSpec: func(s string) string {
			return trimToMinor(strings.TrimSpace(s))
		},
		parseCli: func(s string) string {
			fields := strings.Fields(s)
			if len(fields) < 2 {
				return ""
			}
			return trimToMinor(fields[1])
		},
	},
	{
		label:    "Ruby",
		files:    []string{".ruby-version"},
		command:  []string{"ruby", "--version"},
		parseSpec: func(s string) string {
			return trimToMinor(strings.TrimSpace(s))
		},
		parseCli: func(s string) string {
			fields := strings.Fields(s)
			if len(fields) < 2 {
				return ""
			}
			return trimToMinor(fields[1])
		},
	},
	{
		label:    "Go",
		files:    []string{".go-version"},
		command:  []string{"go", "version"},
		parseSpec: func(s string) string {
			return trimToMinor(strings.TrimSpace(s))
		},
		parseCli: func(s string) string {
			// `go version go1.22.3 linux/amd64`
			re := regexp.MustCompile(`(\d+\.\d+)`)
			return re.FindString(s)
		},
	},
	{
		label:    "Java",
		files:    []string{".java-version"},
		command:  []string{"java", "-version"},
		parseSpec: func(s string) string {
			s = strings.TrimSpace(s)
			if idx := strings.Index(s, "."); idx >= 0 {
				return s[:idx]
			}
			return s
		},
		parseCli: func(s string) string {
			re := regexp.MustCompile(`\d+`)
			lines := strings.Split(s, "\n")
			if len(lines) == 0 {
				return ""
			}
			return re.FindString(lines[0])
		},
	},
}

// trimToMinor strips a string to "MAJOR.MINOR" (e.g. "3.11.2" → "3.11").
func trimToMinor(s string) string {
	s = strings.TrimSpace(s)
	parts := strings.SplitN(s, ".", 3)
	if len(parts) >= 2 {
		return parts[0] + "." + parts[1]
	}
	return s
}

func checkRuntimeVersion(in *Input) []Finding {
	proj := in.ProjectDir
	var out []Finding
	for _, spec := range runtimeSpecs {
		fileFound := ""
		for _, name := range spec.files {
			if fileExists(proj, name) {
				fileFound = name
			}
		}
		if fileFound == "" {
			continue
		}
		if _, err := exec.LookPath(spec.command[0]); err != nil {
			continue
		}
		b, err := os.ReadFile(filepath.Join(proj, fileFound))
		if err != nil {
			continue
		}
		expected := spec.parseSpec(string(b))
		actualOut, err := exec.Command(spec.command[0], spec.command[1:]...).CombinedOutput()
		if err != nil && len(actualOut) == 0 {
			continue
		}
		actual := spec.parseCli(string(actualOut))
		if expected == "" || actual == "" {
			continue
		}
		name := fmt.Sprintf("Runtime Version (%s)", spec.label)
		if expected == actual {
			out = append(out, pass(name, fmt.Sprintf(
				"%s requires %s, running %s. ✓", fileFound, expected, actual)))
		} else {
			out = append(out, warn(name, fmt.Sprintf(
				"%s requires %s, but running %s.", fileFound, expected, actual)))
		}
	}
	// Rust toolchain (separate because its file is TOML).
	if fileExists(proj, "rust-toolchain.toml") {
		if _, err := exec.LookPath("rustc"); err == nil {
			b, err := os.ReadFile(filepath.Join(proj, "rust-toolchain.toml"))
			if err == nil {
				re := regexp.MustCompile(`channel\s*=\s*"([^"]+)"`)
				m := re.FindStringSubmatch(string(b))
				if len(m) == 2 {
					expected := m[1]
					actualOut, _ := exec.Command("rustc", "--version").CombinedOutput()
					fields := strings.Fields(string(actualOut))
					if len(fields) >= 2 {
						actual := fields[1]
						name := "Runtime Version (Rust)"
						if strings.Contains(actual, expected) {
							out = append(out, pass(name, fmt.Sprintf(
								"rust-toolchain.toml channel %s, running %s. ✓",
								expected, actual)))
						} else {
							out = append(out, warn(name, fmt.Sprintf(
								"rust-toolchain.toml expects channel %s, but running %s.",
								expected, actual)))
						}
					}
				}
			}
		}
	}
	return out
}

// --- Port availability ----------------------------------------------------

var dashPortRE = regexp.MustCompile(`(?:--port[= ]|\s-p\s+)(\d+)`)

func checkPorts(in *Input) []Finding {
	var ports []string
	for _, key := range []string{"UI_TEST_CMD", "BUILD_CHECK_CMD"} {
		val := in.Getenv(key)
		if val == "" {
			continue
		}
		switch {
		case strings.Contains(val, "next dev"), strings.Contains(val, "next start"):
			ports = append(ports, "3000")
		case strings.Contains(val, "vite"):
			ports = append(ports, "5173")
		case strings.Contains(val, "webpack-dev-server"):
			ports = append(ports, "8080")
		case strings.Contains(val, "ng serve"):
			ports = append(ports, "4200")
		case strings.Contains(val, "flask run"):
			ports = append(ports, "5000")
		case strings.Contains(val, "django"), strings.Contains(val, "manage.py"):
			ports = append(ports, "8000")
		}
		if m := dashPortRE.FindStringSubmatch(val); len(m) == 2 {
			ports = append(ports, m[1])
		}
	}
	if len(ports) == 0 {
		return nil
	}
	var out []Finding
	for _, p := range ports {
		name := fmt.Sprintf("Port Availability (:%s)", p)
		if isPortInUse(p) {
			out = append(out, warn(name, fmt.Sprintf(
				"Port %s is already in use. This may cause conflicts with dev server.", p)))
		} else {
			out = append(out, pass(name, fmt.Sprintf("Port %s is available.", p)))
		}
	}
	return out
}

// isPortInUse reports whether something is listening on the given TCP
// port on localhost. Mirrors `_pf_is_port_in_use` — we use a 250ms dial
// timeout which is plenty for localhost and avoids hanging the check on a
// slow stack.
func isPortInUse(port string) bool {
	conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", port), 250*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

// --- Lock freshness -------------------------------------------------------

func checkLockFreshness(in *Input) []Finding {
	proj := in.ProjectDir
	var out []Finding

	// Node.js
	if fileExists(proj, "package.json") {
		lock := ""
		for _, name := range []string{"package-lock.json", "yarn.lock", "pnpm-lock.yaml"} {
			if fileExists(proj, name) {
				lock = name
				break
			}
		}
		if lock != "" {
			pkg := filepath.Join(proj, "package.json")
			lockPath := filepath.Join(proj, lock)
			if fileNewer(pkg, lockPath) {
				out = append(out, warn("Lock Freshness (Node.js)", fmt.Sprintf(
					"package.json is newer than %s. Dependencies may have been added. Consider: npm install",
					lock)))
			} else {
				out = append(out, pass("Lock Freshness (Node.js)", fmt.Sprintf(
					"%s is up-to-date with package.json.", lock)))
			}
		}
	}

	// Python
	if fileExists(proj, "pyproject.toml") && fileExists(proj, "poetry.lock") {
		if fileNewer(filepath.Join(proj, "pyproject.toml"), filepath.Join(proj, "poetry.lock")) {
			out = append(out, warn("Lock Freshness (Python)",
				"pyproject.toml is newer than poetry.lock. Consider: poetry lock"))
		}
	}

	// Ruby
	if fileExists(proj, "Gemfile") && fileExists(proj, "Gemfile.lock") {
		if fileNewer(filepath.Join(proj, "Gemfile"), filepath.Join(proj, "Gemfile.lock")) {
			out = append(out, warn("Lock Freshness (Ruby)",
				"Gemfile is newer than Gemfile.lock. Consider: bundle install"))
		}
	}

	// Go
	if fileExists(proj, "go.mod") && fileExists(proj, "go.sum") {
		if fileNewer(filepath.Join(proj, "go.mod"), filepath.Join(proj, "go.sum")) {
			out = append(out, warn("Lock Freshness (Go)",
				"go.mod is newer than go.sum. Consider: go mod tidy"))
		}
	}
	return out
}
