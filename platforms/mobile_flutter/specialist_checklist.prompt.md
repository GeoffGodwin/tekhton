## Flutter-Specific Review Checklist

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
