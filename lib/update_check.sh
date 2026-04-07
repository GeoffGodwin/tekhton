#!/usr/bin/env bash
# =============================================================================
# update_check.sh — Version check and update notification
#
# Sourced by tekhton.sh — do not run directly.
# Provides: check_for_updates(), perform_update()
#
# Checks GitHub Releases for newer versions. Respects a 24-hour cooldown
# (stored in ~/.tekhton/.last_update_check). Never interrupts pipeline
# execution — notices appear only at the very end.
# =============================================================================
set -euo pipefail

# --- Constants ---------------------------------------------------------------

_UPDATE_CHECK_COOLDOWN=86400  # 24 hours in seconds
_UPDATE_CHECK_FILE="${HOME}/.tekhton/.last_update_check"
_GITHUB_REPO="geoffgodwin/tekhton"
_GITHUB_API="https://api.github.com/repos/${_GITHUB_REPO}"
_GITHUB_DOWNLOAD="https://github.com/${_GITHUB_REPO}/releases/download"

# --- Semver comparison -------------------------------------------------------
# Returns 0 if v1 < v2, 1 otherwise. Handles X.Y.Z format.

_semver_lt() {
    local v1="$1" v2="$2"
    local v1_major v1_minor v1_patch v2_major v2_minor v2_patch

    IFS='.' read -r v1_major v1_minor v1_patch <<< "$v1"
    IFS='.' read -r v2_major v2_minor v2_patch <<< "$v2"

    v1_major="${v1_major:-0}"; v1_minor="${v1_minor:-0}"; v1_patch="${v1_patch:-0}"
    v2_major="${v2_major:-0}"; v2_minor="${v2_minor:-0}"; v2_patch="${v2_patch:-0}"

    if [[ "$v1_major" -lt "$v2_major" ]]; then return 0; fi
    if [[ "$v1_major" -gt "$v2_major" ]]; then return 1; fi
    if [[ "$v1_minor" -lt "$v2_minor" ]]; then return 0; fi
    if [[ "$v1_minor" -gt "$v2_minor" ]]; then return 1; fi
    if [[ "$v1_patch" -lt "$v2_patch" ]]; then return 0; fi
    return 1
}

# _is_valid_semver VERSION
# Returns 0 if VERSION matches X.Y.Z pattern, 1 otherwise.

