package preflight

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// fileExists reports whether ⟨dir⟩/⟨name⟩ exists and is a regular file.
func fileExists(dir, name string) bool {
	st, err := os.Stat(filepath.Join(dir, name))
	if err != nil {
		return false
	}
	return st.Mode().IsRegular()
}

// dirExists reports whether path exists and is a directory.
func dirExists(path string) bool {
	st, err := os.Stat(path)
	if err != nil {
		return false
	}
	return st.IsDir()
}

// dirExistsNonEmpty reports whether path is a directory with at least one entry.
func dirExistsNonEmpty(path string) bool {
	if !dirExists(path) {
		return false
	}
	entries, err := os.ReadDir(path)
	if err != nil {
		return false
	}
	return len(entries) > 0
}

// fileNewer reports whether a is newer than b (both mtime). Returns false
// if either file is missing or stat fails — matches bash `[[ a -nt b ]]`
// semantics. The bash form returns false when either operand is missing.
func fileNewer(a, b string) bool {
	sa, err := os.Stat(a)
	if err != nil {
		return false
	}
	sb, err := os.Stat(b)
	if err != nil {
		return false
	}
	return sa.ModTime().After(sb.ModTime())
}

// globMatch reports whether at least one direct-child entry of dir matches
// the shell glob pattern. Equivalent to `compgen -G "$dir/$pat"` — only one
// directory level, no recursion.
func globMatch(dir, pattern string) bool {
	matches, _ := filepath.Glob(filepath.Join(dir, pattern))
	return len(matches) > 0
}

// hasLanguage reports whether the project appears to use the named language.
// Uses an extension/manifest scan keyed off the project root; results are
// cached on Input for the duration of the run.
func hasLanguage(in *Input, name string) bool {
	if in.languages == nil {
		in.languages = detectLanguages(in.ProjectDir)
	}
	_, ok := in.languages[strings.ToLower(name)]
	return ok
}

// detectLanguages mirrors the relevant slice of lib/detect.sh that
// preflight consumed via `_pf_has_language`. Returns map of lowercase
// language name → triggering file (presence is the signal).
func detectLanguages(projectDir string) map[string]string {
	out := make(map[string]string)
	manifest := map[string]string{
		"package.json":     "javascript",
		"pyproject.toml":   "python",
		"requirements.txt": "python",
		"Pipfile":          "python",
		"poetry.lock":      "python",
		"Gemfile":          "ruby",
		"go.mod":           "go",
		"Cargo.toml":       "rust",
		"composer.json":    "php",
		"pom.xml":          "java",
		"build.gradle":     "java",
	}
	for f, lang := range manifest {
		if fileExists(projectDir, f) {
			out[lang] = f
		}
	}
	// Lightweight extension signal — only top-level scan. Bash walked
	// two dir levels but the preflight branches are short enough that
	// missing a nested-language signal is acceptable.
	entries, err := os.ReadDir(projectDir)
	if err == nil {
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			ext := strings.ToLower(filepath.Ext(e.Name()))
			switch ext {
			case ".py":
				if _, ok := out["python"]; !ok {
					out["python"] = e.Name()
				}
			case ".rb":
				if _, ok := out["ruby"]; !ok {
					out["ruby"] = e.Name()
				}
			case ".php":
				if _, ok := out["php"]; !ok {
					out["php"] = e.Name()
				}
			}
		}
	}
	return out
}

// detectTestFrameworks mirrors `_pf_detect_test_frameworks`. Returns a map
// of lowercase framework name → triggering manifest path. Cached on Input.
func detectTestFrameworks(in *Input) map[string]string {
	if in.testFrameworks != nil {
		return in.testFrameworks
	}
	out := make(map[string]string)
	proj := in.ProjectDir
	if fileExists(proj, "package.json") {
		b, _ := os.ReadFile(filepath.Join(proj, "package.json"))
		s := string(b)
		if strings.Contains(s, `"@playwright/test"`) || strings.Contains(s, `"playwright"`) {
			out["playwright"] = "package.json"
		}
		if strings.Contains(s, `"cypress"`) {
			out["cypress"] = "package.json"
		}
		if strings.Contains(s, `"jest"`) {
			out["jest"] = "package.json"
		}
		if strings.Contains(s, `"vitest"`) {
			out["vitest"] = "package.json"
		}
	}
	in.testFrameworks = out
	return out
}

// pass / warn / fail / fixed are concise constructors for the corresponding
// Finding shapes. Keeps the check bodies readable.
func pass(name, detail string) Finding  { return Finding{Name: name, Status: StatusPass, Detail: detail} }
func warn(name, detail string) Finding  { return Finding{Name: name, Status: StatusWarn, Detail: detail} }
func failF(name, detail string) Finding { return Finding{Name: name, Status: StatusFail, Detail: detail} }
func fixed(name, detail string) Finding { return Finding{Name: name, Status: StatusFixed, Detail: detail} }

// tryFix attempts an auto-remediation command when PREFLIGHT_AUTO_FIX is
// not disabled. Mirrors bash _pf_try_fix. When the command succeeds we
// emit a "fixed" finding; otherwise a "fail" finding with the same
// diagnosis prefix.
func tryFix(in *Input, command, name, diagnosis string) Finding {
	if in.GetenvDefault("PREFLIGHT_AUTO_FIX", "true") != "true" {
		return failF(name, diagnosis+" Auto-fix disabled.")
	}
	start := time.Now()
	cmd := exec.Command("bash", "-c", command)
	cmd.Dir = in.ProjectDir
	if err := cmd.Run(); err == nil {
		dur := int(time.Since(start).Seconds())
		return fixed(name, fmt.Sprintf("%s Auto-fixed: `%s` (%ds)", diagnosis, command, dur))
	}
	return failF(name, fmt.Sprintf("%s Auto-fix failed: `%s`", diagnosis, command))
}
