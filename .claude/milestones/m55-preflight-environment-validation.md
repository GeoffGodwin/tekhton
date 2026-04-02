# Milestone 55: Pre-flight Environment Validation
<!-- milestone-meta
id: "55"
status: "pending"
-->

## Overview

Build gate failures are expensive: the coder has already spent 20-70 turns
before the gate discovers that Playwright browsers aren't installed or
`node_modules` is stale. Pre-flight validation catches these issues BEFORE
any agent invocation, saving time and API cost.

This milestone adds a lightweight, shell-only pre-flight check that runs after
config loading but before the first pipeline stage. It uses existing detection
engine output (languages, frameworks, test frameworks, services) to know what
to check, then validates environment readiness. Safe issues are auto-remediated
via the M54 engine. Blocking issues halt the pipeline with actionable diagnosis.

Depends on Milestone 53 (error pattern registry for classification). Can run
in parallel with Milestone 54 (auto-remediation — though pre-flight auto-fixes
use the same `attempt_remediation()` function, so M54 must be complete or
the pre-flight only reports without fixing).

## Scope

### 1. Pre-flight Orchestration (`lib/preflight.sh` — NEW)

**Main function:** `run_preflight_checks()`

Called from `tekhton.sh` after config loading and detection, before stage
dispatch. Runs a series of fast, deterministic checks and produces a
PREFLIGHT_REPORT.md with pass/warn/fail per check.

```bash
run_preflight_checks() {
    # Skip if disabled
    [[ "${PREFLIGHT_ENABLED:-true}" == "true" ]] || return 0

    local _pass=0 _warn=0 _fail=0 _remediated=0

    # Run checks based on detected stack
    _preflight_check_dependencies    # node_modules, venv, vendor, go mod
    _preflight_check_tools           # playwright, cypress, build tools
    _preflight_check_generated_code  # prisma, codegen, protobuf
    _preflight_check_env_vars        # .env vs .env.example
    _preflight_check_runtime_version # .node-version, .python-version
    _preflight_check_ports           # ports needed by UI_TEST_CMD, dev server
    _preflight_check_lock_freshness  # lock file vs manifest mtime

    # Emit report
    _emit_preflight_report

    # Fail pipeline if blocking issues remain after remediation
    if [[ "$_fail" -gt 0 ]]; then
        error "Pre-flight failed: $_fail blocking issue(s). See PREFLIGHT_REPORT.md."
        return 1
    fi
    return 0
}
```

**Performance target:** All checks complete in under 5 seconds. No network
calls, no agent invocations, no test execution. Pure filesystem/process checks.

### 2. Dependency Freshness Check

**Function:** `_preflight_check_dependencies()`

Detects when package manager dependencies are stale or missing:

| Ecosystem | Lock File | Install Dir | Staleness Signal |
|-----------|-----------|-------------|-----------------|
| Node.js | `package-lock.json` / `yarn.lock` / `pnpm-lock.yaml` | `node_modules/` | Lock file newer than `node_modules/.package-lock.json` mtime, OR `node_modules/` missing |
| Python | `requirements.txt` / `poetry.lock` / `Pipfile.lock` | `.venv/` / `venv/` | Lock file newer than venv `site-packages/` mtime, OR venv missing |
| Go | `go.sum` | `$GOPATH/pkg/mod/` | `go.sum` newer than mod cache, OR missing entries |
| Ruby | `Gemfile.lock` | `vendor/bundle/` | Gemfile.lock newer than vendor mtime |
| Rust | `Cargo.lock` | `target/` | Cargo.lock newer than target mtime |
| PHP | `composer.lock` | `vendor/` | composer.lock newer than vendor/autoload.php mtime |

**Remediation:** `safe` — runs the appropriate install command (`npm install`,
`pip install -r requirements.txt`, `go mod download`, etc.)

