// Package config owns reading, defaulting, validating, and emitting the
// Tekhton pipeline.conf configuration.
//
// Pre-m16 the bash side parsed pipeline.conf via lib/config.sh::load_config,
// applied defaults via lib/config_defaults.sh, and ran CI auto-detection via
// lib/config_defaults_ci.sh. Subsystems consumed config keys as exported env
// vars. m16 ports the loader into Go: bash callers reach this package via
// the `tekhton config load --emit shell` subcommand executed by the
// lib/config.sh shim, and Go callers consume *Config directly.
//
// The on-disk pipeline.conf format is unchanged. Operators continue to author
// `KEY=value` lines with optional comments and quoting; flipping that to
// YAML/JSON would break tens of existing project configs and is explicitly
// out of scope (m16 Watch For).
//
// Defaults are encoded as an ordered slice of resolver functions so that
// values that derive from earlier keys (`MILESTONE_CODER_MAX_TURNS = CODER_MAX_TURNS * 2`)
// can be expressed cleanly. CI auto-detection runs *before* the default for
// TEKHTON_UI_GATE_FORCE_NONINTERACTIVE is applied, mirroring the m138 rule
// that an explicit pipeline.conf value always wins over the auto-elevation.
//
// Validation runs in two phases:
//
//  1. Inline normalization (mirrors load_config()'s case statements): bad
//     values for enum-style keys (PIPELINE_ORDER, UI_FRAMEWORK, ...) are
//     reset to a safe default with a stderr warning.
//  2. Clamping: integer keys with hard caps and float keys with [min,max]
//     ranges are clamped if out of range.
//
// Emit shell output is sourceable bash. Each key is exported via a single
// `export KEY='value'` line with single-quote escaping. The bash shim reads
// the output via process substitution, so the Go side never touches the
// caller's shell directly.
package config

import (
	"errors"
	"fmt"
	"os"

	terr "github.com/geoffgodwin/tekhton/internal/errors"
)

// configInvalidSentinel marks an error as wrapping terr.ErrConfigInvalid via
// errors.Is so cross-subsystem callers can match every config validation
// failure with a single call (m17 common-sentinel contract).
type configInvalidSentinel struct{ msg string }

func (e *configInvalidSentinel) Error() string { return e.msg }
func (e *configInvalidSentinel) Is(target error) bool {
	if target == terr.ErrConfigInvalid {
		return true
	}
	return e == target
}

// osLookupEnv is a tiny seam so tests can stub env access without touching
// the real process environment. Production calls os.LookupEnv directly.
func osLookupEnv(key string) (string, bool) { return os.LookupEnv(key) }

// Sentinel errors. Callers match with errors.Is.
var (
	// ErrNotFound is returned by Load when the pipeline.conf file does not exist.
	ErrNotFound = errors.New("config: pipeline.conf not found")

	// ErrParse is returned by Load when a line is malformed or contains a
	// dangerous shell metacharacter that the parser refuses to accept.
	ErrParse = errors.New("config: parse error")

	// ErrMissingRequired is returned by Load when one of the three required
	// keys (PROJECT_NAME, CLAUDE_STANDARD_MODEL, ANALYZE_CMD) is absent.
	ErrMissingRequired = errors.New("config: missing required key")

	// ErrValidation is returned by Validate when a config violates a rule that
	// the loader cannot silently correct (e.g. unknown key in strict mode).
	// Wraps terr.ErrConfigInvalid so cross-subsystem callers can match with a
	// single errors.Is call.
	ErrValidation error = &configInvalidSentinel{msg: "config: validation error"}
)

// LoadOptions controls Load behaviour. ProjectDir is used for path resolution
// (relative paths in PIPELINE_STATE_FILE etc. become absolute). MilestoneMode
// applies the milestone-mode overrides on top of the resolved config so the
// emitted shell environment matches what apply_milestone_overrides used to do.
// Strict promotes warnings to errors so `tekhton config validate` can fail on
// configs the loader would otherwise auto-correct.
type LoadOptions struct {
	ProjectDir    string
	MilestoneMode bool
	Strict        bool
	// SuppressDiagnostics silences the stderr platform-detected line that
	// _apply_ci_ui_gate_defaults emits. Tests that exercise CI detection
	// without VERBOSE_OUTPUT pass true; the bash shim leaves it false so the
	// existing operator-facing diagnostic still fires.
	SuppressDiagnostics bool
}

// Config holds the resolved pipeline configuration.
//
// Values is the canonical key/value map after defaults, CI detection,
// inline validation, and clamping. KeysSet records keys explicitly present
// in pipeline.conf — used by _apply_ci_ui_gate_defaults's "user-set?" test
// and by `config show --json` to mark which entries the operator authored.
//
// Warnings collects non-fatal diagnostics. Errors collects fatal ones. The
// caller decides whether to treat warnings as fatal (Strict mode) or print
// them to stderr.
//
// Design note: the m16 design described a nested typed struct
// (Limits.MaxReviewCycles int `conf:"MAX_REVIEW_CYCLES"`, etc.). The port
// landed on map[string]string instead — direct parity with bash env vars,
// no field-name translation, and zero schema churn when a new key arrives.
// Future in-process callers (m17+ orchestrate/prompt/dag) read Values as a
// map; if a typed view becomes useful, add it as an accessor layer rather
// than mutating this struct.
type Config struct {
	Path       string            // source pipeline.conf path
	ProjectDir string            // for relative-path resolution
	Values     map[string]string // canonical resolved key/value map
	KeysSet    map[string]bool   // keys present in pipeline.conf
	Warnings   []string
	Errors     []string

	// CIDetected reflects the m138 contract: true if a CI signal was
	// detected at load time. CIPlatform is the human-readable name.
	CIDetected bool
	CIPlatform string
}

