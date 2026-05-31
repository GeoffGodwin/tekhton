#!/usr/bin/env bash
# capture_baselines.sh — one-shot baseline capture for the m30.1
# crawler parity gate. Run from the tekhton repo root BEFORE the bash
# lib/crawler*.sh files are deleted. Output lands under
# internal/crawler/testdata/baselines/<fixture>/.
#
# Re-running this script regenerates the baselines from the current
# bash crawler. Once the bash files are gone, this script becomes
# inert (the source-time `crawl_project` lookup fails) — that is
# intentional: the baselines are frozen-in-git, and any regeneration
# attempt MUST land before the bash deletion commit.
set -euo pipefail

TEKHTON_DIR="${TEKHTON_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
FIXTURE_ROOT="${TEKHTON_DIR}/internal/crawler/testdata"
BASELINES="${FIXTURE_ROOT}/baselines"

# Source the bash crawler chain.
source "${TEKHTON_DIR}/lib/artifact_defaults.sh"
source "${TEKHTON_DIR}/lib/common_detect.sh"
source "${TEKHTON_DIR}/lib/output.sh"
source "${TEKHTON_DIR}/lib/output_format.sh"
source "${TEKHTON_DIR}/lib/common.sh"
source "${TEKHTON_DIR}/lib/crawler.sh"

# _extract_json_keys was deleted with lib/detect.sh in m29.2; the bash
# crawler still references it (a pre-existing m29.2 regression that
# nobody surfaced because real package.json parsing went through the Go
# detect engine instead). Provide an inline copy of the original
# implementation purely for baseline capture — m30.1's Go crawler calls
# detect.ExtractJSONKeys directly.
_extract_json_keys() {
    local file="$1"
    shift
    local body
    body=$(<"$file")
    local section in_section=false line
    while IFS= read -r line; do
        for section in "$@"; do
            if [[ "$in_section" == false ]] && [[ "$line" == *"$section"* ]]; then
                in_section=true
                break
            fi
        done
        if [[ "$in_section" == true ]]; then
            if [[ "$line" == *"}"* ]]; then
                in_section=false
            else
                echo "$line"
            fi
        fi
    done <<< "$body"
}

for fixture in small_repo monorepo with_submodules; do
    project="${FIXTURE_ROOT}/${fixture}"
    target="${BASELINES}/${fixture}"
    rm -rf "${target}"
    mkdir -p "${target}/samples"

    file_list=$(_list_tracked_files "${project}")

    # Compute doc quality the same way crawl_project does.
    dq_score=0
    dq_output=$(_tk_detect_doc_quality "${project}" 2>/dev/null || true)
    [[ -n "$dq_output" ]] && dq_score=$(echo "$dq_output" | cut -d'|' -f1)

    _emit_tree_txt "${project}" "${target}"
    _emit_inventory_jsonl "${project}" "${file_list}" "${target}"
    _emit_dependencies_json "${project}" "${target}"
    _emit_configs_json "${project}" "${file_list}" "${target}"
    _emit_tests_json "${project}" "${file_list}" "${target}"
    _emit_sampled_files "${project}" "${file_list}" "${target}" 30000
    _emit_meta_json "${project}" "${target}" "${dq_score}"
    echo "baseline captured: ${fixture} (doc_quality=${dq_score})"
done
