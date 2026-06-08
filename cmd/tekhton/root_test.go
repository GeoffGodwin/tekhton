package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/version"
)

// TestRootCmd_BareInvocationReturnsError verifies that calling the root
// command with no subcommand returns an error (prints help, exits non-zero).
// This is the primary m01.1 acceptance criterion: unknown invocations print
// help and exit non-zero.
func TestRootCmd_BareInvocationReturnsError(t *testing.T) {
	cmd := newRootCmd()
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetArgs([]string{})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("bare root invocation: expected non-nil error, got nil")
	}
	if !strings.Contains(err.Error(), "no subcommand specified") {
		t.Errorf("bare root invocation: error = %q; want to contain %q", err.Error(), "no subcommand specified")
	}
}

// TestRootCmd_BareInvocationPrintsHelp verifies that the bare root invocation
// emits help text (Usage/Available Commands section).
func TestRootCmd_BareInvocationPrintsHelp(t *testing.T) {
	cmd := newRootCmd()
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetArgs([]string{})
	_ = cmd.Execute()
	got := out.String()
	if !strings.Contains(got, "Usage:") {
		t.Errorf("bare root invocation: output %q does not contain %q", got, "Usage:")
	}
}

// TestRootCmd_VersionFlagPrintsVersion verifies that --version prints the
// trimmed version string (from internal/version.String()).
func TestRootCmd_VersionFlagPrintsVersion(t *testing.T) {
	version.Version = "4.99.0\n"
	cmd := newRootCmd()
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetArgs([]string{"--version"})
	err := cmd.Execute()
	if err != nil {
		t.Fatalf("--version: unexpected error: %v", err)
	}
	got := strings.TrimSpace(out.String())
	if got != "4.99.0" {
		t.Errorf("--version: output = %q; want %q", got, "4.99.0")
	}
}

// TestRootCmd_HelpFlagSucceeds verifies that --help exits without error and
// prints help content.
func TestRootCmd_HelpFlagSucceeds(t *testing.T) {
	cmd := newRootCmd()
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetArgs([]string{"--help"})
	err := cmd.Execute()
	if err != nil {
		t.Errorf("--help: expected no error, got %v", err)
	}
	got := out.String()
	if !strings.Contains(got, "tekhton") {
		t.Errorf("--help: output %q does not mention binary name", got)
	}
}

// TestRootCmd_VersionTemplateProducesOnlyVersion verifies the version template
// is set to emit only the version number (no "tekhton version" prefix that
// Cobra would add by default).
func TestRootCmd_VersionTemplateProducesOnlyVersion(t *testing.T) {
	version.Version = "1.2.3"
	cmd := newRootCmd()
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	cmd.SetArgs([]string{"--version"})
	_ = cmd.Execute()
	got := strings.TrimSpace(out.String())
	// Must not contain "version" keyword prefix (Cobra default: "tekhton version 1.2.3")
	if strings.Contains(got, "version") {
		t.Errorf("--version: output %q contains 'version' keyword; want bare version number only", got)
	}
	if got != "1.2.3" {
		t.Errorf("--version: output = %q; want %q", got, "1.2.3")
	}
}
