package config

import (
	"strconv"
)

// defaultRule represents one `: "${KEY:=VALUE}"` line from
// lib/config_defaults.sh. Resolve runs against the in-progress Values map so
// derived defaults (e.g. `MILESTONE_CODER_MAX_TURNS = CODER_MAX_TURNS * 2`)
// see earlier defaults. Order matters — earlier entries are visible to later
// resolvers.
type defaultRule struct {
	Key     string
	Resolve func(v map[string]string) string
}

// DefaultKeys returns the list of every key that has a default rule. Used by
// tests to clear inherited env vars before asserting bare-default behavior.
func DefaultKeys() []string {
	out := make([]string, 0, len(baseDefaults))
	for _, r := range baseDefaults {
		out = append(out, r.Key)
	}
	return out
}

// applyDefaults walks the base default rule list, setting cfg.Values[key]
// only when the key is currently absent. Mirrors `:=` semantics from bash.
// Excludes TEKHTON_UI_GATE_FORCE_NONINTERACTIVE — that key is owned by
// applyCIGateDefault, which runs between applyDefaults and applyLateDefaults.
func applyDefaults(cfg *Config) {
	for _, r := range baseDefaults {
		if _, ok := cfg.Values[r.Key]; ok {
			continue
		}
		cfg.Values[r.Key] = r.Resolve(cfg.Values)
	}
}

// applyLateDefaults fills any values that depend on the post-CI state
// (TEKHTON_UI_GATE_FORCE_NONINTERACTIVE residue) plus a few derived caps that
// reference clamp-input values. Idempotent: re-running has no effect. The
// empty-slice fast path keeps the call site cost-free while the hook is
// reserved for future late-phase keys.
func applyLateDefaults(cfg *Config) {
	if len(lateDefaults) == 0 {
		return
	}
	for _, r := range lateDefaults {
		if _, ok := cfg.Values[r.Key]; ok {
			continue
		}
		cfg.Values[r.Key] = r.Resolve(cfg.Values)
	}
}

// applyMilestoneOverrides mirrors apply_milestone_overrides() — the few keys
// the milestone mode replaces wholesale with the MILESTONE_* equivalents,
// plus the activity-timeout multiplier.
func applyMilestoneOverrides(cfg *Config) {
	cfg.Values["MAX_REVIEW_CYCLES"] = cfg.Values["MILESTONE_MAX_REVIEW_CYCLES"]
	cfg.Values["CODER_MAX_TURNS"] = cfg.Values["MILESTONE_CODER_MAX_TURNS"]
	cfg.Values["JR_CODER_MAX_TURNS"] = cfg.Values["MILESTONE_JR_CODER_MAX_TURNS"]
	cfg.Values["REVIEWER_MAX_TURNS"] = cfg.Values["MILESTONE_REVIEWER_MAX_TURNS"]
	cfg.Values["TESTER_MAX_TURNS"] = cfg.Values["MILESTONE_TESTER_MAX_TURNS"]
	cfg.Values["CLAUDE_TESTER_MODEL"] = cfg.Values["MILESTONE_TESTER_MODEL"]

	base := atoiOr(cfg.Values["AGENT_ACTIVITY_TIMEOUT"], 600)
	mul := atoiOr(cfg.Values["MILESTONE_ACTIVITY_TIMEOUT_MULTIPLIER"], 3)
	cfg.Values["AGENT_ACTIVITY_TIMEOUT"] = strconv.Itoa(base * mul)
}

// lit returns a constant resolver.
func lit(s string) func(map[string]string) string {
	return func(_ map[string]string) string { return s }
}

// ref returns a resolver that copies the value of another key.
func ref(k string) func(map[string]string) string {
	return func(v map[string]string) string { return v[k] }
}

// concat builds a path or compound string from a sequence of literal/ref segments.
func concat(parts ...func(map[string]string) string) func(map[string]string) string {
	return func(v map[string]string) string {
		out := ""
		for _, p := range parts {
			out += p(v)
		}
		return out
	}
}

// imul multiplies an integer-valued key by a constant. Returns "" if the key
// has no numeric value (matches bash arithmetic-on-empty behavior of 0 *
// anything = 0, which we mirror as "0").
func imul(k string, factor int) func(map[string]string) string {
	return func(v map[string]string) string {
		return strconv.Itoa(atoiOr(v[k], 0) * factor)
	}
}

// idiv divides an integer-valued key by a constant. Returns "0" on parse failure.
func idiv(k string, divisor int) func(map[string]string) string {
	return func(v map[string]string) string {
		if divisor == 0 {
			return "0"
		}
		return strconv.Itoa(atoiOr(v[k], 0) / divisor)
	}
}

