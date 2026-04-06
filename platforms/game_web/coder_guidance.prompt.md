## Web Game-Specific Coder Guidance

### Game Loop Discipline
- Never perform I/O, DOM manipulation, or heavy computation inside the
  render/update loop. Pre-compute in scene load or use worker threads. Budget
  frame time (16.6ms at 60fps).

### Scene / State Management
- Use the engine's scene system. Clean up resources on scene exit (remove event
  listeners, destroy sprites, clear timers). Separate game logic from rendering —
  game rules should be testable without a canvas.

### Asset Management
- Preload assets during a loading scene. Use texture atlases/sprite sheets, not
  individual images. Cache frequently used assets. Display loading progress to
  the player.

### Configuration
- All tunable values (speeds, costs, timers, spawn rates) must be in
  configuration objects, not hardcoded in logic. This enables balancing without
  code changes.

### Input Handling
- Support both keyboard and mouse/touch (where applicable). Use the engine's
  input system, not raw DOM events. Map logical actions to physical inputs
  (allows rebinding). Handle simultaneous inputs correctly.

### Performance
- Use object pooling for frequently created/destroyed objects (bullets, particles,
  enemies). Minimize draw calls (batch rendering, sprite sheets). Use the engine's
  camera culling — don't render off-screen objects. Profile with browser DevTools
  Performance tab.
