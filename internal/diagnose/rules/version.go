package rules

import (
	"strings"
)

// extractPipelineConfigVersion reads `TEKHTON_CONFIG_VERSION=<value>` from a
// pipeline.conf body. Returns "" when the key is absent. Mirrors the bash
// detect_config_version helper for the slice of behavior this rule needs.
func extractPipelineConfigVersion(body string) string {
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#") {
			continue
		}
		if !strings.HasPrefix(line, "TEKHTON_CONFIG_VERSION=") {
			continue
		}
		val := strings.TrimPrefix(line, "TEKHTON_CONFIG_VERSION=")
		val = strings.Trim(val, "\"' ")
		return val
	}
	return ""
}

// majorMinor returns the leading `MAJOR.MINOR` of a `MAJOR.MINOR.PATCH`
// version string (or the full string when it doesn't contain enough dots).
// Mirrors bash `running_ver="${TEKHTON_VERSION%.*}"`.
func majorMinor(v string) string {
	if v == "" {
		return ""
	}
	if idx := strings.LastIndex(v, "."); idx >= 0 {
		return v[:idx]
	}
	return v
}

// versionLT reports whether semver-shaped `a` is strictly less than `b`.
// Bash uses `_version_lt`, which lexically split on "." and compares each
// component as an integer. We do the same; non-numeric components are treated
// as 0 so the comparator never panics on malformed input.
func versionLT(a, b string) bool {
	aParts := splitVersion(a)
	bParts := splitVersion(b)
	n := len(aParts)
	if len(bParts) > n {
		n = len(bParts)
	}
	for i := 0; i < n; i++ {
		av := 0
		if i < len(aParts) {
			av = aParts[i]
		}
		bv := 0
		if i < len(bParts) {
			bv = bParts[i]
		}
		if av < bv {
			return true
		}
		if av > bv {
			return false
		}
	}
	return false
}

func splitVersion(v string) []int {
	parts := strings.Split(v, ".")
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		n, ok := tryAtoi(p)
		if !ok {
			out = append(out, 0)
			continue
		}
		out = append(out, n)
	}
	return out
}
