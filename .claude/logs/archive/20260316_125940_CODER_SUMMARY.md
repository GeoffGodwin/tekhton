# Coder Summary — Milestone 0: Security Hardening

## Status
COMPLETE

## What Was Implemented

### Phase 1 — Config Injection Elimination (Critical)
- Replaced unsafe `source <(sed ...)` config loading in `lib/config.sh` with `_parse_config_file()` — a safe line-by-line key=value parser using `declare -gx` for assignment
- Parser rejects `$(` and backticks universally to prevent command substitution
- Parser rejects `;`, `|`, `&`, `>`, `<` in non-command keys while allowing them in `*_CMD`, `*_PATTERN`, and `*_CATEGORIES` keys that legitimately use shell metacharacters
- Handles bare values, double-quoted values, single-quoted values, values with `=` signs, values with spaces, and inline `#` comments
- Applied same safe parser pattern to `lib/plan.sh` planning config loader
- Replaced `eval` with `bash -c` in `lib/gates.sh` and `lib/hooks.sh`

### Phase 2 — Temp File Hardening (High)
- Added per-session temp directory via `mktemp -d` in `tekhton.sh` (`TEKHTON_SESSION_DIR`)
- Added EXIT trap cleanup for session directory
- Added PID-based lock file (`.claude/PIPELINE.lock`) with stale lock detection
- Moved all predictable temp paths in `lib/agent.sh` from `/tmp/tekhton_*` to session directory
- Moved FIFO path in `lib/agent.sh` to session directory
- Updated all 6 `mktemp` calls in `lib/drift.sh` to use session directory
- Updated review stage mktemp in `stages/review.sh` to use session directory
- Updated commit temp file in `tekhton.sh` to use session directory

### Phase 3 — Prompt Injection Mitigation (High)
- Added `_wrap_file_content()` helper in `lib/prompts.sh` for consistent content delimiter wrapping
- Added `_safe_read_file()` helper with cross-platform file size validation (1MB limit)
- Wrapped `{{TASK}}` substitution in `render_prompt()` with untrusted-input delimiters
- Wrapped all file-content injections in `stages/coder.sh`, `stages/review.sh`, `stages/tester.sh`, `stages/architect.sh` with content delimiters
- Added Security Directive anti-injection sections to all 5 agent prompt templates

### Phase 4 — Git Safety (High)
- Added `_check_gitignore_safety()` in `lib/hooks.sh` — warns if `.gitignore` missing or lacks sensitive patterns
- Added `_sanitize_for_commit()` in `lib/hooks.sh` — strips control characters and newlines
- Applied task sanitization in `generate_commit_message()`
- Called `_check_gitignore_safety` before `git add -A` in `tekhton.sh`

### Phase 5 — Defense-in-Depth (Medium)
- Added `_clamp_config_value()` in `lib/config.sh` with hard upper bounds (MAX_REVIEW_CYCLES ≤ 20, *_MAX_TURNS ≤ 500)
- Added file size validation via `_safe_read_file()` before reading artifacts into shell variables (rejects files > 1MB)
- Added PID-based `taskkill` before image-name kill fallback in `_kill_agent_windows()`
- Expanded `AGENT_DISALLOWED_TOOLS` with `ssh`, `scp`, `nc`, `ncat`
- Added documentation comments about `--disallowedTools` best-effort nature and scout `Write` scope limitation

## Root Cause (bugs only)
N/A — security hardening initiative, not a bug fix

## Files Created or Modified
- `lib/config.sh` — safe config parser, hard upper bounds
- `lib/plan.sh` — safe planning config loader
- `lib/gates.sh` — eval → bash -c replacements
- `lib/hooks.sh` — bash -c, gitignore safety, commit sanitization
- `lib/prompts.sh` — content wrapping helpers, file size validation, TASK delimiters
- `lib/agent.sh` — session temp dir paths, Windows kill, disallowed tools, documentation
- `lib/drift.sh` — session temp dir for all mktemp calls
- `tekhton.sh` — session dir, lock file, cleanup trap, gitignore check
- `stages/coder.sh` — content wrapping and size validation
- `stages/review.sh` — content wrapping, session temp dir
- `stages/tester.sh` — content wrapping
- `stages/architect.sh` — content wrapping and size validation
- `prompts/coder.prompt.md` — security directive
- `prompts/reviewer.prompt.md` — security directive
- `prompts/tester.prompt.md` — security directive
- `prompts/scout.prompt.md` — security directive
- `prompts/architect.prompt.md` — security directive

## Architecture Decisions
- **`declare -gx` for config assignment**: Combines global scope and export in one command, avoiding SC2163 shellcheck warnings
- **Metacharacter allowlisting for command keys**: Keys matching `*_CMD`, `*_PATTERN`, `*_CATEGORIES` allow `;|&><` since values like `ANALYZE_CMD="eslint --format=json"` legitimately use these characters
- **Cross-platform file size check**: `_safe_read_file()` tries `stat -c%s` (Linux), falls back to `stat -f%z` (macOS), then `wc -c`
- **Content delimiters as defense layer**: Combined with anti-injection directives in system prompts for defense-in-depth

## Test Results
- All 38 existing tests pass (0 failures)
- All modified .sh files pass `bash -n` syntax checking
- shellcheck passes on all modified files
