package diagnose

import (
	"bufio"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestBashRuleAdapter_OrderMatchesBashRegistry is the m32.1 order-mismatch
// canary: the Go-side BashRuleRegistryOrder MUST list rules in the exact same
// priority order as lib/diagnose_rules_registry.sh. Reads the bash file at
// test time and diffs against BashRuleRegistryOrder(). If a future edit to
// the bash registry isn't mirrored in Go, this test fires red — preventing
// the engine from skipping a higher-priority rule by accident.
func TestBashRuleAdapter_OrderMatchesBashRegistry(t *testing.T) {
	t.Parallel()
	home := findTekhtonHome(t)
	if home == "" {
		t.Skip("TEKHTON_HOME not resolvable; skipping order-parity check")
	}
	path := filepath.Join(home, "lib", "diagnose_rules_registry.sh")
	f, err := os.Open(path)
	if err != nil {
		t.Skipf("registry file unavailable: %v", err)
	}
	defer f.Close()

	var bashOrder []string
	sc := bufio.NewScanner(f)
	inside := false
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if !inside {
			if strings.HasPrefix(line, "DIAGNOSE_RULES=(") {
				inside = true
			}
			continue
		}
		if line == ")" {
			break
		}
		// Strip surrounding quotes.
		line = strings.Trim(line, `"`)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		bashOrder = append(bashOrder, line)
	}
	if err := sc.Err(); err != nil {
		t.Fatalf("scan: %v", err)
	}
	goOrder := BashRuleRegistryOrder()
	if len(bashOrder) != len(goOrder) {
		t.Fatalf("registry length drift: bash=%d go=%d\nbash=%v\n  go=%v",
			len(bashOrder), len(goOrder), bashOrder, goOrder)
	}
	for i := range bashOrder {
		if bashOrder[i] != goOrder[i] {
			t.Fatalf("registry index %d drift: bash=%q go=%q", i, bashOrder[i], goOrder[i])
		}
	}
}

// TestBashRuleAdapter_LargeCausalEventsRoundTripViaTempFile exercises the
// >128KB env-var offload path. The adapter must NOT pass values that exceed
// envVarRoundTripLimit directly through `cmd.Env` (Linux exec ARG_MAX is
// large but variable across platforms); instead a tempfile is created and a
// `_DIAG_CAUSAL_EVENTS_FILE` pointer is passed.
func TestBashRuleAdapter_LargeCausalEventsRoundTripViaTempFile(t *testing.T) {
	t.Parallel()
	if runtime.GOOS == "windows" {
		t.Skip("adapter env semantics not portable to Windows in m32.1")
	}
	home := findTekhtonHome(t)
	if home == "" {
		home = "/tmp/fake-tekhton-home" // buildEnv only requires non-empty
	}

	// Craft a payload above the envVarRoundTripLimit so the offload path
	// triggers.
	large := strings.Repeat("X", envVarRoundTripLimit+1024)
	c := &Context{
		ProjectDir:   "/tmp/fake-project",
		CausalEvents: large,
	}

	a := &BashRuleAdapter{TekhtonHome: home}
	env, cleanup, err := a.buildEnv(c)
	if err != nil {
		t.Fatalf("buildEnv: %v", err)
	}
	defer cleanup()

	var foundCausal, foundPointer bool
	var pointerPath string
	for _, kv := range env {
		switch {
		case strings.HasPrefix(kv, "_DIAG_CAUSAL_EVENTS="):
			foundCausal = true
			val := kv[len("_DIAG_CAUSAL_EVENTS="):]
			if val != "" {
				t.Errorf("offloaded payload should pass empty _DIAG_CAUSAL_EVENTS, got %d bytes", len(val))
			}
		case strings.HasPrefix(kv, "_DIAG_CAUSAL_EVENTS_FILE="):
			foundPointer = true
			pointerPath = kv[len("_DIAG_CAUSAL_EVENTS_FILE="):]
		}
	}
	if !foundCausal {
		t.Error("expected _DIAG_CAUSAL_EVENTS to be present (empty)")
	}
	if !foundPointer {
		t.Fatal("expected _DIAG_CAUSAL_EVENTS_FILE pointer for large payload")
	}
	if pointerPath == "" {
		t.Fatal("pointer path empty")
	}
	body, err := os.ReadFile(pointerPath)
	if err != nil {
		t.Fatalf("read pointer file: %v", err)
	}
	if string(body) != large {
		t.Fatalf("pointer file body mismatch: want %d bytes got %d", len(large), len(body))
	}
}

