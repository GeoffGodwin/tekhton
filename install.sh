#!/usr/bin/env bash
# =============================================================================
# install.sh — Cross-platform Tekhton installer
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/geoffgodwin/tekhton/main/install.sh | bash
#   curl ... | bash -s -- --prefix=/opt/tekhton
#   curl ... | bash -s -- --version=3.5.0
#   curl ... | bash -s -- --uninstall
#
# This script must remain bash 3.2 compatible (macOS ships bash 3.2).
# Tekhton itself requires bash 4.3+, but this installer runs BEFORE Tekhton.
# =============================================================================

set -euo pipefail

# --- Constants ---------------------------------------------------------------

GITHUB_REPO="geoffgodwin/tekhton"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}"
GITHUB_RAW="https://github.com/${GITHUB_REPO}/releases/download"
DEFAULT_PREFIX="${HOME}/.tekhton"
DOCS_URL="https://geoffgodwin.github.io/tekhton/"

# --- Colors (portable — no tput dependency) ----------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'  # No color

# --- Helpers -----------------------------------------------------------------

info()  { echo -e "${BLUE}[i]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# --- Argument parsing --------------------------------------------------------

INSTALL_PREFIX="${DEFAULT_PREFIX}"
INSTALL_VERSION=""
NO_PATH=false
UNINSTALL=false

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix=*) INSTALL_PREFIX="${1#--prefix=}"; shift ;;
        --prefix)   shift; INSTALL_PREFIX="${1:-}"; shift ;;
        --version=*) INSTALL_VERSION="${1#--version=}"; shift ;;
        --version)  shift; INSTALL_VERSION="${1:-}"; shift ;;
        --no-path)  NO_PATH=true; shift ;;
        --uninstall) UNINSTALL=true; shift ;;
        --help|-h)
            echo "Tekhton Installer"
            echo ""
            echo "Usage: install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --prefix=DIR     Install to DIR (default: ~/.tekhton)"
            echo "  --version=X.Y.Z  Install specific version (default: latest)"
            echo "  --no-path        Don't modify shell rc files"
            echo "  --uninstall      Remove Tekhton installation"
            echo "  --help           Show this help"
            exit 0
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done

# --- Platform detection ------------------------------------------------------

detect_platform() {
    local os arch

    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Linux)
            # Check for WSL
            if grep -qi microsoft /proc/version 2>/dev/null; then
                PLATFORM="linux-wsl"
            else
                PLATFORM="linux"
            fi
            ;;
        Darwin)
            PLATFORM="macos"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo ""
            fail "Git Bash / MSYS / Cygwin is not supported.

Tekhton requires bash 4.3+ features (associative arrays, etc.) that are
not available in Git Bash. Please install Windows Subsystem for Linux (WSL):

  1. Open PowerShell as Administrator
  2. Run: wsl --install
  3. Restart your computer
  4. Open Ubuntu from the Start menu
  5. Re-run this installer inside WSL

More info: https://learn.microsoft.com/en-us/windows/wsl/install"
            ;;
        *)
            fail "Unsupported operating system: ${os}"
            ;;
    esac

    case "$arch" in
        x86_64|amd64) ARCH="x86_64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) ARCH="$arch" ;;
    esac
}

# --- Bash version check -----------------------------------------------------

check_bash_version() {
    local major="${BASH_VERSINFO[0]:-0}"
    local minor="${BASH_VERSINFO[1]:-0}"

    if [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 3 ]; }; then
        if [ "$PLATFORM" = "macos" ]; then
            echo ""
            echo "Tekhton requires bash 4.3+. Install modern bash via Homebrew:"
            echo "  brew install bash"
            echo ""
            echo "Then ensure /opt/homebrew/bin/bash (or /usr/local/bin/bash)"
            echo "is used when running tekhton. You can add to your shell rc:"
            echo "  export PATH=\"/opt/homebrew/bin:\$PATH\""
            echo ""
            fail "macOS ships with bash ${BASH_VERSION} (version 3.x). Aborting."
        else
            echo "Please upgrade bash to 4.3+ before running Tekhton."
            fail "Bash ${BASH_VERSION} detected. Tekhton requires bash 4.3+."
        fi
    fi
}

# --- Dependency check --------------------------------------------------------

