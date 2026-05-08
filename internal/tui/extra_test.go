package tui

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func TestPIDStatusFileGettersDefault(t *testing.T) {
	s := New("/x", "/y")
	if s.PID() != 0 {
		t.Fatalf("PID before start should be 0; got %d", s.PID())
	}
	if s.StatusFile() != "" {
		t.Fatalf("StatusFile before start should be empty; got %q", s.StatusFile())
	}
}

func TestWritePIDFileAndRemove(t *testing.T) {
	dir := t.TempDir()
	s := New("", dir)
	s.writePIDFile(424242)
	pidPath := filepath.Join(dir, ".claude", "tui_sidecar.pid")
	data, err := os.ReadFile(pidPath)
	if err != nil {
		t.Fatalf("pidfile: %v", err)
	}
	if string(data) != "424242" {
		t.Fatalf("pid contents: %q", string(data))
	}
	s.removePIDFile()
	if _, err := os.Stat(pidPath); !os.IsNotExist(err) {
		t.Fatalf("pidfile should be removed; got %v", err)
	}
}

func TestStatusFileIsAtomic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tui_status.json")
	if err := atomicWriteJSON(path, map[string]any{"hello": "world"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("tmpfile leaked: %v", err)
	}
}

func TestStartSpawnsRealProcess(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("posix-only spawn test")
	}
	tekhton := t.TempDir()
	tools := filepath.Join(tekhton, "tools")
	if err := os.MkdirAll(tools, 0o755); err != nil {
		t.Fatal(err)
	}
	// Stub Python script — sleeps so the process exists when Stop fires.
	script := "#!/bin/sh\nexec sleep 30\n"
	if err := os.WriteFile(filepath.Join(tools, "tui.py"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	proj := t.TempDir()
	venvDir := filepath.Join(proj, ".claude", "indexer-venv", "bin")
	if err := os.MkdirAll(venvDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Fake python binary that always reports rich is importable, then runs
	// the script via /bin/sh.
	fakePy := "#!/bin/sh\nif [ \"$1\" = \"-c\" ]; then exit 0; fi\nshift; exec /bin/sh -c \"$@\"\n"
	pyPath := filepath.Join(venvDir, "python")
	if err := os.WriteFile(pyPath, []byte(fakePy), 0o755); err != nil {
		t.Fatal(err)
	}

	s := New(tekhton, proj)
	s.IsTTY = func() bool { return true }
	s.SessionDir = t.TempDir()
	if err := s.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if s.PID() == 0 {
		t.Fatalf("PID not set after Start")
	}
	// Stop should not error.
	if err := s.Stop(context.Background(), false); err != nil {
		t.Fatalf("Stop: %v", err)
	}
}

func TestWaitForExitTimeoutFallsThrough(t *testing.T) {
	// Construct a Sidecar with a fake-but-real long-running command so
	// waitForExit hits its deadline.
	if runtime.GOOS == "windows" {
		t.Skip("posix-only")
	}
	tekhton := t.TempDir()
	tools := filepath.Join(tekhton, "tools")
	_ = os.MkdirAll(tools, 0o755)
	_ = os.WriteFile(filepath.Join(tools, "tui.py"), []byte("#!/bin/sh\nsleep 5\n"), 0o755)

	proj := t.TempDir()
	venvDir := filepath.Join(proj, ".claude", "indexer-venv", "bin")
	_ = os.MkdirAll(venvDir, 0o755)
	_ = os.WriteFile(filepath.Join(venvDir, "python"),
		[]byte("#!/bin/sh\nif [ \"$1\" = \"-c\" ]; then exit 0; fi\nshift; exec /bin/sh -c \"$@\"\n"), 0o755)

	s := New(tekhton, proj)
	s.IsTTY = func() bool { return true }
	s.SessionDir = t.TempDir()
	if err := s.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}
	// waitForExit with a 50ms deadline; the sleep keeps the proc alive.
	start := time.Now()
	s.waitForExit(context.Background(), 50*time.Millisecond)
	elapsed := time.Since(start)
	if elapsed < 40*time.Millisecond {
		t.Fatalf("waitForExit returned too quickly: %v", elapsed)
	}
	_ = s.Stop(context.Background(), false)
}

func TestResolvePythonFallback(t *testing.T) {
	dir := t.TempDir()
	// No python binary anywhere.
	s := New("", dir)
	if _, ok := s.resolvePython(); ok {
		t.Fatalf("expected resolvePython to fail when no candidates exist")
	}
}
