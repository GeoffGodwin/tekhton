## Test Audit Report

### Audit Summary
Tests audited: 2 files, 30 test functions
Verdict: PASS

### Findings

#### COVERAGE: ValidateToolSchema error branches only partially exercised
- File: internal/provider/codex/tools_test.go:135
- Issue: `TestTranslateTools_ErrorOnInvalidSchema` constructs a ToolSchema with only empty Name. `provider.ValidateToolSchema` (provider.go:82) has four independent guard clauses — empty Name, empty Description, Parameters.Type != "object", and AdditionalProperties=true. Only the empty-Name branch is exercised; regressions in the other three guards would go undetected.
- Severity: LOW
- Action: Add a table-driven test or three additional sub-cases covering Description="", Parameters.Type="array", and AdditionalProperties=true.

#### COVERAGE: Map iteration order unaddressed for future multi-key inline-config tests
- File: internal/provider/codex/flags_test.go:118
- Issue: `TestBuildExecArgs_InlineConfig` sets a single inline config key (`codex.config.model.provider`). `buildExecArgs` (flags.go:55) iterates `req.ProviderSpecific` with a plain `for k, v := range`, which is non-deterministic. The current single-key test is safe from flakiness; any future test with multiple `codex.config.*` keys that checks argv index positions would be intermittently flaky.
- Severity: LOW
- Action: Document the iteration-order caveat in a comment near the map range in `buildExecArgs`, and ensure any future multi-key test uses a contains-all check rather than an index-position assertion.

#### COVERAGE: Duplicate permission keys in allowed list untested for Codex compatibility
- File: internal/provider/codex/tools_test.go:67 (coder.json fixture)
- Issue: The coder fixture records `tools.allowed=["fs_read","fs_write","fs_write","shell","fs_read","fs_read"]` — duplicates because Write/Edit both map to `fs_write`, and Read/Glob/Grep all map to `fs_read`. The fixture accurately captures the current implementation; no Codex rejection has been observed. This is a behavioral gap rather than a test integrity issue.
- Severity: LOW
- Action: No test change required now. Add a comment in `translateTools` noting that the allowed list is not deduplicated and that Codex treats it as a set, so duplicates are harmless.

---

No HIGH or MEDIUM findings. All 30 test functions call real implementation code with no excessive mocking, use controlled fixtures or `t.TempDir()`/`t.Setenv()` for isolation, produce deterministic assertions against values derived from implementation logic, and align with currently-existing symbols (no orphaned imports or stale references). The reviewer's prior notes about code quality (duplicate allowed keys, map iteration order, unknown tool_set silent fallback) are well-founded and the corresponding LOW coverage gaps above reinforce them from the test side.

---

## Prior Reviewer Notes (code quality — preserved from reviewer stage)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- tools.go:55-64 — `allowed` slice accumulates duplicate Codex permission keys (e.g., CoderTools produces `["fs_read","fs_write","fs_write","shell","fs_read","fs_read"]`). Codex likely treats `tools.allowed` as a set, but a dedup pass with a `seen` map before `joinAllowed` would make the output minimal and remove the ambiguity entirely.
- flags.go:55-60 — map iteration over `req.ProviderSpecific` for `codex.config.*` keys is non-deterministic. Current tests only check for presence of a single entry, so no flakiness today. Sort the keys before appending to make argv deterministic for future multi-key tests.
- flags.go:64-76 — unknown `codex.tool_set` value (e.g., "architect") silently keeps the default workspace-write sandbox. Consider a default branch that logs a warning so misconfigured stages don't silently inherit the most-permissive tier.
- tools.go:59-61 — unknown tool names silently escalate to the "shell" permission key (Security A04/LOW). Adding a structured warning log would make future unmapped tools immediately visible rather than silently privileged.
- flags.go:46 — `codex.cwd` passed to `--cd` without path validation (Security A01/LOW). A comment on the ProviderSpecific key contract ("callers must sanitize") would prevent silent inheritance by future callers.

## Coverage Gaps
- internal/provider/codex/tools_test.go:216 — `TestCodexToolName_KnownNames` checks only for non-empty return, not exact mapped values. A regression remapping "Bash" from "shell" to "fs_read" would pass this test. Add a table-driven check asserting exact mappings for all six canonical names.
- internal/provider/codex/flags_test.go — `TestBuildExecArgs_ToolSetFromProviderSpecific` covers only the "intake" branch of the four-branch switch in flags.go:65-76. Add companion tests for "coder" (and optionally "reviewer" and "tester") asserting the correct sandbox value.
- internal/provider/codex/flags_test.go — `isInlineConfigKey("codex.config.")` (exact prefix, zero-length suffix) is not tested. The strict `len(k) > len(prefix)` boundary is correct but unverified by any test.

## Drift Observations
- testdata/tool_translations/coder.json and tester.json are currently identical in content because CoderTools == TesterTools. The separate fixture files add maintenance surface without differentiation. If TesterTools ever diverges, the fixtures will correctly diverge too — acceptable until then.
- flags.go:117-118 — manual prefix check `len(k) > len(prefix) && k[:len(prefix)] == prefix` is functionally correct but duplicates what `strings.HasPrefix` expresses. The `strings` package is not currently imported in flags.go; noting for a future cleanup pass if `strings` is added for another reason.