check_dependencies() {
    local missing=""

    for cmd in curl tar sha256sum; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            # macOS uses shasum instead of sha256sum
            if [ "$cmd" = "sha256sum" ] && command -v shasum >/dev/null 2>&1; then
                continue
            fi
            missing="${missing} ${cmd}"
        fi
    done

    if [ -n "$missing" ]; then
        fail "Missing required commands:${missing}

Install them with your package manager:
  Ubuntu/Debian: sudo apt install${missing}
  macOS:         brew install${missing}
  Fedora:        sudo dnf install${missing}"
    fi
}

# --- SHA256 verification (portable) -----------------------------------------

verify_sha256() {
    local file="$1" expected="$2"
    local actual

    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        warn "No sha256sum or shasum found — skipping checksum verification."
        return 0
    fi

    if [ "$actual" != "$expected" ]; then
        fail "SHA256 checksum mismatch!
  Expected: ${expected}
  Got:      ${actual}

The download may be corrupted or tampered with. Aborting."
    fi
    ok "SHA256 checksum verified."
}

# --- Fetch latest version from GitHub ----------------------------------------

fetch_latest_version() {
    local response
    response=$(curl -sSL --fail "${GITHUB_API}/releases/latest" 2>/dev/null) || {
        fail "Could not fetch latest release from GitHub.
Check your internet connection or specify a version: --version=X.Y.Z"
    }

    # Extract tag_name — portable grep (no -P or -o on macOS bash 3.2)
    INSTALL_VERSION=$(echo "$response" | grep '"tag_name"' | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/')

    if [ -z "$INSTALL_VERSION" ]; then
        fail "Could not parse version from GitHub API response."
    fi

    # Strip leading 'v' if present
    INSTALL_VERSION="${INSTALL_VERSION#v}"
}

# --- Download and install ----------------------------------------------------

download_and_install() {
    local version="$1"
    local prefix="$2"
    local version_dir="${prefix}/versions/${version}"
    local tarball_name="tekhton-${version}.tar.gz"
    local tarball_url="${GITHUB_RAW}/v${version}/${tarball_name}"
    local checksums_url="${GITHUB_RAW}/v${version}/SHA256SUMS"
    local tmp_dir

    tmp_dir=$(mktemp -d)
    # Ensure cleanup on exit from this function
    # shellcheck disable=SC2064  # Intentional: expand tmp_dir now so the trap cleans up the right dir
    trap "rm -rf '${tmp_dir}'" EXIT

    info "Downloading Tekhton ${version}..."
    curl -sSL --fail -o "${tmp_dir}/${tarball_name}" "$tarball_url" 2>/dev/null || {
        # Fall back to git clone if release tarball not available
        warn "Release tarball not found. Falling back to git clone..."
        git_clone_install "$version" "$prefix"
        return
    }

    # Download and verify checksum
    info "Verifying checksum..."
    local expected_hash
    if curl -sSL --fail -o "${tmp_dir}/SHA256SUMS" "$checksums_url" 2>/dev/null; then
        expected_hash=$(grep "${tarball_name}" "${tmp_dir}/SHA256SUMS" | awk '{print $1}')
        if [ -n "$expected_hash" ]; then
            verify_sha256 "${tmp_dir}/${tarball_name}" "$expected_hash"
        else
            warn "Tarball not found in SHA256SUMS — skipping verification."
        fi
    else
        warn "SHA256SUMS not available — skipping verification."
    fi

    # Create version directory
    mkdir -p "$version_dir"

    # Extract tarball
    info "Extracting to ${version_dir}..."
    tar -xzf "${tmp_dir}/${tarball_name}" -C "$version_dir" --strip-components=1

    # Update current symlink
    ln -sfn "${version_dir}" "${prefix}/current"
    ok "Installed Tekhton ${version} to ${version_dir}"

    rm -rf "$tmp_dir"
    trap - EXIT
}

# --- Git clone fallback (dev installs) ---------------------------------------

git_clone_install() {
    local version="$1"
    local prefix="$2"
    local version_dir="${prefix}/versions/${version}"

    if ! command -v git >/dev/null 2>&1; then
        fail "git is required for dev installs (no release tarball found)."
    fi

    info "Cloning from GitHub..."
    mkdir -p "$version_dir"

    local clone_ref="main"
    if [ -n "$version" ] && [ "$version" != "latest" ]; then
        clone_ref="v${version}"
    fi

    git clone --depth 1 --branch "$clone_ref" \
        "https://github.com/${GITHUB_REPO}.git" \
        "${version_dir}" 2>/dev/null || {
        # If tag doesn't exist, try main
        git clone --depth 1 \
            "https://github.com/${GITHUB_REPO}.git" \
            "${version_dir}" 2>/dev/null || fail "git clone failed."
    }

    # Remove .git directory from installation (not needed at runtime)
    rm -rf "${version_dir}/.git"

    # Update current symlink
    ln -sfn "${version_dir}" "${prefix}/current"
    ok "Installed Tekhton (dev) to ${version_dir}"
}

# --- PATH setup --------------------------------------------------------------

detect_shell_rc() {
    local current_shell
    current_shell=$(basename "${SHELL:-/bin/bash}")

    case "$current_shell" in
        zsh)
            if [ -f "${HOME}/.zshrc" ]; then
                echo "${HOME}/.zshrc"
            else
                echo "${HOME}/.zshenv"
            fi
            ;;
        bash)
            # Prefer .bashrc on Linux, .bash_profile on macOS
            if [ "$PLATFORM" = "macos" ]; then
                if [ -f "${HOME}/.bash_profile" ]; then
                    echo "${HOME}/.bash_profile"
                elif [ -f "${HOME}/.bashrc" ]; then
                    echo "${HOME}/.bashrc"
                else
                    echo "${HOME}/.bash_profile"
                fi
            else
                if [ -f "${HOME}/.bashrc" ]; then
                    echo "${HOME}/.bashrc"
                elif [ -f "${HOME}/.bash_profile" ]; then
                    echo "${HOME}/.bash_profile"
                else
                    echo "${HOME}/.bashrc"
                fi
            fi
            ;;
        fish)
            echo "${HOME}/.config/fish/config.fish"
            ;;
        *)
            if [ -f "${HOME}/.profile" ]; then
                echo "${HOME}/.profile"
            else
                echo "${HOME}/.bashrc"
            fi
            ;;
    esac
}

