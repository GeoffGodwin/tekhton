## Summary
M80 adds the `--draft-milestones` interactive authoring flow: two new library files
(`draft_milestones.sh`, `draft_milestones_write.sh`), a prompt template, two test
files, and minor wiring in `tekhton.sh`, `config_defaults.sh`, and
`dashboard_emitters.sh`. The change introduces no authentication, cryptography, or
network communication. All shell variables handling external input are quoted. The
octal-safe arithmetic fix (`10#$num`) is correct. Three low-severity observations are
noted; none block the pipeline.

## Findings
- [LOW] [category:A03] [lib/draft_milestones_write.sh:133-136] fixable:yes — `$title` extracted from a milestone file via `grep | sed` is appended verbatim to the pipe-delimited MANIFEST.cfg (`echo "m${id}|${title}|..."`). A title containing `|` would corrupt manifest column parsing downstream (`IFS='|'` reads). Fix: strip pipe characters before interpolation — `title="${title//|/}"`.
- [LOW] [category:A03] [lib/draft_milestones.sh:87] fixable:yes — `head -"$count"` where `$count="${DRAFT_MILESTONES_SEED_EXEMPLARS:-3}"`. `_clamp_config_value` enforces an upper bound but does not enforce the value is numeric. A non-integer config value would pass through to `head` as a malformed flag. Fix: add `[[ "$count" =~ ^[0-9]+$ ]] || count=3` before the `find` pipeline.
- [LOW] [category:A03] [lib/draft_milestones.sh:143-144] fixable:unknown — The CLI seed argument is passed unvalidated to `get_repo_map_slice "$slice_keywords"`. If the indexer Python tool constructs shell commands from this argument, it could be a command-injection vector. Risk is low: (a) developer-facing tool requiring shell access; (b) call uses `|| true` so failures are non-fatal. Verify `get_repo_map_slice` passes the argument as data only.
- [LOW] [category:A03] [lib/draft_milestones.sh:138] fixable:yes — `export DRAFT_SEED_DESCRIPTION="${seed}"` where `$seed` is raw CLI input, rendered directly into the LLM prompt via `{{DRAFT_SEED_DESCRIPTION}}`. A crafted seed string could attempt prompt injection. For an internal developer tool this risk is acceptable, but the prompt template should label this block as untrusted input.

## Verdict
FINDINGS_PRESENT
