## UI Testing Guidance

This project has a user interface. When the milestone creates or modifies UI
components, write E2E tests that verify rendering and interaction — not just logic.

### Decision Tree
1. Does this milestone create or modify UI components (pages, forms, dialogs, navigation)?
   - **Yes** → Write E2E tests for the changed components (see patterns below)
   - **No** → Skip UI tests; write unit/integration tests as usual

### Common UI Test Patterns
- **Page loads without errors**: Navigate to URL, assert no console errors, key elements visible
- **Critical elements visible**: Assert headings, buttons, forms render with expected text
- **Form submission**: Fill inputs, submit, verify success state or error messages
- **Navigation**: Click links/buttons, verify URL change and destination content
- **Interactive elements**: Click buttons, toggle switches, expand accordions — verify state changes
- **Responsive breakpoints**: Test at mobile (375px) and desktop (1280px) widths if layout changes

### Anti-Patterns (avoid these)
- Do NOT test CSS class names or DOM structure — test user-visible behavior
- Do NOT assert exact pixel positions — assert element visibility and content
- Do NOT mock the UI framework itself — mock only external API calls
- Do NOT write tests that depend on animation timing

{{IF:UI_FRAMEWORK}}
### Framework-Specific Guidance: {{UI_FRAMEWORK}}
{{ENDIF:UI_FRAMEWORK}}
{{IF:UI_FRAMEWORK_IS_PLAYWRIGHT}}
**Playwright:**
```typescript
import { test, expect } from '@playwright/test';
test('page loads and shows heading', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('h1')).toBeVisible();
  // Check no console errors
  const errors: string[] = [];
  page.on('console', msg => { if (msg.type() === 'error') errors.push(msg.text()); });
  expect(errors).toHaveLength(0);
});
```
- Use `page.locator()` with accessible roles: `page.getByRole('button', { name: 'Submit' })`
- Use `await expect(...).toBeVisible()` instead of `waitForSelector`
- Run with: `{{UI_TEST_CMD}}`
{{ENDIF:UI_FRAMEWORK_IS_PLAYWRIGHT}}
{{IF:UI_FRAMEWORK_IS_CYPRESS}}
**Cypress:**
```javascript
describe('Page load', () => {
  it('renders without errors', () => {
    cy.visit('/');
    cy.get('h1').should('be.visible');
  });
  it('form submits successfully', () => {
    cy.get('input[name="email"]').type('test@example.com');
    cy.get('button[type="submit"]').click();
    cy.contains('Success').should('be.visible');
  });
});
```
- Use `cy.contains()` and `cy.get('[data-testid=...]')` over CSS selectors
- Run with: `{{UI_TEST_CMD}}`
{{ENDIF:UI_FRAMEWORK_IS_CYPRESS}}
{{IF:UI_FRAMEWORK_IS_SELENIUM}}
**Selenium:**
- Use explicit waits (`WebDriverWait`) instead of `time.sleep()`
- Locate elements by accessible name or test ID, not XPath
- Run with: `{{UI_TEST_CMD}}`
{{ENDIF:UI_FRAMEWORK_IS_SELENIUM}}
{{IF:UI_FRAMEWORK_IS_PUPPETEER}}
**Puppeteer:**
- Use `page.waitForSelector()` before assertions
- Prefer `page.$eval()` for extracting text content
- Run with: `{{UI_TEST_CMD}}`
{{ENDIF:UI_FRAMEWORK_IS_PUPPETEER}}
{{IF:UI_FRAMEWORK_IS_TESTING_LIBRARY}}
**Testing Library:**
```javascript
import { render, screen, fireEvent } from '@testing-library/react';
test('renders heading', () => {
  render(<MyComponent />);
  expect(screen.getByRole('heading')).toBeInTheDocument();
});
```
- Use `screen.getByRole()`, `screen.getByText()`, `screen.getByLabelText()`
- Never query by class name or tag — test accessible behavior
- Run with: `{{UI_TEST_CMD}}`
{{ENDIF:UI_FRAMEWORK_IS_TESTING_LIBRARY}}
{{IF:UI_FRAMEWORK_IS_DETOX}}
**Detox (mobile):**
- Use `element(by.id('testID'))` for reliable element selection
- Use `waitFor(element(...)).toBeVisible().withTimeout(5000)`
- Run with: `{{UI_TEST_CMD}}`
{{ENDIF:UI_FRAMEWORK_IS_DETOX}}
{{IF:UI_FRAMEWORK_IS_GENERIC}}
No specific E2E framework detected. Consider adding Playwright for web UI testing:
```bash
npm init playwright@latest
```
Write tests that verify pages load, forms submit, and navigation works. Use
whatever test runner is available (`{{TEST_CMD}}`).
{{ENDIF:UI_FRAMEWORK_IS_GENERIC}}

### State Management UI
- Assert loading spinner/skeleton is visible during data fetch.
- Verify error message renders on API failure.
- Confirm empty state component shows when data array is empty.
- Test optimistic UI updates revert on failure if applicable.

### Modal / Dialog Behavior
- Focus moves into modal on open.
- Escape key closes the modal.
- Click-outside closes the modal (if applicable to the pattern).
- Focus returns to the trigger element on close.
- Background scroll is locked while modal is open.

### Keyboard Navigation
- Tab order follows visual order.
- Enter/space activates buttons and links.
- Arrow keys navigate within menus and listboxes.
- Escape closes dropdowns and overlays.

### Focus Management
- After route change, focus moves to main content or page title.
- After modal close, focus returns to the trigger element.
- Skip-to-content link is present and functional.

### Responsive Behavior
- Test at mobile (375px) and desktop (1280px) viewports.
- Navigation collapses to mobile menu at narrow widths.
- Content reflows without horizontal scroll.
- Touch targets meet minimum 44x44px size.
