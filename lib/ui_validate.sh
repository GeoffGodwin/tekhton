#!/usr/bin/env bash
# =============================================================================
# ui_validate.sh — UI validation gate orchestrator (Milestone 29)
#
# Sourced by tekhton.sh — do not run directly.
# Expects: UI_SERVE_CMD, UI_SERVE_PORT, UI_SERVER_STARTUP_TIMEOUT,
#          UI_VALIDATION_VIEWPORTS, UI_VALIDATION_TIMEOUT,
#          UI_VALIDATION_CONSOLE_SEVERITY, UI_VALIDATION_FLICKER_THRESHOLD,
#          UI_VALIDATION_RETRY, UI_VALIDATION_SCREENSHOTS,
#          WATCHTOWER_SELF_TEST, TEKHTON_HOME, PROJECT_DIR, TEKHTON_SESSION_DIR
#
# Provides:
#   run_ui_validation      — main gate entry point (called from gates.sh)
#   _check_headless_browser — detect available headless browser
#   _start_ui_server       — start dev/preview server in background
#   _stop_ui_server        — stop background server
# =============================================================================
set -euo pipefail

# Cached headless browser command (session-scoped)
_UI_BROWSER_CMD=""
_UI_BROWSER_CHECKED=false

# Background server PID (0 = not running)
_UI_SERVER_PID=0
_UI_SERVER_PORT_ACTUAL=0

# --- Prerequisite detection ---------------------------------------------------

# _check_headless_browser
# Detects available headless browser in priority order.
# Returns: browser command string via _UI_BROWSER_CMD, or empty if none found.
# Caches result for the session.
_check_headless_browser() {
    if [[ "$_UI_BROWSER_CHECKED" = true ]]; then
        return 0
    fi
    _UI_BROWSER_CHECKED=true
    _UI_BROWSER_CMD=""

    # 1. Playwright (preferred — bundles Chromium)
    if command -v npx &>/dev/null && timeout 10 npx --yes playwright --version &>/dev/null 2>&1; then
        _UI_BROWSER_CMD="playwright"
        return 0
    fi

    # 2. Puppeteer
    if command -v npx &>/dev/null && timeout 10 npx --yes puppeteer --version &>/dev/null 2>&1; then
        _UI_BROWSER_CMD="puppeteer"
        return 0
    fi

    # 3. System Chromium
    local chromium_bin=""
    if command -v chromium-browser &>/dev/null; then
        chromium_bin="chromium-browser"
    elif command -v chromium &>/dev/null; then
        chromium_bin="chromium"
    fi
    if [[ -n "$chromium_bin" ]]; then
        _UI_BROWSER_CMD="system:${chromium_bin}"
        return 0
    fi

    # 4. System Chrome
    if command -v google-chrome &>/dev/null; then
        _UI_BROWSER_CMD="system:google-chrome"
        return 0
    fi

    return 0
}

# _print_browser_install_help
# Prints clear install instructions when no headless browser is available.
_print_browser_install_help() {
    warn "UI validation skipped: headless browser not available."
    warn ""
    warn "To enable UI validation, install one of the following:"
    warn ""
    warn "  npm (recommended):"
    warn "    npm install -g playwright && npx playwright install chromium"
    warn ""
    warn "  macOS:"
    warn "    brew install chromium"
    warn ""
    warn "  Ubuntu/Debian:"
    warn "    apt-get install chromium-browser"
    warn ""
}

# --- Server management -------------------------------------------------------

# _find_available_port BASE_PORT
# Returns the first available port starting from BASE_PORT.
# Tries BASE_PORT through BASE_PORT+10.
_find_available_port() {
    local base_port="$1"
    local port
    for port in $(seq "$base_port" "$((base_port + 10))"); do
        if ! _is_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done
    return 1
}

# _is_port_in_use PORT
# Returns 0 if port is in use, 1 if free.
_is_port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -q ":${port} " && return 0
    else
        # Fallback: try connecting
        (echo >/dev/tcp/localhost/"$port") 2>/dev/null && return 0
    fi
    return 1
}

