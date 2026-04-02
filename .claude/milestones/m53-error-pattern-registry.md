# Milestone 53: Error Pattern Registry & Build Gate Classification
<!-- milestone-meta
id: "53"
status: "pending"
-->

## Overview

Tekhton's build gate treats all failures identically: dump raw output into
BUILD_ERRORS.md and hand it to a build-fix agent. This works when the only
failures are code bugs, but real-world projects produce failures across six
distinct categories — environment setup, service dependencies, build toolchain,
resource constraints, test infrastructure, and actual code errors. Only the last
category should ever reach the build-fix agent.

This milestone introduces a declarative error pattern registry and a
classification engine that categorizes build/test output before any remediation
is attempted. The registry is a simple bash data structure — no new dependencies,
no jq, no Python.

Depends on Milestone 52. Seeds Milestones 54 (auto-remediation) and 55
(pre-flight).

## Scope

### 1. Error Pattern Registry (`lib/error_patterns.sh` — NEW)

A declarative registry mapping error output patterns to classifications.
Each entry is a line in a heredoc-based registry with pipe-delimited fields:

```
REGEX_PATTERN|CATEGORY|SAFETY|REMEDIATION_CMD|DIAGNOSIS
```

**Categories:**
- `env_setup` — Missing tool/binary installation (Playwright browsers, native deps)
- `service_dep` — Required service not running (database, cache, queue)
- `toolchain` — Build pipeline broken (stale deps, missing codegen, cache corruption)
- `resource` — Machine resource issue (port in use, OOM, disk full, permissions)
- `test_infra` — Test infrastructure issue (snapshot staleness, fixture missing, timeout)
- `code` — Actual code error (compilation, type, import, assertion failures)

**Safety ratings:**
- `safe` — Auto-remediation OK (e.g., `npm install`, `npx playwright install`)
- `prompt` — Needs user confirmation (e.g., `npm test -- -u` for snapshot updates)
- `manual` — Cannot auto-fix, human intervention required (e.g., database not running)
- `code` — Route to build-fix agent (actual code bugs)

**Functions:**
- `load_error_patterns()` — Parse the registry into arrays on first call (cached)
- `classify_build_error()` — Takes error output string, returns first matching
  classification as `CATEGORY|SAFETY|REMEDIATION_CMD|DIAGNOSIS`
- `classify_build_errors_all()` — Returns ALL matching patterns (error output
  may contain multiple distinct issues)
- `get_pattern_count()` — Returns number of loaded patterns (for testing)

**Initial pattern coverage (minimum 30 patterns):**

| Ecosystem | Patterns |
|-----------|----------|
| Node.js/npm | `Cannot find module`, `ENOENT.*node_modules`, `npx playwright install`, `npx cypress install`, `npm ERR! Missing`, `EADDRINUSE`, `heap out of memory`, `ERR_MODULE_NOT_FOUND` |
| Python | `ModuleNotFoundError`, `ImportError.*No module`, `pip install`, `No module named`, `venv.*not found` |
| Go | `missing go.sum entry`, `go mod download`, `cannot find package` |
| Rust | `could not compile`, `cargo build`, `unresolved import` |
| Java/Kotlin | `ClassNotFoundException`, `NoClassDefFoundError`, `BUILD FAILED` |
| Database | `ECONNREFUSED.*5432` (postgres), `ECONNREFUSED.*3306` (mysql), `ECONNREFUSED.*27017` (mongo), `ECONNREFUSED.*6379` (redis), `connection refused.*database` |
| Docker | `Cannot connect to the Docker daemon`, `docker.*not found` |
| E2E/Browser | `Executable doesn't exist.*chrome`, `browser.*not found`, `WebDriverError`, `PLAYWRIGHT_BROWSERS_PATH` |
| Generated code | `@prisma/client.*not.*generated`, `prisma generate`, `codegen`, `protoc.*not found` |
| Resource | `EADDRINUSE`, `ENOMEM`, `ENOSPC`, `Permission denied`, `EACCES` |
| Test infra | `Snapshot.*obsolete`, `snapshot.*mismatch`, `TIMEOUT`, `fixture.*not found` |
| Generic | `command not found`, `No such file or directory` (with context-dependent classification) |

### 2. Build Gate Classification Integration (`lib/gates.sh`)

After any phase failure, before writing BUILD_ERRORS.md, run the error output
through `classify_build_errors_all()`. Annotate BUILD_ERRORS.md with
classification headers:

