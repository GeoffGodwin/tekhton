package detect

// Public API surface consumed by sibling internal packages (m30.1 onward).
// The original unexported names are kept to limit churn inside this package;
// these exported wrappers exist so internal/crawler and future sibling
// packages can reuse the detect helpers without duplication.
//
// The exports below MUST stay read-only — they delegate to the private
// helpers in helpers.go and doc_quality.go, which the readonly_test.go
// contract scans.

// ExtractJSONKeys returns the lines between any of the given section
// markers and the next closing brace inside the file at path. Best-effort:
// no JSON parsing — mirrors lib/detect.sh::_extract_json_keys.
func ExtractJSONKeys(path string, sections ...string) string {
	return extractJSONKeys(path, sections...)
}

// AssessDocQuality scores documentation quality in dir on a 0-100 scale and
// returns the score plus per-subscore detail strings. Ports
// lib/detect_doc_quality.sh::assess_doc_quality.
func AssessDocQuality(dir string) *DocQuality {
	return assessDocQuality(dir)
}

// DefaultExcludeDirs returns a copy of the directory-exclusion list shared
// by the detect engine. Mirrors lib/detect.sh::_DETECT_EXCLUDE_DIRS.
func DefaultExcludeDirs() []string {
	out := make([]string, len(detectExcludeDirs))
	copy(out, detectExcludeDirs)
	return out
}
