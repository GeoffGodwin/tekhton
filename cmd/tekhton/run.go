package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/geoffgodwin/tekhton/internal/config"
	"github.com/geoffgodwin/tekhton/internal/manifest"
	"github.com/geoffgodwin/tekhton/internal/pipeline"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/runner"
	stagearchitect "github.com/geoffgodwin/tekhton/internal/stages/architect"
	stagecleanup "github.com/geoffgodwin/tekhton/internal/stages/cleanup"
	stagecoder "github.com/geoffgodwin/tekhton/internal/stages/coder"
	stagedocs "github.com/geoffgodwin/tekhton/internal/stages/docs"
	stageintake "github.com/geoffgodwin/tekhton/internal/stages/intake"
	stagereview "github.com/geoffgodwin/tekhton/internal/stages/review"
	stagesecurity "github.com/geoffgodwin/tekhton/internal/stages/security"
	stagetester "github.com/geoffgodwin/tekhton/internal/stages/tester"
	"github.com/geoffgodwin/tekhton/internal/stagerunner"
	"github.com/geoffgodwin/tekhton/internal/state"
	"github.com/geoffgodwin/tekhton/internal/tui"
	"github.com/spf13/cobra"
)

// newRunCmd wires `tekhton run` — the run-flag entry point ported from
// tekhton.sh in m19. The bash entry point still dispatches the legacy flags
// (--init, --rescan, --report, --status, --metrics, --migrate, --health,
// --rollback) through their existing code paths; m20 flips tekhton.sh to
// route run-flags through here.
func newRunCmd() *cobra.Command {
	var (
		taskFlag              string
		completeFlag          bool
		resumeFlag            bool
		humanFlag             bool
		humanTagFlag          string
		milestoneFlag         string
		autoAdvanceFlag       bool
		autoAdvanceLimit      int
		dryRunFlag            bool
		noTUIFlag             bool
		projectDirFlag        string
		tekhtonHomeFlag       string
		analyzeCmd            string
		compileCmd            string
		testCmd               string
		providerOverride      string
		providerChainOverride string
		requireTier           string
	)

	c := &cobra.Command{
		Use:   "run",
		Short: "Run the Tekhton pipeline (m19).",
		Long: "tekhton run drives the pipeline through internal/runner. Exactly one\n" +
			"of --task / --human / --milestone / --resume must be present.\n" +
			"--complete enables the autonomous outer retry loop. Run-level\n" +
			"behavior bridges to bash for pre-flight, finalize, and the TUI sidecar\n" +
			"during the V4 wedge — see DESIGN_v4.md Phase 5 for the planned cuts.",
		RunE: func(cmd *cobra.Command, args []string) error {
			req, err := buildRunRequest(
				taskFlag, completeFlag, resumeFlag, humanFlag, humanTagFlag,
				milestoneFlag, autoAdvanceFlag, autoAdvanceLimit, dryRunFlag,
				noTUIFlag, projectDirFlag, tekhtonHomeFlag,
			)
			if err != nil {
				printRunUsageError(cmd.ErrOrStderr(), cmd, err, args, autoAdvanceFlag)
				return errExitCode{code: exitUsage, err: err}
			}
			if len(args) > 0 {
				printRunUsageError(cmd.ErrOrStderr(), cmd,
					fmt.Errorf("unexpected positional argument(s): %s", strings.Join(args, " ")),
					args, autoAdvanceFlag)
				return errExitCode{code: exitUsage, err: fmt.Errorf("unexpected positional arguments")}
			}

			// Provider flag overrides: set env before per-stage resolution in buildRunner.
			if providerOverride != "" {
				os.Setenv("PROVIDER", providerOverride)
			}
			if providerChainOverride != "" {
				os.Setenv("PROVIDER", providerChainOverride)
			}
			if requireTier != "" {
				os.Setenv("TEKHTON_REQUIRE_TIER", requireTier)
			}

			r, cleanup, err := buildRunner(req, analyzeCmd, compileCmd, testCmd)
			if err != nil {
				return err
			}
			defer cleanup()

			ctx := context.Background()

			var (
				res    *proto.RunResultV1
				runErr error
			)
			// NOTE: --dry-run is accepted by the flag set and stored in
			// req.DryRun, but no dispatch branch consumes it yet — every path
			// below invokes agents for real. Wiring the flag to a preview-only
			// pipeline path is deferred to Phase 5 / a later milestone.
			// For milestone-mode runs, derive a non-empty Task string from
			// the manifest entry's title. The bash stage subprocesses read
			// TASK to set up the coder prompt; without this, coder agents
			// see an empty `BEGIN USER TASK / END USER TASK` block and
			// self-report "nothing to implement" even when the milestone
			// has real work to do. The MILESTONE_BLOCK env var separately
			// carries the full milestone file content for the bash side's
			// set_focused_milestone_block helper, but the agent's prompt
			// also renders {{TASK}} above the block, and an empty TASK is
			// what triggers the null-run pattern that cascaded through
			// m36.1, m36.2, m41, m42, m43 on the 2026-06-03 auto-advance.
			deriveMilestoneTask(req)

			switch {
			case resumeFlag:
				res, runErr = r.Resume(ctx)
			case completeFlag:
				res, runErr = r.RunCompleteLoop(ctx, req)
			default:
				res, runErr = r.RunSingle(ctx, req)
			}

			if res != nil {
				printRunSummary(cmd.OutOrStdout(), res)
			}
			if runErr != nil {
				if errors.Is(runErr, runner.ErrSafetyBound) || errors.Is(runErr, runner.ErrStuck) {
					return errExitCode{code: 2, err: runErr}
				}
				return runErr
			}
			if res != nil && res.Disposition != proto.RunDispositionSuccess {
				return errExitCode{code: 1, err: fmt.Errorf("disposition=%s", res.Disposition)}
			}

			// Auto-advance loop. Only fires for milestone-mode runs (the only
			// concept "next milestone" applies to) AND when --auto-advance is
			// set AND the just-finished run succeeded. Stops at the configured
			// limit, when the manifest frontier is empty, or as soon as a
			// single advance fails or is declined.
			//
			// This logic used to live in lib/orchestrate_aux.sh:
			// _run_auto_advance_chain. The m20 dogfooding cutover moved the
			// top-level entry point to Go but left this loop behind in bash,
			// which only runs when tekhton-legacy.sh is the entry point.
			// Result on the user's side: `tekhton --milestone m34.1
			// --auto-advance --auto-advance-limit 4` only ran m34.1 then
			// exited cleanly without ever advancing.
			if autoAdvanceFlag && req.Mode == proto.RunModeMilestone {
				if err := runAutoAdvanceLoop(ctx, cmd, req, autoAdvanceLimit,
					analyzeCmd, compileCmd, testCmd); err != nil {
					return err
				}
			}
			return nil
		},
	}

	c.Flags().StringVar(&taskFlag, "task", "", "free-form task description")
	c.Flags().BoolVar(&completeFlag, "complete", false, "run in autonomous --complete mode")
	c.Flags().BoolVar(&resumeFlag, "resume", false, "resume from $PIPELINE_STATE_FILE (default .claude/PIPELINE_STATE.md)")
	c.Flags().BoolVar(&humanFlag, "human", false, "run in --human mode (HUMAN_NOTES.md driven)")
	c.Flags().StringVar(&humanTagFlag, "human-tag", "", "optional tag filter for --human")
	c.Flags().StringVar(&milestoneFlag, "milestone", "", "specific milestone id to run")
	c.Flags().BoolVar(&autoAdvanceFlag, "auto-advance", false, "advance to next milestone on success")
	c.Flags().IntVar(&autoAdvanceLimit, "auto-advance-limit", 0, "override AUTO_ADVANCE_LIMIT — persisted in PIPELINE_STATE and restored on --resume")
	c.Flags().BoolVar(&dryRunFlag, "dry-run", false, "preview run without invoking agents")
	c.Flags().BoolVar(&noTUIFlag, "no-tui", false, "disable TUI sidecar")
	c.Flags().StringVar(&projectDirFlag, "project-dir", "", "target project (defaults to PROJECT_DIR or cwd)")
	c.Flags().StringVar(&tekhtonHomeFlag, "tekhton-home", "", "tekhton repo root (defaults to TEKHTON_HOME)")
	c.Flags().StringVar(&analyzeCmd, "analyze-cmd", "", "build-gate analyze command (default: skip)")
	c.Flags().StringVar(&compileCmd, "compile-cmd", "", "build-gate compile command (default: skip)")
	c.Flags().StringVar(&testCmd, "test-cmd", "", "completion-gate test command (default: skip)")
	c.Flags().StringVar(&providerOverride, "provider", "",
		"Override PROVIDER env for this run (single provider name, e.g. claude)")
	c.Flags().StringVar(&providerChainOverride, "provider-chain", "",
		"Override PROVIDER env with an explicit chain (comma-separated, e.g. codex,claude)")
	c.Flags().StringVar(&requireTier, "require-tier", "",
		"Fail rather than fall through to a costlier tier (subscription | api | local)")
	return c
}

