# Security Notes

Generated: 2026-04-22 22:32:21

## Non-Blocking Findings (MEDIUM/LOW)
- [LOW] [category:A01] [lib/milestone_split_dag.sh:81] fixable:yes — The new `*/*` guard correctly blocks filenames containing a `/` (including `../relative` patterns), but does not explicitly reject the degenerate case of a bare `..` with no slash. Writing to `${milestone_dir}/..` would fail at the OS level (it is a directory, not a file) so no actual traversal is possible, but adding `|| [[ "$sub_file" == ".." ]]` to the guard makes the defensive intent self-documenting and robust against any OS edge case.
