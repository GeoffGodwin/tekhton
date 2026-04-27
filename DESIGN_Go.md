# Tekhton — Go Migration Design Document

> **Status: Design.** Begins at M139 after V3 wraps at M138. Numbering of the
> initiative (V4-rewrite, V5-rewrite, …) is itself a deferred decision — see
> Decision Register §6.

## Vision

Tekhton becomes a single static Go binary, distributed `clone + run`, with
no required runtime on the user's machine. The bash supervisor that has
served Tekhton through 138 milestones is wedged out subsystem by subsystem
in a Ship of Theseus migration: each wedge ships, self-hosts, and proves
itself before the next one starts. Bash and Go coexist throughout,
communicating across a versioned JSON-over-stdio seam that mirrors the
existing `tools/repo_map.py` boundary the codebase has already lived with.

The end state is the same Tekhton, with the same prompts, pipeline order,
agent role files, milestone DAG, and Watchtower dashboard. What changes
is underneath: typed errors instead of `CATEGORY|SUBCATEGORY|TRANSIENT|
MESSAGE` cuts, one `context.Context` cancellation tree instead of a
hand-wired SIGTERM cascade across subshells, real structs instead of 60+
globals named `_RWR_*` and `_ORCH_*`, `fsnotify` instead of `find -newer`
polling. The 218-file `lib/` directory and the 300-line ceiling that
produced it both go away — the ceiling was a bash readability tax, not a
design value.

**Why Go.** Process supervision. Tekhton's spine fans out long-running
subprocesses, fans cancellation back in on SIGINT, escalates to SIGKILL
on activity timeout, and reaps WSL-side `claude.exe` orphans the bash
process group can't see. Go's `context.Context` plus `os/exec` plus
goroutines map cleanly onto this shape; the supervisor's bash code is 90%
the shape Go would write naturally and 10% workarounds for primitives
bash doesn't have. Cross-compilation to a single static binary across
five OS/arch targets from one host is the second factor; the standard
library and tooling are the third.

**Why TS/Bun was the runner-up.** Bun ships single-binary, has excellent
JSON ergonomics, and would have been a natural fit for the prompt engine
and dashboard work. The tiebreaker was supervisor discipline:
TypeScript's cancellation story (AbortController + AbortSignal + third-
party libraries) is younger and less uniform than `context.Context`, and
the bash code being replaced is 60% process supervisor by line count.
Future readers: do not reopen this. The tiebreaker is the supervisor, not
general language fitness; re-litigation must show that the supervisor
part has gotten cheaper, not that some other part has.

**Why Ship of Theseus.** Tekhton self-hosts. A parallel rewrite breaks
self-hosting at every commit until it catches up; a wedge migration
breaks it never. M139+ cannot afford to lose self-hosting.

---

## Architecture Target

Tekhton becomes a **single static binary** (`tekhton`) cross-compiled from one
host. End-state distribution is `clone the repo, run the binary` — no bash, no
Python required for the core pipeline. Cobra owns the CLI surface
(`tekhton run`, `tekhton plan`, `tekhton diagnose`, …) replacing the giant
flag block in `tekhton.sh:1000`. The 218 `lib/*.sh` files collapse into a
small set of Go packages; the 22 `stages/*.sh` files become a `stages` package
with one file per stage rather than per shell-line-budget split.

The migration does **not** rewrite Tekhton from scratch. Bash continues to
supervise the pipeline while subsystems are wedged out into Go and called as
child processes from the bash supervisor. The cross-language seam mirrors the
existing `tools/repo_map.py` and `tools/tui.py` boundaries: JSON over
stdin/stdout for one-shot calls, JSON-status-file polling for long-running
sidecars. No new IPC mechanism, no shared library, no FFI.

Self-hosting is the load-bearing invariant. Tekhton must build Tekhton at
every commit during the migration. A wedge that breaks self-hosting is rolled
back; bash and Go coexist until each wedge is proven.

### Package Layout

