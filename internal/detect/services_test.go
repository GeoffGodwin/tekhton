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

func TestServicesDetector_K8sDeploymentAndService(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"k8s/api-deployment.yaml": `apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 1
`,
		"k8s/api-service.yaml": `apiVersion: v1
kind: Service
metadata:
  name: api-svc
spec:
  selector:
    app: api
`,
	})
	r, _ := ServicesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	names := map[string]bool{}
	for _, row := range r.Findings {
		if row["source"] == "k8s" {
			names[row["name"]] = true
		}
	}
	if !names["api"] {
		t.Errorf("expected k8s Deployment 'api' finding; got findings=%v", r.Findings)
	}
	if !names["api-svc"] {
		t.Errorf("expected k8s Service 'api-svc' finding; got findings=%v", r.Findings)
	}
}

func TestServicesDetector_K8sInDeployDir(t *testing.T) {
	// The detector checks "deploy/" in addition to "k8s/".
	dir := writeFixture(t, map[string]string{
		"deploy/web.yaml": `apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
`,
	})
	r, _ := ServicesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	names := map[string]bool{}
	for _, row := range r.Findings {
		if row["source"] == "k8s" {
			names[row["name"]] = true
		}
	}
	if !names["web"] {
		t.Errorf("expected k8s 'web' Deployment finding in deploy/; got findings=%v", r.Findings)
	}
}

func TestServicesDetector_K8sDeduplicate(t *testing.T) {
	// The same service name appearing twice should only produce one finding.
	yaml := `apiVersion: v1
kind: Service
metadata:
  name: my-service
`
	dir := writeFixture(t, map[string]string{
		"k8s/a.yaml": yaml,
		"k8s/b.yaml": yaml,
	})
	r, _ := ServicesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	count := 0
	for _, row := range r.Findings {
		if row["source"] == "k8s" && row["name"] == "my-service" {
			count++
		}
	}
	if count != 1 {
		t.Errorf("expected deduplicated single my-service finding; got %d", count)
	}
}

func TestServicesDetector_K8sIgnoresNonKindDocs(t *testing.T) {
	// A YAML in k8s/ without a Deployment/Service/StatefulSet kind is skipped.
	dir := writeFixture(t, map[string]string{
		"k8s/configmap.yaml": `apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
`,
	})
	r, _ := ServicesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	for _, row := range r.Findings {
		if row["source"] == "k8s" {
			t.Errorf("expected no k8s finding for ConfigMap; got %v", row)
		}
	}
}

func TestServicesDetector_ProcfileSourceField(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"Procfile": "web: ruby app.rb\nclock: ruby clock.rb\n",
	})
	r, _ := ServicesDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	for _, row := range r.Findings {
		if row["source"] != "procfile" {
			t.Errorf("procfile entry has wrong source: got %q, want procfile", row["source"])
		}
	}
}
