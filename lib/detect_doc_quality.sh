#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# detect_doc_quality.sh — Documentation quality assessment (Milestone 12)
#
# Produces a 0-100 quality score from README, contributing guides, API docs,
# architecture docs, and inline doc density. The score is a heuristic used to
# tune synthesis behavior, not a gate.
#
# Sourced by tekhton.sh — do not run directly.
# Provides: assess_doc_quality()
# =============================================================================

# assess_doc_quality — Evaluates documentation quality for a project.
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Output: Single line: DOC_QUALITY_SCORE|DETAILS
#   Score is 0-100. Details is a semicolon-separated list of findings.
assess_doc_quality() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"
    local score=0
    local details=""

    # --- README (0-30 points) ---
    local readme_score=0
    local readme_file=""
    for candidate in README.md README.rst README.txt README; do
        [[ -f "$proj_dir/$candidate" ]] && { readme_file="$proj_dir/$candidate"; break; }
    done

    if [[ -n "$readme_file" ]]; then
        local readme_lines
        readme_lines=$(wc -l < "$readme_file" 2>/dev/null | tr -d '[:space:]')
        readme_score=5  # exists

        if [[ "$readme_lines" -gt 20 ]]; then
            readme_score=10  # substantial
        fi
        if [[ "$readme_lines" -gt 100 ]]; then
            readme_score=15  # detailed
        fi

        # Has sections?
        local section_count
        section_count=$(grep -cE '^#+\s|^=+$|^-+$' "$readme_file" 2>/dev/null || echo "0")
        if [[ "$section_count" -ge 3 ]]; then
            readme_score=$((readme_score + 5))
        fi

        # Has code examples?
        if grep -q '```' "$readme_file" 2>/dev/null || grep -q '    ' "$readme_file" 2>/dev/null; then
            readme_score=$((readme_score + 5))
        fi

        # Has install/setup instructions?
        if grep -qiE 'install|setup|getting.started|quick.start' "$readme_file" 2>/dev/null; then
            readme_score=$((readme_score + 5))
        fi

        [[ "$readme_score" -gt 30 ]] && readme_score=30
        details="readme:${readme_score}/30"
    else
        details="readme:0/30(missing)"
    fi
    score=$((score + readme_score))

    # --- Contributing / Development guides (0-15 points) ---
    local contrib_score=0
    for candidate in CONTRIBUTING.md DEVELOPMENT.md docs/CONTRIBUTING.md docs/DEVELOPMENT.md \
                     docs/contributing.md docs/development.md .github/CONTRIBUTING.md; do
        if [[ -f "$proj_dir/$candidate" ]]; then
            local lines
            lines=$(wc -l < "$proj_dir/$candidate" 2>/dev/null | tr -d '[:space:]')
            contrib_score=5
            [[ "$lines" -gt 30 ]] && contrib_score=10
            [[ "$lines" -gt 100 ]] && contrib_score=15
            break
        fi
    done
    score=$((score + contrib_score))
    details="${details};contributing:${contrib_score}/15"

    # --- API documentation (0-15 points) ---
    local api_score=0
    # OpenAPI/Swagger specs
    for candidate in openapi.yaml openapi.json swagger.yaml swagger.json \
                     api/openapi.yaml docs/openapi.yaml; do
        if [[ -f "$proj_dir/$candidate" ]]; then
            api_score=10
            break
        fi
    done

    # Generated docs directories
    for candidate in docs/api docs/generated site/api apidocs; do
        if [[ -d "$proj_dir/$candidate" ]]; then
            api_score=$((api_score + 5))
            break
        fi
    done

    [[ "$api_score" -gt 15 ]] && api_score=15
    score=$((score + api_score))
    details="${details};api-docs:${api_score}/15"

    # --- Architecture documentation (0-20 points) ---
    local arch_score=0
    for candidate in ARCHITECTURE.md docs/ARCHITECTURE.md docs/architecture.md \
                     docs/design.md ${DESIGN_FILE:-}; do
        if [[ -f "$proj_dir/$candidate" ]]; then
            local lines
            lines=$(wc -l < "$proj_dir/$candidate" 2>/dev/null | tr -d '[:space:]')
            arch_score=10
            [[ "$lines" -gt 100 ]] && arch_score=15
            [[ "$lines" -gt 300 ]] && arch_score=20
            break
        fi
    done

    # ADRs (Architecture Decision Records)
    if [[ -d "$proj_dir/docs/adr" ]] || [[ -d "$proj_dir/docs/ADR" ]] || [[ -d "$proj_dir/adr" ]]; then
        local adr_count
        adr_count=$(find "$proj_dir/docs/adr" "$proj_dir/docs/ADR" "$proj_dir/adr" \
            -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d '[:space:]')
        if [[ "$adr_count" -gt 0 ]]; then
            arch_score=$((arch_score + 5))
        fi
    fi

    [[ "$arch_score" -gt 20 ]] && arch_score=20
    score=$((score + arch_score))
    details="${details};architecture:${arch_score}/20"

    # --- Inline documentation density (0-20 points) ---
    local inline_score=0
    inline_score=$(_assess_inline_docs "$proj_dir")
    score=$((score + inline_score))
    details="${details};inline:${inline_score}/20"

    # Clamp
    [[ "$score" -gt 100 ]] && score=100
    [[ "$score" -lt 0 ]] && score=0

    echo "${score}|${details}"
}

# _assess_inline_docs — Sample source files for documentation density.
# Returns: score 0-20
_assess_inline_docs() {
    local proj_dir="$1"
    local total_files=0
    local documented_files=0

    # Sample up to 10 source files from top 2 levels
    local sample_files
    if git -C "$proj_dir" rev-parse --git-dir &>/dev/null; then
        sample_files=$(git -C "$proj_dir" ls-files 2>/dev/null | \
            grep -E '\.(py|ts|js|go|rs|java|rb|cs|kt|swift)$' | \
            head -10)
    else
        sample_files=$(find "$proj_dir" -maxdepth 3 -type f \
            \( -name "*.py" -o -name "*.ts" -o -name "*.js" -o -name "*.go" \
               -o -name "*.rs" -o -name "*.java" -o -name "*.rb" \) \
            -not -path "*/node_modules/*" -not -path "*/.git/*" \
            -not -path "*/vendor/*" 2>/dev/null | head -10)
    fi

    [[ -z "$sample_files" ]] && { echo 0; return 0; }

    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local full_path="$proj_dir/$f"
        [[ ! -f "$full_path" ]] && full_path="$f"
        [[ ! -f "$full_path" ]] && continue

        total_files=$((total_files + 1))

        # Check for docstrings/JSDoc/godoc/rustdoc patterns
        if grep -qE '"""|/\*\*|///|#\s+[A-Z].*\.|// [A-Z].*\.' "$full_path" 2>/dev/null; then
            documented_files=$((documented_files + 1))
        fi
    done <<< "$sample_files"

    [[ "$total_files" -eq 0 ]] && { echo 0; return 0; }

    local ratio=$(( (documented_files * 100) / total_files ))
    if [[ "$ratio" -ge 80 ]]; then echo 20
    elif [[ "$ratio" -ge 60 ]]; then echo 15
    elif [[ "$ratio" -ge 40 ]]; then echo 10
    elif [[ "$ratio" -ge 20 ]]; then echo 5
    else echo 0
    fi
}
