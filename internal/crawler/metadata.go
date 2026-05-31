package crawler

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// ErrMetadataFieldUnknown is returned when ExtractScanMetadata is asked for
// a field outside the recognized set (Scan-Commit | Last-Scan | File-Count
// | Total-Lines). Callers can errors.Is-check this for typo defense.
var ErrMetadataFieldUnknown = errors.New("crawler: unknown metadata field")

// metadataFieldJSON maps the public field name (matching the bash
// _extract_scan_metadata case arms) to its meta.json key. Used by
// ExtractScanMetadata to select the structured-source lookup; the legacy
// HTML-comment fallback uses the public name verbatim.
var metadataFieldJSON = map[string]string{
	"Scan-Commit": "scan_commit",
	"Last-Scan":   "scan_date",
	"File-Count":  "file_count",
	"Total-Lines": "total_lines",
}

// ExtractScanMetadata reads a single metadata field. Prefers the
// structured .claude/index/meta.json (post-M68); falls back to parsing
// the legacy HTML-comment header (`<!-- Field: value -->`) embedded in
// PROJECT_INDEX.md for pre-M68 projects.
//
// indexFile is the markdown index path (typically PROJECT_INDEX.md); the
// meta.json sibling is computed from filepath.Dir(indexFile) +
// "/.claude/index/meta.json".
//
// Returns the empty string (not an error) when the field is absent from
// both sources — matches bash semantics. ErrMetadataFieldUnknown is
// returned only for typos in the field name itself.
func ExtractScanMetadata(indexFile, field string) (string, error) {
	jsonField, ok := metadataFieldJSON[field]
	if !ok {
		return "", fmt.Errorf("%w: %q", ErrMetadataFieldUnknown, field)
	}

	projectDir := filepath.Dir(indexFile)
	metaFile := filepath.Join(projectDir, ".claude", "index", "meta.json")

	if v, ok := readMetaJSONField(metaFile, jsonField); ok && v != "" {
		return v, nil
	}

	// Legacy fallback. The bash version greps for `<!-- Field:` then
	// strips the comment markers and trims whitespace. We do the same
	// without forking awk/sed.
	return extractHTMLCommentField(indexFile, field), nil
}

// readMetaJSONFieldByPublicName reads meta.json directly from a known
// path and returns the value associated with `field` (the public
// Scan-Commit / Last-Scan / etc. name, NOT the JSON key). This is the
// non-bash-quirky lookup used by Rescan internally — it knows the
// IndexDir up front and does not rely on dirname(indexFile) ascending
// the wrong way for `.tekhton/PROJECT_INDEX.md` callers.
//
// Returns "" when the file is missing, unparseable, the field name is
// unknown, or the JSON key is absent — every condition is non-fatal.
func readMetaJSONFieldByPublicName(metaFile, field string) string {
	jsonKey, ok := metadataFieldJSON[field]
	if !ok {
		return ""
	}
	v, _ := readMetaJSONField(metaFile, jsonKey)
	return v
}

// readMetaJSONField loads meta.json and returns the value associated with
// jsonKey. Returns ("", false) when the file is missing, unparseable, or
// the key is absent. Bash silently swallows all these conditions, so the
// Go port surfaces them as "not present" rather than errors — preserving
// the fallback contract with extractHTMLCommentField.
func readMetaJSONField(metaFile, jsonKey string) (string, bool) {
	body, err := os.ReadFile(metaFile) //nolint:gosec // intentional read of index artifact
	if err != nil {
		return "", false
	}
	var meta map[string]any
	if err := json.Unmarshal(body, &meta); err != nil {
		return "", false
	}
	v, ok := meta[jsonKey]
	if !ok || v == nil {
		return "", false
	}
	// json.Unmarshal yields float64 for numeric JSON values. fmt.Sprint
	// renders 7.0 as "7" via %v for ints and "7.0" for true floats —
	// meta.json file_count / total_lines are always emitted as integers
	// by emit.go's strconv.Itoa, so reading them back round-trips
	// through float64. Force integer rendering when the value is whole.
	switch t := v.(type) {
	case string:
		return strings.TrimSpace(t), true
	case float64:
		if t == float64(int64(t)) {
			return fmt.Sprintf("%d", int64(t)), true
		}
		return fmt.Sprintf("%g", t), true
	default:
		return strings.TrimSpace(fmt.Sprint(v)), true
	}
}

