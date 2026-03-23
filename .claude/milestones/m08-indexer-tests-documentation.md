#### Milestone 8: Indexer Tests & Documentation
<!-- milestone-meta
id: "8"
status: "done"
-->

Comprehensive test coverage for all indexing functionality: shell orchestration,
Python tools, pipeline integration, fallback behavior, and Serena lifecycle.
Update project documentation and repository layout.

Files to create:
- `tests/test_indexer.sh` — shell-side tests: `check_indexer_available()` returns
  correct status for present/absent Python, `run_repo_map()` handles exit codes
  (0/1/2), `get_repo_map_slice()` extracts correct file entries, fallback to 2.0
  when indexer unavailable, config key validation (budget must be positive, etc.)
- `tests/test_mcp.sh` — MCP lifecycle tests: `start_mcp_server()` / `stop_mcp_server()`
  create and clean up processes, `check_mcp_health()` detects running/stopped
  server, EXIT trap cleanup works, orphan prevention
- `tests/test_repo_map_integration.sh` — end-to-end tests using a small fixture
  project (created in test setup): verify repo map generation, stage injection
  (coder/reviewer/tester get correct slices), context budget respected, conditional
  prompt blocks render correctly when feature on/off
- `tools/tests/test_repo_map.py` — Python unit tests: tag extraction for each
  supported language, graph construction from tags, PageRank output, token budget
  enforcement, `.gitignore` respect, error handling for unparseable files
- `tools/tests/test_tag_cache.py` — cache hit/miss, mtime invalidation, pruning
  deleted files, version migration, concurrent write safety
- `tools/tests/test_history.py` — task→file recording, JSONL append, history
  loading, personalization vector computation, max records pruning
- `tools/tests/conftest.py` — shared fixtures: small multi-language project tree,
  mock git repo, sample tag cache files
- `tests/fixtures/indexer_project/` — small fixture project with Python, JS, and
  Bash files for integration testing

Files to modify:
- `CLAUDE.md` — update Repository Layout to include `tools/` directory, `lib/indexer.sh`,
  `lib/mcp.sh`. Update Template Variables table with all new config keys and their
  defaults. Update Non-Negotiable Rules to note Python as an optional dependency.
- `templates/pipeline.conf.example` — ensure all indexer config keys have
  explanatory comments matching the detail level of existing keys
- `tests/run_tests.sh` — add new test files to the test runner. Add conditional
  Python test execution: if Python available, run `python3 -m pytest tools/tests/`;
  if not, skip with a note.

Acceptance criteria:
- All shell tests pass via `bash tests/run_tests.sh`
- All Python tests pass via `python3 -m pytest tools/tests/` (when Python available)
- Test runner gracefully skips Python tests when Python unavailable
- Fixture project exercises multi-language parsing (Python + JS + Bash minimum)
- Integration test verifies full flow: setup → generate map → inject into stage →
  verify prompt contains repo map content → verify context budget respected
- Fallback test verifies: disable indexer → run pipeline → identical to v2 output
- MCP tests verify no orphaned processes after normal exit, Ctrl+C, and error exit
- `CLAUDE.md` Repository Layout includes all new files and directories
- `CLAUDE.md` Template Variables table includes all new config keys
- `bash -n` passes on all new `.sh` files
- `shellcheck` passes on all new `.sh` files
- All pre-existing tests (37+) continue to pass unchanged

Watch For:
- Python test fixtures must be self-contained — no network access, no real
  language servers. Mock tree-sitter parsing for unit tests; use real parsing
  only in integration tests.
- The fixture project must be small (5-10 files) to keep tests fast.
- MCP lifecycle tests are inherently flaky (process timing). Use retry logic
  and generous timeouts in test assertions, not in production code.
- Shell tests that verify prompt content should check for the presence of
  `REPO_MAP_CONTENT` variable, not exact prompt text (prompts will evolve).
- Ensure Python tests work with both `tree-sitter-languages` (bundled) and
  individual grammar packages — CI environments may have either.

Seeds Forward:
- Test fixtures and patterns established here are reused by future v3 milestones
  (DAG execution, parallel agents, UI plugin) for their own testing
- The integration test pattern (fixture project → full pipeline) becomes the
  template for end-to-end testing of future features
