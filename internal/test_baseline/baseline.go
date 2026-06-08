// Package test_baseline ports the M92 baseline subsystem from
// lib/test_baseline.sh to Go. m38.5 — fifth decimal of the m38 tester
// family port.
//
// Responsibilities:
//
//   - Capture a pre-existing-failures snapshot at the start of a milestone
//     so that unrelated failures already present in the project's test
//     suite do not block acceptance.
//   - Compare current test output against the captured baseline (Tier 1)
//     and classify failures as pre_existing / new_failures / inconclusive.
//   - Detect "stuck" runs where the acceptance test output is byte-identical
//     across consecutive attempts (Tier 2) — when this fires, the operator
//     can opt into auto-pass via TEST_BASELINE_PASS_ON_STUCK.
//
// Load-bearing default preserved here: DefaultStuckPolicy().PassOnPreexisting
// is false. M92 flipped this from the original true; earlier versions
// silently auto-passed any pre-existing failure and operators stopped
// noticing baseline drift. TestDefaultStuckPolicy_PassOnPreexistingIsFalse
// is the regression-canary for this milestone.
package test_baseline

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/geoffgodwin/tekhton/internal/causal"
)

// Baseline is the on-disk metadata captured at the start of a milestone
// run. The struct field order (run_id, timestamp, milestone, exit_code,
// output_hash, failure_hash, failure_count) is load-bearing — the bash
// implementation emitted JSON in that exact order via printf. A
// byte-equivalence test would flag any reordering as a regression.
type Baseline struct {
	RunID        string    `json:"run_id"`
	Timestamp    time.Time `json:"timestamp"`
	Milestone    string    `json:"milestone"`
	ExitCode     int       `json:"exit_code"`
	OutputHash   string    `json:"output_hash"`
	FailureHash  string    `json:"failure_hash"`
	FailureCount int       `json:"failure_count"`
}

// CaptureOptions bundles the inputs to Capture. The default zero value is
// invalid — TestCmd and ProjectDir are required.
type CaptureOptions struct {
	Milestone  string
	RunID      string
	ProjectDir string
	TestCmd    string
}

// Verdict mirrors the bash compare_test_with_baseline string vocabulary.
type Verdict int

const (
	// VerdictInconclusive — no baseline available, or signatures diverge
	// without a clear classification.
	VerdictInconclusive Verdict = iota
	// VerdictPreExisting — current failures match the baseline signature
	// byte-for-byte; safe to treat as pre-existing.
	VerdictPreExisting
	// VerdictNewFailures — baseline was clean, or current failure count
	// exceeds baseline; failures are new.
	VerdictNewFailures
)

// String renders the verdict using the same vocabulary as the bash
// implementation, for log + CLI parity.
func (v Verdict) String() string {
	switch v {
	case VerdictPreExisting:
		return "pre_existing"
	case VerdictNewFailures:
		return "new_failures"
	default:
		return "inconclusive"
	}
}

// StuckPolicy governs the Tier 2 cross-attempt stuck check. PassOnPreexisting
// defaults to false — see the m38.5 regression-canary at the top of the
// package. PassOnStuck likewise defaults to false (separate flag, different
// code path).
type StuckPolicy struct {
	Threshold         int
	PassOnStuck       bool
	PassOnPreexisting bool
}

// DefaultStuckPolicy returns the canonical M92-flipped defaults. Both
// pass-on toggles default false — do not change without flipping the M92
// regression-canary test.
func DefaultStuckPolicy() StuckPolicy {
	return StuckPolicy{
		Threshold:         2,
		PassOnStuck:       false,
		PassOnPreexisting: false,
	}
}

// StuckState carries the cross-call state for CheckAcceptanceStuck. The
// caller owns the value (typically a pointer field on the orchestrator
// struct) so the check is reproducible across attempts.
type StuckState struct {
	LastHash       string
	IdenticalCount int
}

// StuckResult is the verdict returned by CheckAcceptanceStuck.
type StuckResult int

const (
	// StuckResultNotStuck — output differs from the prior attempt, OR
	// the identical-count is below threshold, OR the baseline was clean
	// (the safety-check branch — clean baseline means all failures are
	// new regressions, never auto-pass).
	StuckResultNotStuck StuckResult = iota
	// StuckResultAutoPass — stuck detected, PassOnStuck=true, and the
	// baseline had failures. Caller treats acceptance as passed.
	StuckResultAutoPass
	// StuckResultExit — stuck detected, PassOnStuck=false. Caller exits
	// to avoid burning more retries.
	StuckResultExit
)

// File path helpers ---------------------------------------------------

func baselineJSONPath(projectDir string) string {
	return filepath.Join(claudeDir(projectDir), "TEST_BASELINE.json")
}