// rxHTMLComment captures the value inside `<!-- Field: value -->` markers.
// Built per-call via buildHTMLCommentRegex because the field name is
// caller-supplied data and must be regex-quoted.
func buildHTMLCommentRegex(field string) *regexp.Regexp {
	return regexp.MustCompile(`<!-- ` + regexp.QuoteMeta(field) + `:\s*([^>]*?)\s*-->`)
}

// extractHTMLCommentField scans indexFile line-by-line for the first
// `<!-- Field: value -->` marker matching field. Whitespace inside the
// value is preserved up to a trailing `-->` boundary, then trimmed —
// mirrors the bash sed + tr -d '[:space:]' pipeline (which strips all
// whitespace, but the captured value never contains internal whitespace
// in any real-world scan-metadata field, so trimming is equivalent here).
func extractHTMLCommentField(indexFile, field string) string {
	body, err := os.ReadFile(indexFile) //nolint:gosec // intentional read of index file
	if err != nil {
		return ""
	}
	rx := buildHTMLCommentRegex(field)
	for _, line := range strings.Split(string(body), "\n") {
		if m := rx.FindStringSubmatch(line); m != nil {
			// Bash `tr -d '[:space:]'` strips ALL whitespace — match it
			// for parity with the field formats we know about (hashes,
			// dates, integers — none contain inner whitespace).
			return stripAllSpaces(m[1])
		}
	}
	return ""
}

