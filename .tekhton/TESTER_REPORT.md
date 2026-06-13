## Planned Tests
- [ ] `tests/test_tty_no_screen_clear.sh` — verify _tui_restore_terminal is guarded by _TUI_ACTIVE; no alt-screen sequences on inactive TUI
- [ ] `tests/test_tui_status_contract.sh` — verify Go-emitted tui_status.json is consumed by Python renderer without crashing
- [ ] `internal/tui/status_contract_test.go` — verify WriteInitial emits correct field names (current_agent_status, not agent_status)

## Test Run Results
Passed: 0  Failed: 0

## Bugs Found
None

## Files Modified
- [ ] `tests/test_tty_no_screen_clear.sh`
- [ ] `tests/test_tui_status_contract.sh`
- [ ] `internal/tui/status_contract_test.go`
