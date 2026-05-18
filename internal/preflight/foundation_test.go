package preflight

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestFoundationCheck_GoDepsPass(t *testing.T) {
	proj := t.TempDir()
	mustWrite(t, proj, "go.mod", "module x\n")
	mustWrite(t, proj, "go.sum", "")
	r := (FoundationCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	if findStatusByName(r.Findings, "Dependencies (Go)") != StatusPass {
		t.Errorf("expected pass for Dependencies (Go); got %v", r.Findings)
	}
}

func TestFoundationCheck_NodeModulesMissing_Fail(t *testing.T) {
	proj := t.TempDir()
	mustWrite(t, proj, "package-lock.json", `{}`)
	// Auto-fix disabled so the dummy `npm install` does not actually run
	// inside the test sandbox.
	in := &Input{ProjectDir: proj, Env: map[string]string{"PREFLIGHT_AUTO_FIX": "false"}}
	r := (FoundationCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "Dependencies (node_modules)") != StatusFail {
		t.Errorf("expected fail for Dependencies (node_modules); got %+v", r.Findings)
	}
}

func TestFoundationCheck_ToolSkipsBuiltins(t *testing.T) {
	proj := t.TempDir()
	in := &Input{ProjectDir: proj, Env: map[string]string{"ANALYZE_CMD": "true"}}
	r := (FoundationCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "Tools (ANALYZE_CMD)") != "" {
		t.Errorf("expected no finding for true; got %+v", r.Findings)
	}
}

func TestFoundationCheck_ToolMissing_Warn(t *testing.T) {
	proj := t.TempDir()
	in := &Input{
		ProjectDir: proj,
		Env:        map[string]string{"ANALYZE_CMD": "definitely-not-a-real-bin-xyz"},
	}
	r := (FoundationCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "Tools (ANALYZE_CMD)") != StatusWarn {
		t.Errorf("expected warn for missing tool; got %+v", r.Findings)
	}
}

func TestFoundationCheck_EnvVarsAllPresent_Pass(t *testing.T) {
	proj := t.TempDir()
	mustWrite(t, proj, ".env.example", "FOO=bar\nBAZ=qux\n")
	mustWrite(t, proj, ".env", "FOO=set\nBAZ=set\n")
	r := (FoundationCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	if findStatusByName(r.Findings, "Environment Variables") != StatusPass {
		t.Errorf("expected pass for Environment Variables; got %+v", r.Findings)
	}
}

func TestFoundationCheck_EnvVarsMissingKey_Warn(t *testing.T) {
	proj := t.TempDir()
	mustWrite(t, proj, ".env.example", "FOO=bar\nBAZ=qux\n")
	mustWrite(t, proj, ".env", "FOO=set\n")
	r := (FoundationCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	if findStatusByName(r.Findings, "Environment Variables") != StatusWarn {
		t.Errorf("expected warn for missing key; got %+v", r.Findings)
	}
}

func TestFoundationCheck_SkipsWhenNothingApplies(t *testing.T) {
	proj := t.TempDir()
	// Clear pipeline-config envs that could leak from the dev shell — the
	// Tools sub-check looks them up via Getenv → os.Getenv.
	for _, k := range []string{"ANALYZE_CMD", "BUILD_CHECK_CMD", "TEST_CMD", "UI_TEST_CMD"} {
		t.Setenv(k, "")
	}
	r := (FoundationCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	if len(r.Findings) != 0 {
		t.Errorf("empty project should produce no findings; got %+v", r.Findings)
	}
}

func mustWrite(t *testing.T, dir, name, body string) {
	t.Helper()
	full := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func findStatusByName(findings []Finding, name string) Status {
	for _, f := range findings {
		if f.Name == name {
			return f.Status
		}
	}
	return ""
}