// TestBashRuleAdapter_SmallCausalEventsInlined exercises the under-the-limit
// path: small payloads pass through env directly, no tempfile.
func TestBashRuleAdapter_SmallCausalEventsInlined(t *testing.T) {
	t.Parallel()
	c := &Context{CausalEvents: "abc"}
	a := &BashRuleAdapter{TekhtonHome: "/tmp/fake"}
	env, cleanup, err := a.buildEnv(c)
	if err != nil {
		t.Fatalf("buildEnv: %v", err)
	}
	defer cleanup()
	var sawInline, sawPointer bool
	for _, kv := range env {
		if strings.HasPrefix(kv, "_DIAG_CAUSAL_EVENTS=") {
			val := kv[len("_DIAG_CAUSAL_EVENTS="):]
			if val == "abc" {
				sawInline = true
			}
		}
		if strings.HasPrefix(kv, "_DIAG_CAUSAL_EVENTS_FILE=") {
			sawPointer = true
		}
	}
	if !sawInline {
		t.Error("small payload must be inlined into _DIAG_CAUSAL_EVENTS")
	}
	if sawPointer {
		t.Error("small payload must not emit a _DIAG_CAUSAL_EVENTS_FILE pointer")
	}
}

// TestParseRuleOutput_HandlesEmbeddedNewlines ensures the bash wrapper's
// `\n` -> LF round-trip works for suggestions that contain literal newlines.
func TestParseRuleOutput_HandlesEmbeddedNewlines(t *testing.T) {
	t.Parallel()
	stdout := `DIAG_CLASSIFICATION=BUILD_FAILURE
DIAG_CONFIDENCE=high
DIAG_SUGGESTIONS_COUNT=2
DIAG_SUGGESTION=Build failed.\nSee BUILD_ERRORS.md
DIAG_SUGGESTION=Options:\n  1. Fix\n  2. Retry
`
	d := parseRuleOutput(stdout, "_rule_build_failure", "coder")
	if d.Classification != "BUILD_FAILURE" {
		t.Errorf("classification: got %q", d.Classification)
	}
	if d.Confidence != ConfidenceHigh {
		t.Errorf("confidence: got %q", d.Confidence)
	}
	if len(d.Suggestions) != 2 {
		t.Fatalf("want 2 suggestions, got %d: %v", len(d.Suggestions), d.Suggestions)
	}
	if !strings.Contains(d.Suggestions[0], "\nSee BUILD_ERRORS.md") {
		t.Errorf("embedded newline missing in suggestion 0: %q", d.Suggestions[0])
	}
	if !strings.Contains(d.Suggestions[1], "\n  1. Fix\n  2. Retry") {
		t.Errorf("embedded newlines missing in suggestion 1: %q", d.Suggestions[1])
	}
}

// TestBashRuleAdapter_RulesReturnsAllEighteen verifies the adapter exposes
// every rule in the bash registry.
func TestBashRuleAdapter_RulesReturnsAllEighteen(t *testing.T) {
	t.Parallel()
	a := &BashRuleAdapter{TekhtonHome: "/tmp/fake"}
	rules := a.Rules()
	if len(rules) != 18 {
		t.Fatalf("want 18 rules, got %d", len(rules))
	}
	if rules[0].Name() != "_rule_ui_gate_interactive_reporter" {
		t.Errorf("first rule must be _rule_ui_gate_interactive_reporter, got %q", rules[0].Name())
	}
	if rules[len(rules)-1].Name() != "_rule_unknown" {
		t.Errorf("last rule must be _rule_unknown, got %q", rules[len(rules)-1].Name())
	}
}

// TestBashRuleAdapter_MatchWithoutHomeFails ensures the adapter returns
// no-match (not crash) when TekhtonHome is empty.
func TestBashRuleAdapter_MatchWithoutHomeFails(t *testing.T) {
	t.Parallel()
	a := &BashRuleAdapter{TekhtonHome: ""}
	r := &bashRule{name: "_rule_unknown", adapter: a}
	_, ok := r.Match(&Context{Outcome: "failure"})
	if ok {
		t.Fatal("empty TekhtonHome must yield no-match")
	}
}