```markdown
# Build Errors — 2026-04-02 16:03:15
## Stage
post-coder

## Error Classification
- **env_setup** (safe): Playwright browsers not installed
  → Auto-fix: `npx playwright install`
- **code** (code): TypeScript compilation error in src/auth.ts
  → Route to build-fix agent

## Classified as Environment/Setup (1 issue)
...raw output...

## Classified as Code Error (1 issue)
...raw output...
```

**Refactor**: Remove the hardcoded Playwright/Cypress detection added in the
prior hotfix (the patterns now live in the registry). The auto-remediation
logic itself moves to M54; this milestone only classifies.

### 3. Build-Fix Agent Error Routing (`stages/coder.sh`)

When invoking the build-fix agent, filter BUILD_ERRORS.md to include ONLY
`code`-category errors. Non-code errors get a summary header:

```
## Already Handled (not code errors)
- Environment: Playwright browsers installed automatically
- Service: PostgreSQL not running (flagged for human action)

## Code Errors to Fix
[only code-category errors here]
```

If ALL errors are non-code, skip the build-fix agent entirely and route to
either auto-remediation (M54) or HUMAN_ACTION_REQUIRED.md.

### 4. Error Taxonomy Extension (`lib/errors.sh`)

Extend the existing error taxonomy with new subcategories that map to the
pattern registry categories:

- `ENVIRONMENT/env_setup` — Tool/binary setup needed
- `ENVIRONMENT/service_dep` — Service not running
- `ENVIRONMENT/toolchain` — Build toolchain issue
- `ENVIRONMENT/resource` — Resource constraint
- `ENVIRONMENT/test_infra` — Test infrastructure issue

These integrate with the existing `classify_error()` and `suggest_recovery()`
functions so the orchestration recovery layer also benefits.

## Acceptance Criteria

- `load_error_patterns()` parses registry into arrays without errors
- `classify_build_error()` correctly classifies at least 30 distinct patterns
- `classify_build_errors_all()` returns multiple classifications from mixed output
- BUILD_ERRORS.md includes classification annotations after any gate failure
- Build-fix agent receives only code-category errors
- When all errors are non-code, build-fix agent is NOT invoked
- Hardcoded Playwright/Cypress patterns in gates.sh are replaced by registry lookup
- `errors.sh` taxonomy includes new subcategories
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n lib/error_patterns.sh` passes
- `shellcheck lib/error_patterns.sh` passes
- New test file `tests/test_error_patterns.sh` covers: pattern loading, each
  category classification, mixed-output classification, empty input handling,
  unknown error passthrough (defaults to `code` category)

Tests:
- Pattern count ≥ 30 after `load_error_patterns()`
- `classify_build_error "Cannot find module 'express'"` returns `toolchain|safe|npm install|...`
- `classify_build_error "ECONNREFUSED 127.0.0.1:5432"` returns `service_dep|manual||PostgreSQL not running`
- `classify_build_error "error TS2304: Cannot find name 'foo'"` returns `code|code||...`
- Mixed output with both service and code errors returns both classifications
- Unrecognized error text defaults to `code|code||Unclassified build error`

Watch For:
- Pattern order matters: more specific patterns must come before generic ones.
  `Cannot find module.*playwright` (env_setup) must match before `Cannot find module`
  (toolchain). Load patterns in specificity order.
- Regex must be compatible with bash `[[ "$text" =~ $pattern ]]` or `grep -E`.
  Avoid PCRE-only features. Test each pattern individually.
- The `code` fallback category is critical: any unrecognized error MUST default
  to `code` so the build-fix agent still gets a chance. Never silently drop errors.
- BUILD_ERRORS.md format change must not break the build-fix prompt template
  variable `{{BUILD_ERRORS_CONTENT}}` — the prompt still reads this file.
- Large error output (e.g., 500-line TypeScript error dump) should not cause
  `classify_build_errors_all()` to hang. Process line-by-line with early exit
  on first match per line, not full-text regex on the entire output.

Seeds Forward:
- Milestone 54 consumes the registry's REMEDIATION_CMD field for auto-fixes
- Milestone 55 reuses the pattern categories for pre-flight check prioritization
- The registry is extensible: projects can eventually define custom patterns in
  pipeline.conf or a `.claude/error_patterns.cfg` file (future milestone)
