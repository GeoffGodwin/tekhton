package runner

import (
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/config"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// kvLookup converts an AsKV slice back to a map for assertion convenience.
// Returns the LAST value seen for any duplicate key — duplicates would be
// a real bug, and the test that catches duplicates uses the slice directly.
func kvLookup(kv []string) map[string]string {
	m := make(map[string]string, len(kv))
	for _, line := range kv {
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		m[line[:eq]] = line[eq+1:]
	}
	return m
}

func TestCompose_RuntimeFlagsFromRequest(t *testing.T) {
	b := NewEnvBuilder(nil, LogContext{})
	req := &proto.RunRequestV1{
		Mode:             proto.RunModeMilestone,
		Milestone:        "m26",
		Task:             "stage env contract",
		AutoAdvance:      true,
		AutoAdvanceLimit: 3,
		HumanTag:         "FEAT",
	}
	got := b.Compose(req, nil)
	if !got.MilestoneMode {
		t.Error("MilestoneMode: got false; want true for --milestone run")
	}
	if got.CurrentMilestone != "m26" {
		t.Errorf("CurrentMilestone: got %q, want m26", got.CurrentMilestone)
	}
	if got.Task != "stage env contract" {
		t.Errorf("Task: got %q", got.Task)
	}
	if !got.AutoAdvance || got.AutoAdvanceLimit != 3 {
		t.Errorf("AutoAdvance/Limit: got %v/%d", got.AutoAdvance, got.AutoAdvanceLimit)
	}
	if got.HumanNotesTag != "FEAT" {
		t.Errorf("HumanNotesTag: got %q", got.HumanNotesTag)
	}
}

func TestCompose_LayeringOverridesBeatConfig(t *testing.T) {
	cfg := &config.Config{Values: map[string]string{
		"CLAUDE_STANDARD_MODEL": "claude-haiku-4-5",
		"INTAKE_MAX_TURNS":      "10",
	}}
	b := NewEnvBuilder(cfg, LogContext{})
	req := &proto.RunRequestV1{Task: "t"}
	overrides := map[string]string{
		"INTAKE_MAX_TURNS": "30",  // beats config
		"EXTRA_KEY":        "yes", // pure addition
	}
	got := b.Compose(req, overrides)
	if got.ConfigKeys["INTAKE_MAX_TURNS"] != "30" {
		t.Errorf("override should beat config: got %q", got.ConfigKeys["INTAKE_MAX_TURNS"])
	}
	if got.ConfigKeys["CLAUDE_STANDARD_MODEL"] != "claude-haiku-4-5" {
		t.Errorf("config preserved for non-overridden keys: got %q",
			got.ConfigKeys["CLAUDE_STANDARD_MODEL"])
	}
	if got.ConfigKeys["EXTRA_KEY"] != "yes" {
		t.Errorf("override-only keys should land in ConfigKeys: got %q",
			got.ConfigKeys["EXTRA_KEY"])
	}
}

// TestCompose_DefaultsOnly is the m26 acceptance criterion: when
// pipeline.conf is missing/unparseable the builder must still emit a
// populated env (run-request fields + no ConfigKeys), no panic, no nil
// deref. Exercises the "bare directory" path preflight is supposed to
// flag.
func TestCompose_DefaultsOnly(t *testing.T) {
	b := NewEnvBuilder(nil, LogContext{Dir: "/tmp/logs", Timestamp: "20260519_120000"})
	req := &proto.RunRequestV1{
		Mode:      proto.RunModeMilestone,
		Milestone: "m26",
		Task:      "stage env contract",
	}
	got := b.Compose(req, nil)
	if got == nil {
		t.Fatal("Compose returned nil with nil cfg")
	}
	if !got.MilestoneMode || got.CurrentMilestone != "m26" {
		t.Errorf("runtime flags lost in defaults-only path: %+v", got)
	}
	if got.LogFile == "" {
		t.Error("LogFile not synthesized in defaults-only path")
	}
	// ConfigKeys may be nil or empty — both acceptable. AsKV must still
	// produce a usable env regardless.
	kv := b.AsKV(got)
	m := kvLookup(kv)
	if m["MILESTONE_MODE"] != "true" {
		t.Errorf("MILESTONE_MODE not exported: %v", m["MILESTONE_MODE"])
	}
	if m["_CURRENT_MILESTONE"] != "m26" {
		t.Errorf("_CURRENT_MILESTONE not exported: %v", m["_CURRENT_MILESTONE"])
	}
}

func TestCompose_NilRequest(t *testing.T) {
	b := NewEnvBuilder(nil, LogContext{})
	got := b.Compose(nil, nil)
	if got == nil {
		t.Fatal("Compose returned nil for nil request")
	}
	if got.MilestoneMode {
		t.Error("MilestoneMode should default to false for nil request")
	}
}

// TestAsKV_RuntimeFlagsAlwaysExported guards the most important m26
// invariant: every runtime bash global is present in the env even when
// its value is empty / false, so the consumer's set -u never trips on
// `"$MILESTONE_MODE"` or `"$TASK"`.
func TestAsKV_RuntimeFlagsAlwaysExported(t *testing.T) {
	b := NewEnvBuilder(nil, LogContext{})
	kv := b.AsKV(b.Compose(&proto.RunRequestV1{}, nil))
	m := kvLookup(kv)
	want := []string{"MILESTONE_MODE", "_CURRENT_MILESTONE", "TASK",
		"AUTO_ADVANCE", "HUMAN_MODE", "HUMAN_NOTES_TAG"}
	for _, k := range want {
		if _, ok := m[k]; !ok {
			t.Errorf("AsKV missing required runtime flag %q (would crash set -u in bash)", k)
		}
	}
}

// TestAsKV_DoesNotShellQuote — exec.Cmd.Env is execve fodder, not a shell.
// Apostrophes, spaces, anything in a config value must pass through
// VERBATIM. Re-quoting (as config.EmitShell does for the eval path)
// would corrupt every value the bash subprocess reads.
func TestAsKV_DoesNotShellQuote(t *testing.T) {
	cfg := &config.Config{Values: map[string]string{
		"WITH_APOSTROPHE": "Geoff's value",
		"WITH_SPACE":      "hello world",
	}}
	b := NewEnvBuilder(cfg, LogContext{})
	kv := b.AsKV(b.Compose(&proto.RunRequestV1{}, nil))
	m := kvLookup(kv)
	if m["WITH_APOSTROPHE"] != "Geoff's value" {
		t.Errorf("AsKV must not re-quote apostrophes: got %q", m["WITH_APOSTROPHE"])
	}
	if m["WITH_SPACE"] != "hello world" {
		t.Errorf("AsKV must not re-quote spaces: got %q", m["WITH_SPACE"])
	}
}

func TestAsKV_DeterministicOrder(t *testing.T) {
	cfg := &config.Config{Values: map[string]string{
		"ZEBRA":  "z",
		"ALPHA":  "a",
		"MIDDLE": "m",
	}}
	b := NewEnvBuilder(cfg, LogContext{})
	env := b.Compose(&proto.RunRequestV1{}, nil)
	first := b.AsKV(env)
	second := b.AsKV(env)
	if strings.Join(first, "\n") != strings.Join(second, "\n") {
		t.Error("AsKV must be deterministic across calls")
	}
	// Spot-check: ALPHA precedes ZEBRA in the config-key section.
	alphaIdx := -1
	zebraIdx := -1
	for i, line := range first {
		if strings.HasPrefix(line, "ALPHA=") {
			alphaIdx = i
		}
		if strings.HasPrefix(line, "ZEBRA=") {
			zebraIdx = i
		}
	}
	if alphaIdx < 0 || zebraIdx < 0 || alphaIdx > zebraIdx {
		t.Errorf("ConfigKeys not sorted: alpha=%d zebra=%d", alphaIdx, zebraIdx)
	}
}

func TestLogContext_LogFileShape(t *testing.T) {
	lc := LogContext{Dir: "/tmp/logs", Timestamp: "20260519_120000"}
	req := &proto.RunRequestV1{Task: "Add OAuth Login"}
	want := "/tmp/logs/20260519_120000_add_oauth_login.log"
	if got := lc.LogFile(req); got != want {
		t.Errorf("LogFile: got %q, want %q", got, want)
	}
}

func TestLogContext_LogFile_FallsBackToMilestoneWhenTaskEmpty(t *testing.T) {
	lc := LogContext{Dir: "/tmp/logs", Timestamp: "20260519_120000"}
	req := &proto.RunRequestV1{Milestone: "m26"}
	want := "/tmp/logs/20260519_120000_m26.log"
	if got := lc.LogFile(req); got != want {
		t.Errorf("LogFile: got %q, want %q", got, want)
	}
}

func TestLogContext_LogFile_EmptyDirReturnsEmpty(t *testing.T) {
	lc := LogContext{Timestamp: "20260519_120000"}
	if got := lc.LogFile(&proto.RunRequestV1{Task: "t"}); got != "" {
		t.Errorf("LogFile with empty Dir: got %q, want empty", got)
	}
}

// TestTaskSlug directly exercises the unexported slug function used for
// log-file path synthesis. The bash-side slugifier lives in lib/common.sh;
// these cases establish the byte-level contract so a future bash→Go
// divergence fails in this test before reaching a scraper.
func TestTaskSlug(t *testing.T) {
	cases := []struct {
		name      string
		task      string
		milestone string
		want      string
	}{
		{"task_preferred_over_milestone", "Add OAuth", "m99", "add_oauth"},
		{"milestone_fallback_when_task_empty", "", "m26", "m26"},
		{"both_empty_returns_run", "", "", "run"},
		{"nil_req_returns_run", "", "", "run"}, // exercised via nil below
		{"uppercase_lowercased", "FIX TYPO", "", "fix_typo"},
		{"special_chars_collapsed", "fix: auth/session-bug", "", "fix_auth_session_bug"},
		{"leading_trailing_stripped", "  hello world  ", "", "hello_world"},
		{"numbers_preserved", "fix 3 bugs", "", "fix_3_bugs"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := &proto.RunRequestV1{Task: tc.task, Milestone: tc.milestone}
			got := taskSlug(req)
			if got != tc.want {
				t.Errorf("taskSlug(%q, %q) = %q, want %q", tc.task, tc.milestone, got, tc.want)
			}
		})
	}
	// nil request
	if got := taskSlug(nil); got != "run" {
		t.Errorf("taskSlug(nil) = %q, want run", got)
	}
}