// buildRunRequest validates flag combinations and assembles a RunRequestV1.
// Exactly-one-of validation is the primary failure mode; the rest is field
// transcription.
func buildRunRequest(
	task string,
	complete, resume, human bool,
	humanTag string,
	milestone string,
	autoAdvance bool,
	autoAdvanceLimit int,
	dryRun, noTUI bool,
	projectDir, tekhtonHome string,
) (*proto.RunRequestV1, error) {
	chosen := 0
	mode := ""
	switch {
	case resume:
		chosen++
		mode = proto.RunModeResume
	}
	if task != "" {
		chosen++
		mode = proto.RunModeTask
	}
	if human {
		chosen++
		mode = proto.RunModeHuman
	}
	if milestone != "" {
		chosen++
		mode = proto.RunModeMilestone
	}
	if chosen != 1 {
		return nil, fmt.Errorf("exactly one of --task / --human / --milestone / --resume required (saw %d)", chosen)
	}

	// Normalize the milestone arg to canonical lowercase-id form. The bash
	// side (lib/milestone_dag.sh, lib/intake_helpers.sh, etc.) keys files
	// off `m<NN>`; accepting "M27" / "m27" / "27" at the CLI and emitting a
	// single canonical form keeps intake from silently passing through
	// because dag_number_to_id couldn't match an uppercase prefix.
	if milestone != "" {
		milestone = normalizeMilestoneID(milestone)
	}

	if projectDir == "" {
		projectDir = os.Getenv("PROJECT_DIR")
	}
	if projectDir == "" {
		cwd, _ := os.Getwd()
		projectDir = cwd
	}
	if tekhtonHome == "" {
		tekhtonHome = os.Getenv("TEKHTON_HOME")
	}
	if tekhtonHome == "" {
		return nil, fmt.Errorf("--tekhton-home or TEKHTON_HOME required")
	}

	req := &proto.RunRequestV1{
		Proto:            proto.RunRequestProtoV1,
		Mode:             mode,
		Task:             task,
		HumanTag:         humanTag,
		Milestone:        milestone,
		Complete:         complete,
		AutoAdvance:      autoAdvance,
		AutoAdvanceLimit: autoAdvanceLimit,
		DryRun:           dryRun,
		NoTUI:            noTUI,
		ProjectDir:       projectDir,
		TekhtonHome:      tekhtonHome,
	}
	if mode != proto.RunModeResume {
		if err := req.Validate(); err != nil {
			return nil, err
		}
	}
	return req, nil
}

