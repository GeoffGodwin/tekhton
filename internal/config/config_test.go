package config

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func writeConf(t *testing.T, body string) string {
	t.Helper()
	d := t.TempDir()
	p := filepath.Join(d, "pipeline.conf")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatalf("write conf: %v", err)
	}
	return p
}

func TestLoad_Minimal(t *testing.T) {
	p := writeConf(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="echo ok"
`)
	clearCIEnv(t)
	cfg, err := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Values["PROJECT_NAME"] != "t" {
		t.Errorf("PROJECT_NAME=%q", cfg.Values["PROJECT_NAME"])
	}
	if cfg.Values["CODER_MAX_TURNS"] != "80" {
		t.Errorf("CODER_MAX_TURNS default expected 80, got %q", cfg.Values["CODER_MAX_TURNS"])
	}
	// Required keys recorded as set.
	for _, k := range []string{"PROJECT_NAME", "CLAUDE_STANDARD_MODEL", "ANALYZE_CMD"} {
		if !cfg.KeysSet[k] {
			t.Errorf("KeysSet missing %q", k)
		}
	}
}

func TestLoad_MissingRequired(t *testing.T) {
	p := writeConf(t, `PROJECT_NAME="t"
ANALYZE_CMD="echo ok"
`)
	_, err := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if !errors.Is(err, ErrMissingRequired) {
		t.Errorf("expected ErrMissingRequired, got %v", err)
	}
}

func TestLoad_NotFound(t *testing.T) {
	_, err := Load("/no/such/file/pipeline.conf", LoadOptions{})
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

func TestParse_RejectsCommandSubstitution(t *testing.T) {
	p := writeConf(t, `PROJECT_NAME="$(rm -rf /)"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
`)
	_, err := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if !errors.Is(err, ErrParse) {
		t.Errorf("expected ErrParse, got %v", err)
	}
}

func TestParse_RejectsBackticks(t *testing.T) {
	p := writeConf(t, "PROJECT_NAME=\"`whoami`\"\nCLAUDE_STANDARD_MODEL=\"x\"\nANALYZE_CMD=\"echo ok\"\n")
	_, err := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if !errors.Is(err, ErrParse) {
		t.Errorf("expected ErrParse, got %v", err)
	}
}

func TestParse_RejectsShellMetachars(t *testing.T) {
	p := writeConf(t, `PROJECT_NAME="t; rm -rf /"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
`)
	_, err := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if !errors.Is(err, ErrParse) {
		t.Errorf("expected ErrParse, got %v", err)
	}
}

func TestParse_AllowsMetacharsInCmdKeys(t *testing.T) {
	p := writeConf(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="eslint . | grep error"
TEST_CMD="npm test && echo done"
`)
	cfg, err := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if !strings.Contains(cfg.Values["ANALYZE_CMD"], "|") {
		t.Errorf("pipe stripped from ANALYZE_CMD: %q", cfg.Values["ANALYZE_CMD"])
	}
}

func TestParse_QuoteStripping(t *testing.T) {
	p := writeConf(t, `PROJECT_NAME='single-q'
CLAUDE_STANDARD_MODEL="double-q"
ANALYZE_CMD=bare
`)
	cfg, err := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Values["PROJECT_NAME"] != "single-q" {
		t.Errorf("single-quote strip: %q", cfg.Values["PROJECT_NAME"])
	}
	if cfg.Values["CLAUDE_STANDARD_MODEL"] != "double-q" {
		t.Errorf("double-quote strip: %q", cfg.Values["CLAUDE_STANDARD_MODEL"])
	}
	if cfg.Values["ANALYZE_CMD"] != "bare" {
		t.Errorf("bare value: %q", cfg.Values["ANALYZE_CMD"])
	}
}

