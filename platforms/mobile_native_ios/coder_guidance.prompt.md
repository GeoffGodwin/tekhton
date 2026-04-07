## iOS-Specific Coder Guidance

### SwiftUI Idioms
- Prefer `@State` for view-local state, `@ObservedObject`/`@StateObject` for
  shared state. Use `ViewModifier` for reusable style combinations. Prefer
  `LazyVStack`/`LazyHStack` for lists. Use `@Environment` for system values
  (color scheme, size class, accessibility).

### UIKit Idioms
- Subclass sparingly. Use Auto Layout (programmatic or IB). Delegate pattern for
  communication up. Avoid massive view controllers — extract into child view
  controllers or separate concerns.

### Human Interface Guidelines
- Use SF Symbols for icons (specify rendering mode). Respect Dynamic Type — use
  `preferredFont(forTextStyle:)` or `.font(.body)` in SwiftUI. Support Dark
  Mode — use semantic colors from asset catalogs. Respect safe areas. Use standard
  navigation patterns (NavigationStack, TabView, sheets).

### Accessibility
- Set `accessibilityLabel` on all interactive and meaningful elements. Group
  related elements with `accessibilityElement(children: .combine)`. Support
  VoiceOver gestures. Ensure Dynamic Type works up to AX5. Use
  `accessibilityAction` for custom interactions.

### Adaptive Layout
- Use size classes for iPad vs iPhone layouts. Support Split View on iPad. Use
  `GeometryReader` sparingly — prefer layout priorities and flexible frames.