func baselineOutputPath(projectDir string) string {
	return filepath.Join(claudeDir(projectDir), "TEST_BASELINE_OUTPUT.txt")
}

func acceptanceOutputPath(projectDir string) string {
	return filepath.Join(claudeDir(projectDir), "test_acceptance_output.tmp")
}

func claudeDir(projectDir string) string {
	if projectDir == "" {
		projectDir = "."
	}
	return filepath.Join(projectDir, ".claude")
}

// Normalization helpers ----------------------------------------------

// Regexes mirror the sed -E patterns in lib/test_baseline.sh:44-54. The
// set was dogfooded into shape across pytest, go test, jest/mocha, cargo,
// and JUnit output. Do not "improve" them — treat as data.
var (
	reANSI      = regexp.MustCompile(`\x1b\[[0-9;]*[mGKHJ]`)
	reTimestamp = regexp.MustCompile(`[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?Z?`)
	reFloatSec  = regexp.MustCompile(`[0-9]+\.[0-9]+s`)
	reInSeconds = regexp.MustCompile(`in [0-9]+ seconds?`)
	reMS        = regexp.MustCompile(`[0-9]+ms`)
	reFloatSecB = regexp.MustCompile(`[0-9]+\.[0-9]+ seconds?`)
	rePID       = regexp.MustCompile(`(?i)pid[\s]*[0-9]+`)
	reHexAddr   = regexp.MustCompile(`0x[0-9a-fA-F]+`)
	reFailLine  = regexp.MustCompile(`(?i)(^FAIL[\s]|^---[\s]*FAIL|FAILED|FAILURE[S]?|^ERROR[\s]|ERROR:|AssertionError|assert.*failed|panic:|failures:)`)
)

// NormalizeTestOutput strips non-deterministic content so the hash is
// stable across runs. Preserves test names and assertion text.
func NormalizeTestOutput(in string) string {
	s := reANSI.ReplaceAllString(in, "")
	s = reTimestamp.ReplaceAllString(s, "TIMESTAMP")
	s = reFloatSec.ReplaceAllString(s, "N.NNs")
	s = reInSeconds.ReplaceAllString(s, "in N seconds")
	s = reMS.ReplaceAllString(s, "Nms")
	s = reFloatSecB.ReplaceAllString(s, "N.NN seconds")
	s = rePID.ReplaceAllString(s, "pid NNN")
	s = reHexAddr.ReplaceAllString(s, "0xADDR")
	return s
}

// ExtractFailureLines returns the lines from the input that look like
// test failures, framework-agnostic. Empty slice when no matches.
func ExtractFailureLines(in string) []string {
	if in == "" {
		return nil
	}
	var out []string
	for _, line := range strings.Split(in, "\n") {
		if reFailLine.MatchString(line) {
			out = append(out, line)
		}
	}
	return out
}

func hashContent(s string) string {
	sum := md5.Sum([]byte(s)) //nolint:gosec // baseline hashing, not crypto
	return hex.EncodeToString(sum[:])
}

func failureSignatureHash(out string) string {
	lines := ExtractFailureLines(NormalizeTestOutput(out))
	sort.Strings(lines)
	return hashContent(strings.Join(lines, "\n"))
}

func failureCount(out string) int {
	return len(ExtractFailureLines(out))
}

// Atomic file write --------------------------------------------------

// writeAtomic writes data to path via tmpfile + rename. Mirrors the
// bash `printf > path.tmp.$$ && mv path.tmp.$$ path` pattern; concurrent
// readers (dashboard, milestone tracker) never see a partial write.
func writeAtomic(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	if dir != "" {
		_ = os.MkdirAll(dir, 0o755)
	}
	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".tmp.*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	if err := os.Chmod(tmpName, perm); err != nil {
		os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, path)
}

