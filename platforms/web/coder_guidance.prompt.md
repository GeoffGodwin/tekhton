## Web-Specific Coder Guidance

### CSS & Styling
- Use the project's CSS methodology. If Tailwind: use utility classes, avoid
  `@apply` for one-off styles, use theme values (`text-primary`, `bg-surface`)
  not raw hex/rgb. If CSS modules: scope styles to components. If styled-components
  or CSS-in-JS: colocate styles with components.
- Never use `!important` unless overriding a third-party library.
- Use relative units (`rem`, `em`, `%`, `vw/vh`) over absolute `px` for layout.
  `px` is acceptable for borders, shadows, and icon sizes.
- Responsive: mobile-first with `min-width` breakpoints. Use the project's
  breakpoint system (Tailwind config, CSS variables, or framework breakpoints).
  Test at 375px (mobile), 768px (tablet), 1280px (desktop) minimum.

### Component Patterns
- React: functional components with hooks. Props interface defined with TypeScript
  types. Forward refs on interactive components. Use `children` for composition.
- Vue: Single File Components with `<script setup>` (Vue 3) or Options API matching
  project convention. Scoped styles. Props with type validation.
- Svelte: Component props with `export let`. Reactive declarations. Scoped styles
  by default.
- Angular: Component decorator with appropriate change detection. Input/Output
  decorators. OnPush when possible.
- Use the project's state management pattern. Don't introduce a new state library.

### Web Accessibility (WCAG 2.1 AA)
- Semantic HTML: `<button>` for actions, `<a>` for navigation, `<nav>`, `<main>`,
  `<article>`, `<section>` with accessible names.
- Form inputs: `<label>` elements associated with inputs. Error messages linked
  with `aria-describedby`. Required fields marked with `aria-required`.
- Focus management: visible focus indicators on all interactive elements. Focus
  moves logically with tabbing. Focus trapped in modals. Focus restored on
  modal close.
- Dynamic content: `aria-live` regions for async updates. Loading states
  announced to screen readers. Route changes announced.
- Color: do not convey information through color alone. Minimum 4.5:1 contrast
  for normal text, 3:1 for large text.

### Performance
- Lazy-load routes and heavy components. Use dynamic `import()` for code splitting.
- Images: use `loading="lazy"`, provide `width`/`height` or aspect ratio, use
  appropriate format (WebP with fallback).
- Avoid layout shift: reserve space for async content (skeleton screens, fixed
  dimensions on media elements).
