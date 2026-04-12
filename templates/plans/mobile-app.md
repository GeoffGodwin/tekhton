# Design Document — Mobile App

<!-- Generated from sections below -->

## Developer Philosophy & Constraints
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What are your non-negotiable architectural rules? Examples: -->
<!-- - Offline-first: every screen must render meaningful content without network -->
<!-- - Platform-native feel: animations, gestures, and navigation must match OS conventions -->
<!-- - Accessibility mandatory: every interactive element has accessibility labels from day one -->
<!-- - Thin views: screens are dumb containers, all logic lives in view models/controllers -->
<!-- - Config-driven: feature flags, API URLs, and thresholds live in remote config -->
<!-- What patterns must every contributor follow from day one? What anti-patterns are banned? -->

## Project Overview
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What does this app do? Who is it for? What problem does it solve? -->
<!-- Is this a consumer app, B2B tool, or internal enterprise app? -->
<!-- What existing app or workflow does this replace? -->
<!-- What is the monetization model? (free, freemium, subscription, one-time purchase, ads) -->
<!-- What is the expected user base at launch? At scale? -->

## Tech Stack
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Platform approach: native iOS (Swift/UIKit/SwiftUI), native Android (Kotlin/Compose), -->
<!-- cross-platform (React Native, Flutter, Kotlin Multiplatform, .NET MAUI)? Why? -->
<!-- State management: Redux, MobX, Riverpod, Provider, SwiftUI @Observable, Compose State? -->
<!-- Networking: Retrofit, Alamofire, Dio, Axios, native URLSession/OkHttp? -->
<!-- Local storage: SQLite, Realm, Core Data, Room, Hive, SharedPreferences/UserDefaults? -->
<!-- Navigation: React Navigation, GoRouter, UIKit coordinators, Jetpack Navigation? -->
<!-- CI/CD: Fastlane, Bitrise, GitHub Actions, App Center? -->
<!-- Testing: XCTest, JUnit, widget tests, integration tests, Detox, Appium? -->
<!-- Analytics/crash reporting: Firebase, Sentry, Amplitude, Mixpanel? -->

## Target Platforms & Requirements
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- iOS minimum version: iOS 16? iOS 17? Why? -->
<!-- Android minimum API level: API 26 (8.0)? API 28 (9.0)? Why? -->
<!-- Tablet support: required, adaptive layout, or phone-only? -->
<!-- Device orientation: portrait-only, landscape-only, or both? -->
<!-- Wearable support: watchOS, Wear OS? -->
<!-- Foldable device support? Large screen optimization? -->
<!-- What percentage of target users does each minimum version cover? -->

## Screens & Navigation
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- List every screen as a ### sub-section. For each screen: -->
<!-- - Purpose: what does the user accomplish here? -->
<!-- - Data displayed: what information is shown? Source? -->
<!-- - Interactive elements: buttons, inputs, lists, swipeable areas -->
<!-- - Navigation: what screens can the user reach from here? How? (tap, swipe, back) -->
<!-- - Loading states: what does the screen show while data loads? -->
<!-- - Empty states: what does the screen show when there is no data? -->
<!-- - Error states: what does the screen show when data fails to load? -->
<!-- Navigation pattern: tab bar, drawer, stack, or combination? -->
<!-- Deep link support: which screens are reachable via URL? -->
<!-- Example sub-sections: ### Home, ### Profile, ### Settings, ### Detail View -->

## Core Features
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- List each major feature as a ### sub-section. For each: -->
<!-- - User story: "As a [role], I want to [action] so that [benefit]" -->
<!-- - Behavior: step-by-step from user action to result -->
<!-- - Edge cases: no network, empty data, concurrent actions, backgrounded app -->
<!-- - Platform differences: does this behave differently on iOS vs Android? -->
<!-- - Dependencies: what other features, APIs, or permissions does this need? -->
<!-- - Configurable values: what should be tunable? (timeouts, limits, thresholds) -->

## Data Model & Local Storage
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- What data does the app store locally? For each entity: -->
<!-- - Fields, types, and relationships -->
<!-- - Source: API response, user input, or computed? -->
<!-- - Storage: database table, key-value store, or file? -->
<!-- - Sync strategy: how is local data kept in sync with the server? -->
<!-- - Conflict resolution: what happens if local and server data diverge? -->
<!-- - Cache policy: TTL, LRU, or manual invalidation? -->
<!-- Maximum local storage budget? (e.g., "app should use less than 50MB on device") -->

