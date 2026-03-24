#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# health.sh — Project health scoring engine
#
# Sourced by tekhton.sh — do not run directly.
# Depends on: common.sh, health_checks.sh
# Optional: detect_test_frameworks.sh, detect_ci.sh, detect_doc_quality.sh
#
# Provides:
#   assess_project_health     — Full health assessment, writes HEALTH_REPORT.md
#                                and HEALTH_BASELINE.json
#   reassess_project_health   — Re-assessment with delta from baseline
#   get_health_belt           — Maps score 0-100 to belt label
#   format_health_summary     — One-line summary for prompt injection
# =============================================================================

# Source companion checks file
# shellcheck source=lib/health_checks.sh
source "${TEKHTON_HOME:?}/lib/health_checks.sh"
# shellcheck source=lib/health_checks_infra.sh
source "${TEKHTON_HOME:?}/lib/health_checks_infra.sh"

# --- Belt system --------------------------------------------------------------

# get_health_belt SCORE
# Maps a 0-100 score to a belt label.
get_health_belt() {
    local score="$1"
    if [[ "$score" -ge 90 ]]; then echo "Black Belt"
    elif [[ "$score" -ge 75 ]]; then echo "Blue Belt"
    elif [[ "$score" -ge 60 ]]; then echo "Green Belt"
    elif [[ "$score" -ge 40 ]]; then echo "Orange Belt"
    elif [[ "$score" -ge 20 ]]; then echo "Yellow Belt"
    else echo "White Belt"
    fi
}

# _get_belt_subtitle SCORE
_get_belt_subtitle() {
    local score="$1"
    if [[ "$score" -ge 90 ]]; then echo "Exemplary"
    elif [[ "$score" -ge 75 ]]; then echo "Well-maintained"
    elif [[ "$score" -ge 60 ]]; then echo "Solid practices"
    elif [[ "$score" -ge 40 ]]; then echo "Taking shape"
    elif [[ "$score" -ge 20 ]]; then echo "Foundation laid"
    else echo "Starting fresh"
    fi
}

# --- Shared dimension evaluation ----------------------------------------------

# _run_health_dimensions PROJECT_DIR
# Runs all five dimension checks, computes weighted composite, and prints a
# single tab-delimited line:
#   composite\tbelt\tsubtitle\ttest_score\tquality_score\tdep_score\tdoc_score\thygiene_score\ttest_detail\tquality_detail\tdep_detail\tdoc_detail\thygiene_detail
_run_health_dimensions() {
    local proj_dir="$1"

    local w_tests="${HEALTH_WEIGHT_TESTS:-30}"
    local w_quality="${HEALTH_WEIGHT_QUALITY:-25}"
    local w_deps="${HEALTH_WEIGHT_DEPS:-15}"
    local w_docs="${HEALTH_WEIGHT_DOCS:-15}"
    local w_hygiene="${HEALTH_WEIGHT_HYGIENE:-15}"

    # Run all dimension checks
    local test_result quality_result dep_result doc_result hygiene_result
    test_result=$(_check_test_health "$proj_dir")
    quality_result=$(_check_code_quality "$proj_dir")
    dep_result=$(_check_dependency_health "$proj_dir")
    doc_result=$(_check_doc_quality "$proj_dir")
    hygiene_result=$(_check_project_hygiene "$proj_dir")

    # Parse scores
    local test_score quality_score dep_score doc_score hygiene_score
    test_score=$(echo "$test_result" | cut -d'|' -f2)
    quality_score=$(echo "$quality_result" | cut -d'|' -f2)
    dep_score=$(echo "$dep_result" | cut -d'|' -f2)
    doc_score=$(echo "$doc_result" | cut -d'|' -f2)
    hygiene_score=$(echo "$hygiene_result" | cut -d'|' -f2)

    # Parse detail JSON
    local test_detail quality_detail dep_detail doc_detail hygiene_detail
    test_detail=$(echo "$test_result" | cut -d'|' -f3-)
    quality_detail=$(echo "$quality_result" | cut -d'|' -f3-)
    dep_detail=$(echo "$dep_result" | cut -d'|' -f3-)
    doc_detail=$(echo "$doc_result" | cut -d'|' -f3-)
    hygiene_detail=$(echo "$hygiene_result" | cut -d'|' -f3-)

    # Composite calculation
    local composite=$(( (test_score * w_tests + quality_score * w_quality + \
        dep_score * w_deps + doc_score * w_docs + hygiene_score * w_hygiene) / 100 ))
    [[ "$composite" -gt 100 ]] && composite=100
    [[ "$composite" -lt 0 ]] && composite=0

    local belt subtitle
    belt=$(get_health_belt "$composite")
    subtitle=$(_get_belt_subtitle "$composite")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$composite" "$belt" "$subtitle" \
        "$test_score" "$quality_score" "$dep_score" "$doc_score" "$hygiene_score" \
        "$test_detail" "$quality_detail" "$dep_detail" "$doc_detail" "$hygiene_detail"
}

