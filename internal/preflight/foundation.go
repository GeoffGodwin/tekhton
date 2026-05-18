package preflight

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// FoundationCheck ports lib/preflight_checks.sh — four sub-checks that the
// bash side ran independently but emitted into the same report:
//
//  1. Dependencies — node_modules / venv / vendor / Cargo.lock / composer
//  2. Tools — Playwright/Cypress binary caches + pipeline.conf command first-tokens
//  3. Generated code — Prisma client / codegen / .proto
//  4. Environment variables — .env vs .env.example key coverage
//
// Bash interleaved these with the UI test config check (between #2 and #3).
// The Go orchestrator runs the UI audit as a separate Check (UIConfigCheck)
// — see checkOrder in orchestrator.go for the post-port ordering.
type FoundationCheck struct{}

// Name returns the canonical check name. Matches checkOrder.
func (FoundationCheck) Name() string { return "foundation" }

// Run executes the four sub-checks in the same order bash did.
func (FoundationCheck) Run(_ context.Context, in *Input) Result {
	var r Result
	r.Findings = append(r.Findings, checkDependencies(in)...)
	r.Findings = append(r.Findings, checkTools(in)...)
	r.Findings = append(r.Findings, checkGeneratedCode(in)...)
	r.Findings = append(r.Findings, checkEnvVars(in)...)
	return r
}

// --- Dependencies ----------------------------------------------------------

func checkDependencies(in *Input) []Finding {
	proj := in.ProjectDir
	var out []Finding

	// Node.js
	hasLock := fileExists(proj, "package-lock.json") || fileExists(proj, "yarn.lock") || fileExists(proj, "pnpm-lock.yaml")
	if hasLock {
		nm := filepath.Join(proj, "node_modules")
		if !dirExists(nm) {
			out = append(out, tryFix(in, "npm install", "Dependencies (node_modules)",
				"node_modules/ is missing but a lock file exists."))
		} else if fileExists(proj, "package-lock.json") &&
			fileNewer(filepath.Join(proj, "package-lock.json"),
				filepath.Join(nm, ".package-lock.json")) {
			if fileExists(nm, ".package-lock.json") {
				out = append(out, tryFix(in, "npm install", "Dependencies (node_modules)",
					"node_modules is stale (lock file is newer)."))
			} else {
				out = append(out, pass("Dependencies (node_modules)", "node_modules exists."))
			}
		} else {
			out = append(out, pass("Dependencies (node_modules)", "node_modules is up-to-date."))
		}
	}

	// Python
	if hasLanguage(in, "python") {
		lockFile := ""
		for _, name := range []string{"requirements.txt", "poetry.lock", "Pipfile.lock"} {
			if fileExists(proj, name) {
				lockFile = name
				break
			}
		}
		if lockFile != "" {
			venvDir := ""
			if dirExists(filepath.Join(proj, ".venv")) {
				venvDir = ".venv"
			}
			if dirExists(filepath.Join(proj, "venv")) {
				venvDir = "venv"
			}
			if venvDir == "" {
				out = append(out, warn("Dependencies (Python venv)",
					fmt.Sprintf("No virtualenv found (.venv/ or venv/) but %s exists.", lockFile)))
			} else {
				out = append(out, pass("Dependencies (Python)",
					fmt.Sprintf("Virtualenv %s/ exists with %s.", venvDir, lockFile)))
			}
		}
	}

	// Go
	if fileExists(proj, "go.sum") && fileExists(proj, "go.mod") {
		out = append(out, pass("Dependencies (Go)", "go.sum exists."))
	}

	// Ruby
	if fileExists(proj, "Gemfile.lock") {
		if dirExists(filepath.Join(proj, "vendor/bundle")) {
			out = append(out, pass("Dependencies (Ruby)", "vendor/bundle exists."))
		} else if hasLanguage(in, "ruby") {
			out = append(out, warn("Dependencies (Ruby)",
				"Gemfile.lock exists but vendor/bundle/ not found. Consider: bundle install --path vendor/bundle"))
		}
	}

	// Rust
	if fileExists(proj, "Cargo.lock") && fileExists(proj, "Cargo.toml") {
		out = append(out, pass("Dependencies (Rust)", "Cargo.lock exists."))
	}

	// PHP
	if fileExists(proj, "composer.lock") {
		if fileExists(proj, "vendor/autoload.php") {
			out = append(out, pass("Dependencies (PHP)", "vendor/autoload.php exists."))
		} else if hasLanguage(in, "php") {
			out = append(out, tryFix(in, "composer install --no-interaction", "Dependencies (PHP)",
				"composer.lock exists but vendor/autoload.php is missing."))
		}
	}
	return out
}

// --- Tools -----------------------------------------------------------------

