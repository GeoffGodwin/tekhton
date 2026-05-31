package crawler

import "testing"

// TestAnnotatePackageKnown covers literal-match arms drawn from the bash
// case statement. Each arm exists in the bash case; the table is the
// minimum that proves the literal map didn't drift.
func TestAnnotatePackageKnown(t *testing.T) {
	cases := []struct {
		pkg  string
		want string
	}{
		{"express", "Web framework"},
		{"react", "Frontend framework"},
		{"typescript", "TypeScript compiler"},
		{"jest", "Test framework"},
		{"pytest", "Test framework"},
		{"vite", "Build tool / bundler"},
		{"eslint", "Linter / formatter"},
		{"axios", "HTTP client"},
		{"lodash", "Utility library"},
		{"prisma", "ORM / database"},
		{"pg", "Database driver"},
		{"numpy", "Scientific computing"},
		{"pydantic", "Data validation"},
		{"celery", "Task queue"},
		{"tokio", "Core Rust library"},
		{"clap", "CLI argument parser"},
		// The bash case has an `echo)` arm — preserve literally.
		{"echo", "HTTP router"},
	}
	for _, c := range cases {
		if got := annotatePackage(c.pkg); got != c.want {
			t.Errorf("annotatePackage(%q) = %q, want %q", c.pkg, got, c.want)
		}
	}
}

// TestAnnotatePackageGlobs covers the glob arms (@angular/*, drizzle*,
// spring-boot*, angular*). path.Match runs against the literal package
// name; no anchoring needed.
func TestAnnotatePackageGlobs(t *testing.T) {
	cases := []struct {
		pkg  string
		want string
	}{
		{"@angular/core", "Frontend framework"},
		{"@angular/router", "Frontend framework"},
		{"angular", "Frontend framework"},
		{"angular-cli", "Frontend framework"},
		{"drizzle-orm", "ORM / database"},
		{"spring-boot-starter", "Application framework"},
		{"spring-boot", "Application framework"},
	}
	for _, c := range cases {
		if got := annotatePackage(c.pkg); got != c.want {
			t.Errorf("annotatePackage(%q) = %q, want %q", c.pkg, got, c.want)
		}
	}
}

// TestAnnotatePackageUnknown covers the catch-all `*)` arm — returns
// empty string for unknown packages.
func TestAnnotatePackageUnknown(t *testing.T) {
	for _, pkg := range []string{"unknown-pkg-xyz", "no-such-package", "", "react-router"} {
		if got := annotatePackage(pkg); got != "" {
			t.Errorf("annotatePackage(%q) = %q, want empty", pkg, got)
		}
	}
}
