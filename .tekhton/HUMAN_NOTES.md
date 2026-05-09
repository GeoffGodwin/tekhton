# Human Notes
<!-- notes-format: v2 -->
<!-- IDs are auto-managed by Tekhton. Do not remove note: comments. -->

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.

Prefix each note with a priority tag so the pipeline can scope runs correctly:
- `[BUG]` — something is broken, needs fixing before new features
- `[FEAT]` — new mechanic or system, architectural work
- `[POLISH]` — visual/UX improvement, no logic changes

## Features

## Bugs

## Polish

- [x] [POLISH] **m01/m02 milestone-doc cleanup pass.** Four small doc nits surfaced during V4 Phase 1 implementation, recorded for a future cleanup pass so the docs match what was actually built: 1. `.claude/milestones-v3/v3-final/m01-go-module-foundation.md` contains a Go snippet `//go:embed ../../VERSION` that is not legal Go (path traversal not allowed in embed). The Architecture Change Proposal in CODER_SUMMARY resolved this with the ldflags approach (`-X main.version=$(cat VERSION)`); update the milestone doc to reflect ldflags so future readers don't waste time tracing the discrepancy. 2. `scripts/self-host-check.sh` — m01 AC required running `tekhton.sh --dry-run`, but `--dry-run` calls Claude CLI agents (intake + scout) which require auth that CI cannot satisfy. The script defaults to the lighter `tekhton.sh --version` (exercises the bash entry point with `bin/tekhton` on `$PATH`) and gates the full `--dry-run` behind `TEKHTON_SELF_HOST_DRY_RUN=1`. Update the m01 AC text to reflect this split (CI runs the safe subset; humans with auth run the full smoke). 3. m02 milestone — `init` semantics. The doc's AC #1 prescribes `tekhton causal init` truncates the log and writes an `init-1` event. The bash test suite (the parity gate at AC #7) requires the opposite: `init_causal_log` must NOT truncate (resume-friendly). The implementation honors the resume-friendly semantics; update the doc to match. 4. m02 AC #6 — `grep -r _json_escape lib/ stages/` cannot return empty without breaking ~20 lib callers. The intent ("delete the bash JSON-escape duplication that was tied to causality.sh") is satisfied by relocating the helper to `lib/common.sh`. Reword the AC to "no `_json_escape` definition in `lib/causality.sh` or `stages/`; sole definition lives in `lib/common.sh`."