func TestDefaults_Derived(t *testing.T) {
	clearCIEnv(t)
	cfg := &Config{Values: map[string]string{}, KeysSet: map[string]bool{}}
	cfg.LoadDefaultsOnly(LoadOptions{SuppressDiagnostics: true})

	// CLAUDE_STANDARD_MODEL must be set by default.
	if cfg.Values["CLAUDE_STANDARD_MODEL"] != "claude-sonnet-4-6" {
		t.Errorf("CLAUDE_STANDARD_MODEL=%q", cfg.Values["CLAUDE_STANDARD_MODEL"])
	}
	// Derived models inherit from base.
	if cfg.Values["CLAUDE_CODER_MODEL"] != "claude-sonnet-4-6" {
		t.Errorf("CLAUDE_CODER_MODEL=%q", cfg.Values["CLAUDE_CODER_MODEL"])
	}
	// MILESTONE_CODER_MAX_TURNS = CODER_MAX_TURNS * 2 = 160.
	if cfg.Values["MILESTONE_CODER_MAX_TURNS"] != "160" {
		t.Errorf("MILESTONE_CODER_MAX_TURNS=%q (expected 160)", cfg.Values["MILESTONE_CODER_MAX_TURNS"])
	}
	// MILESTONE_REVIEWER_MAX_TURNS = REVIEWER_MAX_TURNS + 5 = 25.
	if cfg.Values["MILESTONE_REVIEWER_MAX_TURNS"] != "25" {
		t.Errorf("MILESTONE_REVIEWER_MAX_TURNS=%q (expected 25)", cfg.Values["MILESTONE_REVIEWER_MAX_TURNS"])
	}
}

func TestCI_NoSignal(t *testing.T) {
	clearCIEnv(t)
	if got := DetectCI(); got != CINone {
		t.Errorf("DetectCI=%q, expected none", got)
	}
}

func TestCI_GitHubActions(t *testing.T) {
	clearCIEnv(t)
	t.Setenv("GITHUB_ACTIONS", "true")
	if got := DetectCI(); got != CIGitHub {
		t.Errorf("DetectCI=%q, expected GitHub Actions", got)
	}
}

func TestCI_AllPlatforms(t *testing.T) {
	cases := []struct {
		envKey, envVal string
		want           CIPlatform
	}{
		{"GITHUB_ACTIONS", "true", CIGitHub},
		{"GITLAB_CI", "true", CIGitLab},
		{"CIRCLECI", "true", CICircle},
		{"TRAVIS", "true", CITravis},
		{"BUILDKITE", "true", CIBuildkite},
		{"JENKINS_URL", "http://j", CIJenkins},
		{"TF_BUILD", "True", CIAzure},
		{"TEAMCITY_VERSION", "8.0", CITeamCity},
		{"BITBUCKET_BUILD_NUMBER", "42", CIBitbucket},
		{"CI", "true", CIGenericTrue},
	}
	for _, c := range cases {
		clearCIEnv(t)
		t.Setenv(c.envKey, c.envVal)
		if got := DetectCI(); got != c.want {
			t.Errorf("env %s=%s: DetectCI=%q want %q", c.envKey, c.envVal, got, c.want)
		}
	}
}

func TestCI_AutoElevation(t *testing.T) {
	clearCIEnv(t)
	t.Setenv("GITHUB_ACTIONS", "true")
	p := writeConf(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
`)
	cfg, err := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Values["TEKHTON_UI_GATE_FORCE_NONINTERACTIVE"] != "1" {
		t.Errorf("expected auto-elevated to 1, got %q", cfg.Values["TEKHTON_UI_GATE_FORCE_NONINTERACTIVE"])
	}
	if cfg.Values["TEKHTON_CI_ENVIRONMENT_DETECTED"] != "1" {
		t.Errorf("expected CI detected = 1, got %q", cfg.Values["TEKHTON_CI_ENVIRONMENT_DETECTED"])
	}
}

func TestCI_ExplicitOverride(t *testing.T) {
	clearCIEnv(t)
	t.Setenv("GITHUB_ACTIONS", "true")
	p := writeConf(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0
`)
	cfg, err := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Values["TEKHTON_UI_GATE_FORCE_NONINTERACTIVE"] != "0" {
		t.Errorf("explicit 0 should win: got %q", cfg.Values["TEKHTON_UI_GATE_FORCE_NONINTERACTIVE"])
	}
	// CI detection still flagged for downstream consumers.
	if cfg.Values["TEKHTON_CI_ENVIRONMENT_DETECTED"] != "1" {
		t.Errorf("CI detection flag should still be 1, got %q", cfg.Values["TEKHTON_CI_ENVIRONMENT_DETECTED"])
	}
}

