package config

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// runInlineValidation mirrors the case-statement blocks at the bottom of
// load_config(): enum-style keys whose values must be one of a fixed set,
// numeric keys whose values must be positive integers, threshold pairs that
// must hold an ordering invariant, etc. Values that fail validation are
// reset to a safe default and a warning is appended to cfg.Warnings.
func runInlineValidation(cfg *Config) {
	v := cfg.Values

	// TEKHTON_PIN_VERSION must be valid semver X.Y.Z, or empty.
	if pin := v["TEKHTON_PIN_VERSION"]; pin != "" {
		if !semverRE.MatchString(pin) {
			cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
				"[config] TEKHTON_PIN_VERSION must be valid semver X.Y.Z (got: %s). Ignoring pin.", pin))
			v["TEKHTON_PIN_VERSION"] = ""
		}
	}

	// PIPELINE_ORDER: standard | test_first | (auto → standard with warning).
	switch v["PIPELINE_ORDER"] {
	case "", "standard", "test_first":
		// valid
	case "auto":
		cfg.Warnings = append(cfg.Warnings,
			"[config] PIPELINE_ORDER=auto requires V4 PM agent — falling back to standard.")
		v["PIPELINE_ORDER"] = "standard"
	default:
		cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
			"[config] PIPELINE_ORDER must be standard|test_first|auto (got: %s). Using standard.",
			v["PIPELINE_ORDER"]))
		v["PIPELINE_ORDER"] = "standard"
	}

	// UI_FRAMEWORK enum.
	if uf := v["UI_FRAMEWORK"]; uf != "" {
		valid := false
		for _, ok := range []string{"auto", "playwright", "cypress", "selenium", "puppeteer", "testing-library", "detox"} {
			if uf == ok {
				valid = true
				break
			}
		}
		if !valid {
			cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
				"[config] UI_FRAMEWORK must be auto|playwright|cypress|selenium|puppeteer|testing-library|detox (got: %s). Clearing.",
				uf))
			v["UI_FRAMEWORK"] = ""
		}
	}

	// UI_SERVE_PORT must be numeric.
	if x := v["UI_SERVE_PORT"]; x != "" && !isUint(x) {
		cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
			"[config] UI_SERVE_PORT must be numeric (got: %s). Using 3000.", x))
		v["UI_SERVE_PORT"] = "3000"
	}

	// UI_VALIDATION_VIEWPORTS — comma-separated NNNNxNNNN pairs.
	if vp := v["UI_VALIDATION_VIEWPORTS"]; vp != "" {
		ok := true
		for _, p := range strings.Split(vp, ",") {
			p = strings.TrimSpace(p)
			if !viewportRE.MatchString(p) {
				ok = false
				break
			}
		}
		if !ok {
			cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
				"[config] UI_VALIDATION_VIEWPORTS must match NNNNxNNNN format (got: %s). Using default.", vp))
			v["UI_VALIDATION_VIEWPORTS"] = "1280x800,375x812"
		}
	}

	// Numeric positive integer fields.
	for _, k := range []string{"UI_VALIDATION_TIMEOUT", "UI_SERVER_STARTUP_TIMEOUT"} {
		if x := v[k]; x != "" && !isUint(x) {
			cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
				"[config] %s must be a positive integer (got: %s). Using 30.", k, x))
			v[k] = "30"
		}
	}

	// UI_VALIDATION_CONSOLE_SEVERITY enum.
	if sv := v["UI_VALIDATION_CONSOLE_SEVERITY"]; sv != "" && sv != "error" && sv != "warn" {
		cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
			"[config] UI_VALIDATION_CONSOLE_SEVERITY must be error|warn (got: %s). Using error.", sv))
		v["UI_VALIDATION_CONSOLE_SEVERITY"] = "error"
	}

	// SECURITY_UNFIXABLE_POLICY enum.
	if sp := v["SECURITY_UNFIXABLE_POLICY"]; sp != "" {
		switch sp {
		case "escalate", "halt", "waiver":
		default:
			cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
				"[config] SECURITY_UNFIXABLE_POLICY must be escalate|halt|waiver (got: %s). Using 'escalate'.", sp))
			v["SECURITY_UNFIXABLE_POLICY"] = "escalate"
		}
	}

	// SECURITY_BLOCK_SEVERITY enum.
	if sb := v["SECURITY_BLOCK_SEVERITY"]; sb != "" {
		switch sb {
		case "CRITICAL", "HIGH", "MEDIUM", "LOW":
		default:
			cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
				"[config] SECURITY_BLOCK_SEVERITY must be CRITICAL|HIGH|MEDIUM|LOW (got: %s). Using 'HIGH'.", sb))
			v["SECURITY_BLOCK_SEVERITY"] = "HIGH"
		}
	}

	// INTAKE_CLARITY_THRESHOLD: 0-100.
	if x := v["INTAKE_CLARITY_THRESHOLD"]; x != "" && isUint(x) {
		if n, _ := strconv.Atoi(x); n > 100 {
			cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
				"[config] INTAKE_CLARITY_THRESHOLD must be 0-100 (got: %s). Using 40.", x))
			v["INTAKE_CLARITY_THRESHOLD"] = "40"
		}
	}
	if x := v["INTAKE_TWEAK_THRESHOLD"]; x != "" && isUint(x) {
		if n, _ := strconv.Atoi(x); n > 100 {
			cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
				"[config] INTAKE_TWEAK_THRESHOLD must be 0-100 (got: %s). Using 70.", x))
			v["INTAKE_TWEAK_THRESHOLD"] = "70"
		}
	}
	// INTAKE_TWEAK > INTAKE_CLARITY ordering.
	tweak, _ := strconv.Atoi(v["INTAKE_TWEAK_THRESHOLD"])
	clarity, _ := strconv.Atoi(v["INTAKE_CLARITY_THRESHOLD"])
	if tweak > 0 && clarity > 0 && tweak <= clarity {
		cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
			"[config] INTAKE_TWEAK_THRESHOLD (%d) must be greater than INTAKE_CLARITY_THRESHOLD (%d). Using defaults.",
			tweak, clarity))
		v["INTAKE_CLARITY_THRESHOLD"] = "40"
		v["INTAKE_TWEAK_THRESHOLD"] = "70"
	}

	// DASHBOARD_VERBOSITY enum.
	if dv := v["DASHBOARD_VERBOSITY"]; dv != "" {
		switch dv {
		case "minimal", "normal", "verbose":
		default:
			cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
				"[config] DASHBOARD_VERBOSITY must be minimal|normal|verbose (got: %s). Using 'normal'.", dv))
			v["DASHBOARD_VERBOSITY"] = "normal"
		}
	}

	// Range checks (1-N) for several numeric keys.
	rangeCheck(cfg, "DASHBOARD_HISTORY_DEPTH", 1, 100, "50")
	rangeCheck(cfg, "CAUSAL_LOG_RETENTION_RUNS", 1, 200, "50")
	rangeCheck(cfg, "CAUSAL_LOG_MAX_EVENTS", 1, 10000, "2000")
	rangeCheck(cfg, "DASHBOARD_MAX_TIMELINE_EVENTS", 1, 2000, "500")
	rangeCheck(cfg, "QUOTA_RETRY_INTERVAL", 60, 3600, "300")
	rangeCheck(cfg, "QUOTA_RESERVE_PCT", 1, 50, "10")
	rangeCheck(cfg, "QUOTA_MAX_PAUSE_DURATION", 300, 86400, "18900")

	// HEALTH weights must sum to 100 when HEALTH_ENABLED=true.
	if v["HEALTH_ENABLED"] == "true" {
		sum := atoiOr(v["HEALTH_WEIGHT_TESTS"], 30) +
			atoiOr(v["HEALTH_WEIGHT_QUALITY"], 25) +
			atoiOr(v["HEALTH_WEIGHT_DEPS"], 15) +
			atoiOr(v["HEALTH_WEIGHT_DOCS"], 15) +
			atoiOr(v["HEALTH_WEIGHT_HYGIENE"], 15)
		if sum != 100 {
			cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
				"[config] HEALTH_WEIGHT_* must sum to 100 (got: %d). Using defaults.", sum))
			v["HEALTH_WEIGHT_TESTS"] = "30"
			v["HEALTH_WEIGHT_QUALITY"] = "25"
			v["HEALTH_WEIGHT_DEPS"] = "15"
			v["HEALTH_WEIGHT_DOCS"] = "15"
			v["HEALTH_WEIGHT_HYGIENE"] = "15"
		}
		rangeCheck(cfg, "HEALTH_SAMPLE_SIZE", 5, 100, "20")
	}
}

