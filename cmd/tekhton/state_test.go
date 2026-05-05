package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/state"
)

// ---------------------------------------------------------------------------
// parseFieldPairs
// ---------------------------------------------------------------------------

func TestParseFieldPairs_Valid(t *testing.T) {
	pairs, err := parseFieldPairs([]string{"exit_stage=coder", "review_cycle=3"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(pairs) != 2 {
		t.Fatalf("want 2 pairs, got %d", len(pairs))
	}
	if pairs[0].key != "exit_stage" || pairs[0].val != "coder" {
		t.Errorf("pair[0]: got {%q, %q}, want {exit_stage, coder}", pairs[0].key, pairs[0].val)
	}
	if pairs[1].key != "review_cycle" || pairs[1].val != "3" {
		t.Errorf("pair[1]: got {%q, %q}, want {review_cycle, 3}", pairs[1].key, pairs[1].val)
	}
}

func TestParseFieldPairs_Empty(t *testing.T) {
	pairs, err := parseFieldPairs(nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(pairs) != 0 {
		t.Errorf("want 0 pairs, got %d", len(pairs))
	}
}

func TestParseFieldPairs_EmptyValue(t *testing.T) {
	// "key=" is valid — empty value clears the field in applyField
	pairs, err := parseFieldPairs([]string{"notes="})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(pairs) != 1 || pairs[0].key != "notes" || pairs[0].val != "" {
		t.Errorf("empty-val pair: got %+v", pairs)
	}
}

func TestParseFieldPairs_NoEquals_Error(t *testing.T) {
	_, err := parseFieldPairs([]string{"nodivider"})
	if err == nil {
		t.Error("expected error for K without =, got nil")
	}
	if !strings.Contains(err.Error(), "K=V") {
		t.Errorf("error message does not mention K=V format: %v", err)
	}
}

func TestParseFieldPairs_LeadingEquals_Error(t *testing.T) {
	// "=val" has an empty key — eq is at index 0, which is <= 0, so error.
	_, err := parseFieldPairs([]string{"=val"})
	if err == nil {
		t.Error("expected error for =val (empty key), got nil")
	}
}

func TestParseFieldPairs_ValueContainsEquals(t *testing.T) {
	// "key=a=b" should parse as key="key", val="a=b"
	pairs, err := parseFieldPairs([]string{"resume_flag=--milestone=3"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if pairs[0].val != "--milestone=3" {
		t.Errorf("val with inner '=': got %q, want --milestone=3", pairs[0].val)
	}
}

// ---------------------------------------------------------------------------
// applyField — first-class string fields
// ---------------------------------------------------------------------------

func TestApplyField_FirstClassString(t *testing.T) {
	snap := &proto.StateSnapshotV1{}
	applyField(snap, "exit_stage", "tester")
	if snap.ExitStage != "tester" {
		t.Errorf("ExitStage: got %q, want tester", snap.ExitStage)
	}
}

func TestApplyField_FirstClassStringCaseInsensitive(t *testing.T) {
	// Tag matching is case-insensitive per applyField contract.
	snap := &proto.StateSnapshotV1{}
	applyField(snap, "EXIT_STAGE", "review")
	if snap.ExitStage != "review" {
		t.Errorf("case-insensitive: ExitStage got %q, want review", snap.ExitStage)
	}
}

func TestApplyField_MultipleStrings(t *testing.T) {
	snap := &proto.StateSnapshotV1{}
	applyField(snap, "exit_stage", "coder")
	applyField(snap, "exit_reason", "blockers_remain")
	applyField(snap, "resume_task", "Implement m03")
	applyField(snap, "milestone_id", "m03")
	if snap.ExitStage != "coder" || snap.ExitReason != "blockers_remain" ||
		snap.ResumeTask != "Implement m03" || snap.MilestoneID != "m03" {
		t.Errorf("multi-field apply failed: %+v", snap)
	}
}

// ---------------------------------------------------------------------------
// applyField — first-class int fields
// ---------------------------------------------------------------------------

func TestApplyField_FirstClassInt(t *testing.T) {
	snap := &proto.StateSnapshotV1{}
	applyField(snap, "review_cycle", "5")
	if snap.ReviewCycle != 5 {
		t.Errorf("ReviewCycle: got %d, want 5", snap.ReviewCycle)
	}
}

func TestApplyField_AllIntFields(t *testing.T) {
	snap := &proto.StateSnapshotV1{}
	applyField(snap, "pipeline_attempt", "3")
	applyField(snap, "agent_calls_total", "42")
	applyField(snap, "review_cycle", "2")
	if snap.PipelineAttempt != 3 || snap.AgentCallsTotal != 42 || snap.ReviewCycle != 2 {
		t.Errorf("int fields: %+v", snap)
	}
}

func TestApplyField_IntParseFailureFallsToExtra(t *testing.T) {
	// Non-numeric value for an int field goes to Extra — the "best-effort write"
	// contract: parse failures never crash or lose the value silently.
	snap := &proto.StateSnapshotV1{}
	applyField(snap, "review_cycle", "not-a-number")
	if snap.ReviewCycle != 0 {
		t.Errorf("ReviewCycle should remain 0, got %d", snap.ReviewCycle)
	}
	if snap.Extra["review_cycle"] != "not-a-number" {
		t.Errorf("expected Extra[review_cycle]=not-a-number, got %v", snap.Extra)
	}
}

// ---------------------------------------------------------------------------
// applyField — Extra fallthrough and deletion
// ---------------------------------------------------------------------------

func TestApplyField_UnknownKeyGoesToExtra(t *testing.T) {
	snap := &proto.StateSnapshotV1{}
	applyField(snap, "human_mode", "true")
	applyField(snap, "git_diff_stat", " 3 files changed")
	if snap.Extra["human_mode"] != "true" {
		t.Errorf("Extra[human_mode]: got %q", snap.Extra["human_mode"])
	}
	if snap.Extra["git_diff_stat"] != " 3 files changed" {
		t.Errorf("Extra[git_diff_stat]: got %q", snap.Extra["git_diff_stat"])
	}
}

func TestApplyField_EmptyValDeletesFromExtra(t *testing.T) {
	snap := &proto.StateSnapshotV1{
		Extra: map[string]string{"human_mode": "true"},
	}
	applyField(snap, "human_mode", "")
	if _, ok := snap.Extra["human_mode"]; ok {
		t.Error("empty val should delete the key from Extra")
	}
}

func TestApplyField_EmptyValOnAbsentExtraKey_NoOp(t *testing.T) {
	snap := &proto.StateSnapshotV1{}
	// Deleting a key that was never set must not panic or create the Extra map.
	applyField(snap, "nonexistent_key", "")
	if snap.Extra != nil {
		t.Errorf("Extra map should remain nil, got %v", snap.Extra)
	}
}

func TestApplyField_InitializesExtraMapOnFirstSet(t *testing.T) {
	snap := &proto.StateSnapshotV1{}
	if snap.Extra != nil {
		t.Fatal("precondition: Extra must be nil before test")
	}
	applyField(snap, "custom_key", "value")
	if snap.Extra == nil {
		t.Error("Extra map not initialized on first unknown-key write")
	}
}

// ---------------------------------------------------------------------------
// lookupField — first-class string fields
// ---------------------------------------------------------------------------

func TestLookupField_FirstClassString(t *testing.T) {
	snap := &proto.StateSnapshotV1{
		ExitStage:   "review",
		ExitReason:  "blockers_remain",
		ResumeTask:  "Implement m03",
		MilestoneID: "m03",
	}
	cases := map[string]string{
		"exit_stage":   "review",
		"exit_reason":  "blockers_remain",
		"resume_task":  "Implement m03",
		"milestone_id": "m03",
	}
	for field, want := range cases {
		got := lookupField(snap, field)
		if got != want {
			t.Errorf("lookupField(%q): got %q, want %q", field, got, want)
		}
	}
}

func TestLookupField_CaseInsensitive(t *testing.T) {
	snap := &proto.StateSnapshotV1{ExitStage: "tester"}
	if got := lookupField(snap, "EXIT_STAGE"); got != "tester" {
		t.Errorf("case-insensitive lookup: got %q, want tester", got)
	}
}

func TestLookupField_EmptyStringField(t *testing.T) {
	snap := &proto.StateSnapshotV1{}
	// Empty string fields return "" — same signal as absent.
	got := lookupField(snap, "exit_stage")
	if got != "" {
		t.Errorf("empty string field: got %q, want empty", got)
	}
}

// ---------------------------------------------------------------------------
// lookupField — first-class int fields
// ---------------------------------------------------------------------------

func TestLookupField_IntNonZeroReturnsString(t *testing.T) {
	snap := &proto.StateSnapshotV1{ReviewCycle: 3, PipelineAttempt: 7}
	if got := lookupField(snap, "review_cycle"); got != "3" {
		t.Errorf("review_cycle: got %q, want 3", got)
	}
	if got := lookupField(snap, "pipeline_attempt"); got != "7" {
		t.Errorf("pipeline_attempt: got %q, want 7", got)
	}
}

func TestLookupField_IntZeroReturnsEmpty(t *testing.T) {
	// Zero-valued ints are omitempty — the bash shim treats "" as absent,
	// matching the JSON omit-on-zero semantics.
	snap := &proto.StateSnapshotV1{ReviewCycle: 0}
	got := lookupField(snap, "review_cycle")
	if got != "" {
		t.Errorf("zero int should return empty, got %q", got)
	}
}

// ---------------------------------------------------------------------------
// lookupField — Extra and unknown keys
// ---------------------------------------------------------------------------

func TestLookupField_Extra(t *testing.T) {
	snap := &proto.StateSnapshotV1{
		Extra: map[string]string{"human_mode": "true", "git_diff_stat": "4 files"},
	}
	if got := lookupField(snap, "human_mode"); got != "true" {
		t.Errorf("Extra[human_mode]: got %q, want true", got)
	}
	if got := lookupField(snap, "git_diff_stat"); got != "4 files" {
		t.Errorf("Extra[git_diff_stat]: got %q, want '4 files'", got)
	}
}

func TestLookupField_UnknownKeyReturnsEmpty(t *testing.T) {
	snap := &proto.StateSnapshotV1{}
	got := lookupField(snap, "totally_unknown_field")
	if got != "" {
		t.Errorf("unknown key: got %q, want empty", got)
	}
}

func TestLookupField_NilExtraMapDoesNotPanic(t *testing.T) {
	snap := &proto.StateSnapshotV1{} // Extra is nil
	got := lookupField(snap, "any_extra_key")
	if got != "" {
		t.Errorf("nil Extra: got %q, want empty", got)
	}
}

// ---------------------------------------------------------------------------
// resolveStatePath
// ---------------------------------------------------------------------------

func TestResolveStatePath_ExplicitPath(t *testing.T) {
	got := resolveStatePath("/tmp/explicit.json")
	if got != "/tmp/explicit.json" {
		t.Errorf("explicit path: got %q, want /tmp/explicit.json", got)
	}
}

func TestResolveStatePath_EnvFallback(t *testing.T) {
	t.Setenv("PIPELINE_STATE_FILE", "/env/state.json")
	got := resolveStatePath("")
	if got != "/env/state.json" {
		t.Errorf("env fallback: got %q, want /env/state.json", got)
	}
}

func TestResolveStatePath_ExplicitWinsOverEnv(t *testing.T) {
	t.Setenv("PIPELINE_STATE_FILE", "/env/state.json")
	got := resolveStatePath("/explicit/wins.json")
	if got != "/explicit/wins.json" {
		t.Errorf("explicit over env: got %q, want /explicit/wins.json", got)
	}
}

func TestResolveStatePath_BothEmpty(t *testing.T) {
	t.Setenv("PIPELINE_STATE_FILE", "")
	got := resolveStatePath("")
	if got != "" {
		t.Errorf("both empty: got %q, want empty", got)
	}
}

// ---------------------------------------------------------------------------
// state write subcommand — stdin JSON → file (AC #coverage-gap-2)
// ---------------------------------------------------------------------------

func TestStateWriteCmd_ValidJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")

	snap := &proto.StateSnapshotV1{
		ExitStage:   "coder",
		ResumeTask:  "Implement m03 wedge",
		MilestoneID: "m03",
	}
	snap.EnsureProto()
	data, err := snap.MarshalIndented()
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	// Redirect os.Stdin for the duration of this test.
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	_, _ = w.Write(data)
	w.Close()
	oldStdin := os.Stdin
	os.Stdin = r
	t.Cleanup(func() {
		os.Stdin = oldStdin
		r.Close()
	})

	cmd := newStateWriteCmd()
	cmd.SetArgs([]string{"--path", path})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("state write: %v", err)
	}

	got, err := state.New(path).Read()
	if err != nil {
		t.Fatalf("Read after write: %v", err)
	}
	if got.ExitStage != "coder" {
		t.Errorf("ExitStage: got %q, want coder", got.ExitStage)
	}
	if got.ResumeTask != "Implement m03 wedge" {
		t.Errorf("ResumeTask: got %q, want 'Implement m03 wedge'", got.ResumeTask)
	}
	if got.MilestoneID != "m03" {
		t.Errorf("MilestoneID: got %q, want m03", got.MilestoneID)
	}
	if got.Proto != proto.StateProtoV1 {
		t.Errorf("Proto: got %q, want %q", got.Proto, proto.StateProtoV1)
	}
}

func TestStateWriteCmd_InvalidJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")

	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	_, _ = w.Write([]byte("{not valid json"))
	w.Close()
	oldStdin := os.Stdin
	os.Stdin = r
	t.Cleanup(func() {
		os.Stdin = oldStdin
		r.Close()
	})

	cmd := newStateWriteCmd()
	cmd.SetArgs([]string{"--path", path})
	if err := cmd.Execute(); err == nil {
		t.Error("expected error for invalid JSON stdin, got nil")
	}
	// File must not be created when the parse fails.
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Error("state file should not exist after a failed write")
	}
}

func TestStateWriteCmd_MissingPath(t *testing.T) {
	t.Setenv("PIPELINE_STATE_FILE", "")
	cmd := newStateWriteCmd()
	cmd.SetArgs([]string{})
	if err := cmd.Execute(); err == nil {
		t.Error("expected error when --path and env var are both absent")
	}
}

// ---------------------------------------------------------------------------
// state read exit-code mapping (AC #coverage-gap-3 — CLI layer)
// ---------------------------------------------------------------------------

// TestStateReadCmd_ExitCode1_MissingFile verifies that state read returns an
// errExitCode with code 1 when the file does not exist. This is the bash-caller
// contract: exit 1 means "no state" (fresh start or already cleared), not an
// error that warrants --diagnose.
func TestStateReadCmd_ExitCode1_MissingFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nonexistent.json")

	cmd := newStateReadCmd()
	cmd.SetArgs([]string{"--path", path})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error for missing file, got nil")
	}
	var ec errExitCode
	if !errors.As(err, &ec) {
		t.Fatalf("expected errExitCode, got %T: %v", err, err)
	}
	if ec.ExitCode() != 1 {
		t.Errorf("missing file: want exit code 1, got %d", ec.ExitCode())
	}
}