func TestClamp_IntegerExceedsCap(t *testing.T) {
	p := writeConf(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
CODER_MAX_TURNS=99999
`)
	clearCIEnv(t)
	cfg, _ := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if cfg.Values["CODER_MAX_TURNS"] != "500" {
		t.Errorf("CODER_MAX_TURNS clamp expected 500, got %q", cfg.Values["CODER_MAX_TURNS"])
	}
	if len(cfg.Warnings) == 0 {
		t.Errorf("expected at least one warning")
	}
}

func TestClamp_FloatRange(t *testing.T) {
	p := writeConf(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
REWORK_TURN_ESCALATION_FACTOR=99.0
UI_GATE_ENV_RETRY_TIMEOUT_FACTOR=2.5
`)
	clearCIEnv(t)
	cfg, _ := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if cfg.Values["REWORK_TURN_ESCALATION_FACTOR"] != "10.0" {
		t.Errorf("REWORK_TURN_ESCALATION_FACTOR clamp: %q", cfg.Values["REWORK_TURN_ESCALATION_FACTOR"])
	}
	if cfg.Values["UI_GATE_ENV_RETRY_TIMEOUT_FACTOR"] != "1.0" {
		t.Errorf("UI_GATE_ENV_RETRY_TIMEOUT_FACTOR clamp: %q", cfg.Values["UI_GATE_ENV_RETRY_TIMEOUT_FACTOR"])
	}
}

func TestValidate_BadEnumsReset(t *testing.T) {
	p := writeConf(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
PIPELINE_ORDER="bogus"
SECURITY_BLOCK_SEVERITY="BANANA"
DASHBOARD_VERBOSITY="loud"
UI_FRAMEWORK="kitchen-sink"
`)
	clearCIEnv(t)
	cfg, _ := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if cfg.Values["PIPELINE_ORDER"] != "standard" {
		t.Errorf("PIPELINE_ORDER reset: %q", cfg.Values["PIPELINE_ORDER"])
	}
	if cfg.Values["SECURITY_BLOCK_SEVERITY"] != "HIGH" {
		t.Errorf("SECURITY_BLOCK_SEVERITY reset: %q", cfg.Values["SECURITY_BLOCK_SEVERITY"])
	}
	if cfg.Values["DASHBOARD_VERBOSITY"] != "normal" {
		t.Errorf("DASHBOARD_VERBOSITY reset: %q", cfg.Values["DASHBOARD_VERBOSITY"])
	}
	if cfg.Values["UI_FRAMEWORK"] != "" {
		t.Errorf("UI_FRAMEWORK reset to empty, got %q", cfg.Values["UI_FRAMEWORK"])
	}
}

func TestValidate_HealthWeightsReset(t *testing.T) {
	p := writeConf(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
HEALTH_WEIGHT_TESTS=50
HEALTH_WEIGHT_QUALITY=50
HEALTH_WEIGHT_DEPS=50
HEALTH_WEIGHT_DOCS=50
HEALTH_WEIGHT_HYGIENE=50
`)
	clearCIEnv(t)
	cfg, _ := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if cfg.Values["HEALTH_WEIGHT_TESTS"] != "30" {
		t.Errorf("HEALTH_WEIGHT_TESTS reset: %q", cfg.Values["HEALTH_WEIGHT_TESTS"])
	}
}

