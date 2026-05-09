package stagerunner

import (
	"context"
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
		proto.StageIntake:   {"lib/intake_helpers.sh", "lib/intake_verdict_handlers.sh"},
		proto.StageCoder:    {},
		proto.StageSecurity: {"lib/security_helpers.sh"},
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
		proto.StageDocs:    {"lib/docs_agent.sh"},
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

// TestBashAdapterRealHelperIntegration runs the BashAdapter with the real
// tekhton repository's common.sh and lib/intake_helpers.sh — not the minimal
// stubs used in other tests.  This exercises the primary observable behavior
// the M20 fix was meant to deliver: a stage that calls a function defined in
// a real helper file completes successfully, producing a valid envelope.
//
// The test is distinct from TestBashAdapterPerStageHelperSourced (which uses a
// hand-written stub helper) in that it proves the production files are
// sourceable and callable in a real subprocess environment.
func TestBashAdapterRealHelperIntegration(t *testing.T) {
	repoRoot := findRepoRoot(t)
	if repoRoot == "" {
		t.Skip("repository root not found; skipping real-helper integration test")
	}

	// Confirm required files are present before spawning a subprocess.
	for _, rel := range []string{"lib/common.sh", "lib/stage_envelope.sh", "lib/intake_helpers.sh"} {
		if _, err := os.Stat(filepath.Join(repoRoot, rel)); err != nil {
			t.Skipf("required file %s not found: %v", rel, err)
		}
	}

	proj := t.TempDir()

	// Stage script that calls _intake_content_hash — a pure function defined
	// in lib/intake_helpers.sh that hashes its argument with sha256sum.
	// The hash is returned as exit_reason so the test can verify it.
	stageDir := t.TempDir()
	stageScript := filepath.Join(stageDir, "intake.sh")
	const canaryInput = "real-helper-canary"
	stageBody := `run_stage_intake() {
    local result
    result=$(_intake_content_hash "` + canaryInput + `")
    printf '{"proto":"tekhton.stage.result.v1","stage":"intake","verdict":"pass","exit_reason":"%s","agent_calls":0,"duration_sec":0,"human_action_required":false}\n' "$result" > "$TEKHTON_STAGE_RESULT_FILE"
}
`
	if err := os.WriteFile(stageScript, []byte(stageBody), 0o755); err != nil {
		t.Fatalf("write stage script: %v", err)
	}

	a := &BashAdapter{
		TekhtonHome: repoRoot,
		ProjectDir:  proj,
		// LibHelpers is empty: only common.sh is sourced (hardcoded by
		// buildBashScript) plus the per-stage intake_helpers.sh below.
		// This avoids sourcing all 109 DefaultLibHelpers files in a unit test
		// while still proving real files are sourceable.
		LibHelpers: []string{},
		Stages: map[string]StageDef{
			proto.StageIntake: {
				Script:  stageScript, // absolute path — not joined with TekhtonHome
				Helpers: []string{"lib/intake_helpers.sh"},
			},
		},
	}
	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageIntake,
		ResultFile: filepath.Join(proj, "result.json"),
	}

	res, err := a.Run(context.Background(), req)
	if err != nil {
		t.Fatalf("Run with real helper: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Fatalf("verdict: got %q want pass", res.Verdict)
	}
	// _intake_content_hash returns a 64-character SHA-256 hex digest.
	if len(res.ExitReason) != 64 {
		t.Fatalf("expected 64-char SHA-256 hex in exit_reason, got %q (len=%d)",
			res.ExitReason, len(res.ExitReason))
	}
}
