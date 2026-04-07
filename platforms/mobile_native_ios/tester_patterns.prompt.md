## iOS Testing Patterns

### XCTest UI Testing
- Use `XCUIApplication` for launch. `XCUIElement` queries with
  `accessibilityIdentifier` (preferred) or `label`. `waitForExistence` for async
  elements. Assert `isHittable` for interactive elements.

### SwiftUI Previews as Tests
- Use `#Preview` for visual verification. Preview with different color schemes,
  size classes, and Dynamic Type sizes.

### Snapshot Tests
- Use snapshot testing libraries (e.g., swift-snapshot-testing) for visual
  regression on key screens.

### State Testing
- Verify loading, loaded, and error state transitions. Test empty states. Test
  offline behavior. Test with VoiceOver running.

### Anti-Patterns
- Don't sleep for fixed durations — use `waitForExistence`. Don't test against
  frame coordinates. Don't test UIKit internal behavior.