var (
	semverRE   = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
	viewportRE = regexp.MustCompile(`^[0-9]+x[0-9]+$`)
)

// rangeCheck enforces a [min, max] window on an integer key. On violation,
// resets to fallback and appends a warning. Empty/absent values are left alone.
func rangeCheck(cfg *Config, key string, min, max int, fallback string) {
	x := cfg.Values[key]
	if x == "" || !isUint(x) {
		return
	}
	n, _ := strconv.Atoi(x)
	if n < min || n > max {
		cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
			"[config] %s must be %d-%d (got: %s). Using %s.", key, min, max, x, fallback))
		cfg.Values[key] = fallback
	}
}

// runClamps mirrors the _clamp_config_value / _clamp_config_float calls at
// the end of lib/config_defaults.sh. Each entry says: "this key must not
// exceed maxInt" (for ints) or "this key must lie in [min, max]" (for floats).
// Bash only clamps integers when value > max — values <= max pass unchanged
// even if they are 0. We mirror that exactly.
func runClamps(cfg *Config) {
	for _, c := range intClamps {
		v := cfg.Values[c.Key]
		if v == "" || !isUint(v) {
			continue
		}
		n, _ := strconv.Atoi(v)
		if n > c.Max {
			cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
				"[config] %s=%s exceeds hard cap (%d). Clamped to %d.",
				c.Key, v, c.Max, c.Max))
			cfg.Values[c.Key] = strconv.Itoa(c.Max)
		}
	}
	for _, c := range floatClamps {
		v := cfg.Values[c.Key]
		if v == "" {
			continue
		}
		f, err := strconv.ParseFloat(v, 64)
		if err != nil {
			continue
		}
		clamped := f
		if clamped < c.Min {
			clamped = c.Min
		}
		if clamped > c.Max {
			clamped = c.Max
		}
		// Format as %.1f to match the bash awk format string.
		out := strconv.FormatFloat(clamped, 'f', 1, 64)
		if out != v {
			cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
				"[config] %s=%s outside range [%g, %g]. Clamped to %s.",
				c.Key, v, c.Min, c.Max, out))
			cfg.Values[c.Key] = out
		}
	}
}

