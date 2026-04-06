## Web Game-Specific Review Checklist

1. **Frame budget compliance** — No blocking operations in update/render loops.
   Heavy computations deferred or chunked.
2. **Resource lifecycle** — Assets loaded during appropriate scene. Resources
   cleaned up on scene exit. No memory leaks from orphaned event listeners
   or unreferenced objects.
3. **Configuration externalization** — Gameplay values are configurable, not
   hardcoded. Balance changes don't require code changes.
4. **Input robustness** — Multiple input methods supported. No hardcoded key
   codes (use named actions). Input works on mobile browsers if touch supported.
5. **Game state integrity** — State transitions are explicit (menu, playing,
   paused, game over). Pause/resume works correctly. Game state is serializable
   for save/load if applicable.