func TestValidate_IntakeOrderingReset(t *testing.T) {
	p := writeConf(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
INTAKE_CLARITY_THRESHOLD=80
INTAKE_TWEAK_THRESHOLD=70
`)
	clearCIEnv(t)
	cfg, _ := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if cfg.Values["INTAKE_CLARITY_THRESHOLD"] != "40" {
		t.Errorf("INTAKE_CLARITY_THRESHOLD reset: %q", cfg.Values["INTAKE_CLARITY_THRESHOLD"])
	}
	if cfg.Values["INTAKE_TWEAK_THRESHOLD"] != "70" {
		t.Errorf("INTAKE_TWEAK_THRESHOLD reset: %q", cfg.Values["INTAKE_TWEAK_THRESHOLD"])
	}
}

func TestPaths_RelativeResolve(t *testing.T) {
	p := writeConf(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
PIPELINE_STATE_FILE="state/foo.md"
`)
	clearCIEnv(t)
	pd := filepath.Dir(p)
	cfg, _ := Load(p, LoadOptions{ProjectDir: pd, SuppressDiagnostics: true})
	want := pd + "/state/foo.md"
	if cfg.Values["PIPELINE_STATE_FILE"] != want {
		t.Errorf("path resolve: got %q want %q", cfg.Values["PIPELINE_STATE_FILE"], want)
	}
}