```
cmd/tekhton/                # main entry point (Cobra root + subcommand wiring)
internal/causal/            # causal event log (M139-M141)
internal/state/             # pipeline state, resume parsing  (M142-M144)
internal/supervisor/        # agent invocation, monitoring, retry (M145-M150)
internal/orchestrate/       # outer --complete loop, recovery routing
internal/stages/            # one file per stage (intake, coder, review, …)
internal/prompt/            # template engine ({{VAR}} + {{IF:}})
internal/config/            # config + defaults + clamps
internal/manifest/          # milestone DAG + sliding window
internal/indexer/           # repo_map.py / Serena bridge
internal/dashboard/         # watchtower JSON emitters
internal/tui/               # TUI status emitter (Python sidecar stays)
internal/causalq/           # causal-log query layer (was lib/causality_query.sh)
internal/proto/             # versioned JSON contracts (see below)
pkg/api/                    # versioned, exported types for external consumers
testdata/                   # fixtures (replaces tests/fixtures/)
tools/                      # Python tools — unchanged, called as subprocesses
```

`internal/` packages are unimportable from outside the module, which forces
the public surface (`pkg/api/`) to be deliberate rather than emergent. There
is no `lib/` equivalent — Go has packages, not "extracted helpers." The
300-line file ceiling does not carry over: it was a bash readability tax
(no module system, all functions in one namespace), not a design value.

### Single Binary, Subcommand Surface

One binary, multiple subcommands. Multi-binary was considered (`tekhton`,
`tekhton-bridge`, `tekhton-indexer`) and rejected: distribution complexity
multiplies, and no current subsystem warrants its own release cycle. When a
subsystem genuinely needs independent deployment (e.g., a long-running
Watchtower server in V5), promote it then.

The flag soup at `tekhton.sh:14-55` becomes Cobra subcommands. Long-tail
options (`--rescan --full`, `--rollback --check`) become subcommand flags
under their parent (`tekhton rescan --full`). `--start-at coder` becomes
`tekhton run --start-at coder`. The `--init`, `--plan`, `--metrics`,
`--diagnose`, `--health`, `--progress`, `--migrate`, `--draft-milestones`,
`--setup-indexer`, `--rollback`, `--status`, and `--report` flags each become
sibling subcommands.

### JSON Protocol Versioning

Every cross-language seam carries an explicit envelope:

```json
{"proto":"tekhton.causal.v1","run_id":"...","payload":{...}}
```

The `proto` string is `<domain>.<channel>.v<N>`. Producers stamp it;
consumers reject anything they don't recognize. Version bumps are additive
within a major (new optional fields) and breaking across majors. An
acceptance test in `internal/proto/` round-trips every contract through Go,
asserts that bash callers parse it with `jq -e`, and asserts that the
Python sidecars (TUI, indexer) parse it without modification. Skew is a
specific failure mode (Risk §7); the version field exists so it surfaces
loudly instead of silently corrupting data.

The contracts to version on day one: `causal.event.v1` (one line of
`CAUSAL_LOG.jsonl`), `state.snapshot.v1` (replaces the heredoc-based
`PIPELINE_STATE_FILE`), `tui.status.v1` (the snapshot the Python sidecar
polls), `agent.request.v1` / `agent.response.v1` (supervisor → agent runner
contract once Phase 2 lands).

### Signal & Cancellation Discipline

The bash supervisor today fans out kills via a hand-rolled trap chain:
`agent_monitor.sh:65-75` registers `_run_agent_abort`, which kills
`_TEKHTON_AGENT_PID`, escalates to SIGKILL after a sleep, and finally
calls `_kill_agent_windows` to reap WSL `claude.exe` processes the bash
process group can't see. The FIFO-reader subshell can't reach the trap, so
it kills directly (line 174). This is the structural reason the migration
chose Go: every long-lived operation in Go takes a `context.Context`, and
cancelling the root context on SIGINT propagates down through every
spawned goroutine and `exec.CommandContext`-managed subprocess. The
SIGKILL escalation, the cross-subshell signalling, and the WSL reap dance
all reduce to one cancellation, with `os/exec` handling the process tree.

Windows/WSL remains a special case (Risk §6). Go's `os/exec` doesn't
automatically kill the entire process tree on Windows; the supervisor
package keeps a Windows-specific reaper that walks the job-object tree.
But the rest of the supervisor is platform-clean.

### Config Loading

`pipeline.conf` today is sourced as bash, which means defaults live in
`config_defaults.sh` and validation lives in `config.sh`. The Go port keeps
the file format for compatibility but parses it as `KEY=VALUE` lines, no
shell evaluation. Defaults move to a struct with field tags:

```go
type Config struct {
    CoderMaxTurns       int    `key:"CODER_MAX_TURNS"  default:"100"  clamp:"1,500"`
    CausalLogMaxEvents  int    `key:"CAUSAL_LOG_MAX_EVENTS" default:"2000" clamp:"100,100000"`
    // ...
}
```

