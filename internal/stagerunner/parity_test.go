package stagerunner

import (
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// findRepoRoot walks up from the current working directory until it finds
// a go.mod file, which identifies the repository root.  Returns empty string
// when no go.mod is found (e.g., unusual CI layouts).
func findRepoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		return ""
	}
	for {
		if _, statErr := os.Stat(filepath.Join(dir, "go.mod")); statErr == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

// TestDefaultLibHelpersParityWithLegacy reads tekhton-legacy.sh and asserts
// that DefaultLibHelpers matches its global lib source block exactly — same
// entries, same order.  The two lists must stay in sync because they both
// describe the V3 global environment that stage scripts expect.  If
// tekhton-legacy.sh gains a new lib file, this test will fail until
// helpers.go is updated to match.
func TestDefaultLibHelpersParityWithLegacy(t *testing.T) {
	repoRoot := findRepoRoot(t)
	if repoRoot == "" {
		t.Skip("repository root (go.mod) not found; skipping parity check")
	}

	legacyPath := filepath.Join(repoRoot, "tekhton-legacy.sh")
	b, err := os.ReadFile(legacyPath)
	if os.IsNotExist(err) {
		t.Skip("tekhton-legacy.sh not found; skipping parity check")
	}
	if err != nil {
		t.Fatalf("read legacy: %v", err)
	}

	// Parse `source "${TEKHTON_HOME}/<path>"` lines from the global lib block.
	// The block starts at "# --- Library sources" and ends just before
	// "# Stage helpers".
	re := regexp.MustCompile(`source "\$\{TEKHTON_HOME\}/([^"]+)"`)
	var extracted []string
	inBlock := false
	for _, line := range strings.Split(string(b), "\n") {
		tr := strings.TrimSpace(line)
		if strings.Contains(tr, "# --- Library sources") {
			inBlock = true
		}
		if inBlock && strings.Contains(tr, "# Stage helpers") {
			break
		}
		if !inBlock {
			continue
		}
		m := re.FindStringSubmatch(tr)
		if m == nil {
			continue
		}
		path := m[1]
		// common.sh and stage_envelope.sh are sourced by buildBashScript
		// unconditionally and are excluded from DefaultLibHelpers.
		if path == "lib/common.sh" || path == "lib/stage_envelope.sh" {
			continue
		}
		extracted = append(extracted, path)
	}

	if len(extracted) == 0 {
		t.Fatal("no source lines extracted from tekhton-legacy.sh; check that " +
			"'# --- Library sources' and '# Stage helpers' markers are present")
	}

	if len(extracted) != len(DefaultLibHelpers) {
		t.Errorf("length mismatch: tekhton-legacy.sh global block has %d lib entries, "+
			"DefaultLibHelpers has %d", len(extracted), len(DefaultLibHelpers))
	}

	maxLen := len(extracted)
	if len(DefaultLibHelpers) > maxLen {
		maxLen = len(DefaultLibHelpers)
	}
	for i := 0; i < maxLen; i++ {
		var legacyEntry, goEntry string
		if i < len(extracted) {
			legacyEntry = extracted[i]
		}
		if i < len(DefaultLibHelpers) {
			goEntry = DefaultLibHelpers[i]
		}
		if legacyEntry != goEntry {
			t.Errorf("index %d: tekhton-legacy.sh=%q, DefaultLibHelpers=%q",
				i, legacyEntry, goEntry)
		}
	}
}

// TestDefaultLibHelpersFilesExist verifies that every file listed in
// DefaultLibHelpers is present in the repository.  A missing file causes the
// bash wrapper to fail under `set -e` with a silent exit, so this test acts
// as a filesystem-level guard against stale entries after lib reorganisations.
func TestDefaultLibHelpersFilesExist(t *testing.T) {
	repoRoot := findRepoRoot(t)
	if repoRoot == "" {
		t.Skip("repository root not found; skipping filesystem check")
	}
	for _, rel := range DefaultLibHelpers {
		path := filepath.Join(repoRoot, rel)
		if _, statErr := os.Stat(path); statErr != nil {
			t.Errorf("DefaultLibHelpers[%q] missing from repo: %v", rel, statErr)
		}
	}
}

// TestDefaultStageDefsHelperFilesExist verifies that every per-stage helper
// file listed in DefaultStageDefs.Helpers is present in the repository.
func TestDefaultStageDefsHelperFilesExist(t *testing.T) {
	repoRoot := findRepoRoot(t)
	if repoRoot == "" {
		t.Skip("repository root not found; skipping filesystem check")
	}
	for stage, def := range DefaultStageDefs {
		for _, rel := range def.Helpers {
			path := filepath.Join(repoRoot, rel)
			if _, statErr := os.Stat(path); statErr != nil {
				t.Errorf("DefaultStageDefs[%q].Helpers[%q] missing from repo: %v",
					stage, rel, statErr)
			}
		}
	}
}

// TestDefaultStageDefsHelpersMatchLegacy compares each stage's Helpers slice
// in DefaultStageDefs against the expected set derived from the per-stage
// source block in tekhton-legacy.sh (lines 961-983).  The expected set
// contains only the lib/*.sh and stages/*.sh helper files that appear between
// stage script source lines; the stage scripts themselves (.Script field) are
// excluded.
//
// A failure here means a stage-specific helper was added to tekhton-legacy.sh
// but not reflected in DefaultStageDefs — the adapter would fail at runtime
// when that helper's functions are called.
func TestDefaultStageDefsHelpersMatchLegacy(t *testing.T) {
	// wantHelpers is derived from a careful reading of tekhton-legacy.sh
	// lines 961-983.  Each entry is the relative path as it would appear in
	// StageDef.Helpers.  Stage script lines (stages/X.sh) are excluded.
	wantHelpers := map[string][]string{
		// m36.3: intake stage ported to internal/stages/intake/;
		// lib/intake_helpers.sh + lib/intake_verdict_handlers.sh deleted
		// alongside it. No bash helper sourced.
		proto.StageIntake: {},
		proto.StageCoder:  {},
		// m35.2: security stage ported to internal/stages/security/;
		// lib/security_helpers.sh deleted alongside it. No bash helper sourced.
		proto.StageSecurity: {},
		// stages/review_helpers.sh is sourced globally in tekhton-legacy.sh
		// (line 972) after stages/review.sh; stages/review.sh calls
		// _route_specialist_rework() (line 368), which is defined in
		// stages/review_helpers.sh.  The adapter must source it.
		proto.StageReview: {"stages/review_helpers.sh"},
		proto.StageTester: {
			"lib/test_audit_helpers.sh",
			"lib/test_audit_detection.sh",
			"lib/test_audit_verdict.sh",
			"lib/test_audit.sh",
			"lib/test_audit_symbols.sh",
			"lib/test_audit_sampler.sh",
		},
		proto.StageCleanup: {},
		// m34.1: docs stage ported to internal/stages/docs/; lib/docs_agent.sh
		// deleted alongside it. The DefaultStageDefs entry no longer lists any
		// bash helper because the Go path doesn't source one.
		proto.StageDocs: {},
	}

	for stage, want := range wantHelpers {
		def, ok := DefaultStageDefs[stage]
		if !ok {
			t.Errorf("stage %q missing from DefaultStageDefs", stage)
			continue
		}
		got := def.Helpers
		if got == nil {
			got = []string{}
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("stage %q Helpers mismatch:\n  got:  %v\n  want: %v", stage, got, want)
		}
	}
}

// TestBashAdapterRealHelperIntegration — removed in m36.3 alongside the
// deletion of lib/intake_helpers.sh. The bash-adapter per-stage helper
// sourcing path is still covered by TestBashAdapterPerStageHelperSourced
// (which writes its own stub helper) and the cross-stage parity at the
// review / tester boundaries.