func checkTools(in *Input) []Finding {
	var out []Finding
	tfws := detectTestFrameworks(in)

	if _, ok := tfws["playwright"]; ok {
		cache := in.GetenvDefault("PLAYWRIGHT_BROWSERS_PATH",
			filepath.Join(os.Getenv("HOME"), ".cache", "ms-playwright"))
		if dirExistsNonEmpty(cache) {
			out = append(out, pass("Tools (Playwright)",
				fmt.Sprintf("Playwright browsers found in %s.", cache)))
		} else {
			out = append(out, tryFix(in, "npx playwright install", "Tools (Playwright)",
				"Playwright browsers not found."))
		}
	}

	if _, ok := tfws["cypress"]; ok {
		cache := in.GetenvDefault("CYPRESS_CACHE_FOLDER",
			filepath.Join(os.Getenv("HOME"), ".cache", "Cypress"))
		if dirExistsNonEmpty(cache) {
			out = append(out, pass("Tools (Cypress)", "Cypress binary cache found."))
		} else {
			out = append(out, tryFix(in, "npx cypress install", "Tools (Cypress)",
				"Cypress binary cache not found."))
		}
	}

	for _, cmdVar := range []string{"ANALYZE_CMD", "BUILD_CHECK_CMD", "TEST_CMD", "UI_TEST_CMD"} {
		val := in.Getenv(cmdVar)
		if val == "" || val == "true" {
			continue
		}
		// First token = executable.
		token := strings.Fields(val)[0]
		switch token {
		case "true", "false", "echo", ":":
			continue
		}
		if _, err := exec.LookPath(token); err == nil {
			out = append(out, pass(fmt.Sprintf("Tools (%s)", cmdVar),
				fmt.Sprintf("`%s` is available.", token)))
		} else {
			out = append(out, warn(fmt.Sprintf("Tools (%s)", cmdVar),
				fmt.Sprintf("`%s` (from %s) is not found in PATH.", token, cmdVar)))
		}
	}
	return out
}

// --- Generated code --------------------------------------------------------

func checkGeneratedCode(in *Input) []Finding {
	proj := in.ProjectDir
	var out []Finding

	if fileExists(proj, "prisma/schema.prisma") {
		client := filepath.Join(proj, "node_modules/.prisma/client")
		if dirExists(client) {
			if fileNewer(filepath.Join(proj, "prisma/schema.prisma"), client) {
				out = append(out, tryFix(in, "npx prisma generate", "Generated Code (Prisma)",
					"prisma/schema.prisma is newer than generated client."))
			} else {
				out = append(out, pass("Generated Code (Prisma)", "Prisma client is up-to-date."))
			}
		} else if dirExists(filepath.Join(proj, "node_modules")) {
			out = append(out, tryFix(in, "npx prisma generate", "Generated Code (Prisma)",
				"Prisma schema exists but no generated client found."))
		}
	}

	if fileExists(proj, "codegen.yml") || fileExists(proj, "codegen.ts") || fileExists(proj, "codegen.yaml") {
		if fileExists(proj, "package.json") {
			b, _ := os.ReadFile(filepath.Join(proj, "package.json"))
			if strings.Contains(string(b), `"codegen"`) {
				out = append(out, warn("Generated Code (GraphQL)",
					"GraphQL codegen config found. Run `npm run codegen` if generated types are stale."))
			}
		}
	}

	if globMatch(proj, "*.proto") || globMatch(filepath.Join(proj, "proto"), "*.proto") {
		out = append(out, warn("Generated Code (Protobuf)",
			"Protobuf .proto files detected. Ensure generated code is up-to-date."))
	}
	return out
}

// --- Env vars --------------------------------------------------------------

var envKeyRE = regexp.MustCompile(`^([A-Z_][A-Z0-9_]*)=`)

func checkEnvVars(in *Input) []Finding {
	proj := in.ProjectDir
	var exampleFile string
	for _, name := range []string{".env.example", ".env.template", ".env.sample"} {
		if fileExists(proj, name) {
			exampleFile = name
			break
		}
	}
	if exampleFile == "" {
		return nil
	}

	envPath := filepath.Join(proj, ".env")
	if !fileExists(proj, ".env") {
		return []Finding{warn("Environment Variables",
			fmt.Sprintf("%s exists but .env does not. Copy and configure: `cp %s .env`",
				exampleFile, exampleFile))}
	}

	exampleKeys := extractEnvKeys(filepath.Join(proj, exampleFile))
	envBytes, _ := os.ReadFile(envPath)
	envContent := string(envBytes)
	var missing []string
	for _, key := range exampleKeys {
		// Bash uses `grep -q "^${key}="` — line-anchored match.
		needle := key + "="
		found := false
		for _, line := range strings.Split(envContent, "\n") {
			if strings.HasPrefix(line, needle) {
				found = true
				break
			}
		}
		if !found {
			missing = append(missing, key)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing) // Stable output for tests.
		return []Finding{warn("Environment Variables",
			fmt.Sprintf(".env is missing key(s) from %s: %s.",
				exampleFile, strings.Join(missing, ", ")))}
	}
	return []Finding{pass("Environment Variables",
		fmt.Sprintf("All keys from %s are present in .env.", exampleFile))}
}

func extractEnvKeys(path string) []string {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var keys []string
	for _, line := range strings.Split(string(b), "\n") {
		m := envKeyRE.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		keys = append(keys, m[1])
	}
	return keys
}
