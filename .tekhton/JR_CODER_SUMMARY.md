## What Was Fixed

- `internal/stages/intake/context.go:137` — Replaced `notes.ExtractFromProject(cfg.ProjectDir, notes.ExtractOpts{})` with a direct load from the already-resolved `notesPath` using `notes.Load(notesPath)` + `notes.Extract(d, notes.ExtractOpts{})`. This eliminates the ambient `HUMAN_NOTES_FILE` env-var dependency inside `ExtractFromProject` and ensures the function uses the correct, already-resolved path from `cfg.HumanNotesFile` in all environments (production and test).

## Files Modified

- `internal/stages/intake/context.go`
