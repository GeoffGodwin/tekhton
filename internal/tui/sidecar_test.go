package tui

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNewSetsDefaults(t *testing.T) {
	s := New("/home", "/proj")
	if s.SessionDir != "/tmp" {
		t.Fatalf("session dir default: %q", s.SessionDir)
	}
	if s.TickMs != 500 || s.EventLines != 60 || s.WatchdogSecs != 300 {
		t.Fatalf("tick/event/watchdog defaults wrong")
	}
}

func TestStartReturnsDisabledWhenFlagged(t *testing.T) {
	s := New(t.TempDir(), t.TempDir())
	s.Disabled = true
	err := s.Start(context.Background())
	if err == nil || !errors.Is(err, ErrDisabled) {
		t.Fatalf("want ErrDisabled; got %v", err)
	}
}

func TestStartReturnsDisabledWhenNoTekhtonHome(t *testing.T) {
	s := &Sidecar{}
	err := s.Start(context.Background())
	if err == nil || !errors.Is(err, ErrDisabled) {
		t.Fatalf("want ErrDisabled; got %v", err)
	}
}

func TestStartReturnsDisabledWhenNoTUIScript(t *testing.T) {
	tmp := t.TempDir()
	s := New(tmp, t.TempDir())
	s.IsTTY = func() bool { return true }
	err := s.Start(context.Background())
	if err == nil || !errors.Is(err, ErrDisabled) {
		t.Fatalf("want ErrDisabled; got %v", err)
	}
}

func TestStopReturnsErrWhenNotStarted(t *testing.T) {
	s := New("", "")
	err := s.Stop(context.Background(), false)
	if err == nil || !errors.Is(err, ErrNotStarted) {
		t.Fatalf("want ErrNotStarted; got %v", err)
	}
}

func TestKillStaleNoOpsWhenAbsent(t *testing.T) {
	s := New("", t.TempDir())
	// Should not panic / error.
	s.killStale()
}

func TestKillStaleClearsExistingPIDFile(t *testing.T) {
	dir := t.TempDir()
	s := New("", dir)
	pidPath := filepath.Join(dir, ".claude", "tui_sidecar.pid")
	if err := os.MkdirAll(filepath.Dir(pidPath), 0o755); err != nil {
		t.Fatal(err)
	}
	// PID 1 is always present on POSIX, but we can't kill it as non-root.
	// Use a guaranteed-stale PID instead — INT_MAX-ish pid is harmless.
	if err := os.WriteFile(pidPath, []byte("999999\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s.killStale()
	if _, err := os.Stat(pidPath); !os.IsNotExist(err) {
		t.Fatalf("pidfile should be removed; got err=%v", err)
	}
}

func TestWriteInitialEmitsValidJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tui_status.json")
	if err := WriteInitial(path, "task", []string{"intake", "coder"}); err != nil {
		t.Fatalf("write: %v", err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var parsed map[string]any
	if err := json.Unmarshal(b, &parsed); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if parsed["run_mode"] != "task" {
		t.Fatalf("run_mode missing/wrong: %v", parsed["run_mode"])
	}
	if !strings.Contains(string(b), "tekhton.tui.status.v1") {
		t.Fatalf("schema marker missing")
	}
}

func TestWriteFinalSetsCompleteFlag(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tui_status.json")
	if err := WriteFinal(path, "success"); err != nil {
		t.Fatalf("write: %v", err)
	}
	b, _ := os.ReadFile(path)
	var parsed map[string]any
	_ = json.Unmarshal(b, &parsed)
	if parsed["complete"] != true {
		t.Fatalf("complete flag not set")
	}
	if parsed["verdict"] != "success" {
		t.Fatalf("verdict not set: %v", parsed["verdict"])
	}
}

func TestTrimWhitespace(t *testing.T) {
	tests := map[string]string{
		"":         "",
		"  abc  ":  "abc",
		"\nabc\t":  "abc",
		"abc":      "abc",
		"\r\n12\n": "12",
	}
	for in, want := range tests {
		got := string(trimWhitespace([]byte(in)))
		if got != want {
			t.Fatalf("trim %q: got %q want %q", in, got, want)
		}
	}
}

func TestResolvePythonExplicit(t *testing.T) {
	dir := t.TempDir()
	py := filepath.Join(dir, "python")
	if err := os.WriteFile(py, []byte("#!/bin/sh"), 0o755); err != nil {
		t.Fatal(err)
	}
	s := &Sidecar{VenvPython: py, ProjectDir: dir}
	got, ok := s.resolvePython()
	if !ok || got != py {
		t.Fatalf("want %q ok; got %q ok=%v", py, got, ok)
	}
}

func TestShouldActivateNoTTY(t *testing.T) {
	tmp := t.TempDir()
	tools := filepath.Join(tmp, "tools")
	_ = os.MkdirAll(tools, 0o755)
	_ = os.WriteFile(filepath.Join(tools, "tui.py"), []byte("# stub"), 0o644)
	s := New(tmp, t.TempDir())
	s.IsTTY = func() bool { return false }
	ok, reason := s.shouldActivate()
	if ok {
		t.Fatalf("expected !ok")
	}
	if reason != "non-interactive TTY" {
		t.Fatalf("reason: %q", reason)
	}
}