## API & Networking
<!-- PHASE:2 -->
<!-- Backend API: REST, GraphQL, gRPC, or other? Base URL pattern? -->
<!-- Authentication: how does the app authenticate API calls? Token refresh flow? -->
<!-- Request/response patterns: what serialization format? Error response structure? -->
<!-- Retry policy: which requests are retried? How many times? Backoff? -->
<!-- Request cancellation: what happens when the user navigates away mid-request? -->
<!-- Background requests: what happens when the app is backgrounded during a request? -->
<!-- Offline queue: are failed writes queued for retry when connectivity returns? -->
<!-- Certificate pinning: is it used? How is the pin managed? -->

## Authentication & User Management
<!-- PHASE:2 -->
<!-- Sign-in methods: email/password, social auth (Google, Apple, Facebook), SSO, biometrics? -->
<!-- Session management: token storage (Keychain/Keystore), refresh flow, expiry handling -->
<!-- Account creation: what is the sign-up flow? Required fields? Verification? -->
<!-- Account recovery: password reset, account lock, support escalation? -->
<!-- Biometric auth: Face ID, Touch ID, fingerprint? When is it prompted? -->
<!-- Multi-device: can the user be signed in on multiple devices? Session limits? -->
<!-- Guest mode: can the app be used without an account? What is limited? -->

## Offline Behavior & Sync
<!-- PHASE:2 -->
<!-- What features work offline? What is degraded? What is unavailable? -->
<!-- How does the app detect connectivity changes? -->
<!-- Offline data: what data is available offline? How much is pre-fetched? -->
<!-- Sync strategy: full sync, delta sync, or event-based? -->
<!-- Conflict resolution: last-write-wins, merge, or prompt user? -->
<!-- Sync indicators: does the user see sync status? Where? -->
<!-- Background sync: does the app sync data when backgrounded? -->

## Push Notifications
<!-- PHASE:2 -->
<!-- What events trigger push notifications? List each notification type. -->
<!-- For each type: trigger, title template, body template, action on tap -->
<!-- Notification channels (Android): what categories? User-configurable? -->
<!-- Rich notifications: images, action buttons, inline replies? -->
<!-- Notification permissions: when is the user prompted? What if they decline? -->
<!-- Silent notifications: used for background data refresh? -->
<!-- Local notifications: any scheduled or triggered locally? -->

## Permissions & System Access
<!-- PHASE:2 -->
<!-- List every system permission the app requests: -->
<!-- - Camera, photo library, microphone, location, contacts, notifications, etc. -->
<!-- For each: when requested, why needed, what happens if denied -->
<!-- Progressive permission requests: ask only when the feature is first used? -->
<!-- How does the app gracefully degrade when a permission is denied? -->
<!-- Platform differences: iOS permission strings vs Android manifest permissions -->

## UI/UX Design System
<!-- PHASE:2 -->
<!-- Design system: custom, Material Design, Human Interface Guidelines, or hybrid? -->
<!-- Component library: built-in widgets, custom design system, or third-party? -->
<!-- Typography: font family, scale, dynamic type support -->
<!-- Color system: light/dark mode, color tokens, accessibility contrast ratios -->
<!-- Spacing and layout: grid system, consistent spacing scale -->
<!-- Animation: spring physics, duration standards, reduced-motion support -->
<!-- Haptic feedback: what actions trigger haptics? Intensity? -->

## App Lifecycle & Background
<!-- PHASE:2 -->
<!-- What happens when the app is backgrounded? Foregrounded? Killed? -->
<!-- Background tasks: what work continues in the background? (sync, uploads, location) -->
<!-- State preservation: is the screen state restored on relaunch? -->
<!-- Deep links: URL scheme and/or Universal Links / App Links? -->
<!-- Widget support: home screen widgets? What data do they show? -->
<!-- Shortcut actions: 3D Touch / long-press shortcuts from the app icon? -->