// TestAsKV_SessionDir guards the TEKHTON_SESSION_DIR export rule: present
// when non-empty (so bash consumers don't trip on set -u), absent when empty
// (so defaults-only paths don't emit an empty env var that confuses callers
// expecting a real path).
func TestAsKV_SessionDir(t *testing.T) {
	b := NewEnvBuilder(nil, LogContext{SessionDir: "/tmp/run-abc"})
	kv := b.AsKV(b.Compose(&proto.RunRequestV1{}, nil))
	m := kvLookup(kv)
	if m["TEKHTON_SESSION_DIR"] != "/tmp/run-abc" {
		t.Errorf("TEKHTON_SESSION_DIR not exported with non-empty SessionDir: %v", m["TEKHTON_SESSION_DIR"])
	}

	b2 := NewEnvBuilder(nil, LogContext{})
	kv2 := b2.AsKV(b2.Compose(&proto.RunRequestV1{}, nil))
	m2 := kvLookup(kv2)
	if _, ok := m2["TEKHTON_SESSION_DIR"]; ok {
		t.Error("TEKHTON_SESSION_DIR should be absent when SessionDir is empty")
	}
}

// TestAsKV_AutoAdvanceLimitConditionalExport guards the rule that
// AUTO_ADVANCE_LIMIT is emitted only when > 0. The six always-exported
// runtime flags (MILESTONE_MODE etc.) must be present regardless; this
// test confirms the conditional-emit path for the limit field.
func TestAsKV_AutoAdvanceLimitConditionalExport(t *testing.T) {
	b := NewEnvBuilder(nil, LogContext{})

	// Zero limit → key must be absent.
	kvZero := b.AsKV(b.Compose(&proto.RunRequestV1{AutoAdvanceLimit: 0}, nil))
	mZero := kvLookup(kvZero)
	if _, ok := mZero["AUTO_ADVANCE_LIMIT"]; ok {
		t.Error("AUTO_ADVANCE_LIMIT should not be emitted when AutoAdvanceLimit=0")
	}

	// Positive limit → key must be present with correct value.
	kvPos := b.AsKV(b.Compose(&proto.RunRequestV1{AutoAdvanceLimit: 5}, nil))
	mPos := kvLookup(kvPos)
	if mPos["AUTO_ADVANCE_LIMIT"] != "5" {
		t.Errorf("AUTO_ADVANCE_LIMIT: got %q, want 5", mPos["AUTO_ADVANCE_LIMIT"])
	}
}

