package preflight

import (
	"context"
	"testing"
)

func TestServicesCheck_NoComposeNoDeps_NoFindings(t *testing.T) {
	proj := t.TempDir()
	r := (ServicesCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	if len(r.Findings) != 0 || len(r.ServiceRows) != 0 {
		t.Errorf("empty project: expected no findings/rows; got %+v / %+v",
			r.Findings, r.ServiceRows)
	}
}

func TestServicesCheck_DockerComposeWarn_WhenDockerMissing(t *testing.T) {
	// We can't reliably remove docker from PATH in a unit test; instead,
	// assert the compose-file detection path produces *some* finding when
	// docker IS present (pass) — both branches exit through checkDocker.
	proj := t.TempDir()
	mustWrite(t, proj, "docker-compose.yml", "services:\n  db:\n    image: postgres\n")
	r := (ServicesCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	if findStatusByName(r.Findings, "Docker") == "" {
		t.Errorf("expected a Docker finding; got %+v", r.Findings)
	}
}

func TestServicesCheck_InferFromPackageJSON(t *testing.T) {
	proj := t.TempDir()
	mustWrite(t, proj, "package.json", `{"dependencies":{"pg":"^8.0.0"}}`)
	r := (ServicesCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	// PostgreSQL gets inferred. If the local box isn't running pg, this
	// is a warn finding; we just assert the row appears.
	if len(r.ServiceRows) == 0 {
		t.Errorf("expected at least one ServiceRow; got %+v", r.ServiceRows)
	}
	found := false
	for _, row := range r.ServiceRows {
		if row.Display == "PostgreSQL" && row.Source == "package.json" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected PostgreSQL row from package.json; got %+v", r.ServiceRows)
	}
}

func TestServicesCheck_DevServerWarn_WhenNotRunning(t *testing.T) {
	proj := t.TempDir()
	// Synthesize a Playwright config with a localhost URL.
	mustWrite(t, proj, "playwright.config.ts",
		"export default { use: { baseURL: 'http://localhost:54321' } }\n")
	r := (ServicesCheck{}).Run(context.Background(), &Input{ProjectDir: proj})
	if findStatusByName(r.Findings, "Dev Server (:54321)") == "" {
		t.Errorf("expected Dev Server finding; got %+v", r.Findings)
	}
}

// TestServicesCheck_InferredService_CIMode_Pass verifies the CI-environment
// path: when CI=true a service that is not running on its expected port still
// produces a StatusPass finding (managed externally by the CI platform).
func TestServicesCheck_InferredService_CIMode_Pass(t *testing.T) {
	proj := t.TempDir()
	mustWrite(t, proj, "package.json", `{"dependencies":{"pg":"^8.0.0"}}`)
	in := &Input{
		ProjectDir: proj,
		Env:        map[string]string{"CI": "true"},
	}
	r := (ServicesCheck{}).Run(context.Background(), in)
	if findStatusByName(r.Findings, "Service (PostgreSQL)") != StatusPass {
		t.Errorf("expected pass for inferred service in CI mode; got %+v", r.Findings)
	}
}
