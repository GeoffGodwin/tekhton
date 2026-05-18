package preflight

import (
	"context"
	"testing"
)

func TestServicesInferCheck_Run_NoOp(t *testing.T) {
	// The infer Check is a registry placeholder — inference runs inside
	// ServicesCheck. The standalone Run must not produce findings.
	r := (ServicesInferCheck{}).Run(context.Background(), &Input{ProjectDir: t.TempDir()})
	if len(r.Findings) != 0 {
		t.Errorf("expected no findings from infer Check; got %+v", r.Findings)
	}
}

func TestInferFromCompose_ImageAndHostPort(t *testing.T) {
	proj := t.TempDir()
	body := `version: "3"
services:
  db:
    image: postgres:15
    ports:
      - "5433:5432"
  cache:
    image: redis:7
`
	mustWrite(t, proj, "docker-compose.yml", body)
	got := collectServices(&Input{ProjectDir: proj})
	if len(got) < 2 {
		t.Fatalf("expected >=2 inferred services; got %+v", got)
	}
	keys := map[string]bool{}
	for _, s := range got {
		keys[s.Key] = true
	}
	if !keys["postgres"] || !keys["redis"] {
		t.Errorf("expected postgres + redis; got %+v", got)
	}
	// Check the postgres entry pulled the host port mapping.
	for _, s := range got {
		if s.Key == "postgres" && s.HostPort != 5433 {
			t.Errorf("expected host port 5433 for postgres; got %d", s.HostPort)
		}
	}
}

func TestInferFromPackages_NodeDeps(t *testing.T) {
	proj := t.TempDir()
	mustWrite(t, proj, "package.json", `{"dependencies":{"pg":"^8","ioredis":"^5"}}`)
	got := collectServices(&Input{ProjectDir: proj})
	keys := map[string]bool{}
	for _, s := range got {
		keys[s.Key] = true
	}
	if !keys["postgres"] {
		t.Errorf("expected postgres from package.json; got %+v", got)
	}
	if !keys["redis"] {
		t.Errorf("expected redis from package.json; got %+v", got)
	}
}

func TestInferFromEnv_DatabaseURL(t *testing.T) {
	proj := t.TempDir()
	mustWrite(t, proj, ".env.example", "DATABASE_URL=postgres://...\n")
	got := collectServices(&Input{ProjectDir: proj})
	if len(got) != 1 || got[0].Key != "postgres" {
		t.Errorf("expected exactly postgres from .env.example; got %+v", got)
	}
	if got[0].Source != ".env.example" {
		t.Errorf("expected source=.env.example; got %s", got[0].Source)
	}
}

func TestInferFromCompose_DedupAcrossSources(t *testing.T) {
	proj := t.TempDir()
	mustWrite(t, proj, "docker-compose.yml", "services:\n  db:\n    image: postgres\n")
	mustWrite(t, proj, "package.json", `{"dependencies":{"pg":"^8"}}`)
	got := collectServices(&Input{ProjectDir: proj})
	// Both sources mention postgres; only the first should win.
	count := 0
	for _, s := range got {
		if s.Key == "postgres" {
			count++
		}
	}
	if count != 1 {
		t.Errorf("expected dedup to 1 postgres entry; got %d (%+v)", count, got)
	}
}
