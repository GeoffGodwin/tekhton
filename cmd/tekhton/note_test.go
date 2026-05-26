package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// runCLI executes the root command with args and returns stdout +
// stderr. Used by the note_test.go smoke tests to exercise the
// subcommand wiring end-to-end. Clears HUMAN_NOTES_FILE so tests
// don't accidentally pick up a pipeline.conf-supplied override from
// the developer's shell.
func runCLI(t *testing.T, args ...string) (string, string, error) {
	t.Helper()
	t.Setenv("HUMAN_NOTES_FILE", "")
	root := newRootCmd()
	out := &bytes.Buffer{}
	errBuf := &bytes.Buffer{}
	root.SetOut(out)
	root.SetErr(errBuf)
	root.SetArgs(args)
	err := root.Execute()
	return out.String(), errBuf.String(), err
}

func TestNoteHelp(t *testing.T) {
	out, _, err := runCLI(t, "note", "--help")
	if err != nil {
		t.Fatalf("note --help: %v", err)
	}
	// Acceptance criteria: must list at least 9 subcommands.
	for _, sub := range []string{"add", "list", "done", "reopen", "claim", "unclaim", "triage", "migrate", "rollback", "resolve"} {
		if !strings.Contains(out, sub) {
			t.Errorf("`note --help` missing subcommand %q", sub)
		}
	}
}

func TestNoteAddListDone(t *testing.T) {
	dir := t.TempDir()
	args := []string{"note", "add", "--project-dir", dir, "--tag", "BUG", "fix the thing"}
	out, _, err := runCLI(t, args...)
	if err != nil {
		t.Fatalf("note add: %v", err)
	}
	if !strings.Contains(out, "Added [BUG] note") {
		t.Errorf("add output: %s", out)
	}

	// File should now exist.
	if _, err := os.Stat(filepath.Join(dir, "HUMAN_NOTES.md")); err != nil {
		t.Fatalf("HUMAN_NOTES.md not created: %v", err)
	}

	// list --format json should emit the v1 envelope.
	jsonArgs := []string{"note", "list", "--project-dir", dir, "--format", "json"}
	out, _, err = runCLI(t, jsonArgs...)
	if err != nil {
		t.Fatalf("note list --format json: %v", err)
	}
	var env proto.NotesListV1
	if err := json.Unmarshal([]byte(out), &env); err != nil {
		t.Fatalf("decode json: %v\noutput: %s", err, out)
	}
	if env.Proto != proto.NotesListProtoV1 {
		t.Errorf("proto = %q, want %q", env.Proto, proto.NotesListProtoV1)
	}
	if env.Total != 1 {
		t.Errorf("total = %d, want 1", env.Total)
	}
	if len(env.Entries) != 1 {
		t.Fatalf("entries = %d, want 1", len(env.Entries))
	}
	id := env.Entries[0].ID
	if id == "" {
		t.Errorf("entry has no ID")
	}
	if env.Entries[0].Tag != "BUG" {
		t.Errorf("entry tag = %q, want BUG", env.Entries[0].Tag)
	}

	// done by ID.
	out, _, err = runCLI(t, "note", "done", "--project-dir", dir, id)
	if err != nil {
		t.Fatalf("note done: %v", err)
	}
	if !strings.Contains(out, "done: "+id) {
		t.Errorf("done output: %s", out)
	}
}

func TestNoteListPendingFilter(t *testing.T) {
	dir := t.TempDir()
	if _, _, err := runCLI(t, "note", "add", "--project-dir", dir, "--tag", "BUG", "bug1"); err != nil {
		t.Fatalf("add bug1: %v", err)
	}
	if _, _, err := runCLI(t, "note", "add", "--project-dir", dir, "--tag", "FEAT", "feat1"); err != nil {
		t.Fatalf("add feat1: %v", err)
	}
	out, _, err := runCLI(t, "note", "list", "--project-dir", dir, "--tag", "BUG", "--format", "md")
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if !strings.Contains(out, "bug1") {
		t.Errorf("BUG filter missing bug1: %s", out)
	}
	if strings.Contains(out, "feat1") {
		t.Errorf("BUG filter leaked feat1: %s", out)
	}
}

func TestNoteResolveRequiresTag(t *testing.T) {
	dir := t.TempDir()
	if _, _, err := runCLI(t, "note", "add", "--project-dir", dir, "--tag", "BUG", "x"); err != nil {
		t.Fatalf("add: %v", err)
	}
	_, _, err := runCLI(t, "note", "resolve", "--project-dir", dir)
	if err == nil {
		t.Fatalf("resolve without --tag should fail")
	}
}

func TestNoteExtract(t *testing.T) {
	dir := t.TempDir()
	if _, _, err := runCLI(t, "note", "add", "--project-dir", dir, "--tag", "BUG", "extract me"); err != nil {
		t.Fatalf("add: %v", err)
	}
	out, _, err := runCLI(t, "note", "extract", "--project-dir", dir)
	if err != nil {
		t.Fatalf("extract: %v", err)
	}
	if !strings.Contains(out, "- [BUG] extract me") {
		t.Errorf("extract output: %q", out)
	}
	if strings.Contains(out, "<!-- note:") {
		t.Errorf("metadata should be stripped by default")
	}
}
