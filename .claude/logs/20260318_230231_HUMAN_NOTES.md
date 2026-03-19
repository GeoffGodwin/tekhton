# Human Notes

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.

Prefix each note with a priority tag so the pipeline can scope runs correctly:
- `[BUG]` — something is broken, needs fixing before new features
- `[FEAT]` — new mechanic or system, architectural work
- `[POLISH]` — visual/UX improvement, no logic changes


## Features
None currently.

## Bugs
None currently.

## Polish
- [ ] [POLISH] "The Generating" message is a really nice feature we should be using when any of the agents are working. Currently while a claude model is running we don't reflect that to the user in the CLI. We should add a CLI indicator to show when an agent is actively generating content so that users are aware that the pipeline is processing. Let's keep the animating dot pattern we use now for consistency but let's change the message to which Agent is working (e.g. "Coder is generating...") so that it's more informative to the user.