# --- Core assessment ----------------------------------------------------------

# assess_project_health PROJECT_DIR
# Runs all dimension checks and produces composite score.
# Writes HEALTH_REPORT.md and HEALTH_BASELINE.json.
# Returns: composite score on stdout.
assess_project_health() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"

    if [[ "${HEALTH_ENABLED:-true}" != "true" ]]; then
        echo "0"
        return 0
    fi

    local dims
    dims=$(_run_health_dimensions "$proj_dir")

    local composite belt subtitle
    local test_score quality_score dep_score doc_score hygiene_score
    local test_detail quality_detail dep_detail doc_detail hygiene_detail
    IFS=$'\t' read -r composite belt subtitle \
        test_score quality_score dep_score doc_score hygiene_score \
        test_detail quality_detail dep_detail doc_detail hygiene_detail <<< "$dims"

    # Weights needed for baseline JSON
    local w_tests="${HEALTH_WEIGHT_TESTS:-30}"
    local w_quality="${HEALTH_WEIGHT_QUALITY:-25}"
    local w_deps="${HEALTH_WEIGHT_DEPS:-15}"
    local w_docs="${HEALTH_WEIGHT_DOCS:-15}"
    local w_hygiene="${HEALTH_WEIGHT_HYGIENE:-15}"

    # Write HEALTH_BASELINE.json
    local baseline_file="${proj_dir}/${HEALTH_BASELINE_FILE:-.claude/HEALTH_BASELINE.json}"
    local baseline_dir
    baseline_dir=$(dirname "$baseline_file")
    mkdir -p "$baseline_dir" 2>/dev/null || true

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

    local tmpfile="${baseline_file}.tmp.$$"
    cat > "$tmpfile" << JSONEOF
{
  "timestamp": "${timestamp}",
  "composite": ${composite},
  "belt": "$(_health_json_escape "$belt")",
  "dimensions": {
    "test_health": {"score": ${test_score}, "weight": ${w_tests}, "details": ${test_detail}},
    "code_quality": {"score": ${quality_score}, "weight": ${w_quality}, "details": ${quality_detail}},
    "dependency_health": {"score": ${dep_score}, "weight": ${w_deps}, "details": ${dep_detail}},
    "doc_quality": {"score": ${doc_score}, "weight": ${w_docs}, "details": ${doc_detail}},
    "project_hygiene": {"score": ${hygiene_score}, "weight": ${w_hygiene}, "details": ${hygiene_detail}}
  }
}
JSONEOF
    mv "$tmpfile" "$baseline_file"

    # Write HEALTH_REPORT.md
    _write_health_report "$proj_dir" "$composite" "$belt" "$subtitle" \
        "$test_score" "$quality_score" "$dep_score" "$doc_score" "$hygiene_score" \
        "$test_detail" "$quality_detail" "$dep_detail" "$doc_detail" "$hygiene_detail" \
        "" "" "" "" "" ""

    echo "$composite"
}

# --- Re-assessment with delta -------------------------------------------------

