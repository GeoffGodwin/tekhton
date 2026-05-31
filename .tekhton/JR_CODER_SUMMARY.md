## What Was Fixed

- **`engine.go:229-231` — removed `doubleQuotedRe`**: Package-level `var` declared but never referenced anywhere in the package or tests. Removed to resolve staticcheck U1000.
- **`engine.go:389-397` — removed `jsonString()`**: Unexported method on `*Context` that was never called from production code or any test file. Removed to resolve staticcheck U1000.
- **`engine.go` import — removed `"encoding/json"`**: Became unused after `jsonString()` was deleted.

## Files Modified

- `internal/diagnose/engine.go`