// buildRunner wires the runner with its dependencies. Caller invokes the
// returned cleanup func before returning from Cobra.
func buildRunner(req *proto.RunRequestV1, analyzeCmd, compileCmd, testCmd string) (*runner.Runner, func(), error) {
	adapter := &stagerunner.BashAdapter{
		TekhtonHome: req.TekhtonHome,
		ProjectDir:  req.ProjectDir,
		LogWriter:   os.Stderr,
		TekhtonBin:  resolveTekhtonBin(),
	}

	pipeOpts := pipeline.Options{
		LogDir:    filepath.Join(req.ProjectDir, ".claude", "logs"),
		ResultDir: filepath.Join(req.ProjectDir, ".tekhton", "stage_results"),
	}
	if analyzeCmd != "" || compileCmd != "" {
		pipeOpts.Gate = &pipeline.BuildGate{
			AnalyzeCmd: analyzeCmd,
			CompileCmd: compileCmd,
		}
	}
	if testCmd != "" {
		pipeOpts.CompletionGate = &pipeline.CompletionGate{TestCmd: testCmd}
	}

	pipe, err := pipeline.New(adapter, pipeOpts)
	if err != nil {
		return nil, func() {}, err
	}

	// Resolve PIPELINE_STATE_FILE the same way every other config file
	// resolves: env override → canonical default. The canonical default
	// in internal/config/defaults.go is `.claude/PIPELINE_STATE.md` (the
	// bash-era extension; the file content is JSON but bash writes .md).
	// Earlier this path hardcoded `.json` which silently mismatched the
	// bash writer — `tekhton --resume` then failed with "no state file"
	// because the saved file was under .md but the runner looked for
	// .json. Honoring the env contract closes the gap.
	stateOverride := os.Getenv("PIPELINE_STATE_FILE")
	if stateOverride == "" {
		stateOverride = filepath.Join(".claude", "PIPELINE_STATE.md")
	}
	var statePath string
	if filepath.IsAbs(stateOverride) {
		statePath = stateOverride
	} else {
		statePath = filepath.Join(req.ProjectDir, stateOverride)
	}
	r := runner.New(pipe)
	r.State = state.New(statePath)
	r.ProjectDir = req.ProjectDir
	r.TekhtonHome = req.TekhtonHome

	// Per-stage provider injection: resolve PROVIDER/PROVIDER_<STAGE>= env
	// for each stage package so per-stage overrides take effect. Replaces
	// the m02 single-provider injection.
	for _, stageName := range []string{
		"intake", "cleanup", "docs", "security", "architect", "review", "tester", "coder",
	} {
		p, err := runner.ResolveProvider(stageName)
		if err != nil {
			fmt.Fprintf(os.Stderr, "provider: stage %q: %v\n", stageName, err)
			continue
		}
		switch stageName {
		case "intake":
			stageintake.SetProvider(p)
		case "cleanup":
			stagecleanup.SetProvider(p)
		case "docs":
			stagedocs.SetProvider(p)
		case "security":
			stagesecurity.SetProvider(p)
		case "architect":
			stagearchitect.SetProvider(p)
		case "review":
			stagereview.SetProvider(p)
		case "tester":
			stagetester.SetProvider(p)
		case "coder":
			stagecoder.SetProvider(p)
		}
	}

	// m26: load pipeline.conf once and build the EnvBuilder that feeds
	// every stage subprocess + every finalize hook the same composed env.
	// Missing pipeline.conf surfaces as a stderr warning and the builder
	// runs in defaults-only mode — preflight is supposed to flag the bare
	// directory case; we don't crash here.
	envBuilder := buildEnvBuilder(req)
	r.Env = envBuilder
	r.Hooks = &runner.BashHookRunner{TekhtonHome: req.TekhtonHome, Env: envBuilder}

	var sidecar *tui.Sidecar
	if !req.NoTUI {
		sidecar = tui.New(req.TekhtonHome, req.ProjectDir)
		r.TUI = sidecar
	}

	cleanup := func() {
		if sidecar != nil && sidecar.PID() != 0 {
			_ = sidecar.Stop(context.Background(), false)
		}
	}
	return r, cleanup, nil
}

