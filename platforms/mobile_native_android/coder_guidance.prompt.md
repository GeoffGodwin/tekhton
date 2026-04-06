## Android-Specific Coder Guidance

### Compose Idioms
- Stateless composables preferred — hoist state to callers. Use `remember` and
  `rememberSaveable` for local state. Use `LazyColumn`/`LazyRow` for lists
  (never `Column` with `forEach` for dynamic lists). Use `Modifier` parameter
  as first optional parameter in all composable signatures.

### Material Design Compliance
- Use Material3 theme tokens (`MaterialTheme.colorScheme`,
  `MaterialTheme.typography`, `MaterialTheme.shapes`). Follow Material component
  patterns (TopAppBar, NavigationBar, FAB placement). Use `contentColor` and
  `containerColor` semantics.

### Accessibility
- Provide `contentDescription` on images and icons. `Modifier.semantics` for
  custom components. `Modifier.clickable` sets touch target to 48dp minimum
  automatically. Ensure `mergeDescendants` on meaningful groupings. Support
  TalkBack navigation.

### Adaptive Layout
- Use `WindowSizeClass` for phone/tablet/desktop layouts. Support foldable
  devices with Accompanist adaptive layouts or Jetpack WindowManager. Use
  `BoxWithConstraints` for adaptive composables.

### XML Layouts (if applicable)
- ConstraintLayout for complex layouts. `match_parent`/`wrap_content` over fixed
  dimensions. `@dimen` resources for reusable dimensions. Style resources for
  repeated styling.
