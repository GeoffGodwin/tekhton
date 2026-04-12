## Summary
This change addresses 7 open non-blocking notes across four files: `lib/milestone_acceptance.sh` (grep portability and pattern broadening), `lib/notes_core_normalize.sh` (awk fence-handler fix), `tests/test_notes_normalization.sh` (test assertion update), and `lib/prompts.sh` (documentation comment only). None of the changes involve authentication, cryptography, network communication, or direct user input handling. All file-path variables are properly double-quoted throughout. The changes carry no new HIGH or CRITICAL attack surface.

## Findings
- [LOW] [category:A04] [lib/notes_core_normalize.sh:27] fixable:yes — The tempfile created by `mktemp` is not cleaned up if the process is interrupted after `mktemp` but before `mv "$tmpfile" "$file"` completes (e.g. SIGKILL or disk-full abort). The orphaned file in `TEKHTON_SESSION_DIR`/`/tmp` contains only markdown content — no credentials or sensitive data — making this a resource-leak concern rather than a data-exposure risk. Fix: add `trap 'rm -f "$tmpfile"' RETURN ERR` immediately after the `mktemp` call.

## Verdict
CLEAN