# _start_ui_server
# Starts a dev server using UI_SERVE_CMD or python3 http.server for static files.
# Sets _UI_SERVER_PID and _UI_SERVER_PORT_ACTUAL.
# Returns: 0 on success, 1 on failure.
_start_ui_server() {
    local serve_cmd="${UI_SERVE_CMD:-}"
    local serve_port="${UI_SERVE_PORT:-3000}"
    local startup_timeout="${UI_SERVER_STARTUP_TIMEOUT:-30}"

    # Find available port
    local actual_port
    actual_port=$(_find_available_port "$serve_port") || {
        warn "UI validation: no available port in range ${serve_port}-$((serve_port + 10))."
        return 1
    }
    _UI_SERVER_PORT_ACTUAL="$actual_port"

    # Determine server command
    if [[ -z "$serve_cmd" ]]; then
        # Static file server fallback
        if command -v python3 &>/dev/null; then
            serve_cmd="python3 -m http.server ${actual_port}"
        else
            warn "UI validation: no UI_SERVE_CMD and python3 not available for static serving."
            return 1
        fi
    else
        # Substitute port in user command if it contains the configured port
        serve_cmd="${serve_cmd//${serve_port}/${actual_port}}"
    fi

    log "Starting UI server: ${serve_cmd} (port ${actual_port})"
    bash -c "$serve_cmd" &>/dev/null &
    _UI_SERVER_PID=$!

    # Wait for server readiness
    local elapsed=0
    while [[ "$elapsed" -lt "$startup_timeout" ]]; do
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${actual_port}" 2>/dev/null | grep -qE "^[23]"; then
            log "UI server ready on port ${actual_port}."
            return 0
        fi
        # Check if process is still alive
        if ! kill -0 "$_UI_SERVER_PID" 2>/dev/null; then
            warn "UI server process exited before becoming ready."
            _UI_SERVER_PID=0
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    warn "UI server did not become ready within ${startup_timeout}s."
    _stop_ui_server
    return 1
}

# _stop_ui_server
# Stops the background server if running.
_stop_ui_server() {
    if [[ "$_UI_SERVER_PID" -gt 0 ]]; then
        kill "$_UI_SERVER_PID" 2>/dev/null || true
        wait "$_UI_SERVER_PID" 2>/dev/null || true
        _UI_SERVER_PID=0
        log "UI server stopped."
    fi
}

# --- Validation target detection ----------------------------------------------

# _detect_ui_targets
# Reads CODER_SUMMARY.md and detects UI files that need validation.
# Outputs lines: TYPE|PATH (e.g., "html|src/index.html")
_detect_ui_targets() {
    local targets=()

    if [[ -f "CODER_SUMMARY.md" ]]; then
        local files_section
        files_section=$(awk '/^## Files (Created|Modified|Created or Modified)/{f=1;next} /^## /{f=0} f{print}' \
            CODER_SUMMARY.md 2>/dev/null || true)

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # Extract file path from markdown list items
            local filepath
            filepath=$(echo "$line" | sed 's/^[-*] //' | awk '{print $1}' | sed 's/`//g')
            case "$filepath" in
                *.html|*.htm) echo "html|${filepath}" ;;
                *.jsx|*.tsx|*.vue|*.svelte) echo "webapp|${filepath}" ;;
            esac
        done <<< "$files_section"
    fi

    # Also check git diff for changed HTML files
    local changed_files
    changed_files=$(git diff --name-only HEAD 2>/dev/null || true)
    while IFS= read -r filepath; do
        [[ -z "$filepath" ]] && continue
        case "$filepath" in
            *.html|*.htm) echo "html|${filepath}" ;;
        esac
    done <<< "$changed_files"
}

# --- Watchtower self-test -----------------------------------------------------

