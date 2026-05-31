#!/usr/bin/env bash
# tests/lib/normalize_index.sh — In-place normalisation of volatile fields
# in a .claude/index/ artifact tree.
#
# Used by the m30.1 crawler parity gate (tests/test_crawler_parity.sh).
# Two fields in meta.json vary across runs (scan_date / scan_commit) and
# must be replaced with frozen sentinels before diff. Everything else is
# expected to be byte-identical.
#
# Usage: bash tests/lib/normalize_index.sh <index_dir>
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: normalize_index.sh <index_dir>" >&2
    exit 64
fi
index_dir="$1"

if [[ ! -d "$index_dir" ]]; then
    echo "normalize_index.sh: not a directory: $index_dir" >&2
    exit 1
fi

meta="${index_dir}/meta.json"
if [[ -f "$meta" ]]; then
    # Both fields are quoted strings on their own line; replace value
    # contents but preserve key + quoting + indentation.
    sed -i \
        -e 's|"scan_date": "[^"]*"|"scan_date": "FROZEN"|' \
        -e 's|"scan_commit": "[^"]*"|"scan_commit": "FROZEN"|' \
        "$meta"
fi
