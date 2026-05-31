#!/usr/bin/env bash
# =============================================================================
# index_view_budget.sh — Budget allocator for the project-index view.
#
# Extracted from the deleted lib/crawler.sh during the m30.1 cutover.
# The function distributes the total char budget across the view's
# fixed sections (tree / inventory / deps / configs / tests) and rolls
# any surplus from thin sections into the sampled-file budget.
#
# Sourced by lib/index_view.sh — do not run directly.
# =============================================================================

# _budget_allocator — Distributes the total char budget across the view's
# fixed sections. Fixed: tree 10%, inventory 15%, deps 10%, config 5%,
# tests 5%. The remaining 55% plus any surplus from thin sections flows
# to the sampled-file section.
# Args: $1=total, $2=tree_size, $3=inv_size, $4=dep_size, $5=cfg_size, $6=test_size
# Prints: remaining budget for file sampling
_budget_allocator() {
    local total="$1"
    local tree_actual="$2" inv_actual="$3" dep_actual="$4"
    local cfg_actual="$5" test_actual="$6"

    local budget_tree=$(( total * 10 / 100 ))
    local budget_inv=$(( total * 15 / 100 ))
    local budget_dep=$(( total * 10 / 100 ))
    local budget_cfg=$(( total * 5 / 100 ))
    local budget_test=$(( total * 5 / 100 ))

    local surplus=0
    [[ "$tree_actual" -lt "$budget_tree" ]] && surplus=$(( surplus + budget_tree - tree_actual ))
    [[ "$inv_actual"  -lt "$budget_inv"  ]] && surplus=$(( surplus + budget_inv  - inv_actual ))
    [[ "$dep_actual"  -lt "$budget_dep"  ]] && surplus=$(( surplus + budget_dep  - dep_actual ))
    [[ "$cfg_actual"  -lt "$budget_cfg"  ]] && surplus=$(( surplus + budget_cfg  - cfg_actual ))
    [[ "$test_actual" -lt "$budget_test" ]] && surplus=$(( surplus + budget_test - test_actual ))

    local base_sample=$(( total * 55 / 100 ))
    echo $(( base_sample + surplus ))
}