// printRunSummary writes a one-paragraph summary of the run to stdout. The
// finalize bridge prints the full RUN_SUMMARY.md / banner; we keep this
// terse so a CLI caller piping output can grep it.
func printRunSummary(out interface{ Write([]byte) (int, error) }, res *proto.RunResultV1) {
	fmt.Fprintf(out, "tekhton run: disposition=%s attempts=%d agent_calls=%d elapsed=%ds",
		res.Disposition, res.Attempts, res.AgentCalls, res.ElapsedSecs)
	if res.Recovery != "" {
		fmt.Fprintf(out, " recovery=%s", res.Recovery)
	}
	fmt.Fprintln(out)
}

var milestoneIDPattern = regexp.MustCompile(`^[Mm]\d+$`)

// printRunUsageError emits a clear, actionable diagnostic for usage errors
// against `tekhton run`. It surfaces silently-dropped positional args, calls
// out the V3→V4 syntax change for --auto-advance, and prints the full flag
// usage block. The root cmd has SilenceUsage=true; printing it here keeps the
// usage block off non-usage failures while ensuring syntax errors are
// debuggable.
func printRunUsageError(w interface{ Write([]byte) (int, error) }, cmd *cobra.Command, cause error, args []string, autoAdvance bool) {
	fmt.Fprintf(w, "tekhton run: %s\n\n", cause.Error())

	if len(args) > 0 {
		fmt.Fprintf(w, "Unused positional argument(s): %s\n", strings.Join(args, " "))
		hints := suggestionsFromArgs(args, autoAdvance)
		for _, h := range hints {
			fmt.Fprintf(w, "  hint: %s\n", h)
		}
		fmt.Fprintln(w)
	}

	if autoAdvance {
		fmt.Fprintln(w, "Note: in V4 --auto-advance is a boolean flag. The V3 form")
		fmt.Fprintln(w, "  `--auto-advance N \"task\"` is no longer supported. Use:")
		fmt.Fprintln(w, "    --auto-advance --auto-advance-limit N --milestone <id>")
		fmt.Fprintln(w)
	}

	fmt.Fprintln(w, "Examples:")
	fmt.Fprintln(w, "  tekhton --task \"Add OAuth login\"")
	fmt.Fprintln(w, "  tekhton --milestone m23")
	fmt.Fprintln(w, "  tekhton --milestone m23 --auto-advance --auto-advance-limit 3")
	fmt.Fprintln(w, "  tekhton --resume")
	fmt.Fprintln(w)

	fmt.Fprintln(w, cmd.UsageString())
}

// suggestionsFromArgs maps stray positionals to likely intended flags. Bare
// integers next to --auto-advance map to --auto-advance-limit; milestone-id-
// looking tokens map to --milestone; everything else suggests --task.
func suggestionsFromArgs(args []string, autoAdvance bool) []string {
	var out []string
	for _, a := range args {
		switch {
		case autoAdvance && isBareInt(a):
			out = append(out, fmt.Sprintf("did you mean `--auto-advance-limit %s`?", a))
		case milestoneIDPattern.MatchString(a):
			out = append(out, fmt.Sprintf("did you mean `--milestone %s`?", a))
		default:
			out = append(out, fmt.Sprintf("did you mean `--task %q`?", a))
		}
	}
	return out
}

func isBareInt(s string) bool {
	_, err := strconv.Atoi(s)
	return err == nil
}

