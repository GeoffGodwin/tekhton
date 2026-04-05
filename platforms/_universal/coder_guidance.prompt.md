### State Presentation
Every view, screen, or component that fetches data MUST handle loading, error,
and empty states. No blank screens while data loads. Provide meaningful feedback
for each state.

### Accessibility Floor
- Use semantic elements/widgets over generic containers (e.g., `<button>` not
  `<div onclick>`, `Semantics` widget not plain `Container`).
- Every interactive element must be reachable via keyboard/gesture navigation.
- Provide text alternatives for images and icons.
- Ensure sufficient color contrast (WCAG AA minimum: 4.5:1 for text, 3:1 for
  large text and UI components).
- Support screen reader announcements for dynamic content changes.

### Component Composition
- Prefer small, reusable components with clear prop/parameter interfaces.
- Separate data fetching from presentation.
- Avoid prop drilling beyond 2 levels — use context, provider, or state
  management patterns appropriate to the framework.

### Adaptive Layout
- Design for the narrowest supported viewport first.
- Use the project's existing breakpoint/layout system — do not invent new
  breakpoints.
- Ensure touch targets meet minimum platform sizes (44x44pt iOS, 48x48dp
  Android, 44x44px web).

### Design System Adherence
If a design system is detected, use its tokens, components, and patterns.
Do not use raw color values, pixel sizes, or custom components when the
design system provides an equivalent.