# reassess_project_health PROJECT_DIR
# Same as assess, but reads previous baseline and computes deltas.
# Returns: composite score on stdout.
reassess_project_health() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"

    if [[ "${HEALTH_ENABLED:-true}" != "true" ]]; then
        echo "0"
        return 0
    fi

    local baseline_file="${proj_dir}/${HEALTH_BASELINE_FILE:-.claude/HEALTH_BASELINE.json}"

    # Read previous scores if available
    local prev_composite=0 prev_test=0 prev_quality=0 prev_deps=0 prev_docs=0 prev_hygiene=0
    if [[ -f "$baseline_file" ]]; then
        prev_composite=$(_read_json_int "$baseline_file" "composite")
        prev_test=$(_read_json_int "$baseline_file" "test_health.*score")
        prev_quality=$(_read_json_int "$baseline_file" "code_quality.*score")
        prev_deps=$(_read_json_int "$baseline_file" "dependency_health.*score")
        prev_docs=$(_read_json_int "$baseline_file" "doc_quality.*score")
        prev_hygiene=$(_read_json_int "$baseline_file" "project_hygiene.*score")
    fi

    # Run fresh assessment
    local dims
    dims=$(_run_health_dimensions "$proj_dir")

    local composite belt subtitle
    local test_score quality_score dep_score doc_score hygiene_score
    local test_detail quality_detail dep_detail doc_detail hygiene_detail
    IFS=$'\t' read -r composite belt subtitle \
        test_score quality_score dep_score doc_score hygiene_score \
        test_detail quality_detail dep_detail doc_detail hygiene_detail <<< "$dims"

    # Weights needed for baseline JSON
    local w_tests="${HEALTH_WEIGHT_TESTS:-30}"
    local w_quality="${HEALTH_WEIGHT_QUALITY:-25}"
    local w_deps="${HEALTH_WEIGHT_DEPS:-15}"
    local w_docs="${HEALTH_WEIGHT_DOCS:-15}"
    local w_hygiene="${HEALTH_WEIGHT_HYGIENE:-15}"

    # Compute deltas
    local d_composite=$((composite - prev_composite))
    local d_test=$((test_score - prev_test))
    local d_quality=$((quality_score - prev_quality))
    local d_deps=$((dep_score - prev_deps))
    local d_docs=$((doc_score - prev_docs))
    local d_hygiene=$((hygiene_score - prev_hygiene))

    # Update baseline
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
    local tmpfile="${baseline_file}.tmp.$$"
    mkdir -p "$(dirname "$baseline_file")" 2>/dev/null || true
    cat > "$tmpfile" << JSONEOF
{
  "timestamp": "${timestamp}",
  "composite": ${composite},
  "belt": "$(_health_json_escape "$belt")",
  "previous_composite": ${prev_composite},
  "delta": ${d_composite},
  "dimensions": {
    "test_health": {"score": ${test_score}, "weight": ${w_tests}, "previous": ${prev_test}, "delta": ${d_test}, "details": ${test_detail}},
    "code_quality": {"score": ${quality_score}, "weight": ${w_quality}, "previous": ${prev_quality}, "delta": ${d_quality}, "details": ${quality_detail}},
    "dependency_health": {"score": ${dep_score}, "weight": ${w_deps}, "previous": ${prev_deps}, "delta": ${d_deps}, "details": ${dep_detail}},
    "doc_quality": {"score": ${doc_score}, "weight": ${w_docs}, "previous": ${prev_docs}, "delta": ${d_docs}, "details": ${doc_detail}},
    "project_hygiene": {"score": ${hygiene_score}, "weight": ${w_hygiene}, "previous": ${prev_hygiene}, "delta": ${d_hygiene}, "details": ${hygiene_detail}}
  }
}
JSONEOF
    mv "$tmpfile" "$baseline_file"

    # Write report with deltas
    _write_health_report "$proj_dir" "$composite" "$belt" "$subtitle" \
        "$test_score" "$quality_score" "$dep_score" "$doc_score" "$hygiene_score" \
        "$test_detail" "$quality_detail" "$dep_detail" "$doc_detail" "$hygiene_detail" \
        "$d_composite" "$d_test" "$d_quality" "$d_deps" "$d_docs" "$d_hygiene"

    echo "$composite"
}

# --- Report writer ------------------------------------------------------------

