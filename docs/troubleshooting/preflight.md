# Pre-flight Troubleshooting

Tekhton's pre-flight stage runs fast, deterministic checks before any agent
turn is consumed. This page documents the findings you might see in
`PREFLIGHT_REPORT.md` and how to resolve them.

The check categories are:

- Dependencies (node_modules, virtualenvs, vendor dirs)
- Tools (Playwright/Cypress browser caches, command availability)
- Generated code (Prisma client, GraphQL codegen, Protobuf)
- Environment variables (.env vs .env.example)
- Runtime versions (.nvmrc, .python-version, etc.)
- Ports (dev server collisions)
- Lock-file freshness (manifest newer than lock)
- Service readiness (Docker, dev servers)
- **UI test framework config audit (M131 — see below)**

## UI Test Framework Config Audit

When `UI_TEST_CMD` is configured, pre-flight scans the project's test
framework config files for settings that produce interactive
serve-and-wait loops or never-terminating watch modes. Catching these
patterns at pre-flight avoids burning a full `UI_TEST_TIMEOUT` on the
first gate run.

The audit can be disabled with `PREFLIGHT_UI_CONFIG_AUDIT_ENABLED=false`
in `pipeline.conf`.

### PW-1 — Playwright html reporter (FAIL, auto-fix)

**Symptom in report:** `### ✗ UI Config (Playwright) — html reporter`

**Cause:** `playwright.config.{ts,js,mjs,cjs}` sets `reporter: 'html'`
(or `['html']`). Playwright's HTML reporter launches `playwright
show-report --port` and waits for Ctrl+C — Tekhton's gate has no Ctrl+C
to send.

**Auto-fix:** When `PREFLIGHT_UI_CONFIG_AUTO_FIX=true` (default),
Tekhton rewrites the line to:

```ts
reporter: process.env.CI ? 'dot' : 'html'
```

The original is backed up to `.claude/preflight_bak/<YYYYMMDD_HHMMSS>_<filename>`.
Review and commit the change when satisfied.

**Manual fix** (when `PREFLIGHT_UI_CONFIG_AUTO_FIX=false` or
`PREFLIGHT_AUTO_FIX=false`): apply the same rewrite by hand, or set
`PLAYWRIGHT_HTML_OPEN=never` and `CI=1` in `pipeline.conf` to force
non-interactive mode without changing source.

### PW-2 — Playwright video: 'on' (WARN)

**Cause:** `use.video: 'on'` or `'retain-on-failure'` produces large
artifacts. Not blocking, but bloats CI storage.

**Suggested fix:** `video: process.env.CI ? 'off' : 'retain-on-failure'`

### PW-3 — Playwright reuseExistingServer: false (WARN)

**Cause:** `webServer.reuseExistingServer: false` causes the test
runner to hang if the dev server port is already in use.

**Suggested fix:** `reuseExistingServer: !process.env.CI`

### CY-1 — Cypress video: true (WARN)

**Cause:** Cypress records video by default; produces large artifacts
without an opt-out.

**Suggested fix:** `video: !!process.env.CI === false`

### CY-2 — Cypress mochawesome reporter without --exit (WARN)

**Cause:** The mochawesome reporter may orphan the reporter process when
`UI_TEST_CMD` does not include `--exit`.

**Suggested fix:** add `--exit` to `UI_TEST_CMD` in `pipeline.conf`.

### JV-1 — Jest/Vitest watch mode (FAIL — never auto-fixed)

**Symptom in report:** `### ✗ UI Config (Jest/Vitest) — watch mode enabled`

**Cause:** `vitest.config.*` or `jest.config.*` has `watch: true` or
`watchAll: true`. The test process never terminates.

**Manual fix — choose one:**

- Remove `watch: true` from the config file
- Add `--run` to `TEST_CMD` in `pipeline.conf` (Vitest: `vitest run ...`)
- Set `CI=true` in the environment (disables watch in most frameworks)

Watch mode is **never** auto-patched. Disabling it changes the
developer experience for every contributor on the project; the
deliberate choice is left to the developer.

## Configuration Knobs

| Variable | Default | Effect |
|----------|---------|--------|
| `PREFLIGHT_UI_CONFIG_AUDIT_ENABLED` | `true` | Master toggle for the M131 UI config audit. |
| `PREFLIGHT_UI_CONFIG_AUTO_FIX` | `true` | Whether the PW-1 reporter auto-patch runs. Falls back to legacy `PREFLIGHT_AUTO_FIX` when unset. |
| `PREFLIGHT_AUTO_FIX` | `true` | Legacy M55 master switch for all auto-remediation. Honored as the fallback when `PREFLIGHT_UI_CONFIG_AUTO_FIX` is unset. |
| `PREFLIGHT_BAK_DIR` | `${PROJECT_DIR}/.claude/preflight_bak` | Where backup copies of patched config files are written. |

## Interaction with the gate (M126)

When pre-flight detects an interactive Playwright config, it exports
`PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1`. The gate's environment
normalizer (`_ui_deterministic_env_list` in `lib/gates_ui_helpers.sh`)
escalates to the hardened env profile (`CI=1`) on the **first** gate
run rather than only on retry, so a project with a known-bad reporter
never burns a full `UI_TEST_TIMEOUT`.