# _should_self_test_watchtower
# Returns 0 if Watchtower files were modified and self-test is enabled.
#
# NOTE: The DASHBOARD_ENABLED and DASHBOARD_DIR checks below are intentional
# co-feature guards. Watchtower is the Dashboard's self-test mechanism. Both
# keys are set together in config_defaults.sh (line 245):
#   WATCHTOWER_SELF_TEST:=${DASHBOARD_ENABLED:-true}
# This relationship ensures that a future refactor of the Dashboard feature
# will naturally propagate to Watchtower's activation state.
_should_self_test_watchtower() {
    [[ "${WATCHTOWER_SELF_TEST:-false}" = "true" ]] || return 1
    [[ "${DASHBOARD_ENABLED:-true}" = "true" ]] || return 1
    local dashboard_dir="${DASHBOARD_DIR:-.claude/dashboard}"
    [[ -d "$dashboard_dir" ]] || return 1
    [[ -f "${dashboard_dir}/index.html" ]] || return 1

    # Check if dashboard files were modified
    local changed
    changed=$(git diff --name-only HEAD 2>/dev/null || true)
    if echo "$changed" | grep -q "dashboard/"; then
        return 0
    fi
    if [[ -f "CODER_SUMMARY.md" ]] && grep -qi "dashboard" CODER_SUMMARY.md 2>/dev/null; then
        return 0
    fi
    return 1
}

# --- Main validation entry point ----------------------------------------------

