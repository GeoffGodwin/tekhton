# Security Notes

Generated: 2026-04-19 18:47:41

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A03] [lib/output_format.sh:237] fixable:yes — `_out_json_escape` does not escape JSON control characters U+0000–U+0008, U+000B, U+000C, U+000E–U+001F. If a message string contains raw control characters (e.g. from a coder agent that embeds terminal control bytes in its output), `_OUT_CTX[action_items]` will contain invalid JSON that could cause the TUI Python sidecar to fail silently. Fix: add a `tr -d '\x00-\x08\x0b\x0c\x0e-\x1f'` pass or strip individual ranges with bash parameter expansion.
- [LOW] [category:A03] [lib/output_format.sh:227] fixable:yes — `sev` is embedded unescaped into the JSON fragment in `_out_append_action_item`: `"severity\":\"${sev}\"`. Current callers only pass hardcoded literals (`normal`, `warning`, `critical`), so this is latent rather than active. A future caller passing a computed severity string could corrupt the JSON array. Fix: route `$sev` through `_out_json_escape` as well.
- [LOW] [category:A03] [lib/init_helpers_display.sh:34,43,53] fixable:yes — `echo -e` is used to render IFS-split fields (`$lang`, `$manifest`, `$fw`, `$cmd_type`, `$cmd`) derived from filesystem path names and manifest file contents. A project directory whose path components contain `echo -e` escape sequences (e.g. `\n`, `\x1b[...m`) could produce garbled stderr display output. Risk is display-only to stderr; no data is written to files or evaluated. Fix: switch to `printf '%s\n'` throughout, consistent with the rest of the new output module.
