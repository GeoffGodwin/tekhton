package config

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strings"
)

// keyRE matches the KEY=VALUE pattern at the start of a logical line. Mirrors
// the bash regex `^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)`.
var keyRE = regexp.MustCompile(`^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$`)

// parseFile reads pipeline.conf, populates cfg.Values and cfg.KeysSet,
// rejecting dangerous shell metacharacters. Mirrors lib/config.sh::_parse_config_file.
func parseFile(path string, cfg *Config) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("%w: open %s: %v", ErrParse, path, err)
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	// Allow long lines (some _CMD values can be hundreds of bytes).
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)

	lineNum := 0
	for sc.Scan() {
		lineNum++
		line := sc.Text()

		// Strip CR (CRLF from Windows editors)
		line = strings.ReplaceAll(line, "\r", "")

		// Skip empty lines and comments
		trimmed := strings.TrimLeft(line, " \t")
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}

		m := keyRE.FindStringSubmatch(line)
		if m == nil {
			// Unmatched lines silently skipped — matches bash behavior.
			continue
		}
		key := m[1]
		raw := m[2]

		// Strip leading/trailing whitespace from value.
		raw = strings.TrimSpace(raw)

		// Strip surrounding quotes (double or single).
		if len(raw) >= 2 {
			if (raw[0] == '"' && raw[len(raw)-1] == '"') ||
				(raw[0] == '\'' && raw[len(raw)-1] == '\'') {
				raw = raw[1 : len(raw)-1]
			}
		}

		// Strip inline comments: only if preceded by whitespace+# (matches
		// the bash regex `^([^#]*[^[:space:]])[[:space:]]+#.*$`).
		if idx := findInlineComment(raw); idx >= 0 {
			raw = strings.TrimRight(raw[:idx], " \t")
		}

		// Reject command substitution universally.
		if strings.Contains(raw, "$(") || strings.Contains(raw, "`") {
			return fmt.Errorf("%w: %s:%d: REJECTED — value for %q contains command substitution",
				ErrParse, path, lineNum, key)
		}

		// Reject shell metacharacters in non-command, non-pattern keys.
		if !allowsMetachars(key) {
			if hasShellMetachar(raw) {
				return fmt.Errorf("%w: %s:%d: REJECTED — value for %q contains shell metacharacters",
					ErrParse, path, lineNum, key)
			}
		}

		cfg.Values[key] = raw
		cfg.KeysSet[key] = true
	}
	if err := sc.Err(); err != nil {
		return fmt.Errorf("%w: read %s: %v", ErrParse, path, err)
	}
	return nil
}

// findInlineComment locates the start index of an inline " #..." comment in
// a raw value. Returns -1 if none. Mirrors the bash regex
// `^([^#]*[^[:space:]])[[:space:]]+#.*$` — the comment must be preceded by
// at least one whitespace character that itself follows non-whitespace.
func findInlineComment(s string) int {
	for i := 1; i < len(s); i++ {
		if s[i] != '#' {
			continue
		}
		// Look back: at least one whitespace, preceded by non-whitespace.
		j := i - 1
		for j >= 0 && (s[j] == ' ' || s[j] == '\t') {
			j--
		}
		if j < 0 || j == i-1 {
			// Either all whitespace before # (no preceding non-ws content), or
			// no whitespace at all (then it's a literal #).
			continue
		}
		return i
	}
	return -1
}

// allowsMetachars: command keys, pattern keys, and category keys are allowed
// to contain `;`, `|`, `&`, `>`, `<`. Mirrors the bash case statement.
func allowsMetachars(key string) bool {
	return strings.HasSuffix(key, "_CMD") ||
		strings.HasSuffix(key, "_PATTERN") ||
		strings.HasSuffix(key, "_CATEGORIES")
}

// hasShellMetachar returns true if s contains any of `;`, `|`, `&`, `>`, `<`.
func hasShellMetachar(s string) bool {
	return strings.ContainsAny(s, ";|&><")
}