# run_ui_validation
# Called from gates.sh after UI_TEST_CMD.
# Returns: 0 on pass/skip, 1 on failure.
run_ui_validation() {
    local stage_label="${1:-post-coder}"

    # Check if Node.js is available
    if ! command -v node &>/dev/null; then
        warn "UI validation skipped: Node.js not available."
        _emit_ui_validation_event "skipped" "node_missing"
        return 0
    fi

    # Check headless browser
    _check_headless_browser
    if [[ -z "$_UI_BROWSER_CMD" ]]; then
        _print_browser_install_help
        _emit_ui_validation_event "skipped" "no_browser"
        return 0
    fi

    log "UI validation gate (${stage_label}) — browser: ${_UI_BROWSER_CMD}"

    # Detect targets
    local targets=()
    local watchtower_test=false
    local need_server=false

    # Check for Watchtower self-test
    if _should_self_test_watchtower; then
        watchtower_test=true
    fi

    # Detect UI file targets
    while IFS= read -r target_line; do
        [[ -z "$target_line" ]] && continue
        targets+=("$target_line")
    done < <(_detect_ui_targets | sort -u)

    # Need a server if we have webapp targets or UI_SERVE_CMD is set
    if [[ -n "${UI_SERVE_CMD:-}" ]]; then
        need_server=true
    fi

    # If no targets and no watchtower test, skip
    if [[ ${#targets[@]} -eq 0 ]] && [[ "$watchtower_test" = false ]] && [[ "$need_server" = false ]]; then
        log "UI validation: no UI targets detected. Skipping."
        return 0
    fi

    # Prepare screenshots directory
    local screenshot_dir="${PROJECT_DIR:-.}/.claude/ui-validation/screenshots"
    if [[ "${UI_VALIDATION_SCREENSHOTS:-true}" = "true" ]]; then
        mkdir -p "$screenshot_dir" 2>/dev/null || true
        _prune_old_screenshots "$screenshot_dir"
    fi

    local all_results=()
    local server_started=false
    local validation_failed=false

    # Start server if needed for webapp targets
    if [[ "$need_server" = true ]]; then
        if _start_ui_server; then
            server_started=true
        else
            warn "UI validation: server failed to start. Skipping webapp targets."
        fi
    fi

    # Run Watchtower self-test
    if [[ "$watchtower_test" = true ]]; then
        local wt_result
        wt_result=$(_run_watchtower_self_test) || true
        all_results+=("$wt_result")
        if echo "$wt_result" | grep -q '"verdict":"FAIL"'; then
            validation_failed=true
        fi
    fi

    # Run validation on detected targets
    for target_line in "${targets[@]}"; do
        local target_type="${target_line%%|*}"
        local target_path="${target_line#*|}"

        case "$target_type" in
            html)
                local html_result
                html_result=$(_validate_html_file "$target_path" "$screenshot_dir") || true
                [[ -n "$html_result" ]] && all_results+=("$html_result")
                if echo "$html_result" | grep -q '"verdict":"FAIL"'; then
                    validation_failed=true
                fi
                ;;
            webapp)
                if [[ "$server_started" = true ]]; then
                    local app_result
                    app_result=$(_validate_webapp "$target_path" "$screenshot_dir") || true
                    [[ -n "$app_result" ]] && all_results+=("$app_result")
                    if echo "$app_result" | grep -q '"verdict":"FAIL"'; then
                        validation_failed=true
                    fi
                fi
                ;;
        esac
    done

    # Stop server
    if [[ "$server_started" = true ]]; then
        _stop_ui_server
    fi

    # Generate report
    if [[ ${#all_results[@]} -gt 0 ]]; then
        _generate_ui_report "${all_results[@]}"
    fi

    # Handle retry on failure
    if [[ "$validation_failed" = true ]] && [[ "${UI_VALIDATION_RETRY:-true}" = "true" ]]; then
        log "UI validation failed. Retrying once..."
        validation_failed=false
        all_results=()

        if [[ "$server_started" = true ]]; then
            _start_ui_server || true
        fi

        # Re-run failed targets only
        if [[ "$watchtower_test" = true ]]; then
            local wt_result
            wt_result=$(_run_watchtower_self_test) || true
            all_results+=("$wt_result")
            if echo "$wt_result" | grep -q '"verdict":"FAIL"'; then
                validation_failed=true
            fi
        fi
        for target_line in "${targets[@]}"; do
            local target_type="${target_line%%|*}"
            local target_path="${target_line#*|}"
            case "$target_type" in
                html)
                    local html_result
                    html_result=$(_validate_html_file "$target_path" "$screenshot_dir") || true
                    [[ -n "$html_result" ]] && all_results+=("$html_result")
                    if echo "$html_result" | grep -q '"verdict":"FAIL"'; then
                        validation_failed=true
                    fi
                    ;;
                webapp)
                    if [[ "$server_started" = true ]]; then
                        local app_result
                        app_result=$(_validate_webapp "$target_path" "$screenshot_dir") || true
                        [[ -n "$app_result" ]] && all_results+=("$app_result")
                        if echo "$app_result" | grep -q '"verdict":"FAIL"'; then
                            validation_failed=true
                        fi
                    fi
                    ;;
            esac
        done

        if [[ "$server_started" = true ]]; then
            _stop_ui_server
        fi

        if [[ ${#all_results[@]} -gt 0 ]]; then
            _generate_ui_report "${all_results[@]}"
        fi
    fi

    if [[ "$validation_failed" = true ]]; then
        warn "UI validation gate FAILED (${stage_label})."
        _emit_ui_validation_event "failed" ""
        # Set template variables for rework prompt
        export UI_VALIDATION_FAILURES_BLOCK=""
        if [[ -f "UI_VALIDATION_REPORT.md" ]]; then
            UI_VALIDATION_FAILURES_BLOCK=$(cat "UI_VALIDATION_REPORT.md")
        fi
        return 1
    fi

    log "UI validation gate PASSED (${stage_label})."
    _emit_ui_validation_event "passed" ""
    return 0
}

# --- Internal helpers ---------------------------------------------------------

# _validate_html_file FILE SCREENSHOT_DIR
# Validates a static HTML file by serving it and running smoke tests.
_validate_html_file() {
    local filepath="$1"
    local screenshot_dir="$2"

    [[ -f "$filepath" ]] || return 0

    local serve_dir
    serve_dir=$(dirname "$filepath")
    local filename
    filename=$(basename "$filepath")

    # Start a minimal server for the directory
    local port
    port=$(_find_available_port 8900) || return 0

    if command -v python3 &>/dev/null; then
        (cd "$serve_dir" && python3 -m http.server "$port") &>/dev/null &
        local srv_pid=$!
        sleep 1

        local result
        result=$(_run_smoke_test "http://localhost:${port}/${filename}" "$screenshot_dir" "$filepath")

        kill "$srv_pid" 2>/dev/null || true
        wait "$srv_pid" 2>/dev/null || true
        echo "$result"
    fi
}

# _validate_webapp TARGET_PATH SCREENSHOT_DIR
# Validates a webapp target via the running dev server.
_validate_webapp() {
    local target_path="$1"
    local screenshot_dir="$2"
    local port="$_UI_SERVER_PORT_ACTUAL"

    _run_smoke_test "http://localhost:${port}/" "$screenshot_dir" "$target_path"
}

# _run_watchtower_self_test
# Validates the Watchtower dashboard.
_run_watchtower_self_test() {
    local dashboard_dir="${DASHBOARD_DIR:-.claude/dashboard}"
    local screenshot_dir="${PROJECT_DIR:-.}/.claude/ui-validation/screenshots"

    [[ -f "${dashboard_dir}/index.html" ]] || return 0

    local port
    port=$(_find_available_port 8950) || return 0

    if command -v python3 &>/dev/null; then
        (cd "$dashboard_dir" && python3 -m http.server "$port") &>/dev/null &
        local srv_pid=$!
        sleep 1

        local result
        result=$(_run_smoke_test "http://localhost:${port}/index.html" "$screenshot_dir" "watchtower")

        kill "$srv_pid" 2>/dev/null || true
        wait "$srv_pid" 2>/dev/null || true
        echo "$result"
    fi
}

# _run_smoke_test URL SCREENSHOT_DIR LABEL
# Invokes ui_smoke_test.js and returns the JSON result.
_run_smoke_test() {
    local url="$1"
    local screenshot_dir="$2"
    local label="$3"
    local timeout="${UI_VALIDATION_TIMEOUT:-30}"
    local viewports="${UI_VALIDATION_VIEWPORTS:-1280x800,375x812}"
    local severity="${UI_VALIDATION_CONSOLE_SEVERITY:-error}"
    local flicker_threshold="${UI_VALIDATION_FLICKER_THRESHOLD:-0.05}"
    local take_screenshots="${UI_VALIDATION_SCREENSHOTS:-true}"
    local smoke_script="${TEKHTON_HOME}/tools/ui_smoke_test.js"

    if [[ ! -f "$smoke_script" ]]; then
        warn "UI smoke test script not found: ${smoke_script}"
        return 0
    fi

    local browser_arg="$_UI_BROWSER_CMD"

    local result
    result=$(timeout "$((timeout + 10))" node "$smoke_script" \
        --url "$url" \
        --viewports "$viewports" \
        --timeout "$timeout" \
        --severity "$severity" \
        --flicker-threshold "$flicker_threshold" \
        --screenshot-dir "$screenshot_dir" \
        --screenshots "$take_screenshots" \
        --browser "$browser_arg" \
        --label "$label" \
        2>/dev/null) || true

    echo "$result"
}

# _generate_ui_report RESULTS...
# Generates UI_VALIDATION_REPORT.md from JSON results.
_generate_ui_report() {
    # Delegate to report module
    if command -v generate_ui_validation_report &>/dev/null; then
        generate_ui_validation_report "$@"
    fi
}

# _prune_old_screenshots DIR
# Removes screenshots older than 5 runs.
_prune_old_screenshots() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0

    # Keep directories from the last 5 runs (sorted by name, most recent last)
    local run_dirs
    run_dirs=$(find "$dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | head -n -5 || true)
    while IFS= read -r old_dir; do
        [[ -z "$old_dir" ]] && continue
        rm -rf "$old_dir" 2>/dev/null || true
    done <<< "$run_dirs"
}

# _emit_ui_validation_event STATUS REASON
# Emits a Watchtower/causal log event for UI validation.
_emit_ui_validation_event() {
    local status="$1"
    local reason="${2:-}"

    if command -v emit_event &>/dev/null; then
        emit_event "ui_validation" "gate" "status=${status}" \
            "" "" \
            "{\"status\":\"${status}\",\"reason\":\"${reason}\",\"browser\":\"${_UI_BROWSER_CMD:-none}\"}" \
            2>/dev/null || true
    fi
}