setup_path() {
    local prefix="$1"
    local bin_path="${prefix}/current"
    local tekhton_bin="${bin_path}/tekhton.sh"

    # Option 1: symlink to /usr/local/bin if writable
    if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
        ln -sf "$tekhton_bin" /usr/local/bin/tekhton
        ok "Symlinked tekhton to /usr/local/bin/tekhton"
        return
    fi

    # Option 2: Add to PATH via shell rc file
    if [ "$NO_PATH" = true ]; then
        warn "Skipping PATH setup (--no-path). Add to your PATH manually:"
        echo "  export PATH=\"${bin_path}:\$PATH\""
        return
    fi

    local rc_file
    rc_file=$(detect_shell_rc)
    local path_line="export PATH=\"${bin_path}:\$PATH\"  # Added by Tekhton installer"
    local alias_line="alias tekhton='${tekhton_bin}'  # Added by Tekhton installer"
    local current_shell
    current_shell=$(basename "${SHELL:-/bin/bash}")

    # Fish uses different syntax
    if [ "$current_shell" = "fish" ]; then
        path_line="set -gx PATH ${bin_path} \$PATH  # Added by Tekhton installer"
        alias_line="alias tekhton '${tekhton_bin}'  # Added by Tekhton installer"
    fi

    # Check if already in PATH
    if echo "$PATH" | tr ':' '\n' | grep -q "^${bin_path}$" 2>/dev/null; then
        ok "PATH already includes ${bin_path}"
        return
    fi

    # Check if rc file already has our line
    if [ -f "$rc_file" ] && grep -q "Added by Tekhton installer" "$rc_file" 2>/dev/null; then
        ok "Shell rc file already configured."
        return
    fi

    # Show preview and ask for confirmation
    echo ""
    info "To add tekhton to your PATH, the following will be appended to ${rc_file}:"
    echo ""
    echo "  ${path_line}"
    echo "  ${alias_line}"
    echo ""

    # Interactive check — if stdin is a terminal, ask; otherwise proceed
    if [ -t 0 ]; then
        printf "  Proceed? [Y/n] "
        read -r answer
        case "$answer" in
            n|N|no|NO)
                warn "Skipping PATH setup. Add manually:"
                echo "  ${path_line}"
                return
                ;;
        esac
    fi

    # Backup rc file before modifying
    if [ -f "$rc_file" ]; then
        cp "$rc_file" "${rc_file}.tekhton-backup"
        info "Backed up ${rc_file} to ${rc_file}.tekhton-backup"
    fi

    # Create parent directory if needed (for fish)
    mkdir -p "$(dirname "$rc_file")"

    {
        echo ""
        echo "# Tekhton"
        echo "${path_line}"
        echo "${alias_line}"
    } >> "$rc_file"

    ok "Updated ${rc_file}"
    info "Run 'source ${rc_file}' or open a new terminal to use tekhton."
}

