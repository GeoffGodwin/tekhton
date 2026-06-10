#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# init_config_workspace.sh — Workspace/service section emitter
#
# Extracted from init_config_sections.sh to keep that file under the 300-line
# ceiling. Sourced by init_config_sections.sh — do not run directly.
# Provides: _emit_section_workspace, _emit_provider_section
# =============================================================================

# _emit_provider_section — V5 m12 provider selection block.
# Emits PROVIDER=codex,claude default and commented per-stage overrides.
_emit_provider_section() {
    cat << 'EOF'

# === Provider Selection (V5 m12) ============================================
# Cost-ranked: Codex (subscription/free) first, Claude (API) as fallback.
# NOTE (m15 upgrade): default changed from implicit Claude-only to codex,claude.
# To restore Claude-only behavior: PROVIDER=claude
PROVIDER=codex,claude

# Per-stage overrides (uncomment to enable):
# PROVIDER_intake=
# PROVIDER_coder=
# PROVIDER_security=
# PROVIDER_review=
# PROVIDER_tester=
# PROVIDER_architect=
# PROVIDER_docs=
# PROVIDER_cleanup=
EOF
}

# _emit_section_workspace — Emits project structure config if monorepo detected.
_emit_section_workspace() {
    local workspaces="${_INIT_WORKSPACES:-}"
    local services="${_INIT_SERVICES:-}"
    local workspace_scope="${_INIT_WORKSPACE_SCOPE:-}"

    local project_structure="single"
    if [[ -n "$workspaces" ]]; then
        project_structure="monorepo"
    elif [[ -n "$services" ]]; then
        local svc_count
        svc_count=$(echo "$services" | grep -c '.' || echo "0")
        [[ "$svc_count" -gt 1 ]] && project_structure="multi-service"
    fi

    # Only emit if non-trivial structure detected
    if [[ "$project_structure" != "single" ]]; then
        echo ""
        echo "# --- Project structure -------------------------------------------------------"
        echo "PROJECT_STRUCTURE=\"${project_structure}\""

        if [[ -n "$workspaces" ]]; then
            local ws_type
            ws_type=$(echo "$workspaces" | head -1 | cut -d'|' -f1)
            echo "WORKSPACE_TYPE=\"${ws_type}\""
            if [[ -n "$workspace_scope" ]] && [[ "$workspace_scope" != "root" ]]; then
                echo "# WORKSPACE_SCOPE=\"${workspace_scope}\""
            fi
        fi

        if [[ -n "$services" ]]; then
            echo "# Detected services:"
            local name dir tech source
            while IFS='|' read -r name dir tech source; do
                [[ -z "$name" ]] && continue
                echo "# SERVICE: ${name} -> ${dir} (${tech}, detected from ${source})"
            done <<< "$services"
        fi
    fi
}
