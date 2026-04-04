#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# error_patterns_registry.sh — Declarative error pattern registry data
#
# Sourced by lib/error_patterns.sh — do not run directly.
# Provides: _build_pattern_registry()
#
# Extracted from error_patterns.sh to separate registry data from the
# classification engine. Each registry entry:
#   REGEX_PATTERN|CATEGORY|SAFETY|REMEDIATION_CMD|DIAGNOSIS
#
# Categories: env_setup, service_dep, toolchain, resource, test_infra, code
# Safety: safe, prompt, manual, code
# =============================================================================

# --- _build_pattern_registry ------------------------------------------------
# Returns the heredoc registry. Patterns are ordered by specificity:
# more specific patterns BEFORE generic ones.
_build_pattern_registry() {
    cat <<'REGISTRY'
# --- Node.js / npm: environment setup ---
npx playwright install|env_setup|safe|npx playwright install|Playwright browsers not installed
npx cypress install|env_setup|safe|npx cypress install|Cypress binary not installed
PLAYWRIGHT_BROWSERS_PATH|env_setup|safe|npx playwright install|Playwright browser path not configured
Executable doesn't exist.*chrom|env_setup|safe|npx playwright install chromium|Browser binary missing (Chromium)
browser.*not found|env_setup|safe|npx playwright install|Browser binary not found
# --- Node.js / npm: toolchain ---
Cannot find module.*node_modules|toolchain|safe|npm install|Node module missing from node_modules
ERR_MODULE_NOT_FOUND|toolchain|safe|npm install|ES module not found
ENOENT.*node_modules|toolchain|safe|npm install|node_modules path missing
npm ERR! Missing|toolchain|safe|npm install|npm dependency missing
npm ERR! ERESOLVE|toolchain|safe|npm install --legacy-peer-deps|npm dependency resolution conflict
Cannot find module|toolchain|safe|npm install|Node module not found
# --- Python: environment setup ---
venv.*not found|env_setup|safe|python3 -m venv .venv|Python virtual environment missing
# --- Python: toolchain ---
ModuleNotFoundError|toolchain|safe|pip install -r requirements.txt|Python module not installed
ImportError.*No module|toolchain|safe|pip install -r requirements.txt|Python import failed — module not installed
No module named|toolchain|safe|pip install -r requirements.txt|Python module not found
# --- Go: toolchain ---
missing go\.sum entry|toolchain|safe|go mod download|Go module checksum missing
go: cannot find package|toolchain|safe|go mod download|Go package not found
cannot find package|toolchain|safe|go mod download|Go package not found
# --- Rust: code (compilation is code) ---
could not compile|code|code||Rust compilation error
unresolved import|code|code||Rust unresolved import
# --- Java/Kotlin: code ---
ClassNotFoundException|code|code||Java class not found at runtime
NoClassDefFoundError|code|code||Java class definition missing
BUILD FAILED|code|code||Build failed (Gradle/Maven)
# --- Database: service dependencies ---
ECONNREFUSED.*5432|service_dep|manual||PostgreSQL not running (port 5432)
ECONNREFUSED.*3306|service_dep|manual||MySQL not running (port 3306)
ECONNREFUSED.*27017|service_dep|manual||MongoDB not running (port 27017)
ECONNREFUSED.*6379|service_dep|manual||Redis not running (port 6379)
ECONNREFUSED.*5672|service_dep|manual||RabbitMQ not running (port 5672)
ECONNREFUSED.*9092|service_dep|manual||Kafka not running (port 9092)
ECONNREFUSED.*9200|service_dep|manual||Elasticsearch not running (port 9200)
connection.*timed out.*:6379|service_dep|manual||Redis not reachable (port 6379)
connection.*timed out.*:5432|service_dep|manual||PostgreSQL not reachable (port 5432)
connection refused.*database|service_dep|manual||Database connection refused
Connection refused.*localhost|service_dep|manual||Local service connection refused
# --- Docker ---
Cannot connect to the Docker daemon|service_dep|manual||Docker daemon not running
docker.*not found|env_setup|safe|docker --version|Docker not installed
# --- E2E / Browser ---
WebDriverError|env_setup|safe|npx playwright install|WebDriver error — browser setup needed
# --- Generated code ---
@prisma/client.*not.*generated|toolchain|safe|npx prisma generate|Prisma client not generated
prisma generate|toolchain|safe|npx prisma generate|Prisma codegen needed
protoc.*not found|env_setup|manual||Protocol Buffers compiler not installed
codegen.*not found|toolchain|prompt|npm run codegen|Code generation output missing
# --- Resource constraints ---
EADDRINUSE|resource|manual||Port already in use
ENOMEM|resource|manual||Out of memory
heap out of memory|resource|manual||JavaScript heap out of memory
ENOSPC|resource|manual||No disk space left
EACCES|resource|manual||Permission denied (EACCES)
Permission denied|resource|manual||Permission denied
# --- Test infrastructure ---
Snapshot.*obsolete|test_infra|prompt|npm test -- -u|Test snapshots are obsolete
snapshot.*mismatch|test_infra|prompt|npm test -- -u|Snapshot mismatch — may need update
TIMEOUT|test_infra|manual||Test timeout
fixture.*not found|test_infra|manual||Test fixture file missing
# --- Generic patterns (MUST be last — least specific) ---
command not found|env_setup|manual||Required command not installed
No such file or directory|code|code||File or directory not found
error TS[0-9]+:|code|code||TypeScript compilation error
SyntaxError:|code|code||Syntax error in source code
ReferenceError:|code|code||JavaScript reference error
TypeError:|code|code||Type error
REGISTRY
}
