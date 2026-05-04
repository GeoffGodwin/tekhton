package version_test

import (
	"testing"

	"github.com/geoffgodwin/tekhton/internal/version"
)

func TestString_DefaultIsDev(t *testing.T) {
	version.Version = "dev"
	got := version.String()
	if got != "dev" {
		t.Errorf("String() = %q; want %q", got, "dev")
	}
}

func TestString_TrimsTrailingNewline(t *testing.T) {
	version.Version = "4.1.0\n"
	got := version.String()
	if got != "4.1.0" {
		t.Errorf("String() = %q; want %q (trailing newline not stripped)", got, "4.1.0")
	}
}

func TestString_TrimsLeadingWhitespace(t *testing.T) {
	version.Version = "  4.1.0"
	got := version.String()
	if got != "4.1.0" {
		t.Errorf("String() = %q; want %q (leading whitespace not stripped)", got, "4.1.0")
	}
}

func TestString_TrimsBothSides(t *testing.T) {
	version.Version = "\t 4.1.0 \n"
	got := version.String()
	if got != "4.1.0" {
		t.Errorf("String() = %q; want %q (surrounding whitespace not stripped)", got, "4.1.0")
	}
}

func TestString_PlainVersion(t *testing.T) {
	version.Version = "4.1.0"
	got := version.String()
	if got != "4.1.0" {
		t.Errorf("String() = %q; want %q", got, "4.1.0")
	}
}

func TestString_DoesNotTrimInteriorSpaces(t *testing.T) {
	// Interior spaces are unusual in semver but must not be touched.
	version.Version = "4.1.0 beta"
	got := version.String()
	if got != "4.1.0 beta" {
		t.Errorf("String() = %q; want %q (interior space should be preserved)", got, "4.1.0 beta")
	}
}
