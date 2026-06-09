## Test Audit Report

### Audit Summary
Tests audited: 2 files, 22 test functions
Verdict: PASS

### Findings

#### COVERAGE: codexToolName unit test asserts only non-empty, not actual mapped values
- File: internal/provider/codex/tools_test.go:216
- Issue: `TestCodexToolName_KnownNames` verifies all six canonical names return `(nonEmpty, true)` but never checks the actual Codex permission key. A regression where "Bash" remapped from "shell" to "fs_read" would not be caught by this test. The fixture-based integration tests (coder/reviewer/tester) do exercise the mapping end-to-end, so this is not a coverage hole — but it leaves the `codexToolName` unit test weaker than warranted.
- Severity: MEDIUM
- Action: Extend `TestCodexToolName_KnownNames` with a table-driven check asserting exact mapped values: `{"Read","fs_read"}, {"Write","fs_write"}, {"Edit","fs_write"}, {"Bash","shell"}, {"Glob","fs_read"}, {"Grep","fs_read"}`.

#### COVERAGE: codex.tool_set integration only tests the "intake" branch
- File: internal/provider/codex/flags_test.go:260
- Issue: `TestBuildExecArgs_ToolSetFromProviderSpecific` exercises only `codex.tool_set=intake`. The switch in `flags.go:65-76` has four branches (coder, reviewer, tester, intake). A regression where `"coder"` stopped resolving would not be caught by any flags_test.go test — only by translateTools fixture tests which don't go through `buildExecArgs`.
- Severity: LOW
- Action: Add `TestBuildExecArgs_ToolSetFromProviderSpecific_Coder` asserting `codex.tool_set=coder` produces `--sandbox workspace-write`.

#### COVERAGE: isInlineConfigKey exact-prefix boundary not tested
- File: internal/provider/codex/flags_test.go (absence of test)
- Issue: `isInlineConfigKey` uses strict `len(k) > len(prefix)`, so `"codex.config."` (no suffix) returns false. No test covers this boundary.
- Severity: LOW
- Action: Add a table-driven unit test for `isInlineConfigKey` covering the exact-prefix edge case.

#### COVERAGE: TestBuildExecArgs_WithTools does not verify the value of tools.allowed
- File: internal/provider/codex/flags_test.go:215
- Issue: Asserts that `-c tools.allowed=` prefix is present but not the actual permission list. This is acceptable because `TestTranslateTools_IntakeFixture` covers the value at the unit level; the flags test's scope is integration wiring, not value correctness.
- Severity: LOW
- Action: No action required.
