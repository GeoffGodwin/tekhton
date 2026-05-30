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
