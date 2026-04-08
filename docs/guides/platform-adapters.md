# UI Platform Adapters

Tekhton's UI platform adapters give the pipeline first-class understanding of
the platform you're targeting. Web, Flutter, native iOS, native Android, and
browser game engines each get their own detection logic, coder guidance,
specialist review checklist, and tester patterns. The pipeline auto-detects
which adapter to use, but you can pin one explicitly if auto-detection picks
the wrong target.

This replaced the previous web-centric hardcoded `{{IF:UI_PROJECT_DETECTED}}`
prompt blocks with a clean per-platform fragment system delivered in milestones
M57–M60.

## Why Adapters Exist

A senior coder building a Tailwind + React app and a senior coder building a
Flutter app need very different guidance. Hard-coding "use Tailwind utility
classes for spacing" into the universal coder prompt either wastes tokens on
Flutter projects or actively misleads them. Adapters solve this by injecting
only the platform-relevant guidance into each agent's prompt.

The same logic applies to specialist review (a11y rules differ between web and
mobile), tester patterns (Playwright vs Flutter integration tests vs XCUITest),
and detection (Tailwind config vs `pubspec.yaml` vs `Package.swift`).

## Available Adapters

| Adapter | Platform | Detects |
|---------|----------|---------|
| `web` | Web (React, Vue, Svelte, Angular, etc.) | Tailwind, MUI, Chakra, shadcn/ui, daisyUI, Bootstrap, Bulma, UnoCSS, Ant Design, Vuetify, Element Plus, Headless UI, Radix |
| `mobile_flutter` | Flutter | `pubspec.yaml`, Material/Cupertino widgets, GoRouter, Riverpod, Bloc |
| `mobile_native_ios` | Native iOS | `Package.swift`, Xcode projects, SwiftUI, UIKit |
| `mobile_native_android` | Native Android | `build.gradle(.kts)`, Jetpack Compose, XML layouts |
| `game_web` | Browser game engines | Phaser, PixiJS, Three.js, Babylon.js |

A `_universal` fragment set provides cross-platform guidance that's always
included alongside the active adapter.

## Configuration

```bash
# Auto-detect (default) — Tekhton picks the adapter based on detected stack
UI_PLATFORM=auto

# Or pin explicitly to one of:
UI_PLATFORM=web
UI_PLATFORM=mobile_flutter
UI_PLATFORM=mobile_native_ios
UI_PLATFORM=mobile_native_android
UI_PLATFORM=game_web
```

Auto-detection runs during the standard detection pass and walks adapters in
priority order. Native iOS and Android beat web (a project with both an
iOS app and a webhook handler is still primarily an iOS project), and Flutter
beats native (a Flutter project may have a `Package.swift` for the iOS shell).

If detection finds nothing — say, a pure CLI tool or backend service — no
adapter is loaded and the universal fragments handle the (minimal) UI guidance.

## What Each Adapter Provides

Every adapter directory follows the same structure:

```
platforms/<adapter>/
├── detect.sh                    # Stack detection beyond the universal layer
├── coder_guidance.prompt.md     # Coder-specific platform guidance
├── specialist_checklist.prompt.md  # UI/UX specialist review checklist
└── tester_patterns.prompt.md    # Tester patterns and tooling
```

### Coder Guidance

Injected into the coder and rework prompts. Tells the agent the platform
conventions: design tokens vs hardcoded values, accessibility primitives,
responsive behavior, state management patterns. The web adapter includes
design-system-specific snippets — if you're on Tailwind, the coder gets
Tailwind utilities; if you're on MUI, it gets MUI Box/Stack primitives.

### Specialist Checklist

Drives the UI/UX specialist reviewer (M59) — a new specialist alongside
security, performance, and API. The checklist covers:

- **Web**: WCAG 2.1 AA, semantic HTML, focus management, responsive
  breakpoints, color contrast, design system consistency
- **Flutter**: Semantics widgets, Material vs Cupertino consistency, dark mode,
  text scaling, platform conventions
- **Native iOS**: Dynamic Type, VoiceOver labels, HIG compliance, light/dark
  appearance
- **Native Android**: TalkBack labels, Material 3 theming, dark mode, WCAG via
  AccessibilityNodeInfo
- **Game web**: Input handling, performance budgets, asset preloading,
  resolution-independent layout

### Tester Patterns

Tells the tester which testing tools and patterns are conventional for the
platform: Playwright/Cypress for web, `flutter_test` and integration tests
for Flutter, XCUITest for iOS, Espresso for Android, headless game test
harnesses for game engines.

## The UI/UX Specialist (M59)

Before M59, specialist review covered security, performance, and API contracts
but had no UI-aware reviewer. The UI specialist closes that gap and is enabled
automatically whenever a UI platform is detected.

```bash
SPECIALIST_UI_ENABLED=auto       # auto, true, or false (default: auto)
SPECIALIST_UI_MAX_TURNS=8
SPECIALIST_UI_MODEL=             # Defaults to CLAUDE_STANDARD_MODEL
```

When `auto`, the specialist runs only if `UI_PLATFORM` is set (or detected).
Set to `true` to force-enable, `false` to skip even on UI projects.

## Extending or Overriding an Adapter

Adapters live in `${TEKHTON_HOME}/platforms/`, but Tekhton also looks in
`${PROJECT_DIR}/.claude/platforms/<name>/` for project-specific overrides.
This lets you customize an adapter without forking Tekhton:

```
your-project/
└── .claude/
    └── platforms/
        └── web/
            └── coder_guidance.prompt.md   # Overrides built-in
```

Drop just the files you want to override. Files you don't override fall
through to the built-in adapter. You can also create entirely new
`custom_*` platforms in your project's `.claude/platforms/` directory and
pin them with `UI_PLATFORM=custom_yourname`.

## When Auto-Detection Picks the Wrong Adapter

If detection misses or guesses wrong (e.g., a Flutter project that wraps a
WebView and gets detected as web), pin the adapter explicitly:

```bash
# In .claude/pipeline.conf
UI_PLATFORM=mobile_flutter
```

Then re-run. The pin survives across runs and overrides auto-detection.

## What's Next?

- [Pipeline Stages](../reference/stages.md) — Where the UI specialist runs
- [Configuration Reference](../reference/configuration.md#ui-platform-adapters) — All adapter config keys
- [Security Configuration](security-config.md) — Specialist review framework
