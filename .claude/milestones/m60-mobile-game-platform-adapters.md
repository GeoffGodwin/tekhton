# Milestone 60: Mobile & Game Platform Adapters
<!-- milestone-meta
id: "60"
status: "pending"
-->

## Overview

Milestone 57 established the platform adapter framework and M58 populated the
web adapter. This milestone delivers four additional platform adapters covering
the most common non-web UI platforms: Flutter, iOS (SwiftUI/UIKit), Android
(Jetpack Compose/XML), and browser-based game engines (Phaser, PixiJS, Three.js,
Babylon.js).

Each adapter follows the same 4-file convention: `detect.sh` for design system
detection, `coder_guidance.prompt.md` for implementation guidance,
`specialist_checklist.prompt.md` for review criteria, and
`tester_patterns.prompt.md` for test patterns.

Depends on Milestone 57. Parallel-safe with M58 and M59.

## Scope

### 1. Flutter Platform Adapter (`platforms/mobile_flutter/`)

**`detect.sh`** — Design system detection for Flutter/Dart projects:

- **Theme system**: Scan `lib/` for `ThemeData` usage. Check `lib/main.dart` (or
  the file containing `runApp`) for `MaterialApp`/`CupertinoApp`. Look for custom
  theme files matching `*theme*.dart`, `*color*.dart`, `*style*.dart` in `lib/`.
  Set `DESIGN_SYSTEM=material` (MaterialApp) or `DESIGN_SYSTEM=cupertino`
  (CupertinoApp). If both, set `DESIGN_SYSTEM=material` (more common).
- **Design tokens**: Look for `ThemeExtension` subclasses (custom semantic tokens).
  Look for `ColorScheme.fromSeed()` or explicit `ColorScheme()` construction.
  Set `DESIGN_SYSTEM_CONFIG` to the file containing the primary theme definition.
- **Widget library**: Check `pubspec.yaml` deps for state management
  (`flutter_bloc`, `riverpod`, `provider`, `get`, `mobx`). Check for custom
  widget directories: `lib/widgets/`, `lib/ui/`, `lib/components/`,
  `lib/presentation/`. Set `COMPONENT_LIBRARY_DIR` to the first found.

**`coder_guidance.prompt.md`** — Flutter-specific coder guidance:

- **Widget composition**: Prefer composition over inheritance. Use `const`
  constructors wherever possible to enable widget caching. Extract widget
  subtrees into separate widget classes when they exceed ~50 lines or are
  reused. Avoid deeply nested widget trees — extract into named methods or
  widgets at 4+ nesting levels.
- **Theme usage**: Always use `Theme.of(context)` for colors, text styles, and
  shapes. Never hardcode `Color(0xFF...)` or `TextStyle(fontSize: ...)` when a
  theme token exists. Use `ColorScheme` semantic colors (`primary`, `onPrimary`,
  `surface`, etc.) not raw palette values.
- **State management**: Follow the project's established state management pattern.
  Don't introduce a second state management library. Keep widget state local when
  it doesn't need to be shared. Use `ValueNotifier`/`ValueListenableBuilder` for
  simple local state.
- **Adaptive layout**: Use `LayoutBuilder` and `MediaQuery` for responsive layouts.
  Support both portrait and landscape if the app allows rotation. Use
  `SafeArea` to respect system UI intrusions. Test on smallest supported device
  size (typically 320dp wide).
- **Accessibility**: Set `Semantics` widgets on custom interactive elements.
  Provide `semanticLabel` on `Icon` widgets. Ensure touch targets are at least
  48x48dp. Use `ExcludeSemantics` to remove decorative elements from the
  accessibility tree. Test with `SemanticsDebugger` or TalkBack/VoiceOver.
- **Performance**: Avoid `setState` on large widget subtrees — scope rebuilds
  narrowly. Use `const` widgets to prevent unnecessary rebuilds. Avoid
  allocations in `build()` — move to `initState()` or use cached values.
  Lazy-load list items with `ListView.builder`, not `ListView(children: [...])`.

**`specialist_checklist.prompt.md`** — Flutter-specific review additions:

1. **Unnecessary widget rebuilds** — `setState` scoped narrowly. `const`
   constructors used. `AnimatedBuilder`/`ValueListenableBuilder` used instead
   of rebuilding the whole subtree.
