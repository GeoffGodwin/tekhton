## Web Game Testing Patterns

### Unit Tests for Game Logic
- Test game rules, scoring, collision detection, economy calculations
  independently of the renderer. Mock the engine's event system if needed.

### Scene Lifecycle Tests
- Verify scene loads without errors. Verify scene transitions work (menu, game,
  game over, menu). Verify resources are cleaned up on scene exit.

### Input Tests
- Simulate key/mouse/touch events through the engine's test utilities (if
  available) or through dispatching synthetic DOM events. Verify game responds
  correctly to input sequences.

### Configuration Tests
- Verify game works with modified config values (boundary testing: zero values,
  negative values, very large values).

### Headless Rendering
- Phaser supports headless mode with `Phaser.HEADLESS`. Use this for CI.
  Three.js can render to off-screen canvas. Verify no console errors during a
  game loop cycle.

### Anti-Patterns
- Don't test frame-by-frame visual output (flaky). Don't test animation timing
  (environment-dependent). Don't test random outcomes without seeding RNG. Don't
  test engine internals.
