# Bash completion for tekhton
# Install: copy to /etc/bash_completion.d/ or ~/.local/share/bash-completion/completions/

_tekhton() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # All flags
    opts="--init --reinit --plan --replan --plan-from-index --rescan
          --status --progress --diagnose --report --metrics --version --docs --help
          --milestone --auto-advance --draft-milestones --complete --dry-run --continue-preview
          --start-at --skip-security --no-commit --skip-audit --force-audit
          --notes-filter --init-notes --seed-contracts --human
          --usage-threshold --fix
          --migrate --setup-indexer --with-lsp --health
          --setup-completion --update --uninstall"

    case "$prev" in
        --start-at)
            COMPREPLY=( $(compgen -W "intake coder security review tester test" -- "$cur") )
            return 0
            ;;
        --notes-filter)
            COMPREPLY=( $(compgen -W "BUG FEAT POLISH" -- "$cur") )
            return 0
            ;;
        --human)
            COMPREPLY=( $(compgen -W "BUG FEAT POLISH" -- "$cur") )
            return 0
            ;;
        --fix)
            COMPREPLY=( $(compgen -W "nb drift" -- "$cur") )
            return 0
            ;;
        --migrate)
            COMPREPLY=( $(compgen -W "--check --status --rollback --dag" -- "$cur") )
            return 0
            ;;
        --rescan)
            COMPREPLY=( $(compgen -W "--full" -- "$cur") )
            return 0
            ;;
        --init)
            COMPREPLY=( $(compgen -W "--full" -- "$cur") )
            return 0
            ;;
        --update)
            COMPREPLY=( $(compgen -W "--check" -- "$cur") )
            return 0
            ;;
        --help)
            COMPREPLY=( $(compgen -W "--all" -- "$cur") )
            return 0
            ;;
        note)
            COMPREPLY=( $(compgen -W "--tag --help" -- "$cur") )
            return 0
            ;;
        --tag)
            COMPREPLY=( $(compgen -W "BUG FEAT POLISH" -- "$cur") )
            return 0
            ;;
    esac

    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
        return 0
    fi

    # Default: no completion for task descriptions
    return 0
}

complete -F _tekhton tekhton
complete -F _tekhton tekhton.sh
