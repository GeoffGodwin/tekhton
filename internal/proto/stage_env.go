package proto

// Stage / finalize env contract (m26).
//
// Before m26, the bash subprocess env handed to each stage and to the
// finalize hooks was assembled inline at two different points
// (internal/runner/single.go:buildStageEnv for stages, internal/finalize/
// shim.go:buildEnv for finalize hooks). Each surface curated its own subset
// of the bash globals the V3 pipeline set at flag-parse / config-source
// time, with no shared contract. The result: every time a bash file under
// lib/ or stages/ read a runtime global the curated subset hadn't named,
// `set -u` tripped and the stage subprocess exited 1 inside the runner.
//
// StageEnvV1 is the typed Go-side view of the bash subprocess env. It is
// composed once per run by internal/runner.EnvBuilder from three layers
// (config, run-request, caller overrides) and consumed identically by
// every stage and every finalize hook. The serialised form on the wire is
// a flat string→string map (the bash subprocess only sees env strings);
// StageEnvV1 exists so the producer and consumer agree on field names and
// zero values, and so a new field is one edit at the type definition
// rather than two parallel curations.
//
// Versioning. New fields within v1 are additive. A change to an existing
// field's meaning bumps the proto tag.

// StageEnvProtoV1 is the wire identifier for the v1 stage/finalize env
// contract. Mirrors the existing m05 / m18 / m12 envelope-tag style.
const StageEnvProtoV1 = "tekhton.stage_env.v1"

// StageEnvV1 is the typed view of the bash subprocess env that
// internal/runner/env.go composes from config + run-request flags. The
// serialised form is a flat string→string map; this struct is the Go-side
// agreement between producer (runner) and consumers (stagerunner,
// finalize/shim).
//
// Field grouping:
//   - Runtime flag globals — sourced from the run request, not pipeline.conf.
//     These are the bash names the legacy pipeline set at flag-parse time
//     (lib/orchestrate_main.sh, tekhton-legacy.sh:240-260) which the V4
//     subprocess builder must propagate verbatim or `set -u` trips.
//   - Log channel — synthesized once per run by LogContext so future
//     direct callers (e.g. the parity test fixture) get the same path the
//     live pipeline does.
//   - ConfigKeys — the K→V map emitted by internal/config; every
//     pipeline.conf key the m16 loader exposes, including resolved
//     defaults. Passed through verbatim (NOT shell-quoted — see
//     EnvBuilder.AsKV for the rationale).
type StageEnvV1 struct {
	Proto string `json:"proto"`

	// Runtime flag globals.
	MilestoneMode    bool   `json:"milestone_mode"`
	CurrentMilestone string `json:"current_milestone,omitempty"`
	Task             string `json:"task,omitempty"`
	AutoAdvance      bool   `json:"auto_advance"`
	AutoAdvanceLimit int    `json:"auto_advance_limit,omitempty"`
	HumanMode        bool   `json:"human_mode"`
	HumanNotesTag    string `json:"human_notes_tag,omitempty"`

	// Log channel.
	LogDir    string `json:"log_dir,omitempty"`
	LogFile   string `json:"log_file,omitempty"`
	Timestamp string `json:"timestamp,omitempty"`

	// Pipeline.conf — emitted as KEY=value pairs onto exec.Cmd.Env. NOT
	// shell-quoted: exec.Cmd.Env is a []string passed directly to execve,
	// not interpreted by a shell. (config.EmitShell is the *separate*
	// path that quotes for `eval` sourcing.)
	ConfigKeys map[string]string `json:"config_keys,omitempty"`
}

// EnsureProto stamps the envelope tag if absent. Mirrors the helper on
// every other proto envelope in this package.
func (s *StageEnvV1) EnsureProto() {
	if s == nil {
		return
	}
	if s.Proto == "" {
		s.Proto = StageEnvProtoV1
	}
}
