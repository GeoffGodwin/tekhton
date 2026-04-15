# Fish completion for tekhton
# Install: copy to ~/.config/fish/completions/tekhton.fish

# Disable file completions by default
complete -c tekhton -f

# Getting Started
complete -c tekhton -l init -d 'Smart init: detect stack, generate config + agent roles'
complete -c tekhton -l reinit -d 'Re-initialize (destructive)'
complete -c tekhton -l plan -d 'Interactive planning: build DESIGN.md + CLAUDE.md'
complete -c tekhton -l replan -d 'Delta-based update to existing plan'
complete -c tekhton -l plan-from-index -d 'Synthesize docs from PROJECT_INDEX.md'

# Running
complete -c tekhton -l milestone -d 'Milestone mode: higher turn limits'
complete -c tekhton -l auto-advance -d 'Auto-advance through milestones'
complete -c tekhton -l draft-milestones -d 'Interactive milestone authoring flow'
complete -c tekhton -l complete -d 'Loop mode: repeat until done or bounds hit'
complete -c tekhton -l start-at -d 'Resume from specific stage' -xa 'intake coder security review tester test'
complete -c tekhton -l human -d 'Pick next unchecked note as task' -xa 'BUG FEAT POLISH'

# Inspection
complete -c tekhton -l status -d 'Print saved pipeline state'
complete -c tekhton -l progress -d 'Show milestone progress at a glance'
complete -c tekhton -l metrics -d 'Print run metrics dashboard'
complete -c tekhton -l diagnose -d 'Diagnose last failure with recovery suggestions'
complete -c tekhton -l report -d 'Print summary of last pipeline run'
complete -c tekhton -l health -d 'Run project health assessment'

# Maintenance
complete -c tekhton -l rescan -d 'Incrementally update PROJECT_INDEX.md'
complete -c tekhton -l migrate -d 'Upgrade project config' -xa '--check --status --rollback --dag'
complete -c tekhton -l update -d 'Check for and install updates'
complete -c tekhton -l uninstall -d 'Remove Tekhton installation'
complete -c tekhton -l setup-completion -d 'Install shell completions'

# Advanced
complete -c tekhton -l skip-security -d 'Bypass security stage for this run'
complete -c tekhton -l no-commit -d 'Skip auto-commit'
complete -c tekhton -l skip-audit -d 'Skip architect audit'
complete -c tekhton -l force-audit -d 'Force architect audit'
complete -c tekhton -l notes-filter -d 'Inject only tagged notes' -xa 'BUG FEAT POLISH'
complete -c tekhton -l init-notes -d 'Create blank HUMAN_NOTES.md template'
complete -c tekhton -l seed-contracts -d 'Seed inline system contracts'
complete -c tekhton -l usage-threshold -d 'Pause if session usage exceeds N%'
complete -c tekhton -l fix -d 'Run fix subcommand' -xa 'nb drift'
complete -c tekhton -l setup-indexer -d 'Set up Python virtualenv for indexer'
complete -c tekhton -l with-lsp -d 'Also install Serena LSP server'
complete -c tekhton -l docs -d 'Open documentation site in browser'

# Short flags
complete -c tekhton -s v -d 'Print version'
complete -c tekhton -s h -d 'Show help'