type intClamp struct {
	Key string
	Max int
}

type floatClamp struct {
	Key string
	Min float64
	Max float64
}

// intClamps mirrors the _clamp_config_value calls at the bottom of
// lib/config_defaults.sh.
var intClamps = []intClamp{
	{"MAX_REVIEW_CYCLES", 20},
	{"CODER_MAX_TURNS", 500},
	{"JR_CODER_MAX_TURNS", 500},
	{"REVIEWER_MAX_TURNS", 500},
	{"TESTER_MAX_TURNS", 500},
	{"SCOUT_MAX_TURNS", 500},
	{"ARCHITECT_MAX_TURNS", 500},
	{"CODER_MAX_TURNS_CAP", 500},
	{"REVIEWER_MAX_TURNS_CAP", 500},
	{"TESTER_MAX_TURNS_CAP", 500},
	{"MILESTONE_MAX_REVIEW_CYCLES", 40},
	{"MILESTONE_CODER_MAX_TURNS", 500},
	{"MILESTONE_JR_CODER_MAX_TURNS", 500},
	{"MILESTONE_REVIEWER_MAX_TURNS", 500},
	{"MILESTONE_TESTER_MAX_TURNS", 500},
	{"MILESTONE_ACTIVITY_TIMEOUT_MULTIPLIER", 10},
	{"MILESTONE_SPLIT_MAX_TURNS", 50},
	{"MILESTONE_SPLIT_THRESHOLD_PCT", 500},
	{"MILESTONE_MAX_SPLIT_DEPTH", 10},
	{"CLEANUP_BATCH_SIZE", 50},
	{"CLEANUP_MAX_TURNS", 500},
	{"CLEANUP_TRIGGER_THRESHOLD", 100},
	{"ACTION_ITEMS_WARN_THRESHOLD", 100},
	{"ACTION_ITEMS_CRITICAL_THRESHOLD", 200},
	{"HUMAN_NOTES_WARN_THRESHOLD", 100},
	{"HUMAN_NOTES_CRITICAL_THRESHOLD", 200},
	{"HUMAN_NOTES_PROMOTE_THRESHOLD", 200},
	{"SECURITY_MAX_TURNS", 500},
	{"SECURITY_MIN_TURNS", 500},
	{"SECURITY_MAX_TURNS_CAP", 500},
	{"SECURITY_MAX_REWORK_CYCLES", 10},
	{"MILESTONE_SECURITY_MAX_TURNS", 500},
	{"INTAKE_MAX_TURNS", 50},
	{"INTAKE_CLARITY_THRESHOLD", 100},
	{"INTAKE_TWEAK_THRESHOLD", 100},
	{"ARTIFACT_MERGE_MAX_TURNS", 50},
	{"SPECIALIST_SECURITY_MAX_TURNS", 50},
	{"SPECIALIST_PERFORMANCE_MAX_TURNS", 50},
	{"SPECIALIST_API_MAX_TURNS", 50},
	{"SPECIALIST_UI_MAX_TURNS", 50},
	{"DOCS_AGENT_MAX_TURNS", 50},
	{"DRAFT_MILESTONES_MAX_TURNS", 100},
	{"DRAFT_MILESTONES_SEED_EXEMPLARS", 10},
	{"MAX_PIPELINE_ATTEMPTS", 20},
	{"FIX_NONBLOCKERS_MAX_PASSES", 20},
	{"FIX_DRIFT_MAX_PASSES", 20},
	{"AUTONOMOUS_TIMEOUT", 14400},
	{"MAX_AUTONOMOUS_AGENT_CALLS", 500},
	{"METRICS_MIN_RUNS", 100},
	{"MAX_CONTINUATION_ATTEMPTS", 10},
	{"MAX_TRANSIENT_RETRIES", 10},
	{"TRANSIENT_RETRY_BASE_DELAY", 300},
	{"TRANSIENT_RETRY_MAX_DELAY", 600},
	{"REWORK_TURN_MAX_CAP", 500},
	{"MILESTONE_WINDOW_PCT", 80},
	{"MILESTONE_WINDOW_MAX_CHARS", 100000},
	{"REPO_MAP_TOKEN_BUDGET", 16384},
	{"REPO_MAP_HISTORY_MAX_RECORDS", 1000},
	{"SERENA_STARTUP_TIMEOUT", 120},
	{"SERENA_MAX_RETRIES", 10},
	{"CAUSAL_LOG_RETENTION_RUNS", 200},
	{"CAUSAL_LOG_MAX_EVENTS", 10000},
	{"RUN_MEMORY_MAX_ENTRIES", 500},
	{"TEST_AUDIT_MAX_TURNS", 50},
	{"TEST_AUDIT_MAX_REWORK_CYCLES", 5},
	{"TEST_AUDIT_ROLLING_SAMPLE_K", 20},
	{"TEST_AUDIT_HISTORY_MAX_RECORDS", 2000},
	{"AUTO_FIX_MAX_DEPTH", 5},
	{"AUTO_FIX_OUTPUT_LIMIT", 16000},
	{"PREFLIGHT_FIX_MAX_ATTEMPTS", 10},
	{"PREFLIGHT_FIX_MAX_TURNS", 500},
	{"FINAL_FIX_MAX_ATTEMPTS", 10},
	{"FINAL_FIX_MAX_TURNS", 500},
	{"BUILD_FIX_MAX_ATTEMPTS", 20},
	{"BUILD_FIX_BASE_TURN_DIVISOR", 100},
	{"BUILD_FIX_MAX_TURN_MULTIPLIER", 500},
	{"BUILD_FIX_TOTAL_TURN_CAP", 1000},
	{"PREFLIGHT_BAK_RETAIN_COUNT", 1000},
	{"TESTER_FIX_MAX_DEPTH", 5},
	{"TESTER_FIX_MAX_TURNS", 100},
	{"TESTER_FIX_OUTPUT_LIMIT", 16000},
	{"TEST_BASELINE_STUCK_THRESHOLD", 10},
	{"BUILD_GATE_TIMEOUT", 1800},
	{"BUILD_GATE_ANALYZE_TIMEOUT", 900},
	{"BUILD_GATE_COMPILE_TIMEOUT", 600},
	{"BUILD_GATE_CONSTRAINT_TIMEOUT", 300},
	{"UI_TEST_TIMEOUT", 600},
	{"UI_SERVE_PORT", 65535},
	{"UI_SERVER_STARTUP_TIMEOUT", 120},
	{"UI_VALIDATION_TIMEOUT", 120},
	{"TESTER_WRITE_FAILING_MAX_TURNS", 100},
	{"DASHBOARD_HISTORY_DEPTH", 100},
	{"DASHBOARD_REFRESH_INTERVAL", 300},
	{"DASHBOARD_MAX_TIMELINE_EVENTS", 2000},
	{"HEALTH_SAMPLE_SIZE", 100},
	{"QUOTA_RETRY_INTERVAL", 3600},
	{"QUOTA_RESERVE_PCT", 50},
	{"QUOTA_MAX_PAUSE_DURATION", 86400},
	{"QUOTA_SLEEP_CHUNK", 60},
	{"QUOTA_PROBE_MIN_INTERVAL", 3600},
	{"QUOTA_PROBE_MAX_INTERVAL", 3600},
}

