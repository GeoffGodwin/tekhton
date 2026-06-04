package config

import (
	"testing"
)

// TestEveryDefaultLandsInANamedSection guards the operator-facing
// pipeline.conf reference: every variable in the defaults table must
// match a SectionRule in pipelineConfSections, OR explicitly land in
// the "Misc Runtime" / "File & Directory Paths" buckets if it doesn't
// fit anywhere else. The "Uncategorized" fallback should be empty on
// every commit — if it isn't, someone added a new default without
// thinking about where operators would find it.
func TestEveryDefaultLandsInANamedSection(t *testing.T) {
	cfg := &Config{Values: map[string]string{}, KeysSet: map[string]bool{}}
	cfg.LoadDefaultsOnly(LoadOptions{SuppressDiagnostics: true})

	if len(cfg.Values) == 0 {
		t.Fatal("LoadDefaultsOnly produced 0 keys; cannot validate sectioning")
	}

	var uncategorized []string
	for k := range cfg.Values {
		if SectionFor(k) == "Uncategorized" {
			uncategorized = append(uncategorized, k)
		}
	}
	if len(uncategorized) > 0 {
		t.Errorf("%d default(s) landed in the Uncategorized bucket — add a "+
			"SectionRule in internal/config/sections.go so operators can "+
			"find them in pipeline.conf:\n  %v",
			len(uncategorized), uncategorized)
	}
}

// TestSectionRulesAreOrderedSensibly is a smoke test that confirms the
// section table doesn't accidentally hide variables behind a broader
// rule. We don't enforce a specific order here; we just verify a couple
// of known specific-vs-broad pairs route correctly.
func TestSectionRulesAreOrderedSensibly(t *testing.T) {
	cases := []struct {
		key  string
		want string
	}{
		// PROJECT_VERSION_* must beat the generic PROJECT_* exact list
		{"PROJECT_VERSION_STRATEGY", "Project Versioning"},
		{"PROJECT_NAME", "Project Identity & Paths"},
		// Commands beat the generic _FILE / _DIR fallback
		{"TEST_CMD", "Commands (Build / Test / Analyze)"},
		// Milestone catches MILESTONE_* even when the name ends in _FILE
		{"MILESTONE_MANIFEST", "Milestone Mode"},
		// Models bucket gets the CLAUDE_*_MODEL family
		{"CLAUDE_CODER_MODEL", "Models"},
		// Indexer beats the generic _FILE fallback for REPO_MAP keys
		{"REPO_MAP_TOKEN_BUDGET", "Indexer & Repo Map"},
		// File/Dir fallback catches generic *_FILE / *_DIR
		{"PIPELINE_STATE_FILE", "Pipeline Stage Order"},
	}
	for _, c := range cases {
		got := SectionFor(c.key)
		if got != c.want {
			t.Errorf("SectionFor(%q) = %q, want %q", c.key, got, c.want)
		}
	}
}
