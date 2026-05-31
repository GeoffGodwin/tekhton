package rules

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/diagnose"
)

// taskOrFallback ports the bash `${_DIAG_PIPELINE_TASK:-${TASK:-<task not recorded>}}`
// expansion shared by every rule's suggestion-text builder.
func taskOrFallback(c *diagnose.Context) string {
	if c.Task != "" {
		return c.Task
	}
	if t := os.Getenv("TASK"); t != "" {
		return t
	}
	return "<task not recorded>"
}

// projectFileNonEmpty returns true when ${PROJECT_DIR}/<rel> exists and has
// non-zero size — the bash `[[ -s file ]]` predicate the rules lean on.
// `rel` may already be absolute; in that case ProjectDir is ignored.
func projectFileNonEmpty(c *diagnose.Context, rel string) bool {
	path := projectPath(c, rel)
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	if info.IsDir() {
		return false
	}
	return info.Size() > 0
}

// projectFileExists returns true when ${PROJECT_DIR}/<rel> exists and is a
// regular file (the bash `[[ -f file ]]` predicate).
func projectFileExists(c *diagnose.Context, rel string) bool {
	path := projectPath(c, rel)
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

// readProjectFile reads ${PROJECT_DIR}/<rel> as a string. Returns "" on any
// error so the rules can default to the no-match branch without panicking.
func readProjectFile(c *diagnose.Context, rel string) string {
	body, err := os.ReadFile(projectPath(c, rel))
	if err != nil {
		return ""
	}
	return string(body)
}

// projectPath joins ProjectDir (or ".") with the supplied path. Absolute paths
// pass through unchanged.
func projectPath(c *diagnose.Context, rel string) string {
	if filepath.IsAbs(rel) {
		return rel
	}
	root := "."
	if c != nil && c.ProjectDir != "" {
		root = c.ProjectDir
	}
	return filepath.Join(root, rel)
}

// envOr returns os.Getenv(key) if non-empty, otherwise fallback. Used by
// rules to honor the bash `${KEY:-default}` expansion for tunables like
// CODER_MAX_TURNS, MAX_PIPELINE_ATTEMPTS, etc.
func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// pathFromEnvOr is envOr scoped to filesystem paths — used so rules can read
// `${BUILD_ERRORS_FILE:-.tekhton/BUILD_ERRORS.md}`-style fallbacks without
// per-call boilerplate.
func pathFromEnvOr(key, fallback string) string {
	return envOr(key, fallback)
}

// containsLineMatching returns true when any newline-delimited line of `text`
// contains every needle in `needles`. Used by rules that previously called
// `grep -q 'a' | grep -q 'b'` style pipelines (e.g. _rule_review_loop counting
// reviewer verdict lines).
func containsLineMatching(text string, needles ...string) bool {
	for _, line := range strings.Split(text, "\n") {
		ok := true
		for _, n := range needles {
			if !strings.Contains(line, n) {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// countLinesMatching returns the count of newline-delimited lines that match
// every needle. Bash equivalent: `grep -c 'a' | grep -c 'b'`.
func countLinesMatching(text string, needles ...string) int {
	count := 0
	for _, line := range strings.Split(text, "\n") {
		ok := true
		for _, n := range needles {
			if !strings.Contains(line, n) {
				ok = false
				break
			}
		}
		if ok {
			count++
		}
	}
	return count
}

// quoteTask wraps the task in literal double quotes, mirroring the bash
// `"${_task}"` substitution. Bash does not escape the task value inside
// the suggestion strings, so neither do we — operator-facing strings are
// reproduced byte-for-byte.
func quoteTask(task string) string {
	return fmt.Sprintf("\"%s\"", task)
}
