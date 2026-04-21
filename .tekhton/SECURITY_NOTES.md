# Security Notes

Generated: 2026-04-21 17:52:35

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A03] [lib/milestone_split_dag.sh:77-78] fixable:yes — `sub_file` is constructed as `"${sub_id}-${sub_slug}.md"` where `sub_slug` comes from `_slugify "$sub_title"` and `sub_title` is extracted directly from LLM-generated split output (BASH_REMATCH[3] of the heading regex). The write `echo "$sub_block" > "${milestone_dir}/${sub_file}"` relies entirely on `_slugify` stripping path separators. `sub_id` is safe (printf-formatted from a digit-only regex match). Suggested fix: add an explicit path-traversal guard such as `[[ "$sub_file" == */* ]] && return 1` before the write to make safety unconditional.
