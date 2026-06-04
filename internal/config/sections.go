package config

import "strings"

// SectionRule places a config variable into a named section of the
// pipeline.conf reference output. Rules are applied in order; the first
// matching rule wins. The fallback section (`Misc`) catches anything
// that doesn't match — if it has entries on a fresh run, that's a
// signal someone added a new variable without categorising it.
//
// Section ordering follows the operator's mental model: things they
// care about first (project identity, commands, models, turns) at the
// top; deep internals (causal log, quota, telemetry) at the bottom.
// Within a section, keys remain lexicographic for findability.
type SectionRule struct {
	Name        string
	Description string
	Match       func(key string) bool
}

// hasPrefix returns a Match func that matches when key starts with any
// of the supplied prefixes. Short helper to keep the rules table compact.
func hasPrefix(prefixes ...string) func(string) bool {
	return func(key string) bool {
		for _, p := range prefixes {
			if strings.HasPrefix(key, p) {
				return true
			}
		}
		return false
	}
}

// matchExact returns a Match func that matches when key equals any of
// the supplied names.
func matchExact(names ...string) func(string) bool {
	return func(key string) bool {
		for _, n := range names {
			if key == n {
				return true
			}
		}
		return false
	}
}

// matchAny returns a Match func that runs through the supplied
// sub-matchers and returns true on the first hit. Used when a section
// needs both prefix matches and exact-name matches.
func matchAny(ms ...func(string) bool) func(string) bool {
	return func(key string) bool {
		for _, m := range ms {
			if m(key) {
				return true
			}
		}
		return false
	}
}

