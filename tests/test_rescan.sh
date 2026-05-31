#!/usr/bin/env bash
# Skip-stubbed at m30.1.
# The bash rescan logic (significance detection, surgical patching,
# scan-metadata helpers) was deleted alongside the lib/crawler*.sh files
# when the crawler core ported to internal/crawler/. The thin shim that
# replaces rescan_project is exercised by tests/test_crawler_parity.sh
# (full-crawl path) and Go unit tests in internal/crawler/.
# Incremental rescan returns in m30.2; full Go regression coverage
# follows that milestone.
echo "SKIP $(basename "${BASH_SOURCE[0]}"): m30.1 — bash rescan helpers retired (crawler core ported to internal/crawler/)"
exit 0