# _write_health_report PROJECT_DIR COMPOSITE BELT SUBTITLE
#   TEST_SCORE QUALITY_SCORE DEP_SCORE DOC_SCORE HYGIENE_SCORE
#   TEST_DETAIL QUALITY_DETAIL DEP_DETAIL DOC_DETAIL HYGIENE_DETAIL
#   D_COMPOSITE D_TEST D_QUALITY D_DEPS D_DOCS D_HYGIENE
_write_health_report() {
    local proj_dir="$1" composite="$2" belt="$3" subtitle="$4"
    local test_score="$5" quality_score="$6" dep_score="$7" doc_score="$8" hygiene_score="$9"
    shift 9
    local test_detail="$1" quality_detail="$2" dep_detail="$3" doc_detail="$4" hygiene_detail="$5"
    local d_composite="${6:-}" d_test="${7:-}" d_quality="${8:-}" d_deps="${9:-}"
    shift 9
    local d_docs="${1:-}" d_hygiene="${2:-}"

    local report_file="${proj_dir}/${HEALTH_REPORT_FILE:-HEALTH_REPORT.md}"
    local show_belt="${HEALTH_SHOW_BELT:-true}"

    local tmpfile="${report_file}.tmp.$$"
    {
        echo "# Project Health Report"
        echo
        echo "## Composite Score: ${composite}/100"
        if [[ -n "$d_composite" ]]; then
            echo "Delta: $(_trend_arrow "$d_composite") (${d_composite:+${d_composite}})"
        fi
        if [[ "$show_belt" == "true" ]]; then
            echo
            echo "**${belt}** — ${subtitle}"
        fi
        echo
        echo "---"
        echo
        echo "## Dimension Breakdown"
        echo
        echo "| Dimension | Score | Weight |$(if [[ -n "$d_composite" ]]; then echo " Delta |"; fi)"
        echo "|-----------|-------|--------|$(if [[ -n "$d_composite" ]]; then echo "-------|"; fi)"
        _report_dimension_row "Test Health" "$test_score" "${HEALTH_WEIGHT_TESTS:-30}" "${d_test:-}"
        _report_dimension_row "Code Quality" "$quality_score" "${HEALTH_WEIGHT_QUALITY:-25}" "${d_quality:-}"
        _report_dimension_row "Dependency Health" "$dep_score" "${HEALTH_WEIGHT_DEPS:-15}" "${d_deps:-}"
        _report_dimension_row "Documentation" "$doc_score" "${HEALTH_WEIGHT_DOCS:-15}" "${d_docs:-}"
        _report_dimension_row "Project Hygiene" "$hygiene_score" "${HEALTH_WEIGHT_HYGIENE:-15}" "${d_hygiene:-}"
        echo
        echo "---"
        echo
        echo "## Improvement Suggestions"
        echo
        _suggest_improvements "$test_score" "$quality_score" "$dep_score" "$doc_score" "$hygiene_score"
    } > "$tmpfile"
    mv "$tmpfile" "$report_file"
}

# _report_dimension_row NAME SCORE WEIGHT DELTA
_report_dimension_row() {
    local name="$1" score="$2" weight="$3" delta="${4:-}"
    if [[ -n "$delta" ]]; then
        echo "| ${name} | ${score}/100 | ${weight}% | $(_trend_arrow "$delta") ${delta} |"
    else
        echo "| ${name} | ${score}/100 | ${weight}% |"
    fi
}

# _trend_arrow DELTA
_trend_arrow() {
    local delta="${1:-0}"
    if [[ "$delta" -gt 0 ]]; then echo "↑"
    elif [[ "$delta" -lt 0 ]]; then echo "↓"
    else echo "→"
    fi
}