// stripAllSpaces removes every Unicode-whitespace byte from s. Equivalent
// to bash `tr -d '[:space:]'`.
func stripAllSpaces(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case ' ', '\t', '\n', '\r', '\v', '\f':
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// manifestBasenames is the literal-match set ported from
// rescan_helpers.sh::_is_manifest_file. *.csproj and *.sln are handled
// separately via suffix-match below.
var manifestBasenames = map[string]struct{}{
	"package.json":      {},
	"Cargo.toml":        {},
	"go.mod":            {},
	"pyproject.toml":    {},
	"requirements.txt":  {},
	"setup.py":          {},
	"Pipfile":           {},
	"Gemfile":           {},
	"composer.json":     {},
	"pubspec.yaml":      {},
	"Package.swift":     {},
	"mix.exs":           {},
	"build.gradle":      {},
	"build.gradle.kts":  {},
	"pom.xml":           {},
	"stack.yaml":        {},
	"cabal.project":     {},
	"Makefile":          {},
}

// IsManifestFile mirrors rescan_helpers.sh::_is_manifest_file — true for
// any dependency-manifest filename the rescan significance classifier
// treats as load-bearing. Case-sensitive (matches bash `case` semantics
// in a default locale).
func IsManifestFile(path string) bool {
	base := filepath.Base(path)
	if _, ok := manifestBasenames[base]; ok {
		return true
	}
	// .csproj / .sln glob arms from the bash case.
	if strings.HasSuffix(base, ".csproj") || strings.HasSuffix(base, ".sln") {
		return true
	}
	return false
}

// configExtensions is the set of file extensions the bash case treated as
// configuration. Extension match is on the full ".ext" form to match
// bash's `*.ext` arm exactly.
var configExtensions = map[string]struct{}{
	".conf": {}, ".cfg": {}, ".ini": {},
	".toml": {}, ".yaml": {}, ".yml": {}, ".json": {},
	".env": {},
}

// configBasenames is the literal-match set ported from
// rescan_helpers.sh::_is_config_file.
var configBasenames = map[string]struct{}{
	".editorconfig":  {},
	"Dockerfile":     {},
	".dockerignore":  {},
	".gitignore":     {},
	".gitattributes": {},
}

// configGlobs is the ordered glob-arm list ported from
// rescan_helpers.sh::_is_config_file. First match wins (matches bash
// `case` semantics).
var configGlobs = []string{
	".eslintrc*",
	".prettierrc*",
	".babelrc*",
	"webpack.config.*",
	"rollup.config.*",
	"vite.config.*",
	"jest.config.*",
	"docker-compose*",
}

// IsConfigFile mirrors rescan_helpers.sh::_is_config_file — true for any
// filename the rescan significance classifier treats as a configuration
// surface. Extension matches use full ".ext"; literal matches and glob
// matches are checked in bash case order. The `*.env.*` arm from bash
// is matched by the env-prefix walk (basename starts with ".env." or
// is ".env*").
func IsConfigFile(path string) bool {
	base := filepath.Base(path)
	if _, ok := configBasenames[base]; ok {
		return true
	}
	if ext := filepath.Ext(base); ext != "" {
		if _, ok := configExtensions[ext]; ok {
			return true
		}
	}
	// .env.* arm from bash (`*.env.*`).
	if strings.HasPrefix(base, ".env.") {
		return true
	}
	for _, pat := range configGlobs {
		if matched, _ := filepath.Match(pat, base); matched {
			return true
		}
	}
	return false
}

// decodeSamplesManifest reads samples/manifest.json directly from the
// supplied path and returns the list of `original` field values. Used by
// Rescan internally to avoid the bash-bug dirname quirk in
// ExtractSampledFiles. Returns nil on any error (missing / unparseable).
func decodeSamplesManifest(manifestPath string) []string {
	body, err := os.ReadFile(manifestPath) //nolint:gosec // intentional read of artifact
	if err != nil {
		return nil
	}
	var parsed struct {
		Samples []struct {
			Original string `json:"original"`
		} `json:"samples"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil
	}
	out := make([]string, 0, len(parsed.Samples))
	for _, s := range parsed.Samples {
		if s.Original != "" {
			out = append(out, s.Original)
		}
	}
	return out
}

// ExtractSampledFiles returns the list of source-file paths currently
// represented in samples/manifest.json. Falls back to the legacy
// PROJECT_INDEX.md markdown headings (`### path`) when the structured
// manifest is absent.
//
// Used by the rescan section regen logic to decide whether the sampled
// content needs re-rendering: if any currently-sampled file appears in
// the change set, samples must regenerate.
func ExtractSampledFiles(indexFile string) []string {
	projectDir := filepath.Dir(indexFile)
	manifest := filepath.Join(projectDir, ".claude", "index", "samples", "manifest.json")

	if body, err := os.ReadFile(manifest); err == nil { //nolint:gosec // intentional read of artifact
		var parsed struct {
			Samples []struct {
				Original string `json:"original"`
			} `json:"samples"`
		}
		if err := json.Unmarshal(body, &parsed); err == nil {
			out := make([]string, 0, len(parsed.Samples))
			for _, s := range parsed.Samples {
				if s.Original != "" {
					out = append(out, s.Original)
				}
			}
			return out
		}
	}

	// Legacy fallback: parse `### filename` headings from the index.
	body, err := os.ReadFile(indexFile) //nolint:gosec // intentional read of index file
	if err != nil {
		return nil
	}
	var out []string
	for _, line := range strings.Split(string(body), "\n") {
		if !strings.HasPrefix(line, "### ") {
			continue
		}
		name := strings.TrimPrefix(line, "### ")
		// Bash also strips backticks via `sed 's/`//g'`.
		name = strings.ReplaceAll(name, "`", "")
		name = strings.TrimSpace(name)
		if name != "" {
			out = append(out, name)
		}
	}
	return out
}
