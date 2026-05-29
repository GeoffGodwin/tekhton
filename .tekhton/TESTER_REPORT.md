## Planned Tests
- [x] `tests/test_mcp_serena_bin.sh` — m28.1 AC coverage: template content, SERENA_BIN resolver (POSIX + Windows + missing), config substitution, JSON validity, VERSION, CHANGELOG
- [x] `tests/test_mcp_probe.sh` — m28.2 probe AC coverage: empty-bin guard (AC2), probe-failure state in start_mcp_server (AC4), VERSION floor >= 4.27.6 (AC8), CHANGELOG m28.2 entry (AC9)
- [x] `tests/test_serena_template_substitution.sh` — m28.3: fresh-generation, no-overwrite-when-correct, regenerate-when-stale (10/10 PASS)
- [x] `tests/test_mcp.sh` — m28.3: three _probe_serena_startup scenarios (empty bin, failing binary, passing binary via echo) (25/25 PASS)

## Test Run Results
Passed: 494  Failed: 0

## Bugs Found
None

## Files Modified
- [x] `tests/test_mcp_serena_bin.sh`
- [x] `tests/test_mcp_probe.sh`
- [x] `tests/test_serena_template_substitution.sh`
- [x] `tests/test_mcp.sh`
