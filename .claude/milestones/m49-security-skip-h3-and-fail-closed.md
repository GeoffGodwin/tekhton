<!-- milestone-meta
id: "49"
status: "todo"
-->

# m49 — Security Gate Skip: Recognize H3 Subheadings AND Flip the Empty-File Default to Fail-Closed

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | The m48 run (and an unknown number of prior runs going back to m35.2's security port) silently skipped the security stage on real code changes. The CODER_SUMMARY.md emitted by the coder agent for m48 listed three files — `cmd/tekhton/run.go`, `cmd/tekhton/run_test.go`, `tests/test_autoadvance_per_milestone_commits.sh` — none of which are docs/config/assets. All three should have triggered a security scan. Instead, the stage logged `[security] All changed files are docs/config/assets. Skipping security scan.` and exited. The work was low-risk in this case (sentinel file writes + a banner emitter + git log parsing), but the bug means every coder-summary-emitting milestone since m35.2 has had its security gate silently disabled whenever the agent chose H3 subheadings under a parent section instead of the canonical H2 headings. Two layered bugs are in play; both need to be fixed together. |
| **Gap** | (1) `internal/security/findings.go::extractFilesFromCoderSummary` (line 128) only recognizes the canonical H2 headings `## Files Modified` and `## Files Created`. The m48 coder summary emitted `### Modified` and `### Created` — H3 subheadings under an implicit `## Files` parent — and the scanner state never flipped to `in=true`. The bash predecessor `lib/indexer_helpers.sh::extract_files_from_coder_summary` had the same H2-only assumption. (2) `internal/security/findings.go::IsDocsOnly` (line 112-114) returns `(true, nil)` — "docs only — skip scan" — when the file list comes back empty. That's a fail-OPEN default: when the extractor can't classify, the security gate silently passes. Combined with bug 1, every coder summary using H3 subheadings (a common stylistic choice — the m48 agent used them, and historic CODER_SUMMARY.md files in `.tekhton/` show several others) triggers a free pass through security. The two bugs compound: bug 1 produces an empty file list whenever H3 is used; bug 2 interprets empty as "skip". |
| **m49 fills** | Two narrow fixes that together restore security-gate coverage on every coder run. **Fix 1:** extend `extractFilesFromCoderSummary` to also recognize H3 subheadings (`### Modified`, `### Created`, `### Added`, `### Files Modified`, `### Files Created`) under any parent — not just the canonical H2 headings. The scanner state flips on EITHER H2 `## Files Modified`/`## Files Created` OR H3 `### Modified`/`### Created`/`### Added`. Heading-style heterogeneity is the reality of agent-authored summaries; the parser must accept both. **Fix 2:** flip `IsDocsOnly`'s empty-file default from `(true, nil)` (skip) to `(false, nil)` (scan). The new semantic: *"couldn't extract files → scan to be safe."* This is the fail-CLOSED default appropriate for security checks. Adds five fixtures + a table-driven test covering H2-with-files, H3-with-files, both-styles-mixed, no-section-present, present-but-empty. Includes a shim-boundary regression test that drives `tekhton run` against a fixture project with a synthesized CODER_SUMMARY.md using H3 subheadings and asserts the security stage DID run (not skipped). |
| **Depends on** | none (purely internal to `internal/security/`) |
| **Files changed** | `internal/security/findings.go`, `internal/security/findings_test.go`, `internal/security/testdata/docs_only/h2_with_files.md`, `h3_with_files.md`, `h2_h3_mixed.md`, `no_section.md`, `empty_section.md`, `tests/test_security_h3_subheadings.sh` (new) |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m41 | Finalize: stop false-blocking the commit when milestone block can't be populated |
| m42 | Preflight: guard against no-op TEST_CMD |
| m43 | Version-bump completeness |
| m44 | Commit subject regression |
| m45 | Completion gate: stop false-halting on transient TEST_CMD failure |
| m46 | Replan detector body-grep + commit-skip cascade |
| m47 | Stage verdict envelope is source of truth |
| m48 | Auto-advance loop: reset per-iteration state |
| **m49** | **Security gate skip: recognize H3 subheadings AND flip the empty-file default to fail-closed** |

---

## Design

### Sequencing note

m49 is independent of m39.4. Land m49 first so the V4 closer's security
gate runs against m39.4's full change set instead of skipping silently.
m39.4 is large (~2000 LOC of new Go for the coder main stage port), and
the change set includes new public APIs — exactly the kind of work
security review exists to gate.

### Goal 1 — Extend `extractFilesFromCoderSummary` to recognize H3 subheadings

**File:** `internal/security/findings.go`, the `extractFilesFromCoderSummary` function (around line 128).

Current behavior:

```go
if strings.HasPrefix(line, "## Files Modified") ||
    strings.HasPrefix(line, "## Files Created") {
    in = true
    continue
}
if in && strings.HasPrefix(line, "##") {
    break
}
```

The `break` on `##` triggers on BOTH H2 (`## ...`) and H3 (`### ...`),
because `### ...` starts with `##`. That's wrong when the section uses
H3 subheadings: the H3 `### Modified` is the BEGIN marker, and the next
H3 `### Created` or `### Removed` should NOT terminate the scan.

Replace with explicit-prefix matching that recognizes both styles:

```go
// m49 — Recognize either the canonical H2 headings (## Files Modified,
// ## Files Created) OR the H3 subheading style coder agents often
// emit (### Modified, ### Created, ### Added) under any parent section.
// Both styles indicate "the bullet list that follows is the file
// changeset."
//
// The break-on-next-section logic now keys on H2 boundaries only —
// H3 subheadings INSIDE the section are part of the file list grouping,
// not boundary markers. A new H2 ("## Watch For", "## Notes", etc.)
// terminates the scan.
func extractFilesFromCoderSummary(path string) ([]string, error) {
    // ... open file, scanner setup ...

    var out []string
    in := false
    sc := bufio.NewScanner(f)
    for sc.Scan() {
        line := sc.Text()
        // BEGIN markers: H2 canonical OR H3 stylistic.
        if isFilesSectionHeading(line) {
            in = true
            continue
        }
        // END marker: next H2 (NOT H3 — H3 stays inside the section).
        // The check is "exactly two #s followed by space" — H3 is
        // "###" which doesn't match.
        if in && isH2Heading(line) {
            break
        }
        if !in {
            continue
        }
        cleaned := cleanFileBullet(line)
        if cleaned == "" || cleaned == "None" || strings.HasPrefix(cleaned, "(fill") {
            continue
        }
        out = append(out, cleaned)
    }
    if err := sc.Err(); err != nil {
        return nil, err
    }
    return out, nil
}

// isFilesSectionHeading returns true if line is one of the recognized
// file-section heading styles. The set is intentionally narrow — we
// match the headings agents actually produce, not arbitrary file-
// related text.
func isFilesSectionHeading(line string) bool {
    trimmed := strings.TrimSpace(line)
    // H2 canonical.
    if strings.HasPrefix(trimmed, "## Files Modified") ||
        strings.HasPrefix(trimmed, "## Files Created") ||
        strings.HasPrefix(trimmed, "## Files Added") {
        return true
    }
    // H3 stylistic (under any parent).
    if strings.HasPrefix(trimmed, "### Files Modified") ||
        strings.HasPrefix(trimmed, "### Files Created") ||
        strings.HasPrefix(trimmed, "### Modified") ||
        strings.HasPrefix(trimmed, "### Created") ||
        strings.HasPrefix(trimmed, "### Added") {
        return true
    }
    return false
}

// isH2Heading returns true for exactly H2 headings (two #s + space),
// not H3 (three #s + space). Used as the section-end boundary so H3
// subheadings inside a Files section remain inside the scan.
func isH2Heading(line string) bool {
    trimmed := strings.TrimLeft(line, " \t")
    return strings.HasPrefix(trimmed, "## ") && !strings.HasPrefix(trimmed, "### ")
}
```

The mixed-style case (H2 parent `## Files` with H3 subheadings
`### Modified` and `### Created` inside) is the common shape modern
coder agents produce. The scanner enters on the FIRST recognized
heading (H2 `## Files Modified` OR H3 `### Modified`) and stays in
until the next H2.

### Goal 2 — Flip `IsDocsOnly`'s empty-file default to fail-closed

**File:** `internal/security/findings.go::IsDocsOnly` (line 102-122).

Current behavior:

```go
func IsDocsOnly(summaryPath string) (bool, error) {
    if _, err := os.Stat(summaryPath); os.IsNotExist(err) {
        return false, nil
    } else if err != nil {
        return false, err
    }
    files, err := extractFilesFromCoderSummary(summaryPath)
    if err != nil {
        return false, err
    }
    if len(files) == 0 {
        return true, nil    // ← FAIL-OPEN: empty list → skip security
    }
    for _, f := range files {
        ext := strings.TrimPrefix(filepath.Ext(f), ".")
        if !docsExt[ext] {
            return false, nil
        }
    }
    return true, nil
}
```

The `len(files) == 0` → `(true, nil)` branch is a fail-OPEN default for
a security check. After Goal 1 lands, fewer summaries will hit this
branch (the H3 style now extracts correctly), but the branch should
still flip to fail-CLOSED: when the extractor can't find files, the
correct interpretation is *"I don't know what changed → scan to be
safe,"* not *"nothing was extracted → skip security."*

```go
//   - Summary missing                → (false, nil)   "scan anyway"
//   - Summary present but empty list → (false, nil)   "scan anyway —
//                                                       extractor
//                                                       couldn't find
//                                                       files, don't
//                                                       silently skip"
//   - Any file outside the allowlist → (false, nil)   "code file present"
//   - All files in the allowlist     → (true,  nil)   "docs only — skip"
//
// m49: the empty-list default flipped from (true) to (false). Prior
// behavior was fail-OPEN — any coder summary whose file section the
// extractor couldn't parse silently passed security, including all
// summaries using H3 subheadings (the m48 false-skip incident).
func IsDocsOnly(summaryPath string) (bool, error) {
    if _, err := os.Stat(summaryPath); os.IsNotExist(err) {
        return false, nil
    } else if err != nil {
        return false, err
    }
    files, err := extractFilesFromCoderSummary(summaryPath)
    if err != nil {
        return false, err
    }
    if len(files) == 0 {
        return false, nil   // m49 — fail-closed: scan when uncertain
    }
    for _, f := range files {
        ext := strings.TrimPrefix(filepath.Ext(f), ".")
        if !docsExt[ext] {
            return false, nil
        }
    }
    return true, nil
}
```

After this flip, three classes of summary will now correctly trigger
the security scan: (a) summaries using H3 subheadings (Goal 1 fixes
the extraction, but as a belt-and-suspenders this would have caught
them too); (b) summaries with a present-but-empty file section
(`## Files Modified` followed by no bullets — happens on tooling-only
runs); (c) summaries missing the file section entirely (an
agent that forgets the heading).

### Goal 3 — Fixtures + table-driven tests

**File:** `internal/security/testdata/docs_only/` — five new fixtures.

| Fixture | Description | Expected IsDocsOnly result |
|---|---|---|
| `h2_with_files.md` | Canonical H2 heading `## Files Modified` followed by `- foo.go` bullets | `false` (Go file present, not docs-only) |
| `h3_with_files.md` | H3 `### Modified` followed by `- foo.go` bullets | `false` (after m49 fix) |
| `h2_h3_mixed.md` | `## Files` parent + `### Modified` subheading + `### Created` subheading | `false` (after m49 fix) |
| `no_section.md` | Summary without any Files section | `false` (m49 fail-closed) |
| `empty_section.md` | `## Files Modified` followed by no bullets (or only "None") | `false` (m49 fail-closed) |
| `h2_with_docs_only.md` | H2 heading with `- README.md`, `- docs/foo.md` bullets | `true` (all docs ext) |
| `h3_with_docs_only.md` | H3 heading with `- README.md` bullets | `true` (after m49 fix) |

(Seven fixtures total — listing five new ones plus two docs-only positive
cases to lock in that the happy path still skips correctly.)

**File:** `internal/security/findings_test.go` — replace or extend the
existing `TestIsDocsOnly` test with a table-driven structure keyed on
the fixtures above.

```go
func TestIsDocsOnly_TableDriven(t *testing.T) {
    cases := []struct {
        fixture string
        want    bool
    }{
        {"h2_with_files.md", false},
        {"h3_with_files.md", false},       // m49 — H3 recognition
        {"h2_h3_mixed.md", false},          // m49 — mixed styles
        {"no_section.md", false},           // m49 — fail-closed
        {"empty_section.md", false},        // m49 — fail-closed
        {"h2_with_docs_only.md", true},
        {"h3_with_docs_only.md", true},    // m49 — H3 docs-only still skips
    }
    for _, c := range cases {
        t.Run(c.fixture, func(t *testing.T) {
            path := filepath.Join("testdata", "docs_only", c.fixture)
            got, err := IsDocsOnly(path)
            if err != nil {
                t.Fatalf("IsDocsOnly(%q): %v", c.fixture, err)
            }
            if got != c.want {
                t.Errorf("IsDocsOnly(%q) = %v, want %v", c.fixture, got, c.want)
            }
        })
    }
}
```

**File:** `tests/test_security_h3_subheadings.sh` (new, ~80 lines).
Shim-boundary integration test:

1. Set up a throwaway project with a fixture CODER_SUMMARY.md that uses
   H3 subheadings and lists a `.go` file.
2. Stub the agent runner so the security scan would log a detectable
   sentinel if invoked.
3. Drive a single stage invocation against the security stage.
4. Assert the scan DID run (sentinel present), the stage did NOT log
   `"docs/config/assets. Skipping security scan"`.

Self-skips cleanly when the Go binary isn't built — same pattern as
`tests/test_state_writer_resume_fields.sh`.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/security/findings.go` | Modify | Extract `isFilesSectionHeading` + `isH2Heading` helpers; update `extractFilesFromCoderSummary` to recognize H3 subheadings and use H2-only end-boundary; flip `IsDocsOnly`'s empty-list default to `(false, nil)`. |
| `internal/security/findings_test.go` | Modify | Replace `TestIsDocsOnly` (and any sibling) with the seven-fixture table-driven test. |
| `internal/security/testdata/docs_only/h2_with_files.md` | Create | Canonical H2 fixture with a Go file. |
| `internal/security/testdata/docs_only/h3_with_files.md` | Create | H3 fixture with a Go file. |
| `internal/security/testdata/docs_only/h2_h3_mixed.md` | Create | `## Files` parent + H3 subheadings. |
| `internal/security/testdata/docs_only/no_section.md` | Create | Summary missing the Files section entirely. |
| `internal/security/testdata/docs_only/empty_section.md` | Create | Section present but no bullets (or "None" only). |
| `internal/security/testdata/docs_only/h2_with_docs_only.md` | Create | Happy path — H2 with docs-extension files only. Locks in that the skip path still works. |
| `internal/security/testdata/docs_only/h3_with_docs_only.md` | Create | Happy path — H3 with docs-extension files only. |
| `tests/test_security_h3_subheadings.sh` | Create | Shim-boundary integration test asserting the security scan runs against an H3 fixture. |

---

## Acceptance Criteria

- [ ] `internal/security/findings.go` exports `isFilesSectionHeading` and `isH2Heading` helpers (package-private fine — the tests can use them via the table-driven path). Verified by `grep -nE 'func isFilesSectionHeading|func isH2Heading' internal/security/findings.go` returning two matches.
- [ ] `extractFilesFromCoderSummary` recognizes `### Modified` as a BEGIN marker. Verified by `TestIsDocsOnly_TableDriven/h3_with_files.md` returning `false` (the Go file is extracted and is not in docsExt).
- [ ] `extractFilesFromCoderSummary` does NOT treat `### Created` (an H3 INSIDE the Files section) as an END marker. Verified by `TestIsDocsOnly_TableDriven/h2_h3_mixed.md` extracting files from BOTH the H3 Modified and H3 Created subheadings.
- [ ] `IsDocsOnly` returns `(false, nil)` when the file list is empty. Verified by `TestIsDocsOnly_TableDriven/no_section.md` AND `/empty_section.md` returning `false`.
- [ ] `IsDocsOnly` returns `(true, nil)` when ALL extracted files have docs extensions. Verified by `TestIsDocsOnly_TableDriven/h2_with_docs_only.md` AND `/h3_with_docs_only.md` returning `true` (regression guards for the happy path).
- [ ] The shim-boundary test `tests/test_security_h3_subheadings.sh` drives a security-stage invocation against an H3 fixture and asserts the scan ran (not skipped). Verified by running the test.
- [ ] No regression in: existing `internal/security/...` Go tests, `internal/stages/security/...` Go tests, `cmd/tekhton/...` Go tests.
- [ ] `shellcheck tests/test_security_h3_subheadings.sh` returns zero warnings.
- [ ] `golangci-lint run ./internal/security/...` and `go vet ./internal/security/...` clean after the changes.
- [ ] Full suite passes: `bash tests/run_tests.sh` + `go test ./...`.

## Watch For

- **The list of recognized H3 subheadings is opinionated.** Today: `### Modified`, `### Created`, `### Added`, `### Files Modified`, `### Files Created`. If a future coder agent emits another variant (`### Changed`, `### Touched`), the extractor will miss it. The list should be reviewed if future runs surface a new style — but resist adding ambiguous matches like `### Updates` that could appear in non-file contexts.
- **The H2 end-boundary is now strict.** `### Subheading` no longer terminates the scan — only `## H2` does. If a coder summary uses H3 subheadings for non-file content INSIDE the file section (unlikely but possible), those bullets will be incorrectly extracted as files. Mitigation: `cleanFileBullet` already rejects malformed bullets (`(fill...)`, etc.). Watch the test_security_h3_subheadings.sh integration test output for surprise extractions.
- **`(true, nil)` is now a narrower outcome.** Only summaries whose file list extracts cleanly AND has every file in the docs-ext allowlist will skip security. Operator-facing observation: m49 will measurably INCREASE the rate of security scans on dogfood runs. That's the intended behavior. The signal to watch is whether any false-positive scans (security scans finding things that aren't actually code) cause noise — none are expected because the docsExt allowlist hasn't changed.
- **Don't widen `docsExt`.** Adding `.sh` or `.go` to the allowlist to "fix" the issue would be the wrong fix — `.go` files genuinely need security review, and `.sh` files can introduce shell-injection or privilege issues. The fix is in extraction and the fail-closed default, not in the allowlist.
- **The bash predecessor `lib/security_helpers.sh::_security_is_docs_only` had the same H2-only assumption.** Since m35.2 ported security to Go, the bash file is gone — but if a future milestone reintroduces ANY bash file that mirrors this logic (e.g., a shim for an external linter), it must apply the same H2-OR-H3 recognition.
- **Fixture files use full canonical CODER_SUMMARY.md shape.** Don't abbreviate them — include the typical `## Status: COMPLETE` and `## What Was Implemented` sections so the fixtures double as documentation of the format the extractor is expected to handle. A future contributor reading the test should understand what the extractor sees.