## Performance & Optimization
<!-- PHASE:2 -->
<!-- App launch time target: cold start under Xs, warm start under Ys -->
<!-- Memory budget: maximum memory usage (e.g., under 150MB) -->
<!-- App size budget: download size and installed size targets -->
<!-- Image loading: lazy loading, caching (Kingfisher, Glide, CachedNetworkImage)? -->
<!-- List rendering: recycling (RecyclerView, LazyColumn, FlatList)? -->
<!-- Network efficiency: request batching, compression, pagination? -->
<!-- Battery impact: what features are battery-intensive? Mitigation? -->

## Config Architecture
<!-- REQUIRED -->
<!-- PHASE:3 -->
<!-- What values MUST live in config rather than hardcoded? -->
<!-- Local config: build variants, plist/gradle config, .env files? -->
<!-- Remote config: Firebase Remote Config, custom endpoint, or similar? -->
<!-- Show example config with actual keys and default values: -->
<!-- ```json -->
<!-- { -->
<!--   "api_base_url": "https://api.myapp.com/v1", -->
<!--   "session_timeout_seconds": 1800, -->
<!--   "max_offline_cache_mb": 50, -->
<!--   "feature_flag_new_onboarding": false, -->
<!--   "min_password_length": 8, -->
<!--   "push_notification_enabled": true -->
<!-- } -->
<!-- ``` -->
<!-- What is the config override hierarchy? (build config → remote config → user settings) -->
<!-- How quickly do remote config changes take effect? -->

## Documentation Strategy
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- What documentation does this project ship? (README only, README + docs/ site, in-app help) -->
<!-- Where is documentation hosted? (GitHub, GitHub Pages, ReadTheDocs, Notion) -->
<!-- What surfaces must be documented? (screens, deep links, API contracts, config keys, permissions) -->
<!-- On every feature change, which docs must be updated in the same commit? -->
<!-- Is doc freshness strict (block the merge) or warn-only? -->
<!-- Any auto-generation tooling? (dartdoc, jazzy, KDoc, Storybook for React Native) -->

## Testing Strategy
<!-- PHASE:3 -->
<!-- Unit tests: what logic is unit tested? View models, services, utilities? -->
<!-- Widget/UI tests: which components have UI tests? -->
<!-- Integration tests: which user flows have full integration tests? -->
<!-- E2E tests: Detox, Appium, XCUITest, Espresso? Which flows are covered? -->
<!-- Snapshot tests: UI snapshot regression tests? -->
<!-- Device matrix: what devices and OS versions are tested? -->
<!-- CI integration: tests run on every PR? What blocks merge? -->

## App Store & Distribution
<!-- PHASE:3 -->
<!-- App Store Connect / Google Play Console setup -->
<!-- App review: what might reviewers flag? How to handle rejections? -->
<!-- Beta distribution: TestFlight, Firebase App Distribution, internal tracks? -->
<!-- Release cadence: weekly, biweekly, monthly? -->
<!-- Version numbering: semver, build numbers, marketing versions? -->
<!-- Update strategy: force update for breaking changes? In-app update prompts? -->

## Naming Conventions
<!-- PHASE:3 -->
<!-- Code naming: per-platform conventions (Swift camelCase, Kotlin camelCase, Dart camelCase) -->
<!-- File naming: per-platform conventions -->
<!-- Asset naming: image assets, color assets, localization keys -->
<!-- Deep link paths: URL scheme naming -->
<!-- Analytics event naming: snake_case, category prefixes? -->
<!-- What domain terms map to what code concepts? -->

## Open Design Questions
<!-- REQUIRED -->
<!-- PHASE:3 -->
<!-- What decisions are you deliberately deferring? -->
<!-- What needs user testing before you can decide? -->
<!-- Example: "Unsure if tab bar or drawer navigation is better — A/B test after launch" -->
<!-- Example: "Offline sync complexity TBD — start with read-only cache, add write-back later" -->
<!-- List each open question with the information needed to resolve it. -->

## What Not to Build Yet
<!-- PHASE:3 -->
<!-- What features are explicitly deferred? -->
<!-- For each: what it is, why it's deferred, what milestone might add it -->
<!-- Example: "Wearable companion app — phone app must be stable first" -->
<!-- Example: "Social features — core utility must prove value before adding social" -->