// iadd adds an integer constant to an integer-valued key.
func iadd(k string, addend int) func(map[string]string) string {
	return func(v map[string]string) string {
		return strconv.Itoa(atoiOr(v[k], 0) + addend)
	}
}

// atoiOr parses s as a base-10 int, returning fallback on any error.
func atoiOr(s string, fallback int) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		return fallback
	}
	return n
}

// dirOrTekhton produces "${TEKHTON_DIR}/<basename>".
func tdFile(name string) func(map[string]string) string {
	return concat(ref("TEKHTON_DIR"), lit("/"+name))
}

// baseDefaults mirrors the contents of lib/config_defaults.sh in declaration
// order. Each entry corresponds to a `: "${KEY:=VALUE}"` line. Defaults that
// reference earlier keys use ref()/concat()/imul()/iadd()/idiv().
var baseDefaults = []defaultRule{
	{"TEKHTON_DIR", lit(".tekhton")},

	{"TEKHTON_EXPRESS_ENABLED", lit("true")},
	{"EXPRESS_PERSIST_CONFIG", lit("true")},
	{"EXPRESS_PERSIST_ROLES", lit("false")},

	{"VERBOSE_OUTPUT", lit("false")},

	{"CONTEXT_BUDGET_PCT", lit("50")},
	{"CHARS_PER_TOKEN", lit("4")},
	{"CONTEXT_BUDGET_ENABLED", lit("true")},
	{"CONTEXT_COMPILER_ENABLED", lit("false")},

	{"CLAUDE_STANDARD_MODEL", lit("claude-sonnet-4-6")},
	{"REQUIRED_TOOLS", lit("git claude")},
	{"CLAUDE_CODER_MODEL", ref("CLAUDE_STANDARD_MODEL")},
	{"CLAUDE_JR_CODER_MODEL", ref("CLAUDE_STANDARD_MODEL")},
	{"CLAUDE_REVIEWER_MODEL", ref("CLAUDE_STANDARD_MODEL")},
	{"CLAUDE_TESTER_MODEL", ref("CLAUDE_STANDARD_MODEL")},
	{"CODER_MAX_TURNS", lit("80")},
	{"JR_CODER_MAX_TURNS", lit("40")},
	{"REVIEWER_MAX_TURNS", lit("20")},
	{"TESTER_MAX_TURNS", lit("50")},
	{"MAX_REVIEW_CYCLES", lit("3")},
	{"TEST_CMD", lit("true")},
	{"PIPELINE_STATE_FILE", lit(".claude/PIPELINE_STATE.md")},
	{"LOG_DIR", lit(".claude/logs")},
	{"CODER_ROLE_FILE", lit(".claude/agents/coder.md")},
	{"REVIEWER_ROLE_FILE", lit(".claude/agents/reviewer.md")},
	{"TESTER_ROLE_FILE", lit(".claude/agents/tester.md")},
	{"JR_CODER_ROLE_FILE", lit(".claude/agents/jr-coder.md")},
	{"PROJECT_RULES_FILE", lit("CLAUDE.md")},

	{"PROJECT_DESCRIPTION", lit("multi-agent development pipeline")},
	{"SCOUT_MAX_TURNS", lit("20")},
	{"CLAUDE_SCOUT_MODEL", ref("CLAUDE_JR_CODER_MODEL")},
	{"SEED_CONTRACTS_MAX_TURNS", lit("20")},
	{"BUILD_CHECK_CMD", lit("")},
	{"ANALYZE_ERROR_PATTERN", lit("error")},
	{"BUILD_ERROR_PATTERN", lit("ERROR")},
	{"ARCHITECTURE_FILE", lit("")},
	{"GLOSSARY_FILE", lit("")},
	{"NOTES_FILTER_CATEGORIES", lit("BUG|FEAT|POLISH")},
	{"INLINE_CONTRACT_PATTERN", lit("")},
	{"INLINE_CONTRACT_SEARCH_CMD", lit("")},
	{"SEED_CONTRACTS_ENABLED", lit("false")},
	{"DESIGN_FILE", tdFile("DESIGN.md")},

	{"CODER_SUMMARY_FILE", tdFile("CODER_SUMMARY.md")},
	{"REVIEWER_REPORT_FILE", tdFile("REVIEWER_REPORT.md")},
	{"TESTER_REPORT_FILE", tdFile("TESTER_REPORT.md")},
	{"JR_CODER_SUMMARY_FILE", tdFile("JR_CODER_SUMMARY.md")},
	{"BUILD_ERRORS_FILE", tdFile("BUILD_ERRORS.md")},
	{"BUILD_RAW_ERRORS_FILE", tdFile("BUILD_RAW_ERRORS.txt")},
	{"BUILD_ROUTING_DIAGNOSIS_FILE", tdFile("BUILD_ROUTING_DIAGNOSIS.md")},
	{"BUILD_FIX_REPORT_FILE", tdFile("BUILD_FIX_REPORT.md")},
	{"UI_TEST_ERRORS_FILE", tdFile("UI_TEST_ERRORS.md")},
	{"PREFLIGHT_ERRORS_FILE", tdFile("PREFLIGHT_ERRORS.md")},
	{"DIAGNOSIS_FILE", tdFile("DIAGNOSIS.md")},
	{"CLARIFICATIONS_FILE", tdFile("CLARIFICATIONS.md")},
	{"HUMAN_NOTES_FILE", tdFile("HUMAN_NOTES.md")},
	{"SPECIALIST_REPORT_FILE", tdFile("SPECIALIST_REPORT.md")},
	{"UI_VALIDATION_REPORT_FILE", tdFile("UI_VALIDATION_REPORT.md")},
	{"PREFLIGHT_REPORT_FILE", tdFile("PREFLIGHT_REPORT.md")},

	{"SCOUT_REPORT_FILE", tdFile("SCOUT_REPORT.md")},
	{"ARCHITECT_PLAN_FILE", tdFile("ARCHITECT_PLAN.md")},
	{"CLEANUP_REPORT_FILE", tdFile("CLEANUP_REPORT.md")},
	{"DRIFT_ARCHIVE_FILE", tdFile("DRIFT_ARCHIVE.md")},
	{"PROJECT_INDEX_FILE", tdFile("PROJECT_INDEX.md")},
	{"REPLAN_DELTA_FILE", tdFile("REPLAN_DELTA.md")},
	{"MERGE_CONTEXT_FILE", tdFile("MERGE_CONTEXT.md")},

	{"FINAL_FIX_ENABLED", lit("true")},
	{"FINAL_FIX_MAX_ATTEMPTS", lit("2")},
	{"FINAL_FIX_MAX_TURNS", idiv("CODER_MAX_TURNS", 3)},
	{"TEST_FIX_FOCUS_ENABLED", lit("true")},

	{"BUILD_FIX_ENABLED", lit("true")},
	{"BUILD_FIX_MAX_ATTEMPTS", lit("3")},
	{"BUILD_FIX_BASE_TURN_DIVISOR", lit("3")},
	{"BUILD_FIX_MAX_TURN_MULTIPLIER", lit("100")},
	{"BUILD_FIX_REQUIRE_PROGRESS", lit("true")},
	{"BUILD_FIX_TOTAL_TURN_CAP", lit("120")},

	{"ARCHITECTURE_LOG_FILE", tdFile("ARCHITECTURE_LOG.md")},
	{"DRIFT_LOG_FILE", tdFile("DRIFT_LOG.md")},
	{"HUMAN_ACTION_FILE", tdFile("HUMAN_ACTION_REQUIRED.md")},
	{"DRIFT_OBSERVATION_THRESHOLD", lit("8")},
	{"DRIFT_RUNS_SINCE_AUDIT_THRESHOLD", lit("5")},
	{"DRIFT_RESOLVED_KEEP_COUNT", lit("20")},
	{"NON_BLOCKING_LOG_FILE", tdFile("NON_BLOCKING_LOG.md")},
	{"NON_BLOCKING_INJECTION_THRESHOLD", lit("8")},

	{"ARCHITECT_ROLE_FILE", lit(".claude/agents/architect.md")},
	{"ARCHITECT_MAX_TURNS", lit("25")},
	{"MILESTONE_ARCHITECT_MAX_TURNS", imul("ARCHITECT_MAX_TURNS", 2)},
	{"CLAUDE_ARCHITECT_MODEL", ref("CLAUDE_STANDARD_MODEL")},
	{"DEPENDENCY_CONSTRAINTS_FILE", lit("")},

	{"AGENT_NULL_RUN_THRESHOLD", lit("2")},
	{"AGENT_SKIP_PERMISSIONS", lit("false")},

	{"DYNAMIC_TURNS_ENABLED", lit("true")},
	{"CODER_MIN_TURNS", lit("60")},
	{"CODER_MAX_TURNS_CAP", lit("200")},
	{"REVIEWER_MIN_TURNS", lit("20")},
	{"REVIEWER_MAX_TURNS_CAP", lit("60")},
	{"TESTER_MIN_TURNS", lit("30")},
	{"TESTER_MAX_TURNS_CAP", lit("120")},

	{"CLARIFICATION_ENABLED", lit("true")},
	{"REPLAN_ENABLED", lit("true")},

	// REPLAN_MODEL/REPLAN_MAX_TURNS reference unset PLAN_GENERATION_*. Falls
	// through to the bash defaults: PLAN_GENERATION_MODEL or "opus", and 50.
	{"REPLAN_MODEL", func(v map[string]string) string {
		if x := v["PLAN_GENERATION_MODEL"]; x != "" {
			return x
		}
		if x := v["CLAUDE_PLAN_MODEL"]; x != "" {
			return x
		}
		return "opus"
	}},
	{"REPLAN_MAX_TURNS", func(v map[string]string) string {
		if x := v["PLAN_GENERATION_MAX_TURNS"]; x != "" {
			return x
		}
		return "50"
	}},

	{"AUTO_ADVANCE_ENABLED", lit("false")},
	{"AUTO_ADVANCE_LIMIT", lit("3")},
	{"AUTO_ADVANCE_CONFIRM", lit("true")},

	{"MILESTONE_TAG_ON_COMPLETE", lit("false")},

	{"MILESTONE_DAG_ENABLED", lit("true")},
	{"MILESTONE_DIR", lit(".claude/milestones")},
	{"MILESTONE_MANIFEST", lit("MANIFEST.cfg")},
	{"MILESTONE_AUTO_MIGRATE", lit("true")},
	{"MILESTONE_WINDOW_PCT", lit("30")},
	{"MILESTONE_WINDOW_MAX_CHARS", lit("20000")},

	{"REPO_MAP_ENABLED", lit("false")},
	{"REPO_MAP_TOKEN_BUDGET", lit("2048")},
	{"REPO_MAP_CACHE_DIR", lit(".claude/index")},
	{"REPO_MAP_LANGUAGES", lit("auto")},
	{"REPO_MAP_VENV_DIR", lit(".claude/indexer-venv")},
	{"REPO_MAP_HISTORY_ENABLED", lit("true")},
	{"REPO_MAP_HISTORY_MAX_RECORDS", lit("200")},
	{"SCOUT_REPO_MAP_TOOLS_ONLY", lit("true")},
	{"INDEXER_STARTUP_AUDIT", lit("true")},

	{"TUI_ENABLED", lit("auto")},
	{"TUI_TICK_MS", lit("500")},
	{"TUI_EVENT_LINES", lit("60")},
	{"TUI_VENV_DIR", ref("REPO_MAP_VENV_DIR")},
	{"TUI_COMPLETE_HOLD_TIMEOUT", lit("120")},
	{"TUI_SIMPLE_LOGO", lit("false")},
	{"TUI_WATCHDOG_TIMEOUT", lit("300")},
	{"TUI_LIFECYCLE_V2", lit("true")},

	{"SERENA_ENABLED", lit("false")},
	{"SERENA_PATH", lit(".claude/serena")},
	{"SERENA_CONFIG_PATH", lit("")},
	{"SERENA_LANGUAGE_SERVERS", lit("auto")},
	{"SERENA_STARTUP_TIMEOUT", lit("30")},
	{"SERENA_MAX_RETRIES", lit("2")},

	{"MILESTONE_SPLIT_ENABLED", lit("true")},
	{"MILESTONE_SPLIT_MODEL", ref("CLAUDE_CODER_MODEL")},
	{"MILESTONE_SPLIT_MAX_TURNS", lit("15")},
	{"MILESTONE_SPLIT_THRESHOLD_PCT", lit("120")},
	{"MILESTONE_AUTO_RETRY", lit("true")},
	{"MILESTONE_MAX_SPLIT_DEPTH", lit("6")},

	{"CLEANUP_ENABLED", lit("false")},
	{"CLEANUP_BATCH_SIZE", lit("5")},
	{"CLEANUP_MAX_TURNS", lit("15")},
	{"CLEANUP_TRIGGER_THRESHOLD", lit("5")},

	{"ACTION_ITEMS_WARN_THRESHOLD", ref("CLEANUP_TRIGGER_THRESHOLD")},
	{"ACTION_ITEMS_CRITICAL_THRESHOLD", imul("ACTION_ITEMS_WARN_THRESHOLD", 2)},
	{"HUMAN_NOTES_WARN_THRESHOLD", lit("10")},
	{"HUMAN_NOTES_CRITICAL_THRESHOLD", lit("20")},

	{"HUMAN_NOTES_TRIAGE_ENABLED", lit("true")},
	{"HUMAN_NOTES_TRIAGE_MODEL", lit("haiku")},
	{"HUMAN_NOTES_PROMOTE_THRESHOLD", lit("20")},
	{"HUMAN_NOTES_PROMOTE_MODE", lit("confirm")},

	{"SCOUT_ON_BUG", lit("always")},
	{"SCOUT_ON_FEAT", lit("auto")},
	{"SCOUT_ON_POLISH", lit("never")},
	{"BUG_TURN_MULTIPLIER", lit("1.0")},
	{"FEAT_TURN_MULTIPLIER", lit("1.0")},
	{"POLISH_TURN_MULTIPLIER", lit("0.6")},
	{"POLISH_SKIP_REVIEW", lit("true")},
	{"POLISH_SKIP_REVIEW_PATTERNS", lit("*.css *.scss *.less *.json *.yaml *.yml *.toml *.cfg *.ini *.svg *.png *.md")},
	{"POLISH_LOGIC_FILE_PATTERNS", lit("*.py *.js *.ts *.sh *.go *.rs *.java *.rb *.c *.cpp *.h")},

	{"CONTINUATION_ENABLED", lit("true")},
	{"MAX_CONTINUATION_ATTEMPTS", lit("3")},

	{"TRANSIENT_RETRY_ENABLED", lit("true")},
	{"MAX_TRANSIENT_RETRIES", lit("3")},
	{"TRANSIENT_RETRY_BASE_DELAY", lit("30")},
	{"TRANSIENT_RETRY_MAX_DELAY", lit("120")},

	{"REWORK_TURN_ESCALATION_ENABLED", lit("true")},
	{"REWORK_TURN_ESCALATION_FACTOR", lit("1.5")},
	{"REWORK_TURN_MAX_CAP", ref("CODER_MAX_TURNS_CAP")},

	{"USAGE_THRESHOLD_PCT", lit("0")},
	{"AUTO_COMMIT", lit("false")},

	{"COMPLETE_MODE_ENABLED", lit("true")},
	{"MAX_PIPELINE_ATTEMPTS", lit("5")},
	{"AUTONOMOUS_TIMEOUT", lit("7200")},
	{"MAX_AUTONOMOUS_AGENT_CALLS", lit("200")},
	{"AUTONOMOUS_PROGRESS_CHECK", lit("true")},
	{"FIX_NONBLOCKERS_MAX_PASSES", lit("3")},
	{"FIX_DRIFT_MAX_PASSES", lit("3")},

	{"QUOTA_RETRY_INTERVAL", lit("300")},
	{"QUOTA_RESERVE_PCT", lit("10")},
	{"CLAUDE_QUOTA_CHECK_CMD", lit("")},
	{"QUOTA_MAX_PAUSE_DURATION", lit("18900")},
	{"QUOTA_SLEEP_CHUNK", lit("5")},
	{"QUOTA_PROBE_MIN_INTERVAL", lit("600")},
	{"QUOTA_PROBE_MAX_INTERVAL", lit("1800")},

	{"METRICS_ENABLED", lit("true")},
	{"METRICS_MIN_RUNS", lit("5")},
	{"METRICS_ADAPTIVE_TURNS", lit("true")},

	{"SECURITY_AGENT_ENABLED", lit("true")},
	{"CLAUDE_SECURITY_MODEL", ref("CLAUDE_STANDARD_MODEL")},
	{"SECURITY_MAX_TURNS", lit("15")},
	{"SECURITY_MIN_TURNS", lit("8")},
	{"SECURITY_MAX_TURNS_CAP", lit("30")},
	{"SECURITY_MAX_REWORK_CYCLES", lit("2")},
	{"MILESTONE_SECURITY_MAX_TURNS", imul("SECURITY_MAX_TURNS", 2)},
	{"SECURITY_BLOCK_SEVERITY", lit("HIGH")},
	{"SECURITY_UNFIXABLE_POLICY", lit("escalate")},
	{"SECURITY_OFFLINE_MODE", lit("auto")},
	{"SECURITY_ONLINE_SOURCES", lit("")},
	{"SECURITY_ROLE_FILE", lit(".claude/agents/security.md")},
	{"SECURITY_NOTES_FILE", tdFile("SECURITY_NOTES.md")},
	{"SECURITY_REPORT_FILE", tdFile("SECURITY_REPORT.md")},
	{"SECURITY_WAIVER_FILE", lit("")},

	{"INTAKE_AGENT_ENABLED", lit("true")},
	{"CLAUDE_INTAKE_MODEL", ref("CLAUDE_STANDARD_MODEL")},
	{"INTAKE_MAX_TURNS", lit("10")},
	{"INTAKE_CLARITY_THRESHOLD", lit("40")},
	{"INTAKE_TWEAK_THRESHOLD", lit("70")},
	{"INTAKE_CONFIRM_TWEAKS", lit("false")},
	{"INTAKE_AUTO_SPLIT", lit("false")},
	{"INTAKE_ROLE_FILE", lit(".claude/agents/intake.md")},
	{"INTAKE_REPORT_FILE", tdFile("INTAKE_REPORT.md")},

	{"PROJECT_INDEX_BUDGET", lit("120000")},

	{"DETECT_WORKSPACES_ENABLED", lit("true")},
	{"DETECT_SERVICES_ENABLED", lit("true")},
	{"DETECT_CI_ENABLED", lit("true")},
	{"DETECT_INFRASTRUCTURE_ENABLED", lit("true")},
	{"DETECT_TEST_FRAMEWORKS_ENABLED", lit("true")},
	{"DOC_QUALITY_ASSESSMENT_ENABLED", lit("true")},
	{"WORKSPACE_ENUM_LIMIT", lit("50")},
	{"PROJECT_STRUCTURE", lit("single")},

	{"ARTIFACT_DETECTION_ENABLED", lit("true")},
	{"ARTIFACT_HANDLING_DEFAULT", lit("")},
	{"ARTIFACT_ARCHIVE_DIR", lit(".claude/archived-ai-config")},
	{"ARTIFACT_MERGE_MODEL", ref("CLAUDE_STANDARD_MODEL")},
	{"ARTIFACT_MERGE_MAX_TURNS", lit("10")},

	{"BUILD_GATE_TIMEOUT", lit("600")},
	{"BUILD_GATE_ANALYZE_TIMEOUT", lit("300")},
	{"BUILD_GATE_COMPILE_TIMEOUT", lit("120")},
	{"BUILD_GATE_CONSTRAINT_TIMEOUT", lit("60")},

	{"UI_TEST_CMD", lit("")},
	{"UI_FRAMEWORK", lit("")},
	{"UI_PROJECT_DETECTED", lit("false")},
	{"UI_VALIDATION_ENABLED", lit("true")},
	{"UI_TEST_TIMEOUT", lit("120")},

	{"UI_SERVE_CMD", lit("")},
	{"UI_SERVE_PORT", lit("3000")},
	{"UI_SERVER_STARTUP_TIMEOUT", lit("30")},
	{"UI_VALIDATION_VIEWPORTS", lit("1280x800,375x812")},
	{"UI_VALIDATION_TIMEOUT", lit("30")},
	{"UI_VALIDATION_CONSOLE_SEVERITY", lit("error")},
	{"UI_VALIDATION_FLICKER_THRESHOLD", lit("0.05")},
	{"UI_VALIDATION_RETRY", lit("true")},
	{"UI_VALIDATION_SCREENSHOTS", lit("true")},
	{"WATCHTOWER_SELF_TEST", func(v map[string]string) string {
		if x, ok := v["DASHBOARD_ENABLED"]; ok && x != "" {
			return x
		}
		return "true"
	}},

	{"PIPELINE_ORDER", lit("standard")},
	{"TDD_PREFLIGHT_FILE", tdFile("TESTER_PREFLIGHT.md")},
	{"TESTER_WRITE_FAILING_MAX_TURNS", lit("15")},
	{"CODER_TDD_TURN_MULTIPLIER", lit("1.2")},

	{"DRY_RUN_CACHE_TTL", lit("3600")},
	{"DRY_RUN_CACHE_DIR", func(v map[string]string) string {
		pd := v["PROJECT_DIR"]
		if pd == "" {
			pd = "."
		}
		return pd + "/.claude/dry_run_cache"
	}},

	{"CHECKPOINT_ENABLED", lit("true")},
	{"CHECKPOINT_FILE", lit(".claude/CHECKPOINT_META.json")},

	{"CAUSAL_LOG_ENABLED", lit("true")},
	{"CAUSAL_LOG_FILE", lit(".claude/logs/CAUSAL_LOG.jsonl")},
	{"CAUSAL_LOG_RETENTION_RUNS", lit("50")},
	{"CAUSAL_LOG_MAX_EVENTS", lit("2000")},

	{"RUN_MEMORY_MAX_ENTRIES", lit("50")},

	{"PREFLIGHT_ENABLED", lit("true")},
	{"PREFLIGHT_AUTO_FIX", lit("true")},
	{"PREFLIGHT_FAIL_ON_WARN", lit("false")},

	{"UI_GATE_ENV_RETRY_ENABLED", lit("true")},
	{"UI_GATE_ENV_RETRY_TIMEOUT_FACTOR", lit("0.5")},

	{"BUILD_FIX_CLASSIFICATION_REQUIRED", lit("true")},

	{"PREFLIGHT_UI_CONFIG_AUDIT_ENABLED", lit("true")},
	{"PREFLIGHT_UI_CONFIG_AUTO_FIX", lit("true")},

	{"PREFLIGHT_BAK_RETAIN_COUNT", lit("5")},

	{"PREFLIGHT_FIX_ENABLED", lit("true")},
	{"PREFLIGHT_FIX_MAX_ATTEMPTS", lit("2")},
	{"PREFLIGHT_FIX_MODEL", ref("CLAUDE_JR_CODER_MODEL")},
	{"PREFLIGHT_FIX_MAX_TURNS", ref("JR_CODER_MAX_TURNS")},

	{"TESTER_FIX_ENABLED", lit("false")},
	{"TESTER_FIX_MAX_DEPTH", lit("1")},
	{"TESTER_FIX_OUTPUT_LIMIT", lit("4000")},
	{"TESTER_FIX_MAX_TURNS", idiv("CODER_MAX_TURNS", 3)},

	{"TEST_BASELINE_ENABLED", lit("true")},
	{"TEST_BASELINE_PASS_ON_PREEXISTING", lit("false")},
	{"TEST_BASELINE_STUCK_THRESHOLD", lit("2")},
	{"TEST_BASELINE_PASS_ON_STUCK", lit("false")},

	{"TEST_DEDUP_ENABLED", lit("true")},

	{"PRE_RUN_CLEAN_ENABLED", lit("true")},
	{"PRE_RUN_FIX_MAX_TURNS", lit("20")},
	{"PRE_RUN_FIX_MAX_ATTEMPTS", lit("1")},

	{"COMPLETION_GATE_TEST_ENABLED", lit("true")},

	{"TEST_AUDIT_ENABLED", lit("true")},
	{"TEST_AUDIT_MAX_TURNS", lit("15")},
	{"TEST_AUDIT_MAX_REWORK_CYCLES", lit("1")},
	{"TEST_AUDIT_ORPHAN_DETECTION", lit("true")},
	{"TEST_AUDIT_WEAKENING_DETECTION", lit("true")},
	{"TEST_AUDIT_REPORT_FILE", tdFile("TEST_AUDIT_REPORT.md")},
	{"TEST_AUDIT_SYMBOL_MAP_ENABLED", lit("true")},

	{"TEST_AUDIT_ROLLING_ENABLED", lit("true")},
	{"TEST_AUDIT_ROLLING_SAMPLE_K", lit("3")},
	{"TEST_AUDIT_HISTORY_MAX_RECORDS", lit("500")},

	{"HEALTH_ENABLED", lit("true")},
	{"HEALTH_REASSESS_ON_COMPLETE", lit("false")},
	{"HEALTH_RUN_TESTS", lit("false")},
	{"HEALTH_SAMPLE_SIZE", lit("20")},
	{"HEALTH_WEIGHT_TESTS", lit("30")},
	{"HEALTH_WEIGHT_QUALITY", lit("25")},
	{"HEALTH_WEIGHT_DEPS", lit("15")},
	{"HEALTH_WEIGHT_DOCS", lit("15")},
	{"HEALTH_WEIGHT_HYGIENE", lit("15")},
	{"HEALTH_SHOW_BELT", lit("true")},
	{"HEALTH_BASELINE_FILE", lit(".claude/HEALTH_BASELINE.json")},
	{"HEALTH_REPORT_FILE", tdFile("HEALTH_REPORT.md")},

	{"DASHBOARD_ENABLED", lit("true")},
	{"DASHBOARD_VERBOSITY", lit("normal")},
	{"DASHBOARD_HISTORY_DEPTH", lit("50")},
	{"DASHBOARD_REFRESH_INTERVAL", lit("10")},
	{"DASHBOARD_DIR", lit(".claude/dashboard")},
	{"DASHBOARD_MAX_TIMELINE_EVENTS", lit("500")},

	{"TEKHTON_UPDATE_CHECK", lit("true")},
	{"TEKHTON_PIN_VERSION", lit("")},

	{"TEKHTON_CONFIG_VERSION", lit("")},
	{"MIGRATION_AUTO", lit("true")},
	{"MIGRATION_BACKUP_DIR", lit(".claude/migration-backups")},

	{"SPECIALIST_SKIP_IRRELEVANT", lit("true")},
	{"REVIEW_SKIP_THRESHOLD", lit("0")},
	{"SPECIALIST_SECURITY_ENABLED", lit("false")},
	{"SPECIALIST_SECURITY_MODEL", ref("CLAUDE_STANDARD_MODEL")},
	{"SPECIALIST_SECURITY_MAX_TURNS", lit("8")},
	{"SPECIALIST_PERFORMANCE_ENABLED", lit("false")},
	{"SPECIALIST_PERFORMANCE_MODEL", ref("CLAUDE_STANDARD_MODEL")},
	{"SPECIALIST_PERFORMANCE_MAX_TURNS", lit("8")},
	{"SPECIALIST_API_ENABLED", lit("false")},
	{"SPECIALIST_API_MODEL", ref("CLAUDE_STANDARD_MODEL")},
	{"SPECIALIST_API_MAX_TURNS", lit("8")},

	{"DOCS_ENFORCEMENT_ENABLED", lit("true")},
	{"DOCS_STRICT_MODE", lit("false")},
	{"DOCS_DIRS", lit("docs/")},
	{"DOCS_README_FILE", lit("README.md")},

	{"DOCS_AGENT_ENABLED", lit("false")},
	{"DOCS_AGENT_MODEL", lit("claude-haiku-4-5-20251001")},
	{"DOCS_AGENT_MAX_TURNS", lit("10")},
	{"DOCS_AGENT_REPORT_FILE", tdFile("DOCS_AGENT_REPORT.md")},

	{"PROJECT_VERSION_ENABLED", lit("true")},
	{"PROJECT_VERSION_STRATEGY", lit("semver")},
	{"PROJECT_VERSION_CONFIG", lit(".claude/project_version.cfg")},
	{"PROJECT_VERSION_DEFAULT_BUMP", lit("patch")},
	{"PROJECT_VERSION_TAG_ON_BUMP", lit("false")},
	{"PROJECT_VERSION_AUTO_DETECT", lit("true")},

	{"CHANGELOG_ENABLED", lit("true")},
	{"CHANGELOG_FILE", lit("CHANGELOG.md")},
	{"CHANGELOG_FORMAT", lit("keep-a-changelog")},
	{"CHANGELOG_INIT_IF_MISSING", lit("true")},

	{"DRAFT_MILESTONES_MODEL", ref("CLAUDE_STANDARD_MODEL")},
	{"DRAFT_MILESTONES_MAX_TURNS", lit("40")},
	{"DRAFT_MILESTONES_AUTO_WRITE", lit("false")},
	{"DRAFT_MILESTONES_SEED_EXEMPLARS", lit("3")},

	{"INIT_AUTO_PROMPT", lit("false")},

	{"UI_PLATFORM", lit("auto")},
	{"SPECIALIST_UI_ENABLED", lit("auto")},
	{"SPECIALIST_UI_MODEL", ref("CLAUDE_STANDARD_MODEL")},
	{"SPECIALIST_UI_MAX_TURNS", lit("8")},

	{"MILESTONE_MAX_REVIEW_CYCLES", imul("MAX_REVIEW_CYCLES", 2)},
	{"MILESTONE_CODER_MAX_TURNS", imul("CODER_MAX_TURNS", 2)},
	{"MILESTONE_JR_CODER_MAX_TURNS", imul("JR_CODER_MAX_TURNS", 2)},
	{"MILESTONE_REVIEWER_MAX_TURNS", iadd("REVIEWER_MAX_TURNS", 5)},
	{"MILESTONE_TESTER_MAX_TURNS", imul("TESTER_MAX_TURNS", 2)},
	{"MILESTONE_TESTER_MODEL", ref("CLAUDE_STANDARD_MODEL")},

	{"MILESTONE_ACTIVITY_TIMEOUT_MULTIPLIER", lit("3")},

	// AGENT_ACTIVITY_TIMEOUT default lives in lib/agent_monitor.sh today
	// (not in config_defaults.sh). Mirror the operative default so the
	// milestone-mode multiplier has a base to scale.
	{"AGENT_ACTIVITY_TIMEOUT", lit("600")},
}

// lateDefaults: keys whose default depends on values resolved in CI gate or
// other late-stage operations. Currently empty — kept as a hook for future
// arc milestones (m17+) without re-flowing the order of baseDefaults.
//
// TODO(m17+): populate when a late-phase key arrives or collapse into
// applyDefaults if it becomes clear no late-phase keys are needed.
var lateDefaults = []defaultRule{}
