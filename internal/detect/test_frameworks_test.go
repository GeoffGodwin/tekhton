package detect

import (
	"context"
	"testing"
)

func TestTestFrameworksDetector_Pytest(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"pytest.ini": "[pytest]\n",
	})
	r, _ := TestFrameworksDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 1 || r.Findings[0]["name"] != "pytest" {
		t.Errorf("pytest: got %v", r.Findings)
	}
}

func TestTestFrameworksDetector_JestVitestCoexist(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"package.json": `{"devDependencies":{"jest":"*","vitest":"*"}}`,
	})
	r, _ := TestFrameworksDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	got := map[string]bool{}
	for _, row := range r.Findings {
		got[row["name"]] = true
	}
	if !got["jest"] || !got["vitest"] {
		t.Errorf("expected both jest and vitest; got %v", r.Findings)
	}
}

func TestTestFrameworksDetector_None(t *testing.T) {
	dir := writeFixture(t, map[string]string{"README.md": "# x"})
	r, _ := TestFrameworksDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 0 {
		t.Errorf("expected no test frameworks; got %v", r.Findings)
	}
}

func TestTestFrameworksDetector_GoTest(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"go.mod":          "module example.com/x\n\ngo 1.22\n",
		"pkg/foo_test.go": "package pkg\n\nimport \"testing\"\n\nfunc TestFoo(t *testing.T) {}\n",
	})
	r, _ := TestFrameworksDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["name"] == "go-test" {
			found = true
			if row["confidence"] != "high" {
				t.Errorf("go-test confidence: got %q, want high", row["confidence"])
			}
		}
	}
	if !found {
		t.Fatalf("expected go-test finding; got %v", r.Findings)
	}
}

func TestTestFrameworksDetector_Rust(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"Cargo.toml": "[package]\nname = \"my-crate\"\nversion = \"0.1.0\"\n",
	})
	r, _ := TestFrameworksDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["name"] == "cargo-test" {
			found = true
			if row["config"] != "Cargo.toml" {
				t.Errorf("cargo-test config: got %q, want Cargo.toml", row["config"])
			}
		}
	}
	if !found {
		t.Fatalf("expected cargo-test finding; got %v", r.Findings)
	}
}

func TestTestFrameworksDetector_RubyRSpec(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"Gemfile": "source 'https://rubygems.org'\ngem 'rspec'\n",
	})
	r, _ := TestFrameworksDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["name"] == "rspec" {
			found = true
			if row["config"] != "Gemfile" {
				t.Errorf("rspec config: got %q, want Gemfile", row["config"])
			}
		}
	}
	if !found {
		t.Fatalf("expected rspec finding; got %v", r.Findings)
	}
}

func TestTestFrameworksDetector_JavaJUnit(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"build.gradle": "dependencies {\n  testImplementation 'junit:junit:4.13'\n}\n",
	})
	r, _ := TestFrameworksDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["name"] == "junit" {
			found = true
			if row["confidence"] != "high" {
				t.Errorf("junit confidence: got %q, want high", row["confidence"])
			}
		}
	}
	if !found {
		t.Fatalf("expected junit finding; got %v", r.Findings)
	}
}

func TestTestFrameworksDetector_CSharpXUnit(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"MyApp.Tests.csproj": `<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
    <PackageReference Include="xunit" Version="2.4.1" />
  </ItemGroup>
</Project>
`,
	})
	r, _ := TestFrameworksDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["name"] == "xunit" {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected xunit finding; got %v", r.Findings)
	}
}

func TestTestFrameworksDetector_DartFlutter(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"pubspec.yaml": "name: my_app\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n",
	})
	r, _ := TestFrameworksDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["name"] == "flutter-test" {
			found = true
			if row["config"] != "pubspec.yaml" {
				t.Errorf("flutter-test config: got %q, want pubspec.yaml", row["config"])
			}
		}
	}
	if !found {
		t.Fatalf("expected flutter-test finding; got %v", r.Findings)
	}
}

func TestTestFrameworksDetector_ShellTests(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"tests/run_tests.sh": "#!/usr/bin/env bash\nset -euo pipefail\n",
	})
	r, _ := TestFrameworksDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["name"] == "shell-tests" {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected shell-tests finding; got %v", r.Findings)
	}
}

func TestTestFrameworksDetector_BatsFiles(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		"tests/unit.bats": "#!/usr/bin/env bats\n@test 'example' { true; }\n",
	})
	r, _ := TestFrameworksDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["name"] == "bats" {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected bats finding; got %v", r.Findings)
	}
}