// normalizeMilestoneID maps "M27" / "m27" / "27" / "M27.1" / "27.1" onto
// the canonical bare-number form ("27" / "27.1") the bash side expects in
// _CURRENT_MILESTONE. lib/milestone_dag.sh:63 dag_number_to_id iterates
// over _DAG_IDS comparing against dag_id_to_number, which strips the "m"
// prefix — so passing "m27" produces an off-by-one match failure and
// intake silently passes with no content. Anything that doesn't match a
// recognized shape is returned unchanged (lowercased) so a future format
// extension doesn't silently corrupt operator input.
func normalizeMilestoneID(s string) string {
	if s == "" {
		return s
	}
	low := strings.ToLower(s)
	// Strip the "m" / "M" prefix when present: "m27" → "27", "M27.1" → "27.1".
	if len(low) > 1 && low[0] == 'm' && low[1] >= '0' && low[1] <= '9' {
		return low[1:]
	}
	// Already bare-number form.
	if low[0] >= '0' && low[0] <= '9' {
		return low
	}
	return low
}

// buildEnvBuilder loads the project's pipeline.conf and wires it onto a
// runner.EnvBuilder for the run. The builder is shared by the stage
// dispatcher (every stage in defaultStageOrder sees the same env) and
// the finalize chain (every hook sees the same env).
//
// Defaults-only path. config.Load failure does NOT panic; we warn on
// stderr and return a builder with a nil *config.Config. Compose then
// produces only the runtime-flag fields + an empty ConfigKeys map, which
// is enough for bash stages whose only requirement is "set -u doesn't
// trip on MILESTONE_MODE / TASK". Preflight is the layer responsible for
// flagging the missing config as a Fail; the runner should not silently
// mask its diagnostic by refusing to start.
func buildEnvBuilder(req *proto.RunRequestV1) *runner.EnvBuilder {
	confPath := filepath.Join(req.ProjectDir, ".claude", "pipeline.conf")
	cfg, err := config.Load(confPath, config.LoadOptions{
		ProjectDir:    req.ProjectDir,
		MilestoneMode: req.Mode == proto.RunModeMilestone,
	})
	if err != nil {
		// Note: config.Load returns *Config alongside an error for some
		// recoverable cases (missing required key, validation warnings).
		// We only blank the builder out on outright not-found / parse;
		// other errors leave the partial Config so resolved keys can
		// still feed the env.
		if errors.Is(err, config.ErrNotFound) || errors.Is(err, config.ErrParse) {
			fmt.Fprintln(os.Stderr, "env: pipeline.conf not loadable, running with defaults — preflight should fail:", err)
			cfg = nil
		} else {
			fmt.Fprintln(os.Stderr, "env: pipeline.conf load returned warnings:", err)
		}
	}
	// Per-run scratch directory — the legacy dispatcher created this via
	// mktemp (tekhton.sh:219). Bash files like lib/intake_helpers.sh:29
	// read $TEKHTON_SESSION_DIR with no default under set -u; without
	// this the intake stage subprocess trips immediately. Creation
	// failures fall back to /tmp so the env still names a writable path.
	sessionDir, err := os.MkdirTemp("", "tekhton_session_")
	if err != nil {
		fmt.Fprintln(os.Stderr, "env: failed to create session dir, using /tmp:", err)
		sessionDir = "/tmp"
	}
	logCtx := runner.LogContext{
		Dir:        filepath.Join(req.ProjectDir, ".claude", "logs"),
		Timestamp:  time.Now().UTC().Format("20060102_150405"),
		SessionDir: sessionDir,
	}
	return runner.NewEnvBuilder(cfg, logCtx)
}