// TestCompose_HumanMode verifies that HUMAN_MODE is set to true exactly
// when the run-request mode is RunModeHuman, and false for all other modes.
// This mirrors the bash-side `$HUMAN_MODE` check in lib/orchestrate_main.sh.
func TestCompose_HumanMode(t *testing.T) {
	b := NewEnvBuilder(nil, LogContext{})
	cases := []struct {
		mode      string
		milestone string
		wantHuman bool
		wantMS    bool
	}{
		{proto.RunModeHuman, "", true, false},
		{proto.RunModeMilestone, "m26", false, true},
		{proto.RunModeTask, "", false, false},
		{proto.RunModeResume, "", false, false},
		// Milestone set but mode is task → MilestoneMode still true (|| check)
		{proto.RunModeTask, "m26", false, true},
	}
	for _, tc := range cases {
		t.Run(tc.mode+"/"+tc.milestone, func(t *testing.T) {
			got := b.Compose(&proto.RunRequestV1{Mode: tc.mode, Milestone: tc.milestone}, nil)
			if got.HumanMode != tc.wantHuman {
				t.Errorf("HumanMode: got %v, want %v", got.HumanMode, tc.wantHuman)
			}
			if got.MilestoneMode != tc.wantMS {
				t.Errorf("MilestoneMode: got %v, want %v", got.MilestoneMode, tc.wantMS)
			}
		})
	}
}