func TestMilestoneOverrides(t *testing.T) {
	p := writeConf(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
CODER_MAX_TURNS=80
MILESTONE_CODER_MAX_TURNS=200
`)
	clearCIEnv(t)
	cfg, _ := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), MilestoneMode: true, SuppressDiagnostics: true})
	if cfg.Values["CODER_MAX_TURNS"] != "200" {
		t.Errorf("milestone override CODER_MAX_TURNS: %q", cfg.Values["CODER_MAX_TURNS"])
	}
}

func TestEmitShell_Quoting(t *testing.T) {
	cfg := &Config{Values: map[string]string{
		"K":     "value with spaces",
		"PIPED": "a | b",
		"EMBED": "x's apostrophe",
		"EMPTY": "",
	}, KeysSet: map[string]bool{}}
	var buf bytes.Buffer
	if err := cfg.EmitShell(&buf); err != nil {
		t.Fatalf("EmitShell: %v", err)
	}
	out := buf.String()
	if !strings.Contains(out, "export EMBED='x'\\''s apostrophe'") {
		t.Errorf("apostrophe not escaped: %s", out)
	}
	if !strings.Contains(out, "export EMPTY=''") {
		t.Errorf("empty value missing: %s", out)
	}
}

func TestEmitJSON_Roundtrip(t *testing.T) {
	cfg := &Config{
		Path:    "/p/conf",
		Values:  map[string]string{"A": "1", "B": "2"},
		KeysSet: map[string]bool{"A": true},
	}
	var buf bytes.Buffer
	if err := cfg.EmitJSON(&buf, false); err != nil {
		t.Fatalf("EmitJSON: %v", err)
	}
	if !strings.Contains(buf.String(), `"envelope_ver":"tekhton.config.v1"`) {
		t.Errorf("envelope_ver missing: %s", buf.String())
	}
}

func TestParse_InlineComments(t *testing.T) {
	cfg := &Config{Values: map[string]string{}, KeysSet: map[string]bool{}}
	p := writeConf(t, `PROJECT_NAME="t" # comment after quoted
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
`)
	if err := parseFile(p, cfg); err != nil {
		t.Fatalf("parseFile: %v", err)
	}
	// When the inline comment follows a complete quoted value, the value
	// (including quotes) survives because the quote-strip regex doesn't
	// match (trailing char is not the matching quote).
	if cfg.Values["PROJECT_NAME"] != `"t"` {
		t.Errorf("PROJECT_NAME=%q", cfg.Values["PROJECT_NAME"])
	}
}

func TestParse_CmdKeyInlineComment(t *testing.T) {
	// ANALYZE_CMD is a CMD key — metacharacters are allowed. Verify that inline
	// comment stripping and pipe preservation both work together. Quote-stripping
	// runs before inline-comment removal, so when the raw value is
	// `"eslint . | grep" # comment`, the trailing char at strip time is 't'
	// (not '"'), leaving the quotes intact after the comment is removed.
	p := writeConf(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="eslint . | grep" # comment
`)
	clearCIEnv(t)
	cfg, err := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if err != nil {
		t.Fatalf("Load should not error for CMD key with inline comment: %v", err)
	}
	v := cfg.Values["ANALYZE_CMD"]
	// Inline comment stripped: no # text in the stored value.
	if strings.Contains(v, "comment") {
		t.Errorf("inline comment leaked into ANALYZE_CMD value: %q", v)
	}
	// Pipe metachar preserved: CMD keys are exempt from the metachar rejection.
	if !strings.Contains(v, "|") {
		t.Errorf("pipe stripped from CMD key ANALYZE_CMD: %q", v)
	}
	// Exact value: quotes survive because they could not be stripped before
	// the inline comment was present (raw[last] != '"' at strip time).
	want := `"eslint . | grep"`
	if v != want {
		t.Errorf("ANALYZE_CMD: got %q, want %q", v, want)
	}
}

func TestParse_FindInlineComment(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"value", -1},
		{"value # comment", 6},
		{"value#nocomment", -1},
		{"#comment-at-start", -1}, // no preceding non-ws char
		{"a #c", 2},
		{"", -1},
	}
	for _, c := range cases {
		if got := findInlineComment(c.in); got != c.want {
			t.Errorf("findInlineComment(%q)=%d want %d", c.in, got, c.want)
		}
	}
}

// TestApplyLateDefaults_EmptyFastPath verifies that the empty-slice guard in
// applyLateDefaults returns without touching cfg.Values when lateDefaults is
// the currently-empty slice. This prevents a silent regression if the guard
// is removed before the slice is populated.
func TestApplyLateDefaults_EmptyFastPath(t *testing.T) {
	// lateDefaults must be empty for this test to be meaningful.
	if len(lateDefaults) != 0 {
		t.Skip("lateDefaults is non-empty; fast-path test is no longer relevant")
	}
	cfg := &Config{
		Values:  map[string]string{"EXISTING_KEY": "original_value"},
		KeysSet: map[string]bool{},
	}
	applyLateDefaults(cfg)
	// Values must be unchanged: no keys added, no existing key overwritten.
	if len(cfg.Values) != 1 {
		t.Errorf("expected 1 key after empty fast path, got %d: %v", len(cfg.Values), cfg.Values)
	}
	if cfg.Values["EXISTING_KEY"] != "original_value" {
		t.Errorf("existing key modified: got %q, want %q", cfg.Values["EXISTING_KEY"], "original_value")
	}
}

// TestApplyLateDefaults_NonEmptyPath exercises the non-fast-path branch by
// temporarily populating lateDefaults with a sentinel rule. This confirms the
// loop body is reachable and applies := semantics (absent key gets set, present
// key is left alone) — the same contract applyDefaults has.
func TestApplyLateDefaults_NonEmptyPath(t *testing.T) {
	// Save and restore lateDefaults so other tests are unaffected.
	saved := lateDefaults
	t.Cleanup(func() { lateDefaults = saved })

	lateDefaults = []defaultRule{
		{"LATE_KEY_ABSENT", lit("late_value")},
		{"LATE_KEY_PRESENT", lit("should_not_overwrite")},
	}

	cfg := &Config{
		Values:  map[string]string{"LATE_KEY_PRESENT": "original"},
		KeysSet: map[string]bool{},
	}
	applyLateDefaults(cfg)

	if cfg.Values["LATE_KEY_ABSENT"] != "late_value" {
		t.Errorf("absent key not set: got %q, want %q", cfg.Values["LATE_KEY_ABSENT"], "late_value")
	}
	if cfg.Values["LATE_KEY_PRESENT"] != "original" {
		t.Errorf(":= semantics violated: got %q, want %q (existing value must not be overwritten)",
			cfg.Values["LATE_KEY_PRESENT"], "original")
	}
}

// clearCIEnv removes every CI env var DetectCI inspects, plus every key
// with a default rule, so tests assert against bare defaults rather than
// values leaked from the parent shell (Tekhton self-hosts and exports the
// pipeline's own env). Called by every Load-touching test.
func clearCIEnv(t *testing.T) {
	t.Helper()
	keys := []string{"GITHUB_ACTIONS", "GITLAB_CI", "CIRCLECI", "TRAVIS",
		"BUILDKITE", "JENKINS_URL", "TF_BUILD", "TEAMCITY_VERSION",
		"BITBUCKET_BUILD_NUMBER", "CI"}
	for _, r := range baseDefaults {
		keys = append(keys, r.Key)
	}
	for _, k := range keys {
		old, ok := os.LookupEnv(k)
		_ = os.Unsetenv(k)
		if ok {
			oldCopy := old
			t.Cleanup(func() { _ = os.Setenv(k, oldCopy) })
		}
	}
}

func TestAllKeys(t *testing.T) {
	cfg := &Config{Values: map[string]string{"A": "1", "B": "2"}, KeysSet: map[string]bool{}}
	got := cfg.AllKeys()
	if len(got) != 2 {
		t.Errorf("AllKeys len=%d want 2", len(got))
	}
}

// TestAllKeys_EdgeCases covers the three AllKeys edge cases identified by
// review: duplicate keys from pipeline.conf, keys seeded only from env, and
// LoadDefaultsOnly with a non-empty pre-populated KeysSet.
func TestAllKeys_EdgeCases(t *testing.T) {
	t.Run("DuplicateKeyLastWins", func(t *testing.T) {
		clearCIEnv(t)
		// Same key appears twice; last value must win and AllKeys must return
		// the key exactly once.
		p := writeConf(t, "PROJECT_NAME=\"first\"\nPROJECT_NAME=\"second\"\nCLAUDE_STANDARD_MODEL=\"x\"\nANALYZE_CMD=\"echo ok\"\n")
		cfg, err := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		if cfg.Values["PROJECT_NAME"] != "second" {
			t.Errorf("last-write-wins: got %q, want %q", cfg.Values["PROJECT_NAME"], "second")
		}
		count := 0
		for _, k := range cfg.AllKeys() {
			if k == "PROJECT_NAME" {
				count++
			}
		}
		if count != 1 {
			t.Errorf("AllKeys returned PROJECT_NAME %d times, want 1", count)
		}
	})

	t.Run("EnvSeededKeyNotInKeysSet", func(t *testing.T) {
		clearCIEnv(t)
		// CODER_MAX_TURNS set only via env — must appear in Values (env seed)
		// but NOT in KeysSet (env is not pipeline.conf).
		t.Setenv("CODER_MAX_TURNS", "42")
		p := writeConf(t, "PROJECT_NAME=\"t\"\nCLAUDE_STANDARD_MODEL=\"x\"\nANALYZE_CMD=\"echo ok\"\n")
		cfg, err := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		if cfg.Values["CODER_MAX_TURNS"] != "42" {
			t.Errorf("env seed: CODER_MAX_TURNS=%q, want 42", cfg.Values["CODER_MAX_TURNS"])
		}
		if cfg.KeysSet["CODER_MAX_TURNS"] {
			t.Error("env-seeded key must not appear in KeysSet")
		}
		found := false
		for _, k := range cfg.AllKeys() {
			if k == "CODER_MAX_TURNS" {
				found = true
				break
			}
		}
		if !found {
			t.Error("AllKeys must include env-seeded CODER_MAX_TURNS")
		}
	})

	t.Run("LoadDefaultsOnlyNonEmptyKeysSet", func(t *testing.T) {
		clearCIEnv(t)
		// Pre-populate Values and KeysSet; LoadDefaultsOnly must not overwrite
		// a key already in Values (the := semantics), and the pre-existing
		// KeysSet entry must survive.
		cfg := &Config{
			Values:  map[string]string{"CODER_MAX_TURNS": "55"},
			KeysSet: map[string]bool{"CODER_MAX_TURNS": true},
		}
		cfg.LoadDefaultsOnly(LoadOptions{SuppressDiagnostics: true})
		if cfg.Values["CODER_MAX_TURNS"] != "55" {
			t.Errorf("pre-populated value overwritten: got %q, want 55", cfg.Values["CODER_MAX_TURNS"])
		}
		if !cfg.KeysSet["CODER_MAX_TURNS"] {
			t.Error("pre-populated KeysSet entry must survive LoadDefaultsOnly")
		}
		found := false
		for _, k := range cfg.AllKeys() {
			if k == "CODER_MAX_TURNS" {
				found = true
				break
			}
		}
		if !found {
			t.Error("AllKeys must include pre-populated CODER_MAX_TURNS after LoadDefaultsOnly")
		}
	})
}

// TestParse_FindInlineComment_ApostropheEdgeCases verifies that single-quote
// characters inside a value do not confuse the inline-comment detector. The
// apostrophe-escape path in EmitShell (shellQuote) runs on the stored value
// after comment stripping, so the two operations must compose correctly.
func TestParse_FindInlineComment_ApostropheEdgeCases(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"it's # comment", 5},     // apostrophe then space-hash: comment found
		{"it's# literal", -1},     // hash immediately after apostrophe (no space): not a comment
		{"it's value # here", 11}, // apostrophe early, space-hash later: comment found
		{"don't #stop", 6},        // apostrophe in word, space-hash: comment found
	}
	for _, c := range cases {
		if got := findInlineComment(c.in); got != c.want {
			t.Errorf("findInlineComment(%q)=%d want %d", c.in, got, c.want)
		}
	}
}

// TestLoad_ApostropheAndInlineComment exercises the full parse path for a
// value that contains an apostrophe and an inline comment. The comment must
// be stripped, the apostrophe preserved, and EmitShell must correctly escape
// it with the '\” idiom.
func TestLoad_ApostropheAndInlineComment(t *testing.T) {
	clearCIEnv(t)
	// ANALYZE_CMD ends in _CMD so metacharacters are allowed. The apostrophe
	// in the value is not a shell metachar, but it exercises the shell-quoting
	// path in EmitShell.
	p := writeConf(t, "PROJECT_NAME=\"t\"\nCLAUDE_STANDARD_MODEL=\"x\"\nANALYZE_CMD=it's valid # inline comment\n")
	cfg, err := Load(p, LoadOptions{ProjectDir: filepath.Dir(p), SuppressDiagnostics: true})
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	got := cfg.Values["ANALYZE_CMD"]
	if got != "it's valid" {
		t.Errorf("ANALYZE_CMD after comment strip: got %q, want %q", got, "it's valid")
	}

	// EmitShell must escape the apostrophe with the standard close/escape/open idiom.
	var buf bytes.Buffer
	if err := cfg.EmitShell(&buf); err != nil {
		t.Fatalf("EmitShell: %v", err)
	}
	shell := buf.String()
	want := "export ANALYZE_CMD='it'\\''s valid'"
	if !strings.Contains(shell, want) {
		t.Errorf("apostrophe not escaped correctly in EmitShell output.\nwant substring: %s\ngot:\n%s", want, shell)
	}
}

// TestEmitShell_EvalRoundTrip_SingleQuoteAndNewline verifies that a value
// containing both a single quote and a literal newline survives a full
// EmitShell + bash eval round-trip without corruption. This exercises the
// multi-line shell output path (the export statement spans two lines) and the
// apostrophe-escape path simultaneously.
func TestEmitShell_EvalRoundTrip_SingleQuoteAndNewline(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not found in PATH")
	}
	want := "it's a\nnewline value"
	cfg := &Config{
		Values:  map[string]string{"ROUNDTRIP_VAR": want},
		KeysSet: map[string]bool{},
	}
	var buf bytes.Buffer
	if err := cfg.EmitShell(&buf); err != nil {
		t.Fatalf("EmitShell: %v", err)
	}
	shell := buf.String()

	// Source the emitted shell output and print the variable back via printf
	// (not echo, to avoid trailing-newline interference).
	script := shell + "\nprintf '%s' \"$ROUNDTRIP_VAR\""
	out, err := exec.Command("bash", "-c", script).Output()
	if err != nil {
		t.Fatalf("bash eval: %v\nscript:\n%s", err, script)
	}
	if string(out) != want {
		t.Errorf("eval round-trip:\n  got  %q\n  want %q", string(out), want)
	}
}