2. **Platform channel safety** — UI thread not blocked by platform channel calls.
   `compute()` or isolates used for heavy work.
3. **Navigation consistency** — Uses the project's router (GoRouter, auto_route,
   Navigator 2.0). Deep links handled. Back button behavior correct.
4. **Cupertino/Material consistency** — If the app supports both iOS and Android
   looks, adaptive widgets used (`Switch.adaptive`, platform-specific dialogs).
5. **Asset management** — Images in appropriate resolution buckets (1x, 2x, 3x).
   Fonts loaded correctly. No hardcoded asset paths — use generated constants
   if available.

**`tester_patterns.prompt.md`** — Flutter testing patterns:

- **Widget tests**: Use `testWidgets` and `WidgetTester`. Pump widgets with
  `pumpWidget(MaterialApp(home: YourWidget()))`. Use `find.byType`, `find.text`,
  `find.byKey` for element discovery. Verify state changes with `tester.tap()`
  + `tester.pump()`.
- **Integration tests**: Use `integration_test` package. Test full user flows
  (navigate → interact → verify). Use `binding.setSurfaceSize()` for responsive
  testing.
- **Golden tests**: Use `matchesGoldenFile` for visual regression on critical
  components. Generate goldens with `--update-goldens`.
- **State testing patterns**: Verify loading indicator shows during async
  operations (`tester.pump()` between states). Verify error widgets render
  on exception. Verify empty state widget when data list is empty.
- **Anti-patterns**: Don't test Flutter framework behavior. Don't assert on
  render object properties. Don't use `find.byWidget` (fragile). Don't
  hardcode pixel positions.

### 2. iOS Platform Adapter (`platforms/mobile_native_ios/`)

**`detect.sh`** — Design system detection for iOS projects:

- **UI framework**: Scan `.swift` files for `import SwiftUI` → `swiftui`.
  Scan for `UIViewController` subclasses, `.xib`, `.storyboard` files → `uikit`.
  If both present, set `DESIGN_SYSTEM` to whichever has more files.
- **Asset catalog**: Check for `Assets.xcassets/` (always present in iOS projects).
  Check for custom color sets within (`*.colorset/`). Set `DESIGN_SYSTEM_CONFIG`
  to the primary `.xcassets` path.
- **Custom components**: Check for `Views/`, `Screens/`, `Components/` directories
  in the source tree. Check for custom `ViewModifier` files (SwiftUI) or
  reusable `UIView` subclasses (UIKit). Set `COMPONENT_LIBRARY_DIR`.
- **Design patterns**: Check for `ViewModels/` (MVVM pattern), `Coordinators/`
  (coordinator pattern). This informs coder guidance about architecture.

**`coder_guidance.prompt.md`** — iOS-specific coder guidance:

- **SwiftUI idioms**: Prefer `@State` for view-local state, `@ObservedObject`/
  `@StateObject` for shared state. Use `ViewModifier` for reusable style
  combinations. Prefer `LazyVStack`/`LazyHStack` for lists. Use `@Environment`
  for system values (color scheme, size class, accessibility).
- **UIKit idioms**: Subclass sparingly. Use Auto Layout (programmatic or IB).
  Delegate pattern for communication up. Avoid massive view controllers —
  extract into child view controllers or separate concerns.
- **Human Interface Guidelines**: Use SF Symbols for icons (specify rendering
  mode). Respect Dynamic Type — use `preferredFont(forTextStyle:)` or
  `.font(.body)` in SwiftUI. Support Dark Mode — use semantic colors from
  asset catalogs. Respect safe areas. Use standard navigation patterns
  (NavigationStack, TabView, sheets).
- **Accessibility**: Set `accessibilityLabel` on all interactive and meaningful
  elements. Group related elements with `accessibilityElement(children: .combine)`.
  Support VoiceOver gestures. Ensure Dynamic Type works up to AX5. Use
  `accessibilityAction` for custom interactions.
- **Adaptive layout**: Use size classes for iPad vs iPhone layouts. Support
  Split View on iPad. Use `GeometryReader` sparingly — prefer layout
  priorities and flexible frames.

**`specialist_checklist.prompt.md`** — iOS-specific review additions:

1. **HIG compliance** — SF Symbols used for standard actions. System colors
   and Dynamic Type respected. Standard navigation patterns followed.
2. **Memory management** — No strong reference cycles in closures (use
   `[weak self]`). Image caching appropriate. Large assets not held in memory.