Validation, clamping, and the 137+ keys come from one place. `tekhton config
explain` prints the resolved value, source (default/conf/env), and clamp for
every key — replacing the ad-hoc `:= "default"` scattered across the lib.

### Error Taxonomy

`lib/errors.sh` produces `CATEGORY|SUBCATEGORY|TRANSIENT|MESSAGE` records
that the supervisor splits with `cut -d'|' -f1`. The Go port keeps the
taxonomy but expresses it as typed errors:

```go
type AgentError struct{ Category, Subcategory string; Transient bool; Wrapped error }
var ErrUpstreamRateLimit = &AgentError{Category: "UPSTREAM", Subcategory: "api_rate_limit", Transient: true}
```

Callers use `errors.Is(err, ErrUpstreamRateLimit)` and `errors.As` to unwrap
contextual data. Transient retry, quota pause, and recovery routing
dispatch on type rather than parsing string fields. The string form remains
on the wire (causal events, state file) for human diagnosis; the typed form
is internal.

### Test Strategy

Tests live next to the code (`internal/causal/log_test.go`). The bash test
suite (`tests/`) runs unchanged against unported subsystems and is retired
file-by-file as wedges land. Go tests use the standard `testing` package,
table-driven where it fits, with `testdata/` for golden files. Integration
tests that exercise the full pipeline run as `go test ./internal/e2e/...`
and spawn a real `claude` CLI against a mock prompt where possible.
Coverage targets `≥80%` per package; the bash suite never reached this and
the migration is the cheapest moment to set the bar.

Crucially, the same self-hosting test that ran V3 milestone 138 must run
M139 — Tekhton building Tekhton from a clean checkout, with the Go binary
in the supervisor role for whatever subsystem is currently wedged out.

---

## Per-Subsystem Porting Notes

### Causal Log (`lib/causality.sh` → `internal/causal/`)

**Bash shape.** Append-only JSONL writer. Per-stage monotonic counter
(`m130-causal-context-aware-recovery-routing.md` flow depends on it).
Eviction on cap. Hand-rolled `_json_escape`.

**Hacks bash imposed.** File-based per-stage counters in
`${_CAUSAL_SEQ_DIR}/${stage}` because `eid=$(emit_event ...)` runs in a
subshell and any in-memory counter would be lost. The same trick stores
`_LAST_EVENT_ID` and `_CAUSAL_EVENT_COUNT` in files. A 27-line JSON
escape function exists because bash has no JSON library. Cap enforcement
shells out to `wc -l` and `tail -n +N`.

**Go shape.** A `*Log` value owns the writer, an `atomic.Int64` per stage,
and a buffered channel that serializes appends from any goroutine.
`encoding/json` handles escaping. Eviction is an in-place rewrite under a
mutex, fired when `events > cap`. The query layer (`causality_query.sh`)
becomes `internal/causalq` and reads the same JSONL — query and emission
are independent so external tools can read the file too.

**Decisions deferred.** On-disk format (Decision §2).

### Pipeline State (`lib/state.sh` → `internal/state/`)

**Bash shape.** A 178-line file that writes a markdown-with-headings file
via heredoc and parses it back with `awk` regexes
(`orchestrate.sh:99-101`). One section per resumable field.

**Hacks bash imposed.** Heredocs interpret quotes weirdly, so the writer
strips quotes from `resume_task` (line 39-42). Tmpfile + `mv -f` for
atomicity. WSL/NTFS redirection quirks force a specific dance (line 57).
Resume reads use `awk '/^## Exit Reason/{getline; print; exit}'` — fragile
to header drift, single-line-only, no nesting.

**Go shape.** State is a struct serialized to JSON
(`state.snapshot.v1`). `os.Rename` provides POSIX atomicity. Resume is
`json.Unmarshal`. Adding a field is a struct-tag change; the awk parser
problem disappears. The human-readable markdown becomes a separate
`tekhton status` rendering of the JSON.

**Decisions deferred.** Legacy markdown reader retention window — yes,
briefly, with a deprecation warning.

### Agent Monitor (`lib/agent_monitor.sh` → `internal/supervisor/`)

This is the hardest wedge. The 301-line bash file implements a process
supervisor that bash was never designed to be.