// runAutoAdvanceLoop continues running milestones in sequence after a
// successful initial run. Mirrors the bash _run_auto_advance_chain logic
// from lib/orchestrate_aux.sh.
//
// Stop conditions:
//   - limit reached (default 3 when limit == 0, matching the bash default)
//   - manifest frontier empty (no more milestones ready to run)
//   - just-finished milestone is not actually marked done (finalize failed
//     to update the manifest — re-running would loop forever)
//   - any iteration fails or completes with non-success disposition
//
// deriveMilestoneTask populates req.Task with a derived "Implement
// Milestone <ID>: <Title>" string when:
//   - req is in milestone mode (req.Mode == RunModeMilestone), AND
//   - req.Task is empty (no explicit override), AND
//   - the manifest can be loaded and the milestone id resolves.
//
// Mirrors the bash convention from stages/coder.sh::_switch_to_sub_milestone
// (`TASK="Implement Milestone ${_first_sub}: ${_first_title}"`) so the coder
// prompt's {{TASK}} block always has a non-empty descriptor on milestone-
// mode runs. Without this, the Go runner emits TASK="" into the stage
// subprocess env, the coder reads an empty `BEGIN USER TASK` block, and
// self-reports nothing-to-implement — the null-run cascade.
//
// Best-effort: any failure (manifest unreadable, id not in manifest,
// missing PROJECT_DIR) leaves req.Task as-is. The bash stage's
// MILESTONE_BLOCK helper still carries the full milestone file content
// independently — this helper is the upper-level TASK descriptor, not
// the design payload.
func deriveMilestoneTask(req *proto.RunRequestV1) {
	if req == nil || req.Mode != proto.RunModeMilestone || req.Task != "" {
		return
	}
	if req.Milestone == "" || req.ProjectDir == "" {
		return
	}
	manifestPath := os.Getenv("MILESTONE_MANIFEST_FILE")
	if manifestPath == "" {
		manifestPath = filepath.Join(req.ProjectDir, ".claude", "milestones", "MANIFEST.cfg")
	}
	m, err := manifest.Load(manifestPath)
	if err != nil {
		return
	}
	// Try the literal id first, then with an "m" prefix prepended. The CLI's
	// normalizeMilestoneID strips the prefix from --milestone arguments so
	// req.Milestone is the bare-number form ("36.1"), but the manifest stores
	// entries keyed by the prefixed form ("m36.1"). Without the second
	// lookup, this entire helper silently no-ops for every CLI-initiated
	// milestone run — which is what produced the empty TASK that triggered
	// the "feat: changes in .claude/project_version.cfg" commit subjects
	// across the m36.1 dogfood pass.
	entry, ok := m.Get(req.Milestone)
	if !ok && !strings.HasPrefix(req.Milestone, "m") {
		entry, ok = m.Get("m" + req.Milestone)
	}
	if !ok {
		return
	}
	req.Task = fmt.Sprintf("Implement Milestone %s: %s", entry.ID, entry.Title)
}

