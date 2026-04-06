## Test Audit Report

### Audit Summary
Tests audited: 2 files, ~76 inline assertions across 13 sections
- `tests/test_platform_mobile_game.sh` — ~57 assertions, 8 sections
- `tests/test_platform_m60_integration.sh` — ~19 assertions, 7 sections
Verdict: PASS

### Findings

#### COVERAGE: Flutter fragment loading checks only non-empty, not content-specific
- File: tests/test_platform_mobile_game.sh:463-465
- Issue: Section 8 tests Flutter fragment loading with `[[ -n "$UI_CODER_GUIDANCE" ]]`,
  `[[ -n "$UI_SPECIALIST_CHECKLIST" ]]`, and `[[ -n "$UI_TESTER_PATTERNS" ]]` — only
  checking that variables are non-empty. Contrast with the game_web test immediately
  below (lines 472-474), which verifies specific strings ("Game Loop", "Frame budget",
  "Headless") are present. The Flutter test would pass even if the wrong platform's
  content was loaded, or if only the universal fragment was loaded and the Flutter-specific
  fragment was silently dropped. The `mobile_flutter/coder_guidance.prompt.md` file
  contains distinguishing content (e.g., "Material" or "StatefulWidget") that could
  be asserted.
- Severity: MEDIUM
- Action: Add at least one content-specific substring check for each Flutter fragment
  variable, mirroring the game_web pattern. For example:
  `[[ "$UI_CODER_GUIDANCE" == *"Material"* ]]` (from mobile_flutter/coder_guidance.prompt.md)
  and `[[ "$UI_TESTER_PATTERNS" == *"widget"* ]]` (or equivalent distinctive string
  from mobile_flutter/tester_patterns.prompt.md).

#### COVERAGE: iOS and Android platform adapters not validated in fragment loading
- File: tests/test_platform_mobile_game.sh (Section 8)
- Issue: Section 8 calls `load_platform_fragments` only for `mobile_flutter` and
  `game_web`. The `mobile_native_ios` and `mobile_native_android` adapters each have
  three non-empty prompt files confirmed by Section 2 — but the fragment loading
  integration (that `load_platform_fragments` reads them into `UI_CODER_GUIDANCE`,
  `UI_SPECIALIST_CHECKLIST`, `UI_TESTER_PATTERNS`) is never exercised for those two
  platforms. File-presence checks and fragment-loading checks are complementary,
  not interchangeable — a file present on disk but loaded incorrectly would pass
  Section 2 and silently fail in production.
- Severity: MEDIUM
- Action: Add two tests to Section 8: set `UI_PLATFORM="mobile_native_ios"` /
  `"mobile_native_android"` and `UI_PLATFORM_DIR` to the corresponding directory,
  call `load_platform_fragments`, and assert at minimum `[[ -n "$UI_CODER_GUIDANCE" ]]`
  and `[[ -n "$UI_TESTER_PATTERNS" ]]`, mirroring the Flutter test at lines 459-465.

#### COVERAGE: Android empty-project graceful no-op not tested
- File: tests/test_platform_mobile_game.sh (Section 5)
- Issue: Flutter (lines 158-161) and game_web (lines 385-388) both test an empty
  project and assert `DESIGN_SYSTEM` remains unset. The iOS tests implicitly cover
  this (the asset/component tests use projects with no Swift files and DESIGN_SYSTEM
  is not set). Android has no equivalent. The `_detect_android_ui_framework` function
  in `mobile_native_android/detect.sh:40-46` silently exits without setting anything
  when `compose_count=0` and `xml_count=0`, but this path is never exercised.
- Severity: LOW
- Action: Add one test after line 289: `make_proj "android_empty"`,
  `source "${TEKHTON_HOME}/platforms/mobile_native_android/detect.sh"`,
  `[[ -z "$DESIGN_SYSTEM" ]] && pass "Android: empty project → no design system" || fail ...`