Detection is conditional: only check ecosystems that `detect_languages()` found.
If no lock file exists, skip (don't create one — that's the coder's job).

### 3. Tool Availability Check

**Function:** `_preflight_check_tools()`

Cross-references detected test frameworks with required tool installations:

| Framework | Check | Remediation |
|-----------|-------|-------------|
| Playwright | Browser binaries exist in cache dir | `safe`: `npx playwright install` |
| Cypress | Cypress binary exists | `safe`: `npx cypress install` |
| Puppeteer | Chrome/Chromium binary reachable | `warn` only (varies by platform) |
| Android (Flutter/RN) | `ANDROID_HOME` set, platform-tools exist | `manual`: instructions only |
| iOS (Flutter/Swift) | `xcodebuild` available, simulator exists | `manual`: instructions only |

Also checks that commands referenced in pipeline.conf are available:
- `ANALYZE_CMD` first token is executable
- `BUILD_CHECK_CMD` first token is executable
- `TEST_CMD` first token is executable
- `UI_TEST_CMD` first token is executable

### 4. Generated Code Freshness Check

**Function:** `_preflight_check_generated_code()`

Detects when schema/definition files are newer than their generated output:

| Tool | Schema File | Generated Output | Remediation |
|------|-------------|-----------------|-------------|
| Prisma | `prisma/schema.prisma` | `node_modules/.prisma/client/` | `safe`: `npx prisma generate` |
| GraphQL Codegen | `codegen.yml` / `codegen.ts` | Check for `generated/` or configured output | `safe`: `npm run codegen` (if script exists) |
| Protobuf | `*.proto` files | Corresponding `*_pb.js` / `*_pb2.py` | `warn`: varies by setup |
| OpenAPI | `openapi.yaml` / `swagger.json` | Configured output dir | `warn`: varies by setup |

Only checks when the tool's config file is detected in the project.

### 5. Environment Variable Check

**Function:** `_preflight_check_env_vars()`

If `.env.example` (or `.env.template`, `.env.sample`) exists but `.env` does
not, emit a warning. Do NOT create `.env` automatically (security: may contain
secrets that need manual configuration).

If `.env` exists, check that every key in `.env.example` has a corresponding
key in `.env` (key presence only — never read values). Missing keys produce
warnings, not failures.

### 6. Runtime Version Check

**Function:** `_preflight_check_runtime_version()`

If version pinning files exist, validate the running runtime matches:

| File | Check |
|------|-------|
| `.node-version` / `.nvmrc` | `node --version` major matches |
| `.python-version` | `python3 --version` major.minor matches |
| `rust-toolchain.toml` | `rustc --version` channel matches |
| `.ruby-version` | `ruby --version` major.minor matches |
| `.go-version` | `go version` major.minor matches |
| `.java-version` | `java --version` major matches |

Mismatches produce warnings (not failures) since the project may still work
with a close version.

### 7. Port Availability Check

**Function:** `_preflight_check_ports()`

If `UI_TEST_CMD` or `BUILD_CHECK_CMD` implies a dev server (detectable via
common patterns: `next dev`, `vite`, `webpack-dev-server`, `flask run`),
check if the expected port is already in use. Common ports: 3000, 5173, 8080,
4200, 8000, 5000.

Port check: `ss -tlnp 2>/dev/null | grep -q ":$port "` (Linux) or
`lsof -i :$port` (macOS). Falls back gracefully if neither is available.

Port conflicts produce warnings, not failures (the dev server may handle it).

### 8. Lock File Freshness Check

**Function:** `_preflight_check_lock_freshness()`

Detects when the manifest (package.json, pyproject.toml, etc.) is newer than
the lock file, suggesting the lock file needs regeneration:

```bash
if [[ "package.json" -nt "package-lock.json" ]]; then
    # manifest edited after lock — npm install needed
fi
```

This is separate from the dependency freshness check (§2) which checks
installed deps vs lock file. This check catches lock file drift before
installation.

### 9. Pipeline Integration (`tekhton.sh`)

Wire `run_preflight_checks()` into the main execution path:

```bash
# After config loading, detection, and milestone resolution
# Before first stage dispatch
source "${TEKHTON_HOME}/lib/preflight.sh"
run_preflight_checks || {
    write_pipeline_state "preflight" "env_failure" ...
    exit 1
}
```

**Config keys:**
- `PREFLIGHT_ENABLED` (default: `true`) — Toggle pre-flight checks
- `PREFLIGHT_AUTO_FIX` (default: `true`) — Allow auto-remediation of safe issues
- `PREFLIGHT_FAIL_ON_WARN` (default: `false`) — Treat warnings as failures

### 10. PREFLIGHT_REPORT.md Output

Human-readable report written to the project directory:

```markdown
# Pre-flight Report — 2026-04-02 16:03:15

## Summary
✓ 5 passed  ⚠ 1 warned  ✗ 0 failed  🔧 1 auto-fixed

## Checks

### ✓ Dependencies (node_modules)
node_modules is up-to-date with package-lock.json.

### 🔧 Tools (Playwright)
Playwright browsers were missing. Auto-fixed: `npx playwright install` (14s)

### ⚠ Environment Variables
.env is missing key `DATABASE_URL` (present in .env.example).
This may cause runtime failures if the key is required.

### ✓ Runtime Version (Node.js)
.node-version requires 20.x, running 20.18.1. ✓
```

## Acceptance Criteria

- `run_preflight_checks()` completes in under 5 seconds on a typical project
- Detects stale `node_modules` when `package-lock.json` is newer
- Detects missing Playwright browsers when Playwright is the detected test framework
- Detects missing `.env` when `.env.example` exists
- Detects runtime version mismatch when version file exists
- Detects port conflicts when identifiable from pipeline config
- Auto-remediates safe issues when `PREFLIGHT_AUTO_FIX=true`
- Produces PREFLIGHT_REPORT.md with clear pass/warn/fail per check
- Pipeline halts on blocking failures with actionable message
- Skippable via `PREFLIGHT_ENABLED=false`
- Only checks ecosystems actually detected in the project (no false checks)
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n lib/preflight.sh` passes
- `shellcheck lib/preflight.sh` passes
- New test file `tests/test_preflight.sh` covers:
  - Missing node_modules detection (mock filesystem)
  - Stale lock file detection (touch-based mtime testing)
  - Tool availability check with mock `command -v`
  - Env var presence check
  - Report generation format
  - PREFLIGHT_ENABLED=false skips all checks
  - PREFLIGHT_AUTO_FIX=false reports but doesn't fix

Watch For:
- `mtime` comparison with `-nt` is filesystem-dependent. On some CI systems,
  all files may have the same mtime (git clone doesn't preserve). Handle this
  gracefully: if mtimes are identical, skip the freshness check (assume OK).
- The pre-flight must NOT run during `--init`, `--plan`, `--diagnose`, or
  `--dry-run` — only during actual pipeline execution (task runs).
- `ss` is Linux-only. macOS uses `lsof`. Check platform and fall back.
- `.env` files must NEVER be read for values — only check key presence by
  parsing lines matching `^[A-Z_]+=`. This is a security requirement.
- Some monorepos have multiple `package.json` files. The pre-flight should
  check the root project directory only, not recursively scan.
- `detect_languages()` may not be called yet when pre-flight runs. Ensure
  the detection results are available (they are: sourced at line 752+ in
  tekhton.sh, before stage dispatch).

Seeds Forward:
- Milestone 56 extends pre-flight with service readiness probing (port + health)
- Pre-flight report data feeds into Watchtower dashboard (future)
- Per-project custom pre-flight checks via pipeline.conf (future)
- Pre-flight can eventually cache results with TTL to skip on rapid re-runs