3. **Main thread safety** — UI updates on `@MainActor` or `DispatchQueue.main`.
   No blocking calls on main thread.
4. **Localization readiness** — User-facing strings use `LocalizedStringKey` or
   `NSLocalizedString`. No hardcoded string dimensions. RTL layout supported.
5. **Dark Mode** — All custom colors have dark mode variants. No hardcoded
   colors that fail in dark mode.

**`tester_patterns.prompt.md`** — iOS testing patterns:

- **XCTest UI testing**: Use `XCUIApplication` for launch. `XCUIElement` queries
  with `accessibilityIdentifier` (preferred) or `label`. `waitForExistence`
  for async elements. Assert `isHittable` for interactive elements.
- **SwiftUI previews as tests**: Use `#Preview` for visual verification. Preview
  with different color schemes, size classes, and Dynamic Type sizes.
- **Snapshot tests**: Use snapshot testing libraries (e.g., swift-snapshot-testing)
  for visual regression on key screens.
- **State testing**: Verify loading → loaded → error state transitions. Test
  empty states. Test offline behavior. Test with VoiceOver running
  (`XCUIDevice.shared.press(.home)` accessibility shortcut).
- **Anti-patterns**: Don't sleep for fixed durations — use `waitForExistence`.
  Don't test against frame coordinates. Don't test UIKit internal behavior.

### 3. Android Platform Adapter (`platforms/mobile_native_android/`)

**`detect.sh`** — Design system detection for Android projects:

- **UI framework**: Scan for `@Composable` annotations in `.kt` files →
  `compose`. Scan for `res/layout/*.xml` → `xml-layouts`. If both, determine
  majority.
- **Design system**: Check `build.gradle`/`build.gradle.kts` for
  `material3`/`material` dependency. Check for custom theme files:
  `Theme.kt`, `Color.kt`, `Type.kt`, `Shape.kt` in source. Check
  `res/values/colors.xml`, `res/values/themes.xml`, `res/values/styles.xml`.
  Set `DESIGN_SYSTEM=material3` or `DESIGN_SYSTEM=material`.
- **Component directory**: Check for `ui/` package, `composables/` directory,
  `screens/` directory, `components/` directory. Set `COMPONENT_LIBRARY_DIR`.
- **Design tokens**: Set `DESIGN_SYSTEM_CONFIG` to the custom theme file
  (e.g., `ui/theme/Theme.kt`) if found.

**`coder_guidance.prompt.md`** — Android-specific coder guidance:

- **Compose idioms**: Stateless composables preferred — hoist state to callers.
  Use `remember` and `rememberSaveable` for local state. Use `LazyColumn`/
  `LazyRow` for lists (never `Column` with `forEach` for dynamic lists).
  Use `Modifier` parameter as first optional parameter in all composable
  signatures.
- **Material Design compliance**: Use Material3 theme tokens (`MaterialTheme.
  colorScheme`, `MaterialTheme.typography`, `MaterialTheme.shapes`). Follow
  Material component patterns (TopAppBar, NavigationBar, FAB placement). Use
  `contentColor` and `containerColor` semantics.
- **Accessibility**: Provide `contentDescription` on images and icons.
  `Modifier.semantics` for custom components. `Modifier.clickable` sets
  touch target to 48dp minimum automatically. Ensure `mergeDescendants` on
  meaningful groupings. Support TalkBack navigation.
- **Adaptive layout**: Use `WindowSizeClass` for phone/tablet/desktop layouts.
  Support foldable devices with `Accompanist` adaptive layouts or Jetpack
  WindowManager. Use `BoxWithConstraints` for adaptive composables.
- **XML layouts** (if applicable): ConstraintLayout for complex layouts.
  `match_parent`/`wrap_content` over fixed dimensions. `@dimen` resources
  for reusable dimensions. Style resources for repeated styling.

**`specialist_checklist.prompt.md`** — Android-specific review additions:

1. **Material Design adherence** — Material3 tokens used consistently. Standard
   Material components used (no custom reimplementations of standard patterns).
2. **Recomposition efficiency** — No side effects in `@Composable` functions.
   `derivedStateOf` used for computed values. `key()` used in `LazyColumn` items.
   `State` reads scoped to smallest possible composable.
3. **Configuration change handling** — State survives rotation. `rememberSaveable`
   used for user input. ViewModel used for screen state.
