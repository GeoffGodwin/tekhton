# Architect Plan — 2026-03-25

## Staleness Fixes

**SF-1: Document intentional coupling in `_should_self_test_watchtower()`**

- **File:** `lib/ui_validate.sh:232–248`
- **Observation:** `_should_self_test_watchtower()` reads `DASHBOARD_ENABLED` and
  `DASHBOARD_DIR` directly, creating an implicit coupling between `ui_validate.sh`
  and the Watchtower/Dashboard feature. A future refactor of that feature could
  silently break this guard.
- **Finding:** The coupling is intentional and correct. Watchtower is the Dashboard's
  self-test mechanism. `config_defaults.sh:245` makes this relationship explicit:
  `"${WATCHTOWER_SELF_TEST:=${DASHBOARD_ENABLED:-true}}"`. The function guards are
  not accidental — they are the primary gate that ties Watchtower activation to the
  Dashboard feature being enabled.
- **Action:** Add a short explanatory comment at the top of `_should_self_test_watchtower()`
  (before line 233) stating that the `DASHBOARD_ENABLED`/`DASHBOARD_DIR` checks are
  intentional co-feature guards — Watchtower is the Dashboard's self-test, and both
  keys are set in `config_defaults.sh`. This makes the relationship visible to a
  future reader without any behavioral change.
- **Route:** jr coder (comment only — no logic change)

---

## Dead Code Removal

**DC-1: Delete `prompts/ui_rework.prompt.md`**

- **File:** `prompts/ui_rework.prompt.md` (28 lines)
- **Observation:** No code path calls `render_prompt("ui_rework")`. Searched all
  `lib/*.sh`, `stages/*.sh`, and `tekhton.sh` — zero call sites found. The file was
  authored for a UI rework routing path that was replaced by the `BUILD_ERRORS.md`
  approach during Milestone 29 implementation.
- **Action:** Delete `prompts/ui_rework.prompt.md`. No callers exist; the file is
  purely confusing to future maintainers reading the prompts directory.
- **Route:** jr coder (file deletion only)

---

## Naming Normalization

None.

---

## Simplification

None.

---

## Design Doc Observations

None.

---

## Drift Observations to Resolve

The following entries from DRIFT_LOG.md are addressed by this plan or are ready
for resolution:

- **[2026-03-25] `prompts/ui_rework.prompt.md:1-28`** — resolved by DC-1 (delete file).

- **[2026-03-25] `lib/ui_validate.sh:243-248`** — resolved by SF-1 (add documenting comment).

- **[2026-03-25] Expedited remediation attestation (SF-1/SF-2/out-of-scope confirmation)**
  — These four entries (starting "The expedited remediation addressed all three
  architect-identified drift observations correctly:") are reviewer attestations that
  a prior fix was applied correctly, not new problems. No action required. Mark all
  four as RESOLVED.

---

## Out of Scope

None. All six unresolved observations are addressed above — two via bounded fixes
(DC-1, SF-1) and four via resolution of informational attestation entries that
require no code change.
