# Human Action Required

Items identified during review that need manual attention.

## Non-Blocking Notes Follow-up (M74)

1. **Security: Add tmpfile cleanup trap** (`lib/notes_core_normalize.sh:27`)
   - The security agent specified: `trap 'rm -f "$tmpfile"' RETURN ERR` immediately after the `mktemp` call
   - Not applied during coder pass due to scope prioritization
   - Impact: tmpfiles may leak on SIGKILL or disk-full abort
   - Fix: One-line addition. See REVIEWER_REPORT.md for exact specification.

2. **Update agent role files: "Bash 4+" → "Bash 4.3+"** (3 files)
   - `.claude/agents/coder.md:14,29`
   - `.claude/agents/architect.md:15`
   - `.claude/agents/jr-coder.md:14`
   - Impact: Agent guidance documents inconsistent minimum version vs. codebase guards
   - Note: Write permission denied during coder run; requires manual update

3. **Update docs: "Bash 4+" → "Bash 4.3+"** (`docs/analysis/code-indexing-methods-comparison.md:302`)
   - Impact: Documentation inconsistent with version floor enforced in `tekhton.sh` and `install.sh`
   - Note: Captured from CODER_SUMMARY.md Observed Issues

---

Tracked here for visibility. Corresponding NON_BLOCKING_LOG.md item 4 has been reopened (`[ ]`) to track implementation progress.
