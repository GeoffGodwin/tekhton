package runner

import (
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/config"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// EnvBuilder composes the stage / finalize subprocess env from three layers,
// each beating the one before it:
//
//  1. Project config — pipeline.conf values via internal/config.Load.
//     Cached on the builder so we load once per Runner, not once per stage.
//  2. Run-request flags — fields on RunRequestV1 that the legacy pipeline
//     exposed as bash globals at flag-parse time (MILESTONE_MODE, TASK,
//     _CURRENT_MILESTONE, AUTO_ADVANCE*, HUMAN_MODE, HUMAN_NOTES_TAG).
//  3. Explicit caller overrides — test seams and per-stage knobs
//     (PipelineAttemptRequestV1.StageEnv per stage) that need to win.
//
// Builders are cheap; the Runner holds one per active run so the config
// load happens exactly once.
type EnvBuilder struct {
	cfg *config.Config // nil ⇒ defaults-only path
	log LogContext
}

// LogContext is the single authoritative spot for log-path synthesis.
// Replaces the ad-hoc string-join in internal/finalize/shim.go so the
// runner, finalize, and any future direct caller all see the same path
// for the same (Timestamp, Task) tuple.
//
// SessionDir is the per-run scratch directory the legacy dispatcher
// created via mktemp; we hand it through here so the env builder can
// thread it onto every subprocess.
type LogContext struct {
	Dir        string
	Timestamp  string
	SessionDir string
}

// taskSlug returns the bash-side ${TASK_SLUG} computed for a run request.
// Mirrors the lib/common.sh slugifier: lowercase, non-alphanumerics
// collapsed to '_', leading/trailing underscores stripped, empty → "run".
// Used by both LogFile synthesis and the e2e parity test fixture.
func taskSlug(req *proto.RunRequestV1) string {
	if req == nil {
		return "run"
	}
	s := req.Task
	if s == "" {
		s = req.Milestone
	}
	if s == "" {
		return "run"
	}
	s = strings.ToLower(s)
	s = nonAlnumRE.ReplaceAllString(s, "_")
	s = strings.Trim(s, "_")
	if s == "" {
		return "run"
	}
	return s
}

var nonAlnumRE = regexp.MustCompile(`[^a-z0-9]+`)

// LogFile returns the canonical "${LogDir}/${Timestamp}_${task_slug}.log"
// path for this LogContext + request. Matches the bash-side LOG_FILE shape
// (tekhton-legacy.sh) byte-for-byte so existing log scrapers don't break.
func (l LogContext) LogFile(req *proto.RunRequestV1) string {
	if l.Dir == "" {
		return ""
	}
	ts := l.Timestamp
	if ts == "" {
		ts = "run"
	}
	return filepath.Join(l.Dir, ts+"_"+taskSlug(req)+".log")
}

// NewEnvBuilder constructs a builder. cfg may be nil when pipeline.conf is
// missing or unparseable — Compose still emits the runtime-flag fields and
// a defaults-shaped ConfigKeys map in that case (the "bare directory" path
// preflight is supposed to flag).
func NewEnvBuilder(cfg *config.Config, log LogContext) *EnvBuilder {
	return &EnvBuilder{cfg: cfg, log: log}
}

// Compose returns the env contract for a single subprocess. Pure (no I/O)
// so callers can invoke it per-stage without paying the config-load cost
// each time. The overrides map is layered last and wins over every other
// layer; pass nil when no overrides apply.
func (b *EnvBuilder) Compose(req *proto.RunRequestV1, overrides map[string]string) *proto.StageEnvV1 {
	env := &proto.StageEnvV1{Proto: proto.StageEnvProtoV1}

	// Layer 1: pipeline.conf — every resolved key from internal/config.
	// nil cfg ⇒ leave ConfigKeys nil; consumers must tolerate that.
	if b.cfg != nil && len(b.cfg.Values) > 0 {
		env.ConfigKeys = make(map[string]string, len(b.cfg.Values))
		for k, v := range b.cfg.Values {
			env.ConfigKeys[k] = v
		}
	}

	// Layer 2: run-request flags. The bash globals the legacy pipeline set
	// at flag-parse time map onto these fields.
	if req != nil {
		// MILESTONE_MODE is required: bash files like lib/intake_helpers.sh:191
		// read `"$MILESTONE_MODE"` with no default under set -u.
		env.MilestoneMode = req.Mode == proto.RunModeMilestone || req.Milestone != ""
		env.CurrentMilestone = req.Milestone
		env.Task = req.Task
		env.AutoAdvance = req.AutoAdvance
		env.AutoAdvanceLimit = req.AutoAdvanceLimit
		env.HumanMode = req.Mode == proto.RunModeHuman
		env.HumanNotesTag = req.HumanTag
	}

	// Log channel — synthesized from LogContext + request.
	env.LogDir = b.log.Dir
	env.Timestamp = b.log.Timestamp
	env.LogFile = b.log.LogFile(req)
	env.SessionDir = b.log.SessionDir

	// Layer 3: explicit caller overrides. Land in ConfigKeys so AsKV picks
	// them up alongside the loader-emitted keys; this is the m26 contract
	// "overrides beat config" semantics.
	if len(overrides) > 0 {
		if env.ConfigKeys == nil {
			env.ConfigKeys = make(map[string]string, len(overrides))
		}
		for k, v := range overrides {
			env.ConfigKeys[k] = v
		}
	}

	return env
}

// AsKV flattens StageEnvV1 to bash-style "KEY=value" lines, ready to hand
// to exec.Cmd.Env. The output is deterministic (sorted by key) so a parity
// test or causal-log replay sees the same env every run.
//
// IMPORTANT: ConfigKeys values are passed through verbatim — NOT shell-
// quoted. exec.Cmd.Env is a []string handed directly to execve, not to a
// shell. config.EmitShell does the *separate* shell-quoting for the
// `eval` sourcing path; this method must not double-quote.
func (b *EnvBuilder) AsKV(env *proto.StageEnvV1) []string {
	if env == nil {
		return nil
	}
	// Capacity = config keys + the runtime-flag set we always emit.
	out := make([]string, 0, len(env.ConfigKeys)+10)

	// Runtime flag globals — always emitted (empty string when unset) so
	// `set -u` in the consumer never trips. The bash names mirror the V3
	// pipeline globals exactly.
	out = append(out,
		"MILESTONE_MODE="+boolStr(env.MilestoneMode),
		"_CURRENT_MILESTONE="+env.CurrentMilestone,
		"TASK="+env.Task,
		"AUTO_ADVANCE="+boolStr(env.AutoAdvance),
		"HUMAN_MODE="+boolStr(env.HumanMode),
		"HUMAN_NOTES_TAG="+env.HumanNotesTag,
	)
	if env.AutoAdvanceLimit > 0 {
		out = append(out, "AUTO_ADVANCE_LIMIT="+strconv.Itoa(env.AutoAdvanceLimit))
	}

	// Log channel — emitted only when non-empty so a defaults-only path
	// doesn't leak LOG_FILE="" into the subprocess.
	if env.LogDir != "" {
		out = append(out, "LOG_DIR="+env.LogDir)
	}
	if env.Timestamp != "" {
		out = append(out, "TIMESTAMP="+env.Timestamp)
	}
	if env.LogFile != "" {
		out = append(out, "LOG_FILE="+env.LogFile)
	}
	if env.SessionDir != "" {
		out = append(out, "TEKHTON_SESSION_DIR="+env.SessionDir)
	}

	// Config keys — deterministic sort for parity-test stability.
	if len(env.ConfigKeys) > 0 {
		keys := make([]string, 0, len(env.ConfigKeys))
		for k := range env.ConfigKeys {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			out = append(out, k+"="+env.ConfigKeys[k])
		}
	}
	return out
}

// boolStr renders a bool the way bash scripts expect to read it ("true" /
// "false") rather than Go's "true"/"false" — they happen to match, but
// keeping this funnel here means a future formatting change (e.g. "1" /
// "0") lands in one spot.
func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}