4. **Resource management** — Strings in `strings.xml` (not hardcoded). Dimensions
   in `dimens.xml` for reuse. Night-mode resources provided.
5. **Navigation correctness** — Jetpack Navigation or project router used
   consistently. Back stack correct. Deep links handled.

**`tester_patterns.prompt.md`** — Android testing patterns:

- **Compose testing**: `composeTestRule.setContent {}` for component mounting.
  `onNodeWithText`, `onNodeWithContentDescription`, `onNodeWithTag` for
  element discovery. `performClick()`, `performTextInput()` for interactions.
  `assertIsDisplayed()`, `assertTextEquals()` for assertions.
- **Espresso** (XML layouts): `onView(withId(R.id.x))` for element discovery.
  `perform(click())`, `perform(typeText())` for interactions.
  `check(matches(isDisplayed()))` for assertions. Use `IdlingResource` for
  async operations.
- **Screenshot tests**: Use Compose Preview Screenshot Testing or Paparazzi for
  visual regression.
- **State testing**: Verify loading composable shows during data fetch. Error
  composable renders on failure. Empty state composable when list is empty.
  Snackbar/Toast shown on action completion.
- **Anti-patterns**: Don't use `Thread.sleep` — use `waitUntil` or
  `IdlingResource`. Don't test internal Compose state — test visible behavior.
  Don't hardcode resource IDs that may change.

### 4. Web Game Platform Adapter (`platforms/game_web/`)

**`detect.sh`** — Design system detection for browser-based game projects:

- **Engine**: Parse `package.json` deps for: `phaser` → `phaser`, `pixi.js` or
  `@pixi/*` → `pixi`, `three` → `three`, `@babylonjs/core` → `babylon`.
  Set `DESIGN_SYSTEM` to the engine name (used here as "the design framework"
  rather than a visual design system).