// Capture runs opts.TestCmd via `bash -c`, writes raw output + metadata
// to the .claude/ directory, and emits the test_baseline causal event.
//
// When TestCmd is empty or "true", Capture returns (nil, nil) — there is
// no real test suite to baseline.
func Capture(ctx context.Context, opts CaptureOptions) (*Baseline, error) {
	if opts.TestCmd == "" || opts.TestCmd == "true" {
		return nil, nil
	}
	if opts.ProjectDir == "" {
		return nil, fmt.Errorf("test_baseline: ProjectDir is required")
	}
	cmd := exec.CommandContext(ctx, "bash", "-c", opts.TestCmd)
	cmd.Dir = opts.ProjectDir
	combined, runErr := cmd.CombinedOutput()
	exitCode := 0
	if runErr != nil {
		if ee, ok := runErr.(*exec.ExitError); ok {
			exitCode = ee.ExitCode()
		} else {
			return nil, fmt.Errorf("test_baseline: capture: %w", runErr)
		}
	}
	output := string(combined)
	// Match bash printf '%s\n' — trailing newline.
	if err := writeAtomic(baselineOutputPath(opts.ProjectDir), []byte(output+"\n"), 0o644); err != nil {
		return nil, fmt.Errorf("test_baseline: write output: %w", err)
	}
	bl := &Baseline{
		RunID:        opts.RunID,
		Timestamp:    time.Now().UTC().Truncate(time.Second),
		Milestone:    opts.Milestone,
		ExitCode:     exitCode,
		OutputHash:   hashContent(NormalizeTestOutput(output)),
		FailureHash:  failureSignatureHash(output),
		FailureCount: failureCount(output),
	}
	if bl.RunID == "" {
		bl.RunID = "unknown"
	}
	if bl.Milestone == "" {
		bl.Milestone = "unknown"
	}
	if err := writeBaselineJSON(bl, baselineJSONPath(opts.ProjectDir)); err != nil {
		return nil, err
	}
	emitCaptureEvent(bl)
	return bl, nil
}

// writeBaselineJSON serializes Baseline to JSON in the bash-compatible
// field order. encoding/json honors struct declaration order, so the
// field layout in Baseline drives the on-disk shape.
func writeBaselineJSON(bl *Baseline, path string) error {
	body, err := json.MarshalIndent(bl, "", "  ")
	if err != nil {
		return fmt.Errorf("test_baseline: marshal json: %w", err)
	}
	body = append(body, '\n')
	return writeAtomic(path, body, 0o644)
}

// readBaseline loads the metadata file; returns (nil, nil) when missing.
func readBaseline(projectDir string) (*Baseline, error) {
	path := baselineJSONPath(projectDir)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var bl Baseline
	if err := json.Unmarshal(data, &bl); err != nil {
		return nil, fmt.Errorf("test_baseline: parse json: %w", err)
	}
	return &bl, nil
}

// Has returns true iff a baseline exists for the given milestone. Mirrors
// has_test_baseline — the embedded milestone field must match.
func Has(milestone, projectDir string) bool {
	bl, err := readBaseline(projectDir)
	if err != nil || bl == nil {
		return false
	}
	return bl.Milestone == milestone
}

// ShouldCapture mirrors _should_capture_test_baseline. Returns true when
// a new baseline must be captured — no baseline, missing run_id, or
// different run_id from the current run.
func ShouldCapture(milestone, runID, projectDir string, testBaselineEnabled bool, testCmd string) bool {
	if !testBaselineEnabled {
		return false
	}
	if testCmd == "" || testCmd == "true" {
		return false
	}
	bl, err := readBaseline(projectDir)
	if err != nil || bl == nil {
		return true
	}
	if bl.Milestone != milestone {
		return true
	}
	if bl.RunID == "" {
		// pre-M63 baseline — treat as stale
		return true
	}
	return bl.RunID != runID
}

// Compare classifies the current test output relative to the baseline.
// Mirrors compare_test_with_baseline's decision tree exactly:
//
//  1. no baseline → VerdictInconclusive
//  2. baseline exit_code == 0 → VerdictNewFailures
//  3. failure-hash match → VerdictPreExisting
//  4. current failure count > baseline → VerdictNewFailures
//  5. otherwise → VerdictInconclusive
func Compare(output string, _ int, projectDir string) (Verdict, error) {
	bl, err := readBaseline(projectDir)
	if err != nil {
		return VerdictInconclusive, err
	}
	if bl == nil {
		return VerdictInconclusive, nil
	}
	if bl.ExitCode == 0 {
		return VerdictNewFailures, nil
	}
	if failureSignatureHash(output) == bl.FailureHash {
		return VerdictPreExisting, nil
	}
	if failureCount(output) > bl.FailureCount {
		return VerdictNewFailures, nil
	}
	return VerdictInconclusive, nil
}

// SaveAcceptanceOutput writes the acceptance test output to the .tmp file
// used by CheckAcceptanceStuck on the next attempt.
func SaveAcceptanceOutput(output string, _ int, projectDir string) error {
	return writeAtomic(acceptanceOutputPath(projectDir), []byte(output+"\n"), 0o644)
}

// GetAcceptanceOutputHash returns the normalized hash of the saved
// acceptance output, or "" when no output is saved.
func GetAcceptanceOutputHash(projectDir string) (string, error) {
	data, err := os.ReadFile(acceptanceOutputPath(projectDir))
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	return hashContent(NormalizeTestOutput(string(data))), nil
}