// TestStateReadCmd_ExitCode2_CorruptFile verifies exit code 2 for a present
// but unparseable file — this must not be silently retried by the bash shim;
// the caller must route it to --diagnose.
func TestStateReadCmd_ExitCode2_CorruptFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "corrupt.json")
	if err := os.WriteFile(path, []byte("{not json}"), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	cmd := newStateReadCmd()
	cmd.SetArgs([]string{"--path", path})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error for corrupt file, got nil")
	}
	var ec errExitCode
	if !errors.As(err, &ec) {
		t.Fatalf("expected errExitCode, got %T: %v", err, err)
	}
	if ec.ExitCode() != 2 {
		t.Errorf("corrupt file: want exit code 2, got %d", ec.ExitCode())
	}
}

// TestStateReadCmd_ExitCode1_EmptyField verifies exit code 1 when the file
// is valid but the requested field is empty or absent — bash callers treat
// "no value" the same as "file absent" for resume logic.
func TestStateReadCmd_ExitCode1_EmptyField(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")

	// Write a snapshot with no exit_stage set.
	s := state.New(path)
	if err := s.Update(func(snap *proto.StateSnapshotV1) {
		snap.ResumeTask = "some task"
	}); err != nil {
		t.Fatalf("Update: %v", err)
	}

	cmd := newStateReadCmd()
	cmd.SetArgs([]string{"--path", path, "--field", "exit_stage"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error for empty field, got nil")
	}
	var ec errExitCode
	if !errors.As(err, &ec) {
		t.Fatalf("expected errExitCode, got %T: %v", err, err)
	}
	if ec.ExitCode() != 1 {
		t.Errorf("empty field: want exit code 1, got %d", ec.ExitCode())
	}
}

// TestStateReadCmd_ExitCode0_ValidField verifies the happy path: a populated
// field returns exit code 0 (command succeeds).
func TestStateReadCmd_ExitCode0_ValidField(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")

	s := state.New(path)
	if err := s.Update(func(snap *proto.StateSnapshotV1) {
		snap.ExitStage = "tester"
	}); err != nil {
		t.Fatalf("Update: %v", err)
	}

	cmd := newStateReadCmd()
	cmd.SetArgs([]string{"--path", path, "--field", "exit_stage"})
	if err := cmd.Execute(); err != nil {
		t.Errorf("expected success for valid field, got: %v", err)
	}
}

// TestStateReadCmd_MissingPath verifies that omitting both --path and the env
// var returns a descriptive error rather than panicking.
func TestStateReadCmd_MissingPath(t *testing.T) {
	t.Setenv("PIPELINE_STATE_FILE", "")
	cmd := newStateReadCmd()
	cmd.SetArgs([]string{})
	if err := cmd.Execute(); err == nil {
		t.Error("expected error when --path and env var are both absent")
	}
}

// TestErrExitCode_Unwrap ensures the error chain is intact so errors.Is still
// works after wrapping — callers that do errors.Is(err, state.ErrNotFound)
// must find the underlying error even when it is wrapped in errExitCode.
func TestErrExitCode_Unwrap(t *testing.T) {
	inner := state.ErrNotFound
	wrapped := errExitCode{code: 1, err: inner}
	if !errors.Is(wrapped, state.ErrNotFound) {
		t.Error("errExitCode.Unwrap must expose the inner error for errors.Is")
	}
	if wrapped.ExitCode() != 1 {
		t.Errorf("ExitCode: got %d, want 1", wrapped.ExitCode())
	}
}
