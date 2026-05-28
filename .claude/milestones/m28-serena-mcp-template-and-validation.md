<!-- milestone-meta
id: "28"
status: "split"
-->

# m28 — Serena MCP Config Fix + Validation

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | The Serena MCP config that tekhton emits and the runtime that checks it have been silently broken since `python -m serena` started failing with `No module named serena.__main__`. The pipeline log line `[mcp] Serena MCP integration enabled.` is unconditional once `_resolve_mcp_config` returns 0 — claude tolerates the dead MCP server and the agents run with no LSP-backed tools, so nobody noticed. Caught during a sdivi-rust M29 incident where the missing tool surface went undetected across two consecutive pipeline runs. Three subtasks: fix the template (28.1), make the runtime stop lying (28.2), migrate the stale configs already in the wild (28.3). |
| **Gap** | (1) `tools/serena_config_template.json` emits `"command": "{{SERENA_PYTHON}}", "args": ["-m", "serena", …]` — serena ships a console-script entrypoint, not a `__main__`. (2) `lib/mcp.sh::_resolve_serena_paths` discovers `_SERENA_PYTHON` and `_SERENA_DIR` but never the actual console binary. (3) `start_mcp_server` declares success on config-path resolution alone — no probe that the server can start. (4) Existing project configs keep their broken shape because `_resolve_mcp_config` short-circuits on file presence. |
| **m28 fills** | 28.1 fixes the template + resolver so newly generated configs work end-to-end. 28.2 adds a 2-second startup probe so the runtime stops claiming a dead MCP server is active. 28.3 detects and replaces stale broken configs and ships the regression-test coverage. Each subtask leaves tekhton dogfoodable on itself for the next: 28.1 doesn't touch existing configs, 28.2's probe failure is non-fatal, 28.3 is purely additive. |
| **Depends on** | m27 |
| **Files changed** | `tools/serena_config_template.json`, `tools/setup_serena.sh`, `lib/mcp.sh`, `tests/test_mcp.sh`, `tests/test_serena_template_substitution.sh` (new), `tests/fixtures/serena_configs/` (new), `VERSION`, `CHANGELOG.md`, `.claude/milestones/MANIFEST.cfg`. |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m26 | Stage + finalize env contract — `SERENA_*` env vars are documented in `pipeline.conf`. |
| m27 | Defensive `${VAR:-default}` sweep — `SERENA_ENABLED` and friends carry defaults, but the underlying invocation was still wrong. |
| **m28** | **Fix the broken invocation, add the runtime probe, migrate stale configs in the wild.** |

---

## Design

This milestone is sequenced into three independently dogfoodable subtasks:

- **[m28.1 — Template + resolver fix](m28.1-serena-template-and-resolver.md)** — single coherent fix to the generation path. After this, a fresh `tekhton --setup-indexer --with-lsp` produces a working config. Pre-existing broken configs are left alone (handled in 28.3).
- **[m28.2 — Startup probe + truthful status](m28.2-serena-smoke-test-truthful-status.md)** — spawn the resolved Serena binary in a 2-second smoke probe before declaring success. On probe failure: warn, leave `SERENA_ACTIVE` empty, continue without LSP.
- **[m28.3 — Stale-config migration + tests](m28.3-stale-config-migration-and-tests.md)** — detect old-shape `"args": ["-m", "serena", …]` configs, back them up, regenerate from the (now-correct) template. Pin the entire arc with new unit + lifecycle tests.

See each subtask file for full design, acceptance criteria, and watch-fors.

### Why split this way

- **28.1 alone is a complete win for fresh installs.** New projects get correct configs immediately. Existing projects are no worse off than today — claude already tolerates the dead MCP server.
- **28.2 makes the lie stop without touching configs.** Even on a project with a broken pre-m28.1 config, the runtime now warns instead of declaring success. Lower-risk improvement that ships independently of any config rewrite.
- **28.3 closes the migration loop and adds the regression net.** Tests land last because the surface they cover spans 28.1 + 28.2; landing them earlier means re-writing fixtures.
- **No subtask requires the others to be in a different state to dogfood tekhton on itself.** 28.2 doesn't need 28.1's correct template (the probe can fail on either old or new resolver). 28.3 doesn't need 28.2's probe (stale-detection runs at config-resolution time, before any probe).

---

## Acceptance Criteria (arc-level)

- [ ] m28.1, m28.2, m28.3 each individually close with `status: "done"`.
- [ ] Manifest rows for m28, m28.1, m28.2, m28.3 all read `done` after m28.3 closes; m28 parent flips from `split` to `done`.
- [ ] `VERSION` reads `4.28.0` on m28 close (m28.1 and 28.2 used patch bumps `4.27.5`, `4.27.6`).
- [ ] Single arc CHANGELOG section under the eventual `[4.28.0]` heading consolidates the three subtask entries.
- [ ] `bash tests/run_tests.sh` shows zero regressions vs. the m27-close baseline.
- [ ] Downstream proof: a clean run of `tekhton run --milestone <m> --complete` on sdivi-rust against `.claude/serena_mcp_config.json` regenerated by m28.3 logs `[mcp] Serena MCP integration enabled (probe passed).` — not the silent pre-m28 line.

## Watch For

- **Don't ship 28.1 with `--context ide-assistant` baked into the template without confirming Serena's CLI-mode tool surface matches what Claude Code's agents expect.** Default context is `desktop-app` and is known to work. The `ide-assistant` context is documented as the recommended choice for CLI agents but the surface delta is non-trivial; if uncertain, omit `--context` and accept the default. 28.2's probe will catch any startup-level regression either way.
- **The probe in 28.2 must not block the pipeline.** If the Serena binary hangs on first invocation (rust-analyzer indexing latency, slow disk), the 2s timeout fires and the pipeline continues with MCP disabled. A blocked probe is worse than no MCP.
- **28.3's stale-config detection must match exactly the pre-28.1 broken shape, not anything containing the word `serena`.** A user with a custom MCP config that happens to name a server "serena" must not have it silently overwritten. The signature is `args[0] == "-m" && args[1] == "serena"` — narrow and intentional.
- **Bindings drift:** the four template variables (`{{SERENA_PYTHON}}`, `{{SERENA_PATH}}`, `{{PROJECT_DIR}}`, `{{LANGUAGE_SERVERS}}`) are substituted in two places: `lib/mcp.sh::_resolve_mcp_config` and `tools/setup_serena.sh`. 28.1 must update both. `grep -rn '{{SERENA_PYTHON}}' tools/ lib/ tests/` returning zero matches is the cheap drift-gate.

## Seeds Forward

- **Post-m28**: tekhton's MCP integration is honest. First downstream consumer is sdivi-rust's M29 dogfooded run, which is currently blocked behind this fix.
- **Future MCP servers**: if more MCP integrations land (a future m30+), the template-substitution path generalizes naturally — the substitution machinery is the same; only the per-server template differs. Don't pre-build that abstraction here; one MCP server is not yet a pattern.
- **Backup files (`<config>.bak.<ts>`) accumulate over time.** 28.3's auto-repair preserves originals; cleanup is out of m28's scope. If the accumulation becomes a real pain point, a future task can sweep backups older than 30 days. Don't anticipate-build it.
