package crawler

import (
	"os"
	"path/filepath"
	"testing"
)

func writeManifest(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestParseNodeDepsEmpty(t *testing.T) {
	dir := t.TempDir()
	writeManifest(t, dir, "package.json", `{"name":"x","version":"0"}`)
	g := &DependencyGraph{}
	parseNodeDeps(dir, "", g)
	if len(g.Manifests) != 1 || g.Manifests[0].Manager != "npm" {
		t.Errorf("expected npm manifest row, got %+v", g.Manifests)
	}
	if len(g.KeyDependencies) != 0 {
		t.Errorf("empty deps should yield zero key dependencies, got %+v", g.KeyDependencies)
	}
}

func TestParseNodeDepsSimple(t *testing.T) {
	dir := t.TempDir()
	writeManifest(t, dir, "package.json", `{
  "name": "x",
  "dependencies": {
    "react": "^18.0.0",
    "express": "4.17.1"
  },
  "devDependencies": {
    "jest": "29.0.0"
  }
}`)
	g := &DependencyGraph{}
	parseNodeDeps(dir, "", g)
	// Bash-parity counts include the section-header line (e.g.
	// `"dependencies": {`) — that's the source of the "spurious"
	// dependencies / devDependencies key entries observed in real
	// dependencies.json output. See extractWithHeader in deps.go.
	if g.Manifests[0].Deps != 3 || g.Manifests[0].DevDeps != 2 {
		t.Errorf("dep counts (bash-parity): %+v", g.Manifests[0])
	}
	// Look for real package names anywhere in the key deps slice.
	names := map[string]bool{}
	for _, d := range g.KeyDependencies {
		names[d.Name] = true
	}
	for _, want := range []string{"react", "express", "jest"} {
		if !names[want] {
			t.Errorf("missing expected dep %q in %v", want, names)
		}
	}
}

func TestParseNodeDepsMalformed(t *testing.T) {
	dir := t.TempDir()
	// Missing closing brace — extractJSONKeys is best-effort.
	writeManifest(t, dir, "package.json", `{"dependencies": {"react": "^18.0.0"`)
	g := &DependencyGraph{}
	parseNodeDeps(dir, "", g)
	// Should not crash; at least one manifest row recorded.
	if len(g.Manifests) != 1 {
		t.Errorf("expected one manifest even for malformed input")
	}
}

func TestParseCargoDepsSimpleAndTable(t *testing.T) {
	dir := t.TempDir()
	writeManifest(t, dir, "Cargo.toml", `[package]
name = "x"
version = "0.1.0"

[dependencies]
serde = "1.0"
tokio = { version = "1.0", features = ["full"] }
local-crate = { path = "../local" }

[dev-dependencies]
mock-it = "0.5"
`)
	g := &DependencyGraph{}
	parseCargoDeps(dir, "", g)
	if g.Manifests[0].Deps != 3 || g.Manifests[0].DevDeps != 1 {
		t.Errorf("cargo dep counts: %+v", g.Manifests[0])
	}
	versions := map[string]string{}
	for _, d := range g.KeyDependencies {
		versions[d.Name] = d.Version
	}
	if versions["serde"] != "1.0" {
		t.Errorf("serde version: %v", versions)
	}
	if versions["tokio"] != "1.0" {
		t.Errorf("tokio table form: %v", versions)
	}
	if versions["local-crate"] != "workspace" {
		t.Errorf("local-crate should fall back to 'workspace', got %q", versions["local-crate"])
	}
}

func TestParseCargoDepsEmpty(t *testing.T) {
	dir := t.TempDir()
	writeManifest(t, dir, "Cargo.toml", `[package]
name = "x"
version = "0.1.0"
`)
	g := &DependencyGraph{}
	parseCargoDeps(dir, "", g)
	if g.Manifests[0].Deps != 0 || g.Manifests[0].DevDeps != 0 {
		t.Errorf("empty cargo manifest should have zero deps")
	}
}

func TestParsePythonDeps(t *testing.T) {
	dir := t.TempDir()
	writeManifest(t, dir, "pyproject.toml", `[project]
name = "x"
dependencies = [
    "requests>=2.0",
    "click",
    "pydantic~=2.0",
]
`)
	g := &DependencyGraph{}
	parsePythonDeps(dir, "", g)
	if g.Manifests[0].Deps != 3 {
		t.Errorf("python deps count: %+v", g.Manifests[0])
	}
	if g.KeyDependencies[0].Name != "requests" {
		t.Errorf("first dep: %q", g.KeyDependencies[0].Name)
	}
	if g.KeyDependencies[1].Version != "any" {
		t.Errorf("constraint-less dep should be 'any', got %q", g.KeyDependencies[1].Version)
	}
}

func TestParseGoDeps(t *testing.T) {
	dir := t.TempDir()
	writeManifest(t, dir, "go.mod", `module x

go 1.21

require (
	github.com/spf13/cobra v1.8.1
	github.com/fsnotify/fsnotify v1.9.0
)

require (
	github.com/inconshreveable/mousetrap v1.1.0 // indirect
)
`)
	g := &DependencyGraph{}
	parseGoDeps(dir, "", g)
	if g.Manifests[0].Deps != 3 {
		t.Errorf("go deps count should pick up both blocks: %+v", g.Manifests[0])
	}
}

func TestParseGemfileDeps(t *testing.T) {
	dir := t.TempDir()
	writeManifest(t, dir, "Gemfile", `source 'https://rubygems.org'

gem 'rails', '~> 7.0'
gem 'puma'
gem "rspec", "3.12"
# comment
`)
	g := &DependencyGraph{}
	parseGemfileDeps(dir, "", g)
	if g.Manifests[0].Deps != 3 {
		t.Errorf("gem count: %+v", g.Manifests[0])
	}
	want := map[string]string{"rails": "~> 7.0", "puma": "any", "rspec": "3.12"}
	for _, d := range g.KeyDependencies {
		if want[d.Name] != d.Version {
			t.Errorf("gem %q: got version %q, want %q", d.Name, d.Version, want[d.Name])
		}
	}
}

func TestParseGradleDeps(t *testing.T) {
	dir := t.TempDir()
	writeManifest(t, dir, "build.gradle", `dependencies {
    implementation 'org.springframework.boot:spring-boot-starter:2.7.0'
    testImplementation 'junit:junit:4.13'
    api 'com.google.guava:guava:31.0'
}
`)
	g := &DependencyGraph{}
	parseGradleDeps(dir, "", g)
	if g.Manifests[0].Deps != 3 {
		t.Errorf("gradle dep count: %+v", g.Manifests[0])
	}
}

func TestParsePomDeps(t *testing.T) {
	dir := t.TempDir()
	writeManifest(t, dir, "pom.xml", `<project>
  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter</artifactId>
      <version>2.7.0</version>
    </dependency>
    <dependency>
      <groupId>junit</groupId>
      <artifactId>junit</artifactId>
    </dependency>
  </dependencies>
</project>
`)
	g := &DependencyGraph{}
	parsePomDeps(dir, "", g)
	if g.Manifests[0].Deps != 2 {
		t.Errorf("pom deps count: %+v", g.Manifests[0])
	}
	if g.KeyDependencies[0].Name != "org.springframework.boot:spring-boot-starter" {
		t.Errorf("first dep should be group:artifact, got %q", g.KeyDependencies[0].Name)
	}
}

func TestDetectMonorepoSubprojects(t *testing.T) {
	dir := t.TempDir()
	for _, sub := range []string{"packages/a", "packages/b", "apps/web"} {
		path := filepath.Join(dir, sub)
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
		writeManifest(t, path, "package.json", `{"name":"x"}`)
	}
	subs := detectMonorepoSubprojects(dir)
	if len(subs) != 3 {
		t.Errorf("expected 3 monorepo subprojects, got %d: %v", len(subs), subs)
	}
}