// floatClamps mirrors the _clamp_config_float calls.
var floatClamps = []floatClamp{
	{"REWORK_TURN_ESCALATION_FACTOR", 0.1, 10.0},
	{"UI_GATE_ENV_RETRY_TIMEOUT_FACTOR", 0.1, 1.0},
	{"CODER_TDD_TURN_MULTIPLIER", 0.5, 3.0},
	{"BUG_TURN_MULTIPLIER", 0.1, 3.0},
	{"FEAT_TURN_MULTIPLIER", 0.1, 3.0},
	{"POLISH_TURN_MULTIPLIER", 0.1, 3.0},
}

// resolvePaths converts relative path values to absolute paths under
// PROJECT_DIR. Mirrors the trailing block in load_config().
func resolvePaths(cfg *Config) {
	pd := cfg.ProjectDir
	if pd == "" {
		pd = cfg.Values["PROJECT_DIR"]
	}
	if pd == "" {
		return
	}
	for _, k := range []string{"PIPELINE_STATE_FILE", "LOG_DIR", "MILESTONE_DIR", "CAUSAL_LOG_FILE"} {
		v := cfg.Values[k]
		if v == "" || filepath.IsAbs(v) {
			continue
		}
		cfg.Values[k] = pd + "/" + v
	}
}

// isUint returns true when s parses as a non-negative base-10 integer.
func isUint(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