// CheckAcceptanceStuck mirrors _check_acceptance_stuck's state machine.
// The caller owns state; threshold + auto-pass flags come from policy.
//
// Safety check: when PassOnStuck=true and the baseline exited 0 (clean),
// all current failures are new regressions — we refuse to auto-pass and
// return StuckResultNotStuck instead of StuckResultAutoPass.
func CheckAcceptanceStuck(state *StuckState, policy StuckPolicy, projectDir string) StuckResult {
	if state == nil {
		return StuckResultNotStuck
	}
	hash, err := GetAcceptanceOutputHash(projectDir)
	if err != nil || hash == "" {
		return StuckResultNotStuck
	}
	if hash != state.LastHash {
		state.LastHash = hash
		state.IdenticalCount = 1
		return StuckResultNotStuck
	}
	state.IdenticalCount++
	if state.IdenticalCount < policy.Threshold {
		return StuckResultNotStuck
	}
	emitStuckEvent(hash, state.IdenticalCount)
	if !policy.PassOnStuck {
		return StuckResultExit
	}
	// PassOnStuck=true: safety check on the baseline exit code.
	bl, err := readBaseline(projectDir)
	if err == nil && bl != nil && bl.ExitCode == 0 {
		emitStuckCleanBlockEvent(hash, state.IdenticalCount)
		return StuckResultNotStuck
	}
	return StuckResultAutoPass
}

// Causal emission seam ----------------------------------------------

// CausalEmitter is the seam for emitting baseline-related causal events.
// Production uses a causal.Log; tests substitute a no-op.
type CausalEmitter interface {
	Emit(in causal.EmitInput) (string, error)
}

type noopCausalEmitter struct{}

func (noopCausalEmitter) Emit(causal.EmitInput) (string, error) { return "", nil }

var causalEmitter CausalEmitter = noopCausalEmitter{}

// SetCausalEmitter overrides the package emitter; nil is a no-op (the
// previous emitter is preserved). Returns the prior emitter.
func SetCausalEmitter(e CausalEmitter) CausalEmitter {
	prev := causalEmitter
	if e != nil {
		causalEmitter = e
	}
	return prev
}

func emitCaptureEvent(bl *Baseline) {
	type ctxPayload struct {
		ExitCode     int    `json:"exit_code"`
		FailureCount int    `json:"failure_count"`
		OutputHash   string `json:"output_hash"`
		FailureHash  string `json:"failure_hash"`
	}
	raw, err := json.Marshal(ctxPayload{
		ExitCode:     bl.ExitCode,
		FailureCount: bl.FailureCount,
		OutputHash:   bl.OutputHash,
		FailureHash:  bl.FailureHash,
	})
	if err != nil {
		return
	}
	_, _ = causalEmitter.Emit(causal.EmitInput{
		Stage:   "pipeline",
		Type:    "test_baseline",
		Detail:  fmt.Sprintf("exit=%d, failures=%d", bl.ExitCode, bl.FailureCount),
		Context: raw,
	})
}

func emitStuckEvent(hash string, count int) {
	type ctxPayload struct {
		Hash        string `json:"hash"`
		Consecutive int    `json:"consecutive"`
	}
	raw, err := json.Marshal(ctxPayload{Hash: hash, Consecutive: count})
	if err != nil {
		return
	}
	_, _ = causalEmitter.Emit(causal.EmitInput{
		Stage:   "pipeline",
		Type:    "acceptance_stuck",
		Detail:  fmt.Sprintf("identical_failures=%d", count),
		Context: raw,
	})
}

func emitStuckCleanBlockEvent(hash string, count int) {
	type ctxPayload struct {
		Hash         string `json:"hash"`
		BaselineExit int    `json:"baseline_exit"`
		Consecutive  int    `json:"consecutive"`
	}
	raw, err := json.Marshal(ctxPayload{Hash: hash, BaselineExit: 0, Consecutive: count})
	if err != nil {
		return
	}
	_, _ = causalEmitter.Emit(causal.EmitInput{
		Stage:   "pipeline",
		Type:    "stuck_test_detected",
		Detail:  "clean_baseline_block",
		Context: raw,
	})
}

// GetBaselineExitCode returns the baseline's exit code as a string. Used
// by the operator CLI surface (tekhton baseline get-exit-code). Returns
// "" when no baseline is present, matching the bash semantics.
func GetBaselineExitCode(projectDir string) string {
	bl, err := readBaseline(projectDir)
	if err != nil || bl == nil {
		return ""
	}
	return fmt.Sprintf("%d", bl.ExitCode)
}

// FailureSignatureHashForTesting exposes the internal failureSignatureHash
// helper so consumer-package tests (e.g. internal/tester/fix_test.go) can
// seed a TEST_BASELINE.json whose failure_hash matches a given output
// string and drive the pre-existing short-circuit deterministically.
// Not for production use.
func FailureSignatureHashForTesting(output string) string {
	return failureSignatureHash(output)
}
