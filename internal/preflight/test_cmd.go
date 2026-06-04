package preflight

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/drift"
)

// TestCmdCheck warns when MILESTONE_MODE is on and TEST_CMD is a recognized
// no-op. The default Tekhton init writes `TEST_CMD="true"` when ecosystem
// detection misses, which lets milestones tick green without actually running
// any test. Operators discover this only after a real failure escapes review.
//
// Default disposition is StatusWarn so existing intentional-no-op projects
// (non-test pipelines, very early scaffolding) are not hard-broken on upgrade.
// Setting REQUIRE_REAL_TEST_CMD=true escalates to StatusFail.
//
// HUMAN_ACTION_REQUIRED entry is appended on the first trip per run so the
// operator sees the issue surface in the post-run banner even if they skim
// past the preflight report.
type TestCmdCheck struct{}

// Name returns the canonical check name. Matches checkOrder.
func (TestCmdCheck) Name() string { return "test_cmd" }

// Run executes the no-op TEST_CMD audit. Skips entirely outside milestone
// mode — the warning would be noise on plain --task runs where the value
// has no acceptance-gate weight.
func (TestCmdCheck) Run(_ context.Context, in *Input) Result {
	if !milestoneModeOn(in) {
		return Result{}
	}
	raw := in.Getenv("TEST_CMD")
	if !IsNoopCommand(raw) {
		return Result{}
	}

	displayed := raw
	if displayed == "" {
		displayed = "<unset>"
	}
	detail := fmt.Sprintf(
		"TEST_CMD is a no-op (%s) — milestone acceptance will pass WITHOUT running tests. "+
			"Set a real TEST_CMD in pipeline.conf (e.g. `cargo test`, `npm test`, `go test ./...`).",
		displayed)

	require := strings.EqualFold(strings.TrimSpace(in.Getenv("REQUIRE_REAL_TEST_CMD")), "true")
	var f Finding
	if require {
		f = failF("TEST_CMD (no-op)", detail+" REQUIRE_REAL_TEST_CMD=true — blocking run.")
	} else {
		f = warn("TEST_CMD (no-op)", detail)
	}

	appendHumanActionForNoopTestCmd(in, detail)
	return Result{Findings: []Finding{f}}
}

// IsNoopCommand reports whether a configured TEST_CMD is a recognized
// no-op. The bash side honors `${TEST_CMD:-true}` so an unset variable and
// a literal `"true"` are operationally identical — both run `true`. The
// `:` builtin is the POSIX equivalent.
//
// Exported so the bash shim path and tests share one source of truth.
func IsNoopCommand(cmd string) bool {
	trimmed := strings.TrimSpace(cmd)
	switch trimmed {
	case "", "true", "/bin/true", "/usr/bin/true", ":":
		return true
	}
	return false
}

// milestoneModeOn mirrors the bash `[[ "${MILESTONE_MODE:-false}" = "true" ]]`
// idiom — strict-equals on the lowercase form of the value. Unset / empty /
// any non-"true" value all read as off, matching the orchestrator's own gating.
func milestoneModeOn(in *Input) bool {
	return strings.EqualFold(strings.TrimSpace(in.Getenv("MILESTONE_MODE")), "true")
}

// appendHumanActionForNoopTestCmd writes the finding to HUMAN_ACTION_REQUIRED.md
// via the canonical drift.HumanAction helper so the entry shares the same
// `- [ ] [date | Source: preflight] ...` shape every other preflight-driven
// action item uses. Failure to write is non-fatal — the in-report finding is
// the primary signal; the banner is the secondary one.
func appendHumanActionForNoopTestCmd(in *Input, detail string) {
	path := resolveHumanActionPath(in)
	if path == "" {
		return
	}
	h := drift.NewHumanAction(path)
	_ = h.Append("preflight", detail)
}

// resolveHumanActionPath mirrors the bash `${HUMAN_ACTION_FILE:-${TEKHTON_DIR:-.tekhton}/HUMAN_ACTION_REQUIRED.md}`
// idiom — honors an explicit HUMAN_ACTION_FILE override, otherwise nests
// under TEKHTON_DIR. Relative paths resolve against ProjectDir so callers
// don't have to thread it through.
func resolveHumanActionPath(in *Input) string {
	if in == nil || in.ProjectDir == "" {
		return ""
	}
	rel := in.Getenv("HUMAN_ACTION_FILE")
	if rel == "" {
		tekhtonDir := in.Getenv("TEKHTON_DIR")
		if tekhtonDir == "" {
			tekhtonDir = ".tekhton"
		}
		rel = filepath.Join(tekhtonDir, "HUMAN_ACTION_REQUIRED.md")
	}
	if filepath.IsAbs(rel) {
		return rel
	}
	return filepath.Join(in.ProjectDir, rel)
}