#### COVERAGE: `detect_ui_platform` non-UI project path and empty-framework fallback not tested
- File: tests/test_platform_mobile_game.sh (Section 7)
- Issue: Every invocation of `detect_ui_platform` in Section 7 sets
  `UI_PROJECT_DETECTED="true"`. Two branches in `_base.sh` go untested:
  (1) `UI_PROJECT_DETECTED != "true"` at line 92, which clears UI_PLATFORM and
  returns 1; (2) the empty-framework project-type fallback at lines 118-126, which
  maps `PROJECT_TYPE=web-game` → `game_web`, `PROJECT_TYPE=mobile-app` →
  `mobile_flutter`, and anything else → `web`. These are real runtime paths
  (non-UI projects trigger path 1; projects with UI signals but no specific
  framework detected trigger path 2).
- Severity: LOW
- Action: Add to Section 7: (a) set `UI_PROJECT_DETECTED=false`, call
  `detect_ui_platform`, assert `UI_PLATFORM` is empty; (b) set
  `UI_PROJECT_DETECTED=true`, `UI_FRAMEWORK=""`, `PROJECT_TYPE=web-game`,
  call `detect_ui_platform`, assert `UI_PLATFORM="game_web"`.

#### COVERAGE: `source_platform_detect` empty-platform guard path untested
- File: tests/test_platform_m60_integration.sh
- Issue: `source_platform_detect` in `_base.sh:148-175` has an early return
  when `UI_PLATFORM` is empty (`if [[ -z "$platform" ]]; then return; fi`).
  None of the integration tests exercise this path. It is a real runtime path
  triggered when detect_ui_platform finds no matching framework and returns 1.
- Severity: LOW
- Action: Add one test in the integration file: `make_proj "no_platform"`,
  set `UI_PLATFORM=""`, call `source_platform_detect`, assert `DESIGN_SYSTEM`
  remains unset.

### No Issues Found

#### INTEGRITY
None. All 76 assertions across both files verify real outputs from real function
calls against real fixture data created in `TEST_TMPDIR`. No hard-coded expected
values that bypass implementation logic. No tautological assertions.
Content-specific string checks in Section 8 of `test_platform_mobile_game.sh`
("Game Loop", "Frame budget", "Headless") were verified against the actual prompt
file contents — all three strings appear verbatim in
`platforms/game_web/coder_guidance.prompt.md`, `specialist_checklist.prompt.md`,
and `tester_patterns.prompt.md` respectively.
The integration test Section 5 `&&...|| fail` compound assertions were traced
through both true and false paths: when `DESIGN_SYSTEM_CONFIG` is empty, `fail`
is correctly invoked (not silently skipped). The load_platform_fragments step 7
appends DESIGN_SYSTEM_CONFIG and COMPONENT_LIBRARY_DIR literally into
UI_CODER_GUIDANCE, confirming the assertions at lines 206-213 of the integration
test are non-trivial.

#### EXERCISE
None. Every section sources actual implementation scripts without mocking.
`lib/detect.sh` is pre-sourced to provide `_extract_json_keys` and `_check_dep`
(documented dependencies of `game_web/detect.sh` per its header comment, line 9) —
this is a required dependency load, not a mock substitution. All four platform
detect.sh files and `_base.sh` are exercised directly by sourcing them and
observing their side effects on globals. The integration tests additionally
exercise the two-stage pipeline: `detect_ui_platform` → `source_platform_detect`,
and the three-stage pipeline: `detect_ui_platform` → `source_platform_detect` →
`load_platform_fragments`.

#### WEAKENING
None. Both test files are newly created (untracked `??` in git status per
TESTER_REPORT). No prior test functions exist that could have been modified or
weakened.

#### NAMING
None. All pass/fail messages encode both the scenario and the expected outcome,
e.g.: "Flutter: MaterialApp → material", "iOS: storyboards tip to UIKit",
"Android: Material3 from themes.xml", "Resolve: jetpack-compose → mobile_native_android",
"iOS tie: equal counts → SwiftUI wins (swiftui_count -ge uikit_count)",
"Override: user override detect applied (COMPONENT_LIBRARY_DIR=/custom/override/path)".
Messages are specific enough to diagnose a failure without reading the test body.

#### SCOPE
None. All sourced paths were verified to exist (confirmed via glob and file reads).
No references to deleted files (watchtower-inbox notes, or any other deleted file).
All tested functions — `detect_ui_platform` (_base.sh:74),
`source_platform_detect` (_base.sh:147), `load_platform_fragments` (_base.sh:182),
and the four detect.sh scripts — match the M60 implementation files in the `??`
untracked list.
