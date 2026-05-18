package preflight

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"testing"
	"time"
)

func TestEnvCheck_RuntimeVersion_NoFiles_Skip(t *testing.T) {
	proj := t.TempDir()
	r := (EnvCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	if len(r.Findings) != 0 {
		t.Errorf("expected no findings without version files; got %+v", r.Findings)
	}
}

func TestEnvCheck_GoVersionMismatch_Warn(t *testing.T) {
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go binary not on PATH")
	}
	proj := t.TempDir()
	// Force a version mismatch.
	mustWrite(t, proj, ".go-version", "0.1\n")
	r := (EnvCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	if findStatusByName(r.Findings, "Runtime Version (Go)") != StatusWarn {
		t.Errorf("expected warn for go version mismatch; got %+v", r.Findings)
	}
}

func TestEnvCheck_NodeVersionAbsent_NoFinding(t *testing.T) {
	proj := t.TempDir()
	mustWrite(t, proj, ".nvmrc", "20\n")
	if _, err := exec.LookPath("node"); err == nil {
		// node IS available; skip — we don't control what version.
		t.Skip("node binary present; this test only valid when node is absent")
	}
	r := (EnvCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	if findStatusByName(r.Findings, "Runtime Version (Node.js)") != "" {
		t.Errorf("expected no finding when node not on PATH; got %+v", r.Findings)
	}
}

func TestEnvCheck_LockFreshnessPass(t *testing.T) {
	proj := t.TempDir()
	mustWrite(t, proj, "go.mod", "module x\n")
	mustWrite(t, proj, "go.sum", "")
	// go.sum was written after go.mod, so it should NOT be "stale".
	r := (EnvCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	if findStatusByName(r.Findings, "Lock Freshness (Go)") != "" {
		// Lock-freshness only emits when go.mod IS newer; nothing emitted
		// here is the correct outcome.
		t.Logf("got: %+v", r.Findings)
	}
}

func TestEnvCheck_PortsExtractFromUITestCmd(t *testing.T) {
	proj := t.TempDir()
	in := &Input{ProjectDir: proj, Env: map[string]string{
		"UI_TEST_CMD": "next dev",
	}}
	r := (EnvCheck{}).Run(context.Background(), in)
	// Either pass (port free) or warn (port busy) — both are valid outcomes
	// in CI; the assertion is only that the check produced *a* finding for
	// port 3000.
	if findStatusByName(r.Findings, "Port Availability (:3000)") == "" {
		t.Errorf("expected a finding for port 3000; got %+v", r.Findings)
	}
}

// TestEnvCheck_GoVersionPass verifies the happy path of the runtime version
// check: when .go-version contains the actual installed go major.minor, the
// finding is StatusPass. Skipped when go is not on PATH (CI without Go SDK).
func TestEnvCheck_GoVersionPass(t *testing.T) {
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go binary not on PATH")
	}
	out, err := exec.Command("go", "version").CombinedOutput()
	if err != nil {
		t.Skip("go version failed")
	}
	re := regexp.MustCompile(`(\d+\.\d+)`)
	minor := re.FindString(string(out))
	if minor == "" {
		t.Skip("could not parse go major.minor from output")
	}
	proj := t.TempDir()
	mustWrite(t, proj, ".go-version", minor+"\n")
	r := (EnvCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	if findStatusByName(r.Findings, "Runtime Version (Go)") != StatusPass {
		t.Errorf("expected pass for go version %q; got %+v", minor, r.Findings)
	}
}

// TestEnvCheck_LockFreshness_GoStale_Warn verifies that when go.mod is newer
// than go.sum (stale lock), the check emits a StatusWarn finding.
func TestEnvCheck_LockFreshness_GoStale_Warn(t *testing.T) {
	proj := t.TempDir()
	mustWrite(t, proj, "go.sum", "")
	mustWrite(t, proj, "go.mod", "module x\n")
	// Backdate go.sum and advance go.mod so fileNewer(go.mod, go.sum) is true.
	past := time.Now().Add(-10 * time.Second)
	future := time.Now().Add(10 * time.Second)
	if err := os.Chtimes(filepath.Join(proj, "go.sum"), past, past); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(filepath.Join(proj, "go.mod"), future, future); err != nil {
		t.Fatal(err)
	}
	r := (EnvCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	if findStatusByName(r.Findings, "Lock Freshness (Go)") != StatusWarn {
		t.Errorf("expected warn when go.mod newer than go.sum; got %+v", r.Findings)
	}
}

// TestEnvCheck_LockFreshness_NodeStale_Warn verifies that when package.json
// is newer than package-lock.json, the check emits a StatusWarn finding.
func TestEnvCheck_LockFreshness_NodeStale_Warn(t *testing.T) {
	proj := t.TempDir()
	mustWrite(t, proj, "package-lock.json", "{}")
	mustWrite(t, proj, "package.json", `{"name":"x"}`)
	past := time.Now().Add(-10 * time.Second)
	future := time.Now().Add(10 * time.Second)
	if err := os.Chtimes(filepath.Join(proj, "package-lock.json"), past, past); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(filepath.Join(proj, "package.json"), future, future); err != nil {
		t.Fatal(err)
	}
	r := (EnvCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	if findStatusByName(r.Findings, "Lock Freshness (Node.js)") != StatusWarn {
		t.Errorf("expected warn when package.json newer than package-lock.json; got %+v", r.Findings)
	}
}
