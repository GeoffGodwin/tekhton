## Web-Specific Review Checklist

### CSS Specificity Management
- No `!important` cascading. Styles don't leak between components. CSS module
  or scoped styles used consistently.

### SSR / Hydration Correctness
- If the project uses SSR (Next.js, Nuxt, SvelteKit), verify no hydration
  mismatches. No `window`/`document` access during server render without guards.
  Dynamic content handled with client-only wrappers.

### Bundle Impact
- New dependencies are justified. No full-library imports when tree-shakeable
  alternatives exist (e.g., `import { Button } from '@mui/material'`
  not `import * as MUI`).

### Progressive Enhancement
- Core functionality works without JavaScript where feasible. Form submissions
  have server-side handling if applicable.

### SEO Considerations
- Pages have appropriate `<title>`, `<meta description>`, heading hierarchy.
  Dynamic routes have meaningful URLs.

### Asset Optimization
- Images have alt text and appropriate dimensions. Fonts loaded with
  `font-display: swap` or equivalent. No render-blocking resources in
  critical path.
