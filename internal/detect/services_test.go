package detect

import (
	"context"
	"testing"
)

func TestServicesDetector_DockerCompose(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"docker-compose.yml": `services:
  api:
    build: ./api
  web:
    build: ./web
`,
		"api/package.json": `{}`,
		"web/go.mod":       "module x\n",
	})
	r, err := ServicesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(r.Findings) != 2 {
		t.Fatalf("want 2 services; got %d: %v", len(r.Findings), r.Findings)
	}
	got := map[string]string{}
	for _, row := range r.Findings {
		got[row["name"]] = row["tech_stack"]
	}
	if got["api"] != "node" {
		t.Errorf("api tech_stack: got %q, want node", got["api"])
	}
	if got["web"] != "go" {
		t.Errorf("web tech_stack: got %q, want go", got["web"])
	}
}

func TestServicesDetector_Procfile(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"Procfile": "web: bundle exec rackup\nworker: bundle exec sidekiq\n",
	})
	r, _ := ServicesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 2 {
		t.Fatalf("want 2 procfile services; got %d", len(r.Findings))
	}
}

func TestServicesDetector_None(t *testing.T) {
	dir := writeFixture(t, map[string]string{"README.md": "# x"})
	r, _ := ServicesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 0 {
		t.Errorf("expected no services; got %v", r.Findings)
	}
}