func runAutoAdvanceLoop(
	ctx context.Context,
	cmd *cobra.Command,
	initialReq *proto.RunRequestV1,
	limit int,
	analyzeCmd, compileCmd, testCmd string,
) error {
	if limit <= 0 {
		limit = 3 // bash default — AUTO_ADVANCE_LIMIT in config_defaults.sh
	}

	// IMPORTANT: the manifest stores entries keyed by their `m`-prefixed
	// id ("m34.2"), but `normalizeMilestoneID` strips the prefix so
	// `req.Milestone` is the bare-number form ("34.2"). All manifest
	// operations below — `m.Get(currentID)`, frontier comparisons —
	// need the `m`-prefixed form, or `Get` returns ok=false (silently
	// skipping the safety check) AND the lex comparison gets the wrong
	// ordering (bare "34.2" < any `m*` byte-wise, so every frontier
	// entry passes the "strictly greater" filter and the loop picks
	// `m05.1` instead of `m35.1`). The overnight m34.2 → m05.1 → m05.2
	// → m32.3 advance was exactly this bug. Re-apply the prefix here.
	currentID := initialReq.Milestone
	if currentID != "" && !strings.HasPrefix(currentID, "m") {
		currentID = "m" + currentID
	}
	advances := 0

	for advances < limit {
		// Re-load the manifest each iteration — the prior run's finalize
		// chain just wrote it. Path resolution mirrors the bash side:
		// $MILESTONE_MANIFEST_FILE override → .claude/milestones/MANIFEST.cfg
		// under PROJECT_DIR.
		manifestPath := os.Getenv("MILESTONE_MANIFEST_FILE")
		if manifestPath == "" {
			manifestPath = filepath.Join(initialReq.ProjectDir, ".claude", "milestones", "MANIFEST.cfg")
		}
		m, err := manifest.Load(manifestPath)
		if err != nil {
			fmt.Fprintf(cmd.OutOrStdout(), "auto-advance: load manifest: %v\n", err)
			return nil // best-effort, don't fail the whole run
		}

		// Sanity check: the milestone we just ran must be marked done.
		// If finalize_hook_mark_done didn't flip it (the resume-mode bug
		// where MILESTONE_MODE was false), bail rather than loop on the
		// same id forever.
		if cur, ok := m.Get(currentID); ok && cur.Status != "done" && cur.Status != "skipped" {
			fmt.Fprintf(cmd.OutOrStdout(),
				"auto-advance: %s is %q in manifest, not done — finalize hook may have skipped. Stopping.\n",
				currentID, cur.Status)
			return nil
		}

		// Pick the next milestone from the frontier. Frontier already
		// filters out split parents and entries whose deps aren't met,
		// but it includes ANY ready milestone (including ancient
		// pendings like m05.1 from a previous arc). Prefer the
		// lexicographically-smallest id that's strictly greater than
		// currentID — that gets us m34.2 after m34.1, m35.1 after
		// m34.2, etc. Fall back to the lowest frontier id when nothing
		// is "after" current (covers the case where the user starts
		// from an out-of-order milestone).
		frontier := m.Frontier()
		if len(frontier) == 0 {
			fmt.Fprintln(cmd.OutOrStdout(), "auto-advance: manifest frontier is empty — nothing more to run.")
			return nil
		}
		var next *manifest.Entry
		for _, e := range frontier {
			if e.ID <= currentID {
				continue
			}
			if next == nil || e.ID < next.ID {
				next = e
			}
		}
		if next == nil {
			for _, e := range frontier {
				if next == nil || e.ID < next.ID {
					next = e
				}
			}
		}
		advances++

		fmt.Fprintf(cmd.OutOrStdout(),
			"\n══════════════════════════════════════\n"+
				"  auto-advance %d/%d → %s — %s\n"+
				"══════════════════════════════════════\n\n",
			advances, limit, next.ID, next.Title)

		// m48 — Reset per-iteration commit-skip sentinels. Without this,
		// every iteration after the first inherits the previous one's
		// .commit_decision / .final_check_result sentinels and
		// _hook_commit silently skips. Non-fatal: the worst case is the
		// pre-fix behavior (silent commit skip), and the post-iteration
		// banner below will surface it.
		if err := clearAutoAdvanceIterationState(initialReq.ProjectDir); err != nil {
			fmt.Fprintf(cmd.OutOrStdout(),
				"auto-advance: warning: clear iteration state for %s: %v\n",
				next.ID, err)
		}

		// Build a fresh request for the next milestone. Reuse the original
		// request's project + tekhton-home + flags so the new run sees the
		// same environment as the first.
		nextReq := &proto.RunRequestV1{
			Proto:            proto.RunRequestProtoV1,
			Mode:             proto.RunModeMilestone,
			Milestone:        next.ID,
			Task:             fmt.Sprintf("Implement Milestone %s: %s", next.ID, next.Title),
			ProjectDir:       initialReq.ProjectDir,
			TekhtonHome:      initialReq.TekhtonHome,
			NoTUI:            initialReq.NoTUI,
			DryRun:           initialReq.DryRun,
			AutoAdvance:      true,
			AutoAdvanceLimit: limit,
		}
		r, cleanup, err := buildRunner(nextReq, analyzeCmd, compileCmd, testCmd)
		if err != nil {
			return fmt.Errorf("auto-advance: build runner for %s: %w", next.ID, err)
		}
		res, runErr := r.RunSingle(ctx, nextReq)
		cleanup()

		if res != nil {
			printRunSummary(cmd.OutOrStdout(), res)
		}
		if runErr != nil {
			if errors.Is(runErr, runner.ErrSafetyBound) || errors.Is(runErr, runner.ErrStuck) {
				return errExitCode{code: 2, err: runErr}
			}
			return runErr
		}
		if res != nil && res.Disposition != proto.RunDispositionSuccess {
			return errExitCode{code: 1,
				err: fmt.Errorf("auto-advance: %s disposition=%s", next.ID, res.Disposition)}
		}

		// m48 — Per-iteration commit confirmation banner. Surfaces whether
		// _hook_commit fired for this iteration so the operator can spot a
		// silent skip without scrolling through the log.
		emitAutoAdvanceCommitBanner(cmd.OutOrStdout(), initialReq.ProjectDir, next.ID)

		currentID = next.ID
	}

	fmt.Fprintf(cmd.OutOrStdout(),
		"auto-advance: reached limit %d, stopping.\n", limit)
	return nil
}

// clearAutoAdvanceIterationState removes commit-skip sentinels and other
// per-iteration state files that, if inherited from the previous milestone
// in the chain, would silently poison the current iteration's _hook_commit.
// The reset is intentionally minimal: every file listed here is a sentinel
// that the Go finalize chain WRITES during its own flow; clearing them at
// iteration start is equivalent to running the pipeline against a fresh tree.
//
// Without this reset, every iteration after the first inherits the previous
// iteration's .commit_decision="skipped" (or worse, a FINAL_CHECK_RESULT=1)
// and _hook_commit short-circuits. The m46-added warn fires on every skip,
// but the loud output gets lost in long-chain runs (six milestones × dozens
// of log lines each).
//
// Reference: 2026-06-07 auto-advance run that produced bf46f8f (m47
// [MILESTONE ✓]) + a4579be (m38.5 intake bookkeeping) + zero commits for the
// next 5 milestones. The work landed correctly, but the per-milestone
// narrative was lost.
//
// The sentinel list is exhaustive but not closed. If a future milestone adds
// another commit-skip sentinel, add it to this list.
func clearAutoAdvanceIterationState(projectDir string) error {
	if projectDir == "" {
		return nil
	}
	tekhtonDir := filepath.Join(projectDir, ".tekhton")
	sentinels := []string{
		".final_check_result",
		".final_check_reason",
		".commit_decision",
	}
	var firstErr error
	for _, name := range sentinels {
		path := filepath.Join(tekhtonDir, name)
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			if firstErr == nil {
				firstErr = err
			}
		}
	}
	return firstErr
}

