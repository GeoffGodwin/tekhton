package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestDetectCmd_HelpExitsZero verifies `tekhton detect summary --help`
// (acceptance criterion: subcommand registered, Hidden, runnable).
func TestDetectCmd_HelpExitsZero(t *testing.T) {
	cmd := newRootCmd()
	cmd.SetArgs([]string{"detect", "summary", "--help"})
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	if err := cmd.Execute(); err != nil {
		t.Fatalf("expected exit 0 for --help; got %v", err)
	}
	got := out.String()
	if !strings.Contains(got, "summary") {
		t.Errorf("help output missing 'summary'; got %q", got)
	}
}

// TestDetectCmd_JSONShape covers the --json contract: valid JSON with a
// .languages array that includes the typescript entry from a synthetic
// fixture. Acceptance criterion calls this out specifically.
func TestDetectCmd_JSONShape(t *testing.T) {
	tmp := t.TempDir()
	mustWrite(t, tmp, "package.json", `{"name":"x"}`)
	mustWrite(t, tmp, "tsconfig.json", `{}`)

	cmd := newRootCmd()
	cmd.SetArgs([]string{"detect", "summary", "--json", "--project-dir", tmp})
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	if err := cmd.Execute(); err != nil {
		t.Fatalf("expected exit 0; got %v", err)
	}
	var payload struct {
		Languages []struct {
			Name       string `json:"name"`
			Confidence string `json:"confidence"`
			Manifest   string `json:"manifest"`
		} `json:"languages"`
	}
	if err := json.Unmarshal(out.Bytes(), &payload); err != nil {
		t.Fatalf("json unmarshal: %v\n--- output ---\n%s", err, out.String())
	}
	found := false
	for _, l := range payload.Languages {
		if l.Name == "typescript" && l.Manifest == "package.json" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected typescript entry in languages; got %+v", payload.Languages)
	}
}

// TestDetectCmd_MarkdownDefault asserts the default output is markdown
// (no --json or --markdown flag) and contains the report header.
func TestDetectCmd_MarkdownDefault(t *testing.T) {
	tmp := t.TempDir()
	mustWrite(t, tmp, "go.mod", "module x\n")
	cmd := newRootCmd()
	cmd.SetArgs([]string{"detect", "summary", "--project-dir", tmp})
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	if err := cmd.Execute(); err != nil {
		t.Fatalf("expected exit 0; got %v", err)
	}
	if !strings.Contains(out.String(), "## Tech Stack Detection Report") {
		t.Errorf("expected markdown report header; got:\n%s", out.String())
	}
	if !strings.Contains(out.String(), "| go | medium | go.mod |") {
		t.Errorf("expected go language row; got:\n%s", out.String())
	}
}

// TestDetectCmd_BothFlagsRejected covers the mutual-exclusion guard
// between --json and --markdown.
func TestDetectCmd_BothFlagsRejected(t *testing.T) {
	tmp := t.TempDir()
	cmd := newRootCmd()
	cmd.SetArgs([]string{"detect", "summary", "--json", "--markdown", "--project-dir", tmp})
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	err := cmd.Execute()
	if err == nil {
		t.Fatalf("expected error when both --json and --markdown set; got nil")
	}
	if !strings.Contains(err.Error(), "mutually exclusive") {
		t.Errorf("expected 'mutually exclusive' error; got %v", err)
	}
}

func mustWrite(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
}

// TestRegistrationOrder enforces the exact m29.2 detector registration
// sequence. Reordering changes attach() demux, baselines, and bash-caller
// JSON consumers; this test fails red on any drift.
func TestRegistrationOrder(t *testing.T) {
	want := []string{
		"languages",
		"commands",
		"workspaces",
		"services",
		"ci",
		"infrastructure",
		"test_frameworks",
		"doc_quality",
		"ai_artifacts",
	}
	dets := registeredDetectors()
	if len(dets) != len(want) {
		t.Fatalf("registered detector count: got %d, want %d", len(dets), len(want))
	}
	for i, d := range dets {
		if d.Name() != want[i] {
			t.Errorf("registration order drift at index %d: got %q, want %q", i, d.Name(), want[i])
		}
	}
}
