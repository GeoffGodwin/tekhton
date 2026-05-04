// Package version exposes the build-time version string for the tekhton binary.
//
// Version is populated by the Makefile via -ldflags "-X" injection, sourcing
// the canonical value from the repo-root VERSION file. Direct `go build`
// invocations (without make) leave Version at the "dev" sentinel.
package version

import "strings"

// Version is set at link time via -ldflags. Default keeps unconfigured builds
// distinguishable from release builds.
var Version = "dev"

// String returns the version trimmed of surrounding whitespace.
func String() string {
	return strings.TrimSpace(Version)
}