**Bash shape.** Spawn `claude` with stdout to a FIFO, stderr to a tee, in
a background subshell. A foreground subshell reads the FIFO line-by-line
with `read -t $interval`, parses each JSON line with inline `python3 -c`,
detects API errors via case-statement on string patterns, maintains a
50-line ring buffer, and on activity-timeout fires `find -newer` against
the project tree to decide whether the agent is silently working or hung.
Cross-subshell state moves through files in `$_session_dir`.

**Hacks bash imposed.** FIFO + background-subshell + foreground-reader
because bash has no async/select. `python3 -c` for JSON. Ring buffer
dumped to a file at exit because subshell locals can't propagate. `find
-newer` polling as a productivity heuristic. Two parallel code paths,
one with mkfifo and a fallback without, for systems lacking FIFOs.
SIGTERM cascade with a 2-second sleep before SIGKILL.
`_kill_agent_windows` reaping WSL `claude.exe` orphans via `taskkill.exe`
because the bash process group doesn't extend across the WSL/Windows
boundary.

**Go shape.** `exec.CommandContext` with a `context.Context` whose
cancellation is bound to SIGINT. `cmd.StdoutPipe()` returns a real
`io.Reader`; a goroutine reads with `bufio.Scanner` and decodes each line
with `json.Decoder`. An activity timer is a `time.AfterFunc` reset on
every line; firing it cancels the context, which terminates the
subprocess via `os/exec`'s normal path. The ring buffer is a slice owned
by one goroutine. A separate goroutine watches the project tree via
`fsnotify` rather than `find -newer` polling. Windows process-group
reaping is a 30-line `_windows.go` file using `JobObjects`.

The "API error in stream" detection becomes a method on the JSON decoder
goroutine that pattern-matches typed events into the error taxonomy
above. The `python3 -c` JSON parses are replaced.

**Decisions deferred.** `fsnotify` vs `find -newer` polling. Default: ship
polling first, add `fsnotify` when polling cost shows up in profiling.

### Retry Envelope (`lib/agent_retry.sh` → `internal/supervisor/retry.go`)

**Bash shape.** `_run_with_retry` wraps `_invoke_and_monitor` in a
hand-coded exponential-backoff loop, with subcategory-specific minimum
delays (api_rate_limit ≥ 60s, oom ≥ 15s with backoff floor).

**Hacks bash imposed.** Result globals (`_RWR_EXIT`, `_RWR_TURNS`,
`_RWR_WAS_ACTIVITY_TIMEOUT`) because functions can't return structs.
Nameref args (`_spinner_pid_var`) so the pause/resume bracket can mutate
caller locals around `enter_quota_pause`. Exponential backoff computed
with a `while` loop because bash lacks `**`.

**Go shape.** A `RetryPolicy` struct, a `Retry(ctx, fn)` helper that
returns `(Response, error)`. The pause/resume bracket becomes a context
augmented with a quota-aware `Sleep` that the supervisor honors. The
spinner is a separate concern owned by the TUI layer, not the retry
loop — the nameref passing goes away.

### Orchestration Loop (`lib/orchestrate.sh`)

**Bash shape.** 271-line outer loop with safety bounds (wall-clock,
attempt count, agent call cap), recovery routing, and progress
detection. State is held in 14 `_ORCH_*` globals.

**Hacks bash imposed.** Globals because bash has no struct returns. State
restored from the resume file via `awk` (line 99-101). Outcome dispatch
via numeric return codes (`10=exit success, 11=exit failure, 0=re-loop`)
because bash can't return enums.

**Go shape.** `Orchestrator` struct holds the state. The loop returns
`(result Verdict, err error)` from a switch on typed outcomes. Safety
bounds become `context.WithDeadline` and counter checks. Progress
detection (`_check_progress`) becomes a method that compares git diff
hashes — same logic, real types.

**Wedge timing.** Phase 3 candidate, depending on the post-Phase-2
re-evaluation (see Phase Plan).

### Stages (`stages/*.sh`)

22 files, ~1100 lines for `coder.sh` alone. Each is a function the
supervisor calls; they share globals heavily and write artifact files
(`CODER_SUMMARY.md`, `REVIEWER_REPORT.md`, …) for the next stage.

**Hacks bash imposed.** Globals as the inter-stage protocol. Sourced
helper splits (`coder_buildfix.sh`, `coder_buildfix_helpers.sh`,
`coder_prerun.sh`) driven by the 300-line ceiling, not by domain
boundaries.

**Go shape.** A `Stage` interface (`Run(ctx, *PipelineState) error`) and
one file per stage. The 1100-line `coder.sh` becomes one `coder.go` with
a clear function-decomposition rather than file-decomposition. Inter-stage
artifacts stay on disk (the agents read and write them) but are typed
when they cross Go boundaries.

**Wedge timing.** Phase 4. Coder is the largest and most-touched stage;
review/security/tester are smaller and ride along.

### Prompt Engine (`lib/prompts.sh`)

`{{VAR}}` substitution and `{{IF:VAR}}…{{ENDIF:VAR}}` conditionals against
40+ template variables. A non-negotiable rule (CLAUDE.md §6) forbids
swapping the format. The Go port preserves the template syntax verbatim
and produces byte-for-byte identical output for the same inputs — this
is asserted by a golden-file test against every template in
`prompts/`.

**Decision deferred.** Whether the engine moves into the binary at
Phase 1 (because every stage uses it) or stays in bash until Phase 4
(when stages move). Recommended default: move to Go in Phase 1 as a
pure library exposed via `tekhton render-prompt --template … --vars …`
so bash callers continue to work and Go callers skip the subprocess
hop. See Decision §3.

### Config Loader (`lib/config.sh`, `lib/config_defaults.sh`)

`config_defaults.sh` is the data-only file exempt from the 300-line
ceiling. The Go port uses struct tags (above) and validates at load.
`pipeline.conf` parsing is line-based; the legacy `source` semantics
(arbitrary bash in conf files) is dropped — anyone using bash
expressions in `pipeline.conf` is unsupported and gets a clear error.

### Dashboard Emitters, TUI Sidecar, Milestone DAG, Indexer/MCP Glue

Dashboard emitters write JSON for the Watchtower static site — pure data
transforms, straightforward port, Phase 4. The TUI sidecar (`tools/tui.py`)
stays exactly as-is; the bash status-writer side becomes Go in Phase 4
and the contract is `tui.status.v1`. The milestone DAG and sliding window
are pure data manipulation, clean port, Phase 3 candidate. The indexer
and MCP glue (`lib/indexer.sh`, `lib/mcp.sh`) already shell out to Python;
the Go port keeps the same subprocess boundary, inheriting the existing
bash↔Python seam as bash↔Go↔Python without modification.

---

## Phase Plan

The phases are ordered by descending self-hosting risk: cheap wedges first,
then the load-bearing supervisor, then the bulk of the spine. After each
phase the binary distribution must work and the V3 self-test suite must
pass.

### Phase 0 — Foundation

**Scope.** Go module bootstrapped in the same repo (no separate fork). CI
matrix builds `linux/amd64`, `linux/arm64`, `darwin/amd64`,
`darwin/arm64`, `windows/amd64`. Cobra root command stub, `tekhton --version`
returns the existing VERSION file. JSON protocol package with v1
contracts written but not yet consumed. Self-hosting test harness: a
script that runs Tekhton-on-Tekhton with the Go binary present in the
toolchain (initially as a no-op).

**Exit criteria.** `make build` produces five binaries from one host. CI
passes. The Go binary is on `$PATH` during pipeline runs but no bash code
calls it yet.

### Phase 1 — Safe Leaf Wedges

**Scope.** Causal log and pipeline state. Both are pure data, both have
clear contracts, and both are read by lots of callers but written by few.
Wedge order: causal first (read-mostly), state second (resume-critical so
land it after we trust the pattern).

**Exit criteria.** `lib/causality.sh` is a 5-line shim that calls
`tekhton causal emit …`. Same for state. The bash callers don't know the
difference. `CAUSAL_LOG.jsonl` and `PIPELINE_STATE.json` are produced by
Go; bash callers read them with `jq`. Self-hosting passes; the V3 test
suite passes.

### Phase 2 — Agent Supervisor

**Scope.** `agent_monitor.sh`, `agent_retry.sh`, `agent_monitor_helpers.sh`,
`agent_monitor_platform.sh`, `agent_retry_pause.sh`. The whole supervisor
spine moves at once because the FIFO-monitor / retry / quota-pause / spinner
interactions are too entangled to wedge piecewise. `lib/agent.sh` becomes
a thin shim that launches `tekhton supervise --label coder --model ...`
and parses the resulting `agent.response.v1`.

**Exit criteria.** All `run_agent` call sites in stages still work. SIGINT
cancels cleanly across WSL. Quota pause / resume works. Activity timeout
fires correctly with file-change override. The Windows reaper handles the
known orphan cases. The V3 self-test suite passes; the M126-M138 resilience
arc tests pass.

### Phase 3 — Re-evaluation Point

After Phase 2, the supervisor is in Go, the spine isn't. At this point
two paths are roughly equivalent: (a) continue wedging
`orchestrate.sh` → manifest → milestones → diagnose, with bash as the
shrinking outer shell, or (b) start a parallel `tekhton run` Go entry
point that calls into the now-Go supervisor and re-implements the
orchestration loop natively, while bash continues to work for unported
features.

The recommended default at this point is (a) — finish the Ship of Theseus.
Path (b) buys speed at the cost of a second code path; the user named this
explicitly as the decision to make at this milestone. The trigger to flip
is concrete: if Phase 2 shipped late, scope-crept, or showed seam friction
in three or more places, re-evaluate.

### Phase 4 — Spine & Stages

**Scope.** Orchestration loop, milestone DAG and sliding window, prompt
engine (if not already moved), config loader, error taxonomy, dashboard
emitters, TUI status writer. Stages port last because they're the largest
surface and the most domain-specific code. Within stages, the order is
intake → security → review → tester → coder, because coder is where the
behavior risk concentrates and we land it after the smaller stages have
shaken out the stage-interface design.

**Exit criteria.** `tekhton run` is fully Go; the bash entry point becomes
a one-line wrapper that exec's the binary. The 218 lib files are gone or
shimmed.

### Phase 5 — Bash Deprecation

**Scope.** Diagnose, health, init, plan, draft-milestones, migrate,
notes-cli, rescan, rollback, draft, status, report, metrics. Mostly UI
and CLI wrappers — fast port. The bash test suite retires file-by-file
as Go tests replace it.

**Exit criteria.** Repository contains no `.sh` files in `lib/` or
`stages/`. `tools/` Python files remain unchanged. The 925-file source
count drops by ~75%.

---

## Phase 1 Detail

### M139 — Go Module Foundation

**Acceptance criteria.**
- `go.mod` at repo root, module `github.com/geoffgodwin/tekhton`.
- `cmd/tekhton/main.go` with Cobra root, `--version` reads VERSION.
- CI matrix builds five OS/arch pairs from `ubuntu-latest`. Artifacts
  uploaded.
- `make build` produces the binary. `make test` runs `go test ./...`.
- A `scripts/self-host-check.sh` runs Tekhton against itself with the Go
  binary available, asserting parity with V3.66 self-host run.
- Documentation in this file plus a one-page `docs/go-build.md`.

**Dependencies.** None (greenfield).

**Turn budget.** ~80 turns. Most of the work is CI/build wiring rather
than code.

**Definition of done.** The Go binary exists, builds, ships in CI
artifacts, and is invoked by no production code path. Self-hosting
unchanged.

### M140 — Causal Log Wedge

**Acceptance criteria.**
- `internal/causal` package: `Log`, `Emit(event)`, `Evict()`, `Archive()`.
  Per-stage atomic counter, JSONL append, cap enforcement, archive
  rotation matching `CAUSAL_LOG_RETENTION_RUNS`.
- `tekhton causal emit --stage … --type … --detail … --caused-by …`
  subcommand accepts the same arguments `emit_event` does and prints the
  assigned event ID on stdout.
- `tekhton causal init` replaces `init_causal_log`.
- `lib/causality.sh` is a 5-line shim per function that calls the Go
  binary.
- `causal.event.v1` proto is published in `internal/proto/`.
- `_json_escape` in bash deleted.
- Causality query layer (`causality_query.sh`) reads the same JSONL —
  no changes required.
- All existing `emit_event` call sites work without modification.

**Dependencies.** M139.

**Turn budget.** ~120 turns. The data structures are simple but every
call site must still work.

**Definition of done.** A run produces a `CAUSAL_LOG.jsonl` written
exclusively by the Go binary. The diff against a V3.66 run shows only
formatting differences, no semantic ones. The per-stage counter is
correct in the presence of concurrent stages.

### M141 — Pipeline State Wedge

**Acceptance criteria.**
- `internal/state` package: `Snapshot` struct, `Write(path)`, `Read(path)`,
  `Clear(path)`. `state.snapshot.v1` proto.
- `tekhton state write` and `tekhton state read` subcommands.
- `lib/state.sh` shimmed.
- Resume-from-V3-markdown: when a legacy `PIPELINE_STATE` file is
  encountered (no `proto` field), parse it with the existing awk-style
  rules, log a deprecation warning, and write JSON on next save. After
  one milestone the legacy reader is removed.
- `clear_pipeline_state` and `load_intake_tweaked_task` ported.
- Resume tests cover: human mode, milestone mode, error-classification
  preservation, missing-files cases, WSL/NTFS path quirks.

**Dependencies.** M140.

**Turn budget.** ~100 turns. State is small but every resume path must
work.

**Definition of done.** A pipeline interrupted with SIGINT in any stage
resumes cleanly with the Go writer. Heredoc + awk parser is deleted.

### M142 — Phase 1 Hardening

**Acceptance criteria.**
- 80% line coverage in `internal/causal` and `internal/state`.
- Fuzz test on `state.snapshot.v1` parser (resilient to corrupt files).
- Cross-platform CI matrix passing on all five targets.
- A "wedge audit" script that lists every bash call site for
  `emit_event` / `write_pipeline_state` and confirms it goes through
  the shim. Run in CI.
- `docs/go-migration.md` records what changed in Phase 1, what's left,
  and what early lessons rolled into the Phase 2 plan.

**Dependencies.** M140, M141.

**Turn budget.** ~60 turns.

**Definition of done.** Phase 1 is closed; Phase 2 entry criteria checked
off (supervisor design doc finalized, no open Phase 1 bugs).

---

## Phases 2+ Milestone Outline

**Phase 2 — Agent Supervisor (M143–M148).** M143 supervisor scaffold and
JSON contract. M144 `exec.CommandContext` core, line-by-line stdout
decoder, basic activity-timer. M145 retry envelope with typed errors,
exponential backoff, subcategory-aware floors. M146 quota pause/resume
bracket plus Retry-After header parsing. M147 Windows/WSL reaper,
fsnotify-based change detection. M148 supervisor parity test suite +
removal of `python3 -c` JSON parsing from bash.

**Phase 3 — Re-evaluation Decision (M149).** Single-milestone retro and
formal go/no-go on Ship of Theseus vs parallel-spine. Outcome amends the
remaining phase plan.

**Phase 4 — Spine & Stages (M150–M165, indicative).** Orchestration loop,
milestone DAG, sliding window, prompt engine (if deferred), config loader,
error taxonomy unified, dashboard emitters, TUI status writer, intake
stage, security stage, review stage, tester stage, build-fix loop, coder
stage, post-success cleanup, finalize hooks.

**Phase 5 — Bash Deprecation (M166+).** Diagnose, health, init, plan
(interactive + browser + answers + generate), draft-milestones, migrate,
notes-cli, rescan, rollback, status, report, metrics. Each wraps existing
business logic; the work is mostly CLI plumbing.

The exact M-numbers in Phases 4–5 are placeholders. They will be drafted
after Phase 3's re-evaluation, per the user's instruction not to over-plan.

---

## Decision Register

Each open decision has a recommended default and a trigger that flips it.

**§1 — Single binary vs multi-binary.**
Default: **single binary**. Trigger to split: any subsystem needing its
own release cadence (likely a Watchtower server in V5) or exceeding
30MB. Sub-binaries would ship in the same archive.

**§2 — SQLite vs flat files for state.**
Default: **flat files (JSONL + JSON)** through the migration. Trigger to
flip: causal-log query latency exceeds 500ms in a typical run, or
multi-process write contention surfaces (parallel milestone execution
in V5 is the obvious driver). SQLite is a one-line driver change in Go
and a deliberate non-decision now.

**§3 — Where the prompt engine moves and when.**
Default: **Phase 1 as a pure library, exposed via `tekhton render-prompt`**
so bash callers continue to work and Go callers skip the subprocess hop.
Trigger to defer: if the golden-file parity test against the 30+ existing
templates surfaces edge cases in `{{IF:}}` semantics that we'd rather
explore once stages are also in Go. Defer cost is low; ship cost is also
low.

**§4 — Stages migrate piecewise or in bulk.**
Default: **piecewise, smallest first** (intake → security → review →
tester → coder). Trigger to flip to bulk: if the stage interface ends up
needing per-stage type parameters, indicating smaller stages can't
validate the design. Piecewise is the Ship of Theseus default.

**§5 — V4 or v3-continuation milestone numbering.**
Default: **decide at M139 start, not now**. Per CLAUDE.md, V4 resets
numbering. The user's note on this prompt explicitly leaves it undecided;
this design treats the work as numerically continuous (M139+) so that
later decisions about V4-rewrite vs V5-rewrite labelling don't collide
with already-shipped milestones. If the choice is to label this initiative
V4, then V4 milestones run M01–MNN; the existing V4 design doc would
become V5. If V3-continuation, M139+ stand. The trigger is "by the time
M141 starts, pick a label and update VERSION accordingly."

**§6 — Python `tools/` boundary: preserve, absorb, or replace.**
Default: **preserve indefinitely**. `tree-sitter` and `rich` (TUI) are
better in Python than they would be in Go, and both already sit behind a
stable subprocess boundary. Trigger to absorb: a Go tree-sitter binding
matures past its current rough edges (plausible by V5) AND the user
chooses to drop the tree-sitter Python venv setup step from
onboarding. Trigger to replace TUI: never; Bubbletea is a fine library
but `rich.live` is already shipping. The migration consciously does not
absorb Python; doing so is its own initiative.

---

## Risk Register

| # | Risk | P × I | Mitigation |
|---|------|-------|------------|
| 1 | **Seam multiplication.** Each wedge adds a bash↔Go boundary; transient mid-migration we have N seams instead of 1. | High × Med | Cap concurrent active wedges at 2. Land each seam as a versioned proto in `internal/proto/` so seams are auditable. |
| 2 | **Second-system effect.** "While we're rewriting, let's also redesign X." | High × High | Hard rule, restated in this doc and in every milestone: no feature redesign during the port. Behavior-equivalence tests gate every wedge. |
| 3 | **Cross-language debugging tax.** A failure now spans bash, Go, and Python; a single stack trace doesn't tell the whole story. | Med × Med | Causal log already cross-language-aware (proto v1 from M140); errors carry the originating language explicitly. `tekhton diagnose` learns to reconstruct cross-language traces. |
| 4 | **Self-hosting regression mid-wedge.** A wedge breaks Tekhton-on-Tekhton; M139+ work blocks. | Med × High | `scripts/self-host-check.sh` runs in CI on every PR. A wedge that breaks self-hosting is reverted, not patched-forward. |
| 5 | **Milestone drift during long phases.** Phase 2 takes longer than planned and the rest of V3 grows in the meantime. | High × Med | Phase 2 is sized at six milestones; if it crosses ten, the Phase 3 re-evaluation point fires early. The bash supervisor still works during drift — it's not a release blocker. |
| 6 | **Windows/WSL signal-handling differences.** `os/exec` doesn't kill the process tree on Windows; `claude.exe` orphans hide from the bash process group. | Med × Med | Phase 2 includes a Windows-specific reaper using `JobObjects`. CI runs `windows/amd64` integration tests against a mocked `claude` binary. |
| 7 | **JSON protocol version skew.** A user on an old bash shim hits a new Go binary or vice versa. | Med × Med | The `proto` envelope makes skew loud, not silent. Shims and binaries refuse unknown majors. Distribution is single-binary so users can't easily mix versions inside a project. |
| 8 | **Distribution / cross-compile glitches.** Single-binary promise breaks on a niche target (musl, alpine, NetBSD). | Low × Med | Ship glibc Linux, musl Linux, both macOS arches, and Windows amd64 explicitly. Other targets are best-effort and documented as such. CGO is off by default. |
| 9 | **Loss of "shellcheck clean" guarantee with no Go equivalent.** The `shellcheck` rule (CLAUDE.md §3) was a real quality gate; Go has `go vet` and `staticcheck` but the bar isn't equivalent. | Low × Med | Adopt `golangci-lint` with the "advanced" preset, gated in CI. Treat its output as the V3 shellcheck rule transposed. |
| 10 | **State file readability lost.** `PIPELINE_STATE` is currently a markdown file a human can read with `cat`; JSON is less friendly during incident response. | Low × Low | `tekhton status` renders the JSON as the same human-readable layout. The bytes change; the user experience doesn't. |

---

## Out of Scope

Multi-provider abstraction (V4's centerpiece) layers on top of the Go
supervisor that lands here, in a separate initiative. Parallel milestone
execution is V5+. Watchtower as a long-running WebSocket server is V5.
Absorbing the Python sidecar architecture (TUI, indexer) is explicitly a
non-goal; see Decision §6. No rewrite of agent role files, prompt
templates, milestone DAG schema, dashboard schema, or `pipeline.conf`
format. Tekhton continues to invoke `claude` as a subprocess; replacing
it with a direct API client is not part of this work.