- **Asset pipeline**: Check for `assets/`, `public/assets/`, `static/assets/`
  directories. Look for sprite sheets (`.json` + `.png` pairs in assets),
  tilemap files (`*.tmx`, `*.json` with tilemap markers), audio directories.
  Set `DESIGN_SYSTEM_CONFIG` to the game's main config file if identifiable
  (e.g., Phaser's `new Phaser.Game({...})` file).
- **Scene structure**: Check for `scenes/`, `levels/`, `states/` directories.
  Set `COMPONENT_LIBRARY_DIR` to the scenes directory if found.

**`coder_guidance.prompt.md`** — Web game-specific coder guidance:

- **Game loop discipline**: Never perform I/O, DOM manipulation, or heavy
  computation inside the render/update loop. Pre-compute in scene load or
  use worker threads. Budget frame time (16.6ms at 60fps).
- **Scene/state management**: Use the engine's scene system. Clean up resources
  on scene exit (remove event listeners, destroy sprites, clear timers).
  Separate game logic from rendering — game rules should be testable without
  a canvas.
- **Asset management**: Preload assets during a loading scene. Use texture
  atlases/sprite sheets, not individual images. Cache frequently used assets.
  Display loading progress to the player.
- **Configuration**: All tunable values (speeds, costs, timers, spawn rates)
  must be in configuration objects, not hardcoded in logic. This enables
  balancing without code changes.
- **Input handling**: Support both keyboard and mouse/touch (where applicable).
  Use the engine's input system, not raw DOM events. Map logical actions to
  physical inputs (allows rebinding). Handle simultaneous inputs correctly.
- **Performance**: Use object pooling for frequently created/destroyed objects
  (bullets, particles, enemies). Minimize draw calls (batch rendering, sprite
  sheets). Use the engine's camera culling — don't render off-screen objects.
  Profile with browser DevTools Performance tab.

**`specialist_checklist.prompt.md`** — Game-specific review additions:

1. **Frame budget compliance** — No blocking operations in update/render loops.
   Heavy computations deferred or chunked.
2. **Resource lifecycle** — Assets loaded during appropriate scene. Resources
   cleaned up on scene exit. No memory leaks from orphaned event listeners
   or unreferenced objects.
3. **Configuration externalization** — Gameplay values are configurable, not
   hardcoded. Balance changes don't require code changes.
4. **Input robustness** — Multiple input methods supported. No hardcoded key
   codes (use named actions). Input works on mobile browsers if touch supported.
5. **Game state integrity** — State transitions are explicit (menu → playing →
   paused → game over). Pause/resume works correctly. Game state is
   serializable for save/load if applicable.

**`tester_patterns.prompt.md`** — Game testing patterns:

- **Unit tests for game logic**: Test game rules, scoring, collision detection,
  economy calculations independently of the renderer. Mock the engine's
  event system if needed.
- **Scene lifecycle tests**: Verify scene loads without errors. Verify scene
  transitions work (menu → game → game over → menu). Verify resources are
  cleaned up on scene exit.
- **Input tests**: Simulate key/mouse/touch events through the engine's test
  utilities (if available) or through dispatching synthetic DOM events.
  Verify game responds correctly to input sequences.
- **Configuration tests**: Verify game works with modified config values
  (boundary testing: zero values, negative values, very large values).
- **Headless rendering** (if engine supports): Phaser supports headless mode
  with `Phaser.HEADLESS`. Use this for CI. Three.js can render to
  off-screen canvas. Verify no console errors during a game loop cycle.
- **Anti-patterns**: Don't test frame-by-frame visual output (flaky). Don't
  test animation timing (environment-dependent). Don't test random outcomes
  without seeding RNG. Don't test engine internals.

### 5. Self-Tests

Add to `tests/`:

- `test_platform_mobile_game.sh` — Tests:
  - Flutter `detect.sh` identifies `ThemeData`, `MaterialApp`, custom theme files
  - iOS `detect.sh` identifies SwiftUI vs UIKit, asset catalogs
  - Android `detect.sh` identifies Compose vs XML layouts, Material3
  - Game `detect.sh` identifies Phaser, PixiJS, Three.js, Babylon.js from
    mock `package.json` files
  - All `detect.sh` files pass `bash -n` and `shellcheck`
  - All `.prompt.md` files are non-empty and contain expected section headings
  - Platform resolution maps framework names to correct platform directories

## Acceptance Criteria

- [ ] All four platform adapter directories contain `detect.sh`,
      `coder_guidance.prompt.md`, `specialist_checklist.prompt.md`, and
      `tester_patterns.prompt.md`
- [ ] All `detect.sh` files pass `bash -n` and `shellcheck`
- [ ] Flutter adapter correctly detects Material/Cupertino themes, ThemeData
      files, widget directories
- [ ] iOS adapter correctly identifies SwiftUI vs UIKit and asset catalogs
- [ ] Android adapter correctly identifies Compose vs XML layouts and Material3
- [ ] Game adapter correctly identifies Phaser, PixiJS, Three.js, Babylon.js
- [ ] Coder guidance for each platform covers: component patterns, design system
      usage, accessibility, adaptive layout, performance
- [ ] Specialist checklists add platform-specific review items to the universal
      checklist
- [ ] Tester patterns provide framework-specific test examples for each platform
- [ ] Platform adapters integrate correctly with `load_platform_fragments()` from
      M57 (variables are assembled into `UI_CODER_GUIDANCE`,
      `UI_SPECIALIST_CHECKLIST`, `UI_TESTER_PATTERNS`)
- [ ] All existing tests pass
- [ ] New test file `test_platform_mobile_game.sh` passes

## Files Created
- `platforms/mobile_flutter/detect.sh`
- `platforms/mobile_flutter/coder_guidance.prompt.md`
- `platforms/mobile_flutter/specialist_checklist.prompt.md`
- `platforms/mobile_flutter/tester_patterns.prompt.md`
- `platforms/mobile_native_ios/detect.sh`
- `platforms/mobile_native_ios/coder_guidance.prompt.md`
- `platforms/mobile_native_ios/specialist_checklist.prompt.md`
- `platforms/mobile_native_ios/tester_patterns.prompt.md`
- `platforms/mobile_native_android/detect.sh`
- `platforms/mobile_native_android/coder_guidance.prompt.md`
- `platforms/mobile_native_android/specialist_checklist.prompt.md`
- `platforms/mobile_native_android/tester_patterns.prompt.md`
- `platforms/game_web/detect.sh`
- `platforms/game_web/coder_guidance.prompt.md`
- `platforms/game_web/specialist_checklist.prompt.md`
- `platforms/game_web/tester_patterns.prompt.md`
- `tests/test_platform_mobile_game.sh`

## Files Modified
- None (all new files; M57's framework handles loading)
