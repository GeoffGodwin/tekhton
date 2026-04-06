## Android-Specific Review Checklist

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