_is_valid_semver() {
    local version="$1"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# --- Cooldown management -----------------------------------------------------

_should_check_updates() {
    # Disabled via config or env var
    if [[ "${TEKHTON_UPDATE_CHECK:-true}" == "false" ]]; then
        return 1
    fi

    # No cooldown file — first check ever
    if [[ ! -f "$_UPDATE_CHECK_FILE" ]]; then
        return 0
    fi

    # Read last check timestamp
    local last_check
    last_check=$(head -1 "$_UPDATE_CHECK_FILE" 2>/dev/null || echo "0")
    if ! [[ "$last_check" =~ ^[0-9]+$ ]]; then
        last_check=0
    fi

    local now
    now=$(date +%s)
    local elapsed=$(( now - last_check ))

    [[ "$elapsed" -ge "$_UPDATE_CHECK_COOLDOWN" ]]
}

_write_check_timestamp() {
    local cache_dir
    cache_dir=$(dirname "$_UPDATE_CHECK_FILE")
    mkdir -p "$cache_dir" 2>/dev/null || true
    date +%s > "$_UPDATE_CHECK_FILE" 2>/dev/null || true
}

# --- GitHub API query --------------------------------------------------------

# _fetch_latest_release
# Sets: _LATEST_VERSION, _LATEST_CHANGELOG (global)
# Returns 0 on success, 1 on failure.

_fetch_latest_release() {
    _LATEST_VERSION=""
    _LATEST_CHANGELOG=""

    local response
    response=$(curl -sSL --fail --max-time 5 \
        "${_GITHUB_API}/releases/latest" 2>/dev/null) || return 1

    # Extract version from tag_name
    _LATEST_VERSION=$(echo "$response" | grep '"tag_name"' | \
        sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/' | head -1)
    _LATEST_VERSION="${_LATEST_VERSION#v}"

    if [[ -z "$_LATEST_VERSION" ]]; then
        return 1
    fi

    # Extract brief changelog from release body (first 3 lines of content)
    _LATEST_CHANGELOG=$(echo "$response" | grep '"body"' | \
        sed 's/.*"body"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/' | \
        head -1 | sed 's/\\r\\n/\n/g; s/\\n/\n/g' | head -3 | \
        tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')

    # Truncate to reasonable length
    if [[ ${#_LATEST_CHANGELOG} -gt 120 ]]; then
        _LATEST_CHANGELOG="${_LATEST_CHANGELOG:0:117}..."
    fi

    return 0
}

# --- Public API --------------------------------------------------------------

# check_for_updates [--force]
# Checks for a newer version and prints a notice if one is available.
# Respects 24-hour cooldown unless --force is passed.
# Returns: 0 if update available, 1 if up-to-date or check skipped.

check_for_updates() {
    local force=false
    if [[ "${1:-}" == "--force" ]]; then
        force=true
    fi

    # Skip if disabled
    if [[ "${TEKHTON_UPDATE_CHECK:-true}" == "false" ]]; then
        return 1
    fi

    # Skip if cooldown hasn't elapsed (unless forced)
    if [[ "$force" != true ]] && ! _should_check_updates; then
        return 1
    fi

    # Fetch latest release
    if ! _fetch_latest_release; then
        # Network error or API rate limit — silently skip
        return 1
    fi

    # Record check timestamp
    _write_check_timestamp

    # Cache version and changelog alongside timestamp
    {
        # Line 1 is timestamp (written above), append version + changelog
        echo "$_LATEST_VERSION"
        echo "$_LATEST_CHANGELOG"
    } >> "$_UPDATE_CHECK_FILE" 2>/dev/null || true

    local current="${TEKHTON_VERSION:-0.0.0}"

    # Compare versions
    if _semver_lt "$current" "$_LATEST_VERSION"; then
        local notice
        notice="Tekhton ${_LATEST_VERSION} available (you have ${current})."
        if [[ -n "$_LATEST_CHANGELOG" ]]; then
            notice="${notice} Highlights: ${_LATEST_CHANGELOG}"
        fi
        notice="${notice} Run \`tekhton --update\` to upgrade."
        echo -e "\033[0;36m[i] ${notice}\033[0m"
        return 0
    fi

    return 1
}

# perform_update [--check]
# Handles the --update flag. Downloads and installs the latest version.
# With --check: only reports available version, does not install.
# Returns: 0 on success.

perform_update() {
    local check_only=false
    if [[ "${1:-}" == "--check" ]]; then
        check_only=true
    fi

    # Fetch latest release
    echo "Checking for updates..."
    if ! _fetch_latest_release; then
        echo "[x] Could not reach GitHub. Check your internet connection." >&2
        return 1
    fi

    local current="${TEKHTON_VERSION:-0.0.0}"

    if ! _semver_lt "$current" "$_LATEST_VERSION"; then
        echo "You're already on the latest version (${current})."
        _write_check_timestamp
        return 0
    fi

    # Check version pin
    if [[ -n "${TEKHTON_PIN_VERSION:-}" ]]; then
        if _is_valid_semver "$TEKHTON_PIN_VERSION"; then
            if _semver_lt "$TEKHTON_PIN_VERSION" "$_LATEST_VERSION"; then
                echo "Version ${_LATEST_VERSION} available, but pinned to ${TEKHTON_PIN_VERSION}."
                echo "Remove TEKHTON_PIN_VERSION from pipeline.conf to allow upgrade."
                return 0
            fi
        fi
    fi

    echo "Update available: ${current} -> ${_LATEST_VERSION}"
    if [[ -n "$_LATEST_CHANGELOG" ]]; then
        echo "Highlights: ${_LATEST_CHANGELOG}"
    fi

    if [[ "$check_only" = true ]]; then
        _write_check_timestamp
        return 0
    fi

    # Determine install prefix
    local prefix="${HOME}/.tekhton"
    if [[ -L "${prefix}/current" ]]; then
        # Already installed via installer — use existing prefix
        true
    elif [[ -n "${TEKHTON_HOME:-}" ]]; then
        # Running from git clone or custom location
        echo ""
        echo "Current install is at: ${TEKHTON_HOME}"
        echo "Update via installer:  curl -sSL https://raw.githubusercontent.com/${_GITHUB_REPO}/main/install.sh | bash"
        echo "Or update via git:     cd ${TEKHTON_HOME} && git pull"
        return 0
    fi

    # Download new version
    local version_dir="${prefix}/versions/${_LATEST_VERSION}"
    local tarball_name="tekhton-${_LATEST_VERSION}.tar.gz"
    local tarball_url="${_GITHUB_DOWNLOAD}/v${_LATEST_VERSION}/${tarball_name}"
    local checksums_url="${_GITHUB_DOWNLOAD}/v${_LATEST_VERSION}/SHA256SUMS"

    local tmp_dir
    tmp_dir=$(mktemp -d)

    echo "Downloading Tekhton ${_LATEST_VERSION}..."
    if ! curl -sSL --fail -o "${tmp_dir}/${tarball_name}" "$tarball_url" 2>/dev/null; then
        rm -rf "$tmp_dir"
        echo "[x] Download failed." >&2
        return 1
    fi

    # Verify checksum
    if curl -sSL --fail -o "${tmp_dir}/SHA256SUMS" "$checksums_url" 2>/dev/null; then
        local expected_hash
        expected_hash=$(grep "${tarball_name}" "${tmp_dir}/SHA256SUMS" | awk '{print $1}')
        if [[ -n "$expected_hash" ]]; then
            local actual_hash
            if command -v sha256sum >/dev/null 2>&1; then
                actual_hash=$(sha256sum "${tmp_dir}/${tarball_name}" | awk '{print $1}')
            elif command -v shasum >/dev/null 2>&1; then
                actual_hash=$(shasum -a 256 "${tmp_dir}/${tarball_name}" | awk '{print $1}')
            fi
            if [[ -n "${actual_hash:-}" ]] && [[ "$actual_hash" != "$expected_hash" ]]; then
                rm -rf "$tmp_dir"
                echo "[x] SHA256 checksum mismatch! Aborting." >&2
                return 1
            fi
            echo "[+] Checksum verified."
        fi
    fi

    # Extract
    mkdir -p "$version_dir"
    tar -xzf "${tmp_dir}/${tarball_name}" -C "$version_dir" --strip-components=1

    # Update symlink
    ln -sfn "$version_dir" "${prefix}/current"

    rm -rf "$tmp_dir"
    _write_check_timestamp

    echo ""
    echo "Updated to Tekhton ${_LATEST_VERSION}."
    echo "Run 'tekhton --migrate' in each project to apply configuration updates."
    echo "See changelog: tekhton --docs"
    return 0
}
