# tests/testdata/detect — m29 detect parity-gate fixtures

These fixtures back `tests/test_detect_parity.sh`. Each subdirectory is a
self-contained project the bash detect tree and the Go engine both
analyse; the parity gate asserts both sides produce byte-identical
`### Project Type`, `### Languages`, and `### Frameworks` sections.

| Fixture            | Exercises                                                    |
|--------------------|--------------------------------------------------------------|
| `monorepo-pnpm/`   | pnpm workspace + TypeScript root + React/Vue/Express packages |
| `polyglot-services/` | Go root + Python sidecar + Dockerfile + k8s + GitHub CI    |
| `ai-heavy-mess/`   | `.claude/`, `.cursorrules`, `AGENTS.md`, half-finished pyproject |

Baselines under `baselines/` were captured by
`scripts/capture-detect-baselines.sh` at m29.1 close. They are frozen —
m29.2 must match them byte-for-byte from the Go engine. Do not
regenerate without a deliberate milestone touching the bash detect
tree.