## Seeds Forward

- **Surface `## Files Modified` heading style in the coder prompt.** The m49 extractor recognizes both H2 and H3, but the coder prompt could be tightened to nudge agents toward the canonical H2 form. Light touch in `prompts/coder.prompt.md` — "When listing files, use `## Files Modified` and `## Files Created` (H2) headings." Doesn't break m49's broader acceptance but reduces the surface area going forward.
- **Security-stage telemetry on skip-rate.** Once `IsDocsOnly` is fail-closed and H3-aware, the rate at which security is genuinely skipped (only when all files are docs ext) should drop sharply. A future telemetry hook could log `security_skip_reason` (`agent_disabled` / `skip_flag` / `docs_only`) per run; a spike or anomaly in the rate would be a signal that either the extraction is regressing OR the agent is suddenly producing all-docs changesets (e.g., a documentation-only milestone arc).
- **Audit other extractors for the same pattern.** `internal/intake/`, `internal/review/`, and `internal/test_audit/` all consume `CODER_SUMMARY.md`. Each has its own extraction logic; each may have made the same H2-only assumption. A follow-up arc could harmonize the extractors so a single helper (e.g., `internal/coder/summary.ExtractFiles(path)`) is the source of truth. Tracked as Seeds Forward; not scheduled.
- **Markdown frontmatter or metadata block (V5 candidate):** instead of parsing markdown headings, a future schema could have the coder write a YAML/JSON frontmatter block at the top of CODER_SUMMARY.md with `files_modified: [list]` and `files_created: [list]`. The extractor becomes a one-line YAML parse. Bigger change; V5 territory.
