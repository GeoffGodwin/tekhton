## iOS-Specific Review Checklist

1. **HIG compliance** — SF Symbols used for standard actions. System colors
   and Dynamic Type respected. Standard navigation patterns followed.
2. **Memory management** — No strong reference cycles in closures (use
   `[weak self]`). Image caching appropriate. Large assets not held in memory.
3. **Main thread safety** — UI updates on `@MainActor` or `DispatchQueue.main`.
   No blocking calls on main thread.
4. **Localization readiness** — User-facing strings use `LocalizedStringKey` or
   `NSLocalizedString`. No hardcoded string dimensions. RTL layout supported.
5. **Dark Mode** — All custom colors have dark mode variants. No hardcoded
   colors that fail in dark mode.