// pipelineConfSections is the ordered section table consumed by
// EmitPipelineConf. ORDER MATTERS: the first rule that matches a key
// claims it, so more-specific rules (e.g. PROJECT_VERSION_*) must come
// before broader ones (PROJECT_*).
var pipelineConfSections = []SectionRule{
	{
		Name:        "Project Identity & Paths",
		Description: "PROJECT_NAME, description, root paths, and which files Tekhton reads for context.",
		Match: matchAny(
			matchExact(
				"PROJECT_NAME", "PROJECT_DESCRIPTION", "PROJECT_DIR",
				"PROJECT_RULES_FILE", "PROJECT_TYPE", "PROJECT_STRUCTURE",
				"PROJECT_INDEX_BUDGET",
				"ARCHITECTURE_FILE", "DESIGN_FILE",
				"TEKHTON_DIR", "TEKHTON_HOME", "TEKHTON_CONFIG_VERSION",
				"TEKHTON_SESSION_DIR", "TEKHTON_EXPRESS_ENABLED",
				"TEKHTON_PIPELINE_LOCK_FILE", "TEKHTON_BIN", "TEKHTON_LEGACY_BIN",
				"TEKHTON_PIN_VERSION", "TEKHTON_UPDATE_CHECK",
				"CLAUDE_DIR", "INIT_AUTO_PROMPT", "MIGRATION_AUTO",
			),
		),
	},
	{
		Name:        "Commands (Build / Test / Analyze)",
		Description: "The commands Tekhton runs in the build and completion gates. Set these per project.",
		Match: matchExact(
			"TEST_CMD", "ANALYZE_CMD", "BUILD_CHECK_CMD", "COMPILE_CMD",
			"UI_TEST_CMD", "ANALYZE_ERROR_PATTERN",
		),
	},
	{
		Name:        "Project Versioning",
		Description: "Auto-bump strategy and version-file targets for the project under management.",
		Match:       hasPrefix("PROJECT_VERSION"),
	},
	{
		Name:        "Models",
		Description: "Which Claude model each agent uses. Defaults to a balanced sonnet/haiku mix.",
		Match: matchAny(
			hasPrefix("CLAUDE_"),
			matchExact("MILESTONE_SPLIT_MODEL", "ARTIFACT_MERGE_MODEL", "REPLAN_MODEL",
				"DRAFT_MILESTONES_MODEL", "POLISH_MODEL", "ARCHITECT_MODEL"),
		),
	},
	{
		Name:        "Agent Turn Budgets",
		Description: "Maximum agent turns per stage. DYNAMIC_TURNS_ENABLED lets scout adjust these per run; REWORK_TURN_ESCALATION_* increases budgets after consecutive max-turn exits.",
		Match: matchAny(
			hasPrefix("REWORK_TURN_"),
			matchExact("DYNAMIC_TURNS_ENABLED",
				"CODER_MAX_TURNS", "JR_CODER_MAX_TURNS",
				"REVIEWER_MAX_TURNS", "TESTER_MAX_TURNS",
				"SCOUT_MAX_TURNS", "ARCHITECT_MAX_TURNS",
				"INTAKE_MAX_TURNS", "SECURITY_MAX_TURNS",
				"DOCS_AGENT_MAX_TURNS", "CLEANUP_MAX_TURNS",
				"ARTIFACT_MERGE_MAX_TURNS", "POLISH_MAX_TURNS",
				"DRAFT_MILESTONES_MAX_TURNS", "FINAL_FIX_MAX_TURNS",
				"PRE_RUN_FIX_MAX_TURNS", "MAX_TURNS",
				"BUG_TURN_MULTIPLIER", "FEAT_TURN_MULTIPLIER",
				"SEED_CONTRACTS_MAX_TURNS"),
		),
	},
	{
		Name:        "Milestone Mode",
		Description: "Overrides applied when running in --milestone mode (typically larger budgets, stricter checks).",
		Match:       hasPrefix("MILESTONE_"),
	},
	{
		Name:        "Auto-Advance & Autonomous Run",
		Description: "Controls for --auto-advance milestone chaining and --complete autonomous mode.",
		Match: matchAny(
			hasPrefix("AUTO_ADVANCE", "AUTONOMOUS_", "COMPLETE_MODE_"),
			matchExact("MAX_AUTONOMOUS_AGENT_CALLS", "MAX_PIPELINE_ATTEMPTS"),
		),
	},
	{
		Name:        "Retries & Continuation",
		Description: "Transient-error retry and turn-exhaustion continuation policy across stages.",
		Match: matchAny(
			hasPrefix("TRANSIENT_RETRY", "CONTINUATION_"),
			matchExact("MAX_REVIEW_CYCLES", "MAX_TRANSIENT_RETRIES",
				"MAX_CONTINUATION_ATTEMPTS"),
		),
	},
	{
		Name:        "Pipeline Stage Order",
		Description: "Configurable stage order (standard vs test_first) and stage-level toggles.",
		Match: matchAny(
			hasPrefix("PIPELINE_", "STAGE_"),
		),
	},
	{
		Name:        "Build Gate & Build-Fix Loop",
		Description: "Build verification after the coder stage and the M127/M128 multi-attempt build-fix continuation loop.",
		Match: matchAny(
			hasPrefix("BUILD_"),
			matchExact("FINAL_FIX_ENABLED", "FINAL_FIX_MAX_ATTEMPTS"),
		),
	},
	{
		Name:        "Test Gate, Audit, Baseline",
		Description: "Completion gate TEST_CMD execution, M88/M92 audit, baseline diffing, dedup fingerprint, pre-coder test-state cleanup.",
		Match: matchAny(
			hasPrefix("TEST_BASELINE", "TEST_AUDIT", "TEST_DEDUP", "PRE_RUN_FIX"),
			matchExact("TEST_CMD_DEDUP_ENABLED", "COMPLETION_GATE_TEST_ENABLED",
				"PRE_RUN_CLEAN_ENABLED", "TEST_FIX_FOCUS_ENABLED"),
		),
	},
	{
		Name:        "Coder Stage",
		Description: "Senior/jr coder behavior and rework prompt selection.",
		Match: matchAny(
			hasPrefix("CODER_", "JR_CODER_"),
		),
	},
	{
		Name:        "Scout Sub-Stage",
		Description: "Complexity estimation that runs before each coder invocation.",
		Match:       hasPrefix("SCOUT_"),
	},
	{
		Name:        "Reviewer Stage",
		Description: "Review loop, rework routing, specialist trigger thresholds.",
		Match: matchAny(
			hasPrefix("REVIEWER_"),
			matchExact("REVIEW_SKIP_THRESHOLD"),
		),
	},
	{
		Name:        "Tester Stage",
		Description: "Test writing + TDD pre-flight + post-test validation + tester-fix recursion.",
		Match: matchAny(
			hasPrefix("TESTER_"),
		),
	},
	{
		Name:        "Architect Stage & Drift Log",
		Description: "Pre-stage architect audit, drift observation thresholds, ADL paths, --fix drift loop.",
		Match: matchAny(
			hasPrefix("ARCHITECT_", "DRIFT_"),
			matchExact("ARCHITECTURE_LOG_FILE", "HUMAN_ACTION_FILE",
				"FORCE_AUDIT", "FIX_DRIFT_MAX_PASSES"),
		),
	},
	{
		Name:        "Intake Stage (PM Gate)",
		Description: "Task clarity scoring, verdict routing, historical-verdict injection.",
		Match:       hasPrefix("INTAKE_"),
	},
	{
		Name:        "Security Stage",
		Description: "Security scan agent + severity classification + escalation routing.",
		Match:       hasPrefix("SECURITY_"),
	},
	{
		Name:        "Docs Agent",
		Description: "Optional Haiku-driven docs writer (off by default).",
		Match:       hasPrefix("DOCS_"),
	},
	{
		Name:        "Cleanup Stage",
		Description: "Post-success autonomous debt sweep (off by default).",
		Match:       hasPrefix("CLEANUP_"),
	},
	{
		Name:        "UI/UX Specialist & Validation",
		Description: "UI platform detection, validation viewports, headless browser checks, non-interactive UI gate retry.",
		Match: matchAny(
			hasPrefix("UI_", "PLATFORM_"),
			matchExact("TEKHTON_UI_GATE_FORCE_NONINTERACTIVE"),
		),
	},
	{
		Name:        "Specialist Reviewers",
		Description: "Optional security/performance/api specialist reviewers triggered by reviewer.",
		Match:       hasPrefix("SPECIALIST_"),
	},
	{
		Name:        "Clarification Protocol",
		Description: "When agents can pause for blocking questions during a run.",
		Match:       hasPrefix("CLARIFICATION"),
	},
	{
		Name:        "Replan",
		Description: "Mid-run --replan trigger and brownfield reseed.",
		Match:       hasPrefix("REPLAN_"),
	},
	{
		Name:        "Context Budget & Compiler",
		Description: "Context-window accounting and task-scoped context assembly.",
		Match: matchAny(
			hasPrefix("CONTEXT_"),
			matchExact("CHARS_PER_TOKEN", "RUN_MEMORY_MAX_ENTRIES",
				"MAX_CONTEXT_TOKENS"),
		),
	},
	{
		Name:        "Indexer & Repo Map",
		Description: "Tree-sitter repo map, PageRank ranking, task→file history.",
		Match:       hasPrefix("REPO_MAP", "INDEXER"),
	},
	{
		Name:        "Serena MCP (LSP)",
		Description: "Serena Language Server MCP integration — symbol lookup, find_references, etc.",
		Match:       hasPrefix("SERENA_"),
	},
	{
		Name:        "TUI Sidecar",
		Description: "Rich-based terminal UI sidecar lifecycle and behavior.",
		Match:       hasPrefix("TUI_"),
	},
	{
		Name:        "Watchtower Dashboard",
		Description: "Dashboard data emission cadence and self-test.",
		Match: matchAny(
			hasPrefix("DASHBOARD_", "WATCHTOWER_"),
		),
	},
	{
		Name:        "Metrics & Adaptive Calibration",
		Description: "Run metrics collection and adaptive turn-budget calibration.",
		Match:       hasPrefix("METRICS_"),
	},
	{
		Name:        "Health Score",
		Description: "Project health scoring (gitignore, lockfiles, hygiene, infra).",
		Match:       hasPrefix("HEALTH_"),
	},
	{
		Name:        "Diagnostics",
		Description: "Pipeline diagnostics engine — failure classification, rule registry.",
		Match: matchAny(
			hasPrefix("DIAGNOSE_", "DIAGNOSIS_", "FAILURE_"),
		),
	},
	{
		Name:        "Quota Management",
		Description: "API quota pause/probe/back-off (Claude rate limits).",
		Match:       hasPrefix("QUOTA_"),
	},
	{
		Name:        "Causal Log",
		Description: "Append-only event log for cross-stage causal queries.",
		Match:       hasPrefix("CAUSAL_"),
	},
	{
		Name:        "Notes (Human & Non-Blocking)",
		Description: "HUMAN_NOTES.md and NON_BLOCKING_LOG.md path + behavior. FIX_NONBLOCKERS_* governs the --fix nb loop.",
		Match: matchAny(
			hasPrefix("HUMAN_NOTES", "NOTES_", "NON_BLOCKING"),
			matchExact("HUMAN_MODE", "HUMAN_NOTES_TAG",
				"FIX_NONBLOCKERS_MAX_PASSES"),
		),
	},
	{
		Name:        "Preflight Validation",
		Description: "Pre-run environment checks — tool availability, port collisions, config audits.",
		Match:       hasPrefix("PREFLIGHT_"),
	},
	{
		Name:        "Express Mode",
		Description: "Zero-config quick-start mode for new projects.",
		Match:       hasPrefix("EXPRESS"),
	},
	{
		Name:        "Dry-Run",
		Description: "Preview mode that walks the pipeline without invoking agents.",
		Match:       hasPrefix("DRY_RUN"),
	},
	{
		Name:        "Detection (Stack & CI)",
		Description: "Auto-detection of languages, frameworks, CI systems used by --init. DOC_QUALITY_ASSESSMENT scores the project's existing documentation.",
		Match: matchAny(
			hasPrefix("DETECT"),
			matchExact("DOC_QUALITY_ASSESSMENT_ENABLED",
				"TEKHTON_CI_ENVIRONMENT_DETECTED"),
		),
	},
	{
		Name:        "Artifact Handler",
		Description: "Detection of AI-config artifacts left by other tools (Cursor, Aider, etc.).",
		Match:       hasPrefix("ARTIFACT"),
	},
	{
		Name:        "Polish Agent",
		Description: "Post-coder polish pass agent (m83 era).",
		Match:       hasPrefix("POLISH_"),
	},
	{
		Name:        "Inline Contracts (Seed)",
		Description: "Code-comment contract scraper that seeds reviewer expectations before review.",
		Match: matchAny(
			hasPrefix("SEED_CONTRACTS", "INLINE_CONTRACT"),
		),
	},
	{
		Name:        "Draft Milestones",
		Description: "Interactive milestone authoring agent (--draft-milestones).",
		Match:       hasPrefix("DRAFT_MILESTONES"),
	},
	{
		Name:        "Agent Runtime",
		Description: "Cross-stage agent process settings — activity timeout, null-run detection, tool gating.",
		Match: matchAny(
			hasPrefix("AGENT_"),
		),
	},
	{
		Name:        "Logging & Output",
		Description: "Log directory, verbosity, timestamp format.",
		Match: matchAny(
			hasPrefix("LOG_", "VERBOSE"),
			matchExact("TIMESTAMP_FORMAT", "LOG_FILE"),
		),
	},
	{
		Name:        "File & Directory Paths",
		Description: "Tekhton-managed artifact paths — most users don't change these.",
		Match: matchAny(
			func(k string) bool {
				return strings.HasSuffix(k, "_FILE") || strings.HasSuffix(k, "_DIR")
			},
		),
	},
	{
		Name:        "Misc Runtime",
		Description: "Action-item thresholds, usage gates, editor, workspace settings, etc.",
		Match: matchAny(
			hasPrefix("ACTION_ITEMS", "USAGE_THRESHOLD",
				"WORKSPACE_", "SAFETY_NET", "CHECKPOINT", "CHANGELOG",
				"AUTO_COMMIT", "REQUIRED_TOOLS", "AGENT_TOOLS"),
			matchExact("EDITOR", "MILESTONE_TAG_ON_COMPLETE"),
		),
	},
}

// SectionFor returns the section name for a given config key, walking
// pipelineConfSections in order. The fallback name when nothing matches
// is "Uncategorized" — a non-empty fallback bucket on a fresh run means
// someone added a variable without giving it a home; the operator can
// still see it (alphabetized within Uncategorized) but the unit test
// guards against this drift.
func SectionFor(key string) string {
	for _, r := range pipelineConfSections {
		if r.Match(key) {
			return r.Name
		}
	}
	return "Uncategorized"
}

// SectionsInOrder returns the section names in the order they should
// appear in the pipeline.conf reference output, plus the "Uncategorized"
// fallback at the very end.
func SectionsInOrder() []SectionRule {
	out := make([]SectionRule, len(pipelineConfSections))
	copy(out, pipelineConfSections)
	return append(out, SectionRule{
		Name:        "Uncategorized",
		Description: "Variables that didn't match any section rule. If this section is non-empty on a fresh run, someone added a variable without giving it a home — file a follow-up.",
	})
}
