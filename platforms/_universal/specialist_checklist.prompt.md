## UI/UX Review Checklist

Review each category below. Flag violations as CHANGES_REQUIRED with specific
file and line references.

### 1. Component Structure & Reusability
- Components have clear single responsibility.
- Props/parameters are typed where the language supports it.
- No god-components doing everything.

### 2. Design System / Token Consistency
- Uses project design tokens for colors, spacing, typography.
- No hardcoded values that bypass the design system.

### 3. Responsive / Adaptive Behavior
- Layout adapts correctly to supported viewport sizes.
- No horizontal overflow.
- Touch targets meet minimum size (44x44pt iOS, 48x48dp Android, 44x44px web).

### 4. Accessibility
- Semantic structure (headings, landmarks, roles).
- Keyboard/gesture navigable.
- Screen reader labels on interactive elements.
- Sufficient color contrast.
- Focus management on navigation/modal changes.

### 5. State Presentation
- Loading, error, and empty states are handled.
- No unhandled promise/future rejections that produce blank screens.

### 6. Interaction Patterns
- Form validation provides inline feedback.
- Modals/sheets trap focus and support dismiss.
- Navigation is consistent with platform conventions.

### 7. Visual Hierarchy & Layout Consistency
- Heading levels are sequential.
- Spacing follows a consistent rhythm.
- Typography scale matches project conventions.

### 8. Platform Convention Adherence
- Follows platform-specific guidelines (HIG for iOS, Material for Android,
  WCAG for web, engine best practices for games).
