## Flutter Testing Patterns

### Widget Tests
- Use `testWidgets` and `WidgetTester`. Pump widgets with
  `pumpWidget(MaterialApp(home: YourWidget()))`. Use `find.byType`, `find.text`,
  `find.byKey` for element discovery. Verify state changes with `tester.tap()`
  + `tester.pump()`.

### Integration Tests
- Use `integration_test` package. Test full user flows (navigate, interact,
  verify). Use `binding.setSurfaceSize()` for responsive testing.

### Golden Tests
- Use `matchesGoldenFile` for visual regression on critical components. Generate
  goldens with `--update-goldens`.

### State Testing Patterns
- Verify loading indicator shows during async operations (`tester.pump()` between
  states). Verify error widgets render on exception. Verify empty state widget
  when data list is empty.

### Anti-Patterns
- Don't test Flutter framework behavior. Don't assert on render object properties.
  Don't use `find.byWidget` (fragile). Don't hardcode pixel positions.