# --- Uninstall ---------------------------------------------------------------

run_uninstall() {
    local prefix="$1"

    info "Uninstalling Tekhton from ${prefix}..."

    # Remove symlink from /usr/local/bin
    if [ -L "/usr/local/bin/tekhton" ]; then
        rm -f /usr/local/bin/tekhton
        ok "Removed /usr/local/bin/tekhton symlink"
    fi

    # Remove PATH entries from shell rc files
    local rc_files=("${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.zshrc" "${HOME}/.zshenv" "${HOME}/.profile" "${HOME}/.config/fish/config.fish")
    for rc_file in "${rc_files[@]}"; do
        if [ -f "$rc_file" ] && grep -q "Added by Tekhton installer" "$rc_file" 2>/dev/null; then
            # Remove lines added by installer
            local tmp_rc
            tmp_rc=$(mktemp)
            grep -v "Added by Tekhton installer" "$rc_file" | grep -v "^# Tekhton$" > "$tmp_rc" || true
            mv "$tmp_rc" "$rc_file"
            ok "Cleaned up ${rc_file}"
        fi
    done

    # Remove installation directory
    if [ -d "$prefix" ]; then
        rm -rf "$prefix"
        ok "Removed ${prefix}"
    fi

    echo ""
    ok "Tekhton has been uninstalled."
    info "Project-level .claude/ directories were NOT removed."
}

# --- Verify installation -----------------------------------------------------

verify_installation() {
    local prefix="$1"
    local tekhton_bin="${prefix}/current/tekhton.sh"

    if [ ! -f "$tekhton_bin" ]; then
        fail "Installation verification failed: ${tekhton_bin} not found."
    fi

    if [ ! -x "$tekhton_bin" ]; then
        chmod +x "$tekhton_bin"
    fi

    # Try to get version
    local installed_version
    installed_version=$(grep '^TEKHTON_VERSION=' "$tekhton_bin" | head -1 | sed 's/.*="\(.*\)"/\1/')

    if [ -n "$installed_version" ]; then
        ok "Verified: Tekhton ${installed_version}"
    else
        ok "Verified: tekhton.sh exists at ${tekhton_bin}"
    fi
}

# --- Main --------------------------------------------------------------------

main() {
    echo ""
    echo -e "${BOLD}Tekhton Installer${NC}"
    echo ""

    detect_platform
    info "Platform: ${PLATFORM} (${ARCH})"

    if [ "$UNINSTALL" = true ]; then
        run_uninstall "$INSTALL_PREFIX"
        exit 0
    fi

    check_bash_version
    check_dependencies

    # Determine version to install
    if [ -z "$INSTALL_VERSION" ]; then
        info "Fetching latest version..."
        fetch_latest_version
    fi
    info "Version: ${INSTALL_VERSION}"

    # Create install prefix
    mkdir -p "$INSTALL_PREFIX"

    # Download and install
    download_and_install "$INSTALL_VERSION" "$INSTALL_PREFIX"

    # Set up PATH
    setup_path "$INSTALL_PREFIX"

    # Verify
    verify_installation "$INSTALL_PREFIX"

    # Print WSL note if applicable
    if [ "$PLATFORM" = "linux-wsl" ]; then
        echo ""
        info "Note: ~/.tekhton/ inside WSL is not directly visible from"
        info "Windows Explorer. Use WSL terminal to run tekhton."
    fi

    # Success message
    echo ""
    echo -e "${GREEN}Tekhton ${INSTALL_VERSION} installed successfully!${NC}"
    echo ""
    echo "  Next steps:"
    echo "    cd /path/to/your/project"
    echo "    tekhton --init"
    echo ""
    echo "  Documentation: ${DOCS_URL}"
    echo ""
    echo "  Security note: You can also install by downloading and reviewing"
    echo "  this script first:"
    echo "    curl -sSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh -o install.sh"
    echo "    less install.sh   # review the script"
    echo "    bash install.sh"
    echo ""
}

main "$@"
