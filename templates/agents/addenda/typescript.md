
## TypeScript Stack Notes

- Prefer strict TypeScript (`strict: true` in tsconfig). Avoid `any` — use `unknown` + type guards.
- Use named exports over default exports for better refactoring support.
- Prefer `interface` for object shapes and `type` for unions/intersections.
- Flag circular dependencies between modules — they cause subtle runtime issues.
- Check for unused imports and dead code (`noUnusedLocals`, `noUnusedParameters`).
