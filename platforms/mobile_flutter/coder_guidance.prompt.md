## Flutter-Specific Coder Guidance

### Widget Composition
- Prefer composition over inheritance. Use `const` constructors wherever possible
  to enable widget caching. Extract widget subtrees into separate widget classes
  when they exceed ~50 lines or are reused. Avoid deeply nested widget trees —
  extract into named methods or widgets at 4+ nesting levels.

### Theme Usage
- Always use `Theme.of(context)` for colors, text styles, and shapes. Never
  hardcode `Color(0xFF...)` or `TextStyle(fontSize: ...)` when a theme token
  exists. Use `ColorScheme` semantic colors (`primary`, `onPrimary`, `surface`,
  etc.) not raw palette values.

### State Management
- Follow the project's established state management pattern. Don't introduce a
  second state management library. Keep widget state local when it doesn't need
  to be shared. Use `ValueNotifier`/`ValueListenableBuilder` for simple local state.

### Adaptive Layout
- Use `LayoutBuilder` and `MediaQuery` for responsive layouts. Support both
  portrait and landscape if the app allows rotation. Use `SafeArea` to respect
  system UI intrusions. Test on smallest supported device size (typically 320dp wide).

### Accessibility
- Set `Semantics` widgets on custom interactive elements. Provide `semanticLabel`
  on `Icon` widgets. Ensure touch targets are at least 48x48dp. Use
  `ExcludeSemantics` to remove decorative elements from the accessibility tree.
  Test with `SemanticsDebugger` or TalkBack/VoiceOver.

### Performance
- Avoid `setState` on large widget subtrees — scope rebuilds narrowly. Use `const`
  widgets to prevent unnecessary rebuilds. Avoid allocations in `build()` — move
  to `initState()` or use cached values. Lazy-load list items with
  `ListView.builder`, not `ListView(children: [...])`.