// requiredKeys lists keys that must appear in pipeline.conf. Defaults cover
// the rest. Mirrors load_config()'s required-key check.
var requiredKeys = []string{"PROJECT_NAME", "CLAUDE_STANDARD_MODEL", "ANALYZE_CMD"}

// Load reads pipeline.conf at path, applies defaults, runs CI detection,
// validates and clamps values, and resolves relative paths. The returned
// *Config is a fully resolved view; callers either consume it in-process
// (orchestrate, prompt, dag) or emit it as shell to feed the bash shim.
func Load(path string, opts LoadOptions) (*Config, error) {
	if path == "" {
		return nil, fmt.Errorf("%w: empty path", ErrNotFound)
	}
	if _, err := os.Stat(path); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("%w: %s", ErrNotFound, path)
		}
		return nil, fmt.Errorf("config: stat %s: %w", path, err)
	}

	cfg := &Config{
		Path:       path,
		ProjectDir: opts.ProjectDir,
		Values:     map[string]string{},
		KeysSet:    map[string]bool{},
	}

	// Phase 1: parse pipeline.conf into Values + KeysSet. Dangerous-metachar
	// rejection happens here.
	if err := parseFile(path, cfg); err != nil {
		return nil, err
	}

	// Phase 2: required-key check. Mirrors load_config()'s missing-keys check
	// — it must run BEFORE defaults are applied so an environment-inherited
	// value cannot satisfy the requirement (the bash side calls this out
	// explicitly).
	var missing []string
	for _, k := range requiredKeys {
		if !cfg.KeysSet[k] {
			missing = append(missing, k)
		}
	}
	if len(missing) > 0 {
		return cfg, fmt.Errorf("%w: %v", ErrMissingRequired, missing)
	}

	// Phase 2.5: seed cfg.Values from the environment for keys that have a
	// default rule. The bash loader's `: "${KEY:=value}"` only assigns when
	// the key is unset, so env-set values from the parent shell override
	// defaults. We mirror that here. Note: env-set values are NOT recorded
	// in KeysSet — the m138 "did the user set it in pipeline.conf?" check
	// must remain pipeline.conf-scoped.
	seedFromEnv(cfg)

	// Phase 3: defaults — base values, derived values, the m138 CI gate, and
	// the post-CI residue. Order is preserved by the resolver slice.
	applyDefaults(cfg)

	// Phase 4: CI auto-detection (m138). Must run AFTER base defaults
	// (CONF_KEYS_SET is finalised) but BEFORE the TEKHTON_UI_GATE_FORCE_NONINTERACTIVE
	// fallback default fires. applyCIGateDefault encapsulates the rule.
	applyCIGateDefault(cfg, opts)

	// Phase 5: late defaults that depend on resolved earlier keys. Re-running
	// applyDefaults is safe because each rule is idempotent (`:=`-style "set
	// only if unset"), but the second pass catches any remaining holes.
	applyLateDefaults(cfg)

	// Phase 6: inline validation + normalization (UI_FRAMEWORK enum, PIPELINE_ORDER
	// enum, INTAKE_* threshold ordering, dashboard verbosity, ...).
	runInlineValidation(cfg)

	// Phase 7: clamping. Integer hard caps + float [min,max] ranges. Bash
	// emits a stderr warning when a clamp fires; we record it in Warnings so
	// the emitter can replay it.
	runClamps(cfg)

	// Phase 8: path resolution. Mirrors load_config()'s "if path is not
	// absolute, prepend PROJECT_DIR" block at the bottom of the function.
	resolvePaths(cfg)

	// Phase 9: milestone-mode overrides. Applied on top of base config when
	// requested; mirrors apply_milestone_overrides().
	if opts.MilestoneMode {
		applyMilestoneOverrides(cfg)
	}

	return cfg, nil
}

// LoadDefaultsOnly populates the Config with only the defaults — no
// pipeline.conf parsing. Used by `tekhton config defaults` and by the
// lib/config_defaults.sh shim. The CI gate still runs because it depends on
// process env, not pipeline.conf.
func (c *Config) LoadDefaultsOnly(opts LoadOptions) {
	if c.Values == nil {
		c.Values = map[string]string{}
	}
	if c.KeysSet == nil {
		c.KeysSet = map[string]bool{}
	}
	if opts.ProjectDir != "" {
		c.ProjectDir = opts.ProjectDir
	}
	seedFromEnv(c)
	applyDefaults(c)
	applyCIGateDefault(c, opts)
	applyLateDefaults(c)
	runInlineValidation(c)
	runClamps(c)
	resolvePaths(c)
	if opts.MilestoneMode {
		applyMilestoneOverrides(c)
	}
}

// seedFromEnv mirrors the bash `: "${KEY:=value}"` env-takes-precedence
// behavior. For every key with a default rule, if an env var of the same
// name is set (even to empty? no — bash `:=` treats empty as unset for
// strings), copy the env value into cfg.Values. KeysSet is intentionally
// NOT updated: env-set values do not count as "user-authored in
// pipeline.conf" for the m138 contract.
func seedFromEnv(cfg *Config) {
	for _, r := range baseDefaults {
		if _, already := cfg.Values[r.Key]; already {
			continue
		}
		v, ok := osLookupEnv(r.Key)
		if !ok || v == "" {
			continue
		}
		cfg.Values[r.Key] = v
	}
}

// AllKeys returns the set of keys the loader knows about — every default
// key plus every key parsed from pipeline.conf. Used by `config validate
// --strict` to detect unknown keys.
func (c *Config) AllKeys() []string {
	seen := map[string]bool{}
	out := []string{}
	for k := range c.Values {
		if !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	return out
}