# _suggest_improvements TEST QUALITY DEPS DOCS HYGIENE
_suggest_improvements() {
    local test="$1" quality="$2" deps="$3" docs="$4" hygiene="$5"
    local any=false

    if [[ "$test" -lt 40 ]]; then
        echo "- **Test Health** (${test}/100): Add test files and configure a test runner. Even basic smoke tests improve this score significantly."
        any=true
    fi
    if [[ "$quality" -lt 40 ]]; then
        echo "- **Code Quality** (${quality}/100): Add a linter configuration (ESLint, pylint, golangci-lint, etc.) and consider pre-commit hooks."
        any=true
    fi
    if [[ "$deps" -lt 40 ]]; then
        echo "- **Dependencies** (${deps}/100): Commit your lock file (package-lock.json, Cargo.lock, etc.) and consider adding Dependabot or Renovate."
        any=true
    fi
    if [[ "$docs" -lt 40 ]]; then
        echo "- **Documentation** (${docs}/100): Expand your README with setup instructions and code examples. Consider adding ARCHITECTURE.md."
        any=true
    fi
    if [[ "$hygiene" -lt 40 ]]; then
        echo "- **Project Hygiene** (${hygiene}/100): Ensure .gitignore covers common patterns, add CI/CD, and verify .env is not committed."
        any=true
    fi
    if [[ "$any" == false ]]; then
        echo "All dimensions are in good shape. Keep up the good work!"
    fi
}

# --- Summary for prompt injection ---------------------------------------------

# format_health_summary PROJECT_DIR
# Returns a one-line summary for injection into agent prompts.
format_health_summary() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"
    local baseline_file="${proj_dir}/${HEALTH_BASELINE_FILE:-.claude/HEALTH_BASELINE.json}"

    if [[ ! -f "$baseline_file" ]]; then
        return 0
    fi

    local composite
    composite=$(_read_json_int "$baseline_file" "composite")
    local belt
    belt=$(get_health_belt "$composite")

    local test_score quality_score dep_score doc_score hygiene_score
    test_score=$(_read_json_int "$baseline_file" "test_health.*score")
    quality_score=$(_read_json_int "$baseline_file" "code_quality.*score")
    dep_score=$(_read_json_int "$baseline_file" "dependency_health.*score")
    doc_score=$(_read_json_int "$baseline_file" "doc_quality.*score")
    hygiene_score=$(_read_json_int "$baseline_file" "project_hygiene.*score")

    echo "Health: ${composite}/100 (${belt}) — Tests: ${test_score}, Quality: ${quality_score}, Deps: ${dep_score}, Docs: ${doc_score}, Hygiene: ${hygiene_score}"
}

# --- Display helper -----------------------------------------------------------

# display_health_score COMPOSITE [PREV_COMPOSITE]
# Prints a colored health score line for banners.
display_health_score() {
    local composite="$1"
    local prev="${2:-}"
    local belt
    belt=$(get_health_belt "$composite")

    local color="${RED:-\033[0;31m}"
    if [[ "$composite" -ge 75 ]]; then color="${GREEN:-\033[0;32m}"
    elif [[ "$composite" -ge 40 ]]; then color="${YELLOW:-\033[0;33m}"
    fi

    local line="  Health:    ${color}${BOLD:-\033[1m}${composite}/100${NC:-\033[0m}"
    if [[ "${HEALTH_SHOW_BELT:-true}" == "true" ]]; then
        line="${line} ${belt}"
    fi

    if [[ -n "$prev" ]] && [[ "$prev" != "0" ]]; then
        local delta=$((composite - prev))
        local arrow
        arrow=$(_trend_arrow "$delta")
        if [[ "$delta" -gt 0 ]]; then
            line="${line} ${GREEN:-\033[0;32m}(${prev} ${arrow} ${composite}, +${delta})${NC:-\033[0m}"
        elif [[ "$delta" -lt 0 ]]; then
            line="${line} ${RED:-\033[0;31m}(${prev} ${arrow} ${composite}, ${delta})${NC:-\033[0m}"
        else
            line="${line} (no change)"
        fi
    fi

    echo -e "$line"
}

# --- JSON read helper ---------------------------------------------------------

# _read_json_int FILE PATTERN
# Extracts the first integer matching a grep pattern from a JSON file.
# This is intentionally simple — no jq dependency.
_read_json_int() {
    local file="$1" pattern="$2"
    local val
    val=$(grep -oE "${pattern}\"?[[:space:]]*:[[:space:]]*[0-9]+" "$file" 2>/dev/null | \
        grep -oE '[0-9]+$' | head -1 || true)
    echo "${val:-0}"
}