// emitAutoAdvanceCommitBanner emits a one-line operator-visible confirmation
// after each successful auto-advance iteration. Inspects HEAD to determine
// whether _hook_commit fired for this iteration. Lets the operator see at-a-
// glance whether the per-milestone narrative is being preserved.
//
// The post-finalize commit subject is `[MILESTONE <num> ✓] <message>` when
// _hook_commit fired (see lib/milestone_ops.sh::get_milestone_commit_prefix).
// The number is the bare form ("38.5"), so we strip the "m" prefix from
// milestoneID before building the expected prefix.
//
// m50 — Additionally surfaces a `⚠ MANIFEST.cfg committed by non-finalize
// source` line when HEAD touched .claude/milestones/MANIFEST.cfg under a
// subject that does NOT match the milestone-commit prefix. The bash
// pre-commit guard (lib/finalize_commit.sh::_check_manifest_write_guard)
// is the hard enforcer; this banner is observability for the
// belt-and-suspenders case where a future regression bypasses the bash
// guard (e.g. a code path that calls git commit directly without sourcing
// lib/finalize_commit.sh).
func emitAutoAdvanceCommitBanner(w io.Writer, projectDir, milestoneID string) {
	headHash, headSubject, err := readGitHead(projectDir)
	if err != nil || headHash == "" {
		fmt.Fprintf(w,
			"⚠ %s finalize completed but HEAD read failed (%v) — verify commit fired\n",
			milestoneID, err)
		return
	}
	expectedPrefix := fmt.Sprintf("[MILESTONE %s ✓]", strings.TrimPrefix(milestoneID, "m"))
	if strings.HasPrefix(headSubject, expectedPrefix) {
		fmt.Fprintf(w, "✓ %s committed as %s\n", milestoneID, headHash[:8])
		emitManifestWriteAuditBanner(w, projectDir, milestoneID, headSubject, expectedPrefix)
		return
	}
	fmt.Fprintf(w,
		"⚠ %s finalize skipped commit — HEAD subject is %q (expected %q prefix). "+
			"Inspect .tekhton/.commit_decision and .tekhton/.final_check_result.\n",
		milestoneID, headSubject, expectedPrefix)
	emitManifestWriteAuditBanner(w, projectDir, milestoneID, headSubject, expectedPrefix)
}

// emitManifestWriteAuditBanner is the m50 defense-in-depth observability
// hop layered on top of the per-iteration commit banner. Emits a warning
// line when the HEAD commit touched .claude/milestones/MANIFEST.cfg AND the
// commit subject does not match the milestone-commit prefix (i.e. the
// commit was NOT initiated by the finalize chain). Pure observability —
// the bash pre-commit guard does the hard enforcement; this only fires
// retrospectively if a future regression bypasses the guard.
func emitManifestWriteAuditBanner(w io.Writer, projectDir, milestoneID, headSubject, expectedPrefix string) {
	// Finalize-initiated commits legitimately mutate MANIFEST.cfg via
	// _hook_mark_done; only flag commits that did NOT come from finalize.
	if strings.HasPrefix(headSubject, expectedPrefix) {
		return
	}
	if !headCommitTouchedManifest(projectDir) {
		return
	}
	fmt.Fprintf(w,
		"⚠ %s MANIFEST.cfg committed by non-finalize source — "+
			"inspect HEAD and verify lib/finalize_commit.sh::_check_manifest_write_guard fired\n",
		milestoneID)
}

// headCommitTouchedManifest returns true when `git show --name-only HEAD`
// lists .claude/milestones/MANIFEST.cfg. Errors swallowed — observability
// is opportunistic, never blocking.
func headCommitTouchedManifest(projectDir string) bool {
	c := exec.Command("git", "show", "--name-only", "--format=", "HEAD")
	c.Dir = projectDir
	out, err := c.Output()
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.TrimSpace(line) == ".claude/milestones/MANIFEST.cfg" {
			return true
		}
	}
	return false
}

// readGitHead returns the HEAD commit hash and subject for the repo rooted
// at projectDir. Used by emitAutoAdvanceCommitBanner to detect whether the
// per-milestone commit fired.
func readGitHead(projectDir string) (hash, subject string, err error) {
	c := exec.Command("git", "log", "-1", "--format=%H %s")
	c.Dir = projectDir
	out, err := c.Output()
	if err != nil {
		return "", "", err
	}
	parts := strings.SplitN(strings.TrimSpace(string(out)), " ", 2)
	if len(parts) != 2 {
		return strings.TrimSpace(string(out)), "", nil
	}
	return parts[0], parts[1], nil
}
