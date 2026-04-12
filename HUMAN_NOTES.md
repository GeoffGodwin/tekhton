# Human Notes
<!-- notes-format: v2 -->
<!-- IDs are auto-managed by Tekhton. Do not remove note: comments. -->

Add your observations below as unchecked items. The pipeline will inject
unchecked items into the next coder run and archive them when done.

Use `- [ ]` for new notes. Use `- [x]` to mark items you want to defer/skip.

Prefix each note with a priority tag so the pipeline can scope runs correctly:
- `[BUG]` — something is broken, needs fixing before new features
- `[FEAT]` — new mechanic or system, architectural work
- `[POLISH]` — visual/UX improvement, no logic changes

## Features

## Bugs
- [ ] [BUG] Add early bash version guard in tekhton.sh. Insert a
      BASH_VERSINFO check immediately after `set -euo pipefail`
      (before the EXIT trap at line 131 and before common.sh is
      sourced at line 324). Must use bash-3.2-compatible syntax
      only. On failure, print a friendly message with macOS
      Homebrew install instructions, then `exit 1` with
      _TEKHTON_CLEAN_EXIT=true so the crash banner doesn't fire.
      Repro: run any tekhton.sh subcommand under /bin/bash on
      macOS — currently crashes with "declare: -g: invalid
      option" at lib/common.sh:162 instead of a useful error.

- [ ] [BUG] Promote install.sh:125 bash-version warning to a hard
      fail on macOS. Currently warns but continues, letting users
      land in a broken state. `fail` (not `warn`) when
      BASH_VERSINFO[0] < 4 and PLATFORM=macos.

- [ ] [BUG] README.md lies about macOS being zero-setup. Update
      README.md:102 Requirements line to flag that macOS needs
      `brew install bash`, with a link to
      docs/getting-started/installation.md#macos. Add a one-line
      "macOS users" callout at the top of the Quick Start section
      (line 113). Also reconcile the stated bash floor across
      README.md ("4+"), CLAUDE.md ("4.3+"), and
      docs/getting-started/installation.md ("4.0 or later") —
      pick 4.3+ everywhere. Do NOT duplicate the full install
      steps in the README; the docs page is authoritative.


## Polish
