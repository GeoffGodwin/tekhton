#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# detect_infrastructure.sh — Infrastructure-as-code detection (Milestone 12)
#
# Detects Terraform, Pulumi, CDK, CloudFormation, Ansible.
# NEVER reads .tfstate files (may contain secrets). Only reads .tf config files.
#
# Sourced by tekhton.sh — do not run directly.
# Provides: detect_infrastructure()
# =============================================================================

# detect_infrastructure — Detects IaC tools and their providers.
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Output: One line per tool: IAC_TOOL|PATH|PROVIDER|CONFIDENCE
detect_infrastructure() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"

    _detect_terraform "$proj_dir"
    _detect_pulumi "$proj_dir"
    _detect_cdk "$proj_dir"
    _detect_cloudformation "$proj_dir"
    _detect_ansible "$proj_dir"
}

# --- Terraform ---------------------------------------------------------------

_detect_terraform() {
    local proj_dir="$1"

    # Check for .tf files (NEVER read .tfstate)
    local tf_dirs=""
    local tf_file
    while IFS= read -r tf_file; do
        [[ -z "$tf_file" ]] && continue
        local dir
        dir=$(dirname "$tf_file")
        dir="${dir#"${proj_dir}/"}"
        [[ "$dir" == "$proj_dir" ]] && dir="."
        tf_dirs="${tf_dirs}${dir}"$'\n'
    done < <(find "$proj_dir" -maxdepth 3 -name "*.tf" \
        -not -path "*/.terraform/*" \
        -not -path "*/node_modules/*" \
        -not -path "*/.git/*" \
        2>/dev/null | head -20)

    if [[ -n "$tf_dirs" ]]; then
        local unique_dirs
        unique_dirs=$(echo "$tf_dirs" | sort -u | head -5)
        local provider="unknown"

        # Try to detect provider from .tf files (safe — config only)
        local first_dir
        first_dir=$(echo "$unique_dirs" | head -1)
        local check_path="$proj_dir/$first_dir"
        [[ "$first_dir" == "." ]] && check_path="$proj_dir"

        if grep -rql 'provider "aws"\|source.*hashicorp/aws' "$check_path"/*.tf 2>/dev/null; then
            provider="aws"
        elif grep -rql 'provider "google"\|source.*hashicorp/google' "$check_path"/*.tf 2>/dev/null; then
            provider="gcp"
        elif grep -rql 'provider "azurerm"\|source.*hashicorp/azurerm' "$check_path"/*.tf 2>/dev/null; then
            provider="azure"
        fi

        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            echo "terraform|${d}|${provider}|high"
        done <<< "$unique_dirs"
    fi

    # Also check for terraform/ directory convention
    if [[ -d "$proj_dir/terraform" ]] && [[ -z "$tf_dirs" ]]; then
        echo "terraform|terraform|unknown|medium"
    fi

    # Check for .terraform.lock.hcl
    if [[ -f "$proj_dir/.terraform.lock.hcl" ]] && [[ -z "$tf_dirs" ]]; then
        echo "terraform|.|unknown|medium"
    fi
}

# --- Pulumi ------------------------------------------------------------------

_detect_pulumi() {
    local proj_dir="$1"
    [[ ! -f "$proj_dir/Pulumi.yaml" ]] && return 0

    local provider="unknown"
    # Check Pulumi.*.yaml for stack configs
    local stack_file
    for stack_file in "$proj_dir"/Pulumi.*.yaml; do
        [[ ! -f "$stack_file" ]] && continue
        if grep -q 'aws:' "$stack_file" 2>/dev/null; then provider="aws"; break; fi
        if grep -q 'gcp:' "$stack_file" 2>/dev/null; then provider="gcp"; break; fi
        if grep -q 'azure:' "$stack_file" 2>/dev/null; then provider="azure"; break; fi
    done

    echo "pulumi|.|${provider}|high"
}

# --- AWS CDK -----------------------------------------------------------------

_detect_cdk() {
    local proj_dir="$1"
    if [[ -f "$proj_dir/cdk.json" ]]; then
        echo "aws-cdk|.|aws|high"
    elif [[ -d "$proj_dir/cdk.out" ]]; then
        echo "aws-cdk|.|aws|medium"
    fi
}

# --- CloudFormation ----------------------------------------------------------

_detect_cloudformation() {
    local proj_dir="$1"
    local candidate
    for candidate in template.yaml template.json cloudformation.yaml cloudformation.json; do
        [[ ! -f "$proj_dir/$candidate" ]] && continue
        if grep -q 'AWSTemplateFormatVersion' "$proj_dir/$candidate" 2>/dev/null; then
            echo "cloudformation|${candidate}|aws|high"
            return 0
        fi
    done

    # Check for SAM template
    if [[ -f "$proj_dir/template.yaml" ]]; then
        if grep -q 'AWS::Serverless' "$proj_dir/template.yaml" 2>/dev/null; then
            echo "sam|template.yaml|aws|high"
        fi
    fi
}

# --- Ansible -----------------------------------------------------------------

_detect_ansible() {
    local proj_dir="$1"

    if [[ -f "$proj_dir/ansible.cfg" ]]; then
        echo "ansible|.|unknown|high"
        return 0
    fi

    if [[ -d "$proj_dir/playbooks" ]] || [[ -d "$proj_dir/roles" ]]; then
        echo "ansible|.|unknown|medium"
        return 0
    fi

    # Check for inventory/ directory
    if [[ -d "$proj_dir/inventory" ]]; then
        # Verify it looks like ansible inventory (not just any inventory dir)
        if [[ -f "$proj_dir/inventory/hosts" ]] || [[ -f "$proj_dir/inventory/hosts.yml" ]]; then
            echo "ansible|.|unknown|medium"
        fi
    fi
}
