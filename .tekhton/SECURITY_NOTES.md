# Security Notes

Generated: 2026-04-24 08:32:16

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A03] [lib/milestone_split_dag.sh:87] fixable:yes — `echo "$sub_block" > "${milestone_dir}/${sub_file}"` writes agent-generated markdown content to disk using bash's `echo` built-in. If the assembled `sub_block` string begins with `-n` or `-e`, bash's `echo` will interpret these as flags, suppressing the trailing newline or enabling escape-sequence expansion, potentially producing a truncated or malformed milestone file. Replace with `printf '%s\n' "$sub_block" > "${milestone_dir}/${sub_file}"` to bypass echo flag interpretation of arbitrary content.
