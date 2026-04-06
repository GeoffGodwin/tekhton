## Android Testing Patterns

### Compose Testing
- `composeTestRule.setContent {}` for component mounting. `onNodeWithText`,
  `onNodeWithContentDescription`, `onNodeWithTag` for element discovery.
  `performClick()`, `performTextInput()` for interactions. `assertIsDisplayed()`,
  `assertTextEquals()` for assertions.

### Espresso (XML Layouts)
- `onView(withId(R.id.x))` for element discovery. `perform(click())`,
  `perform(typeText())` for interactions. `check(matches(isDisplayed()))` for
  assertions. Use `IdlingResource` for async operations.

### Screenshot Tests
- Use Compose Preview Screenshot Testing or Paparazzi for visual regression.

### State Testing
- Verify loading composable shows during data fetch. Error composable renders on
  failure. Empty state composable when list is empty. Snackbar/Toast shown on
  action completion.

### Anti-Patterns
- Don't use `Thread.sleep` — use `waitUntil` or `IdlingResource`. Don't test
  internal Compose state — test visible behavior. Don't hardcode resource IDs
  that may change.
