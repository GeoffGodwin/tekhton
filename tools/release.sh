#!/usr/bin/env bash
# =============================================================================
# release.sh — Cut a Tekhton release: tag + push + GitHub Release
#
# Tags the current MAJOR version final state, pushes the tag, and creates a
# GitHub Release. Designed to run once per major version cutover (V2 final,
# V3 final, V4 final, etc.) — not once per minor milestone.
#
# Usage:
#   tools/release.sh <version> [<commit>]
#
# Examples:
#   tools/release.sh v3.66.0                    # tag at HEAD
#   tools/release.sh v3.66.0 4d10d05            # tag at specific commit
#   tools/release.sh v2.21.0 4ee4ade            # retroactive release
#
# What it does:
#   1. Validates the version format and that the commit is reachable
#   2. Reads release notes from notes/<version>.md (must exist)
#   3. Creates an annotated tag at <commit> (defaults to HEAD)
#   4. Pushes the tag to origin
#   5. If `gh` CLI is available, creates a GitHub Release using the notes file
#      and marks the latest stable semver release as Latest
#   6. Otherwise prints the URL where you can create the release manually
#
# Requires:
#   - git
#   - gh CLI (optional but recommended; without it the GitHub Release step
#     becomes a manual UI click)
# =============================================================================

set -euo pipefail

VERSION="${1:-}"
COMMIT="${2:-HEAD}"

# Resolve script directory so notes/ is found relative to the repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NOTES_DIR="$REPO_ROOT/tools/release_notes"

# --- Helpers ---------------------------------------------------------------
err()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
info() { printf '\033[1;36m[i]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

usage() {
    cat <<EOF
Usage: tools/release.sh <version> [<commit>]

  <version>  Semver tag like v3.66.0 (must start with 'v')
  <commit>   Optional commit SHA or ref (default: HEAD)

Release notes must exist at:
  tools/release_notes/<version>.md

Examples:
  tools/release.sh v3.66.0
  tools/release.sh v2.21.0 4ee4ade
EOF
    exit 1
}

# --- Validation ------------------------------------------------------------
[ -n "$VERSION" ] || usage

if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    err "Version must match vMAJOR.MINOR.PATCH (got: $VERSION)"
fi

cd "$REPO_ROOT"

# Check the commit resolves
if ! git rev-parse --verify "$COMMIT" >/dev/null 2>&1; then
    err "Commit not found: $COMMIT"
fi
COMMIT_SHA="$(git rev-parse "$COMMIT")"
COMMIT_SHORT="$(git rev-parse --short "$COMMIT")"
COMMIT_SUBJECT="$(git log -1 --format=%s "$COMMIT")"

# Check tag doesn't already exist locally or on origin
if git rev-parse --verify "refs/tags/$VERSION" >/dev/null 2>&1; then
    err "Tag $VERSION already exists locally. Delete it first: git tag -d $VERSION"
fi
if git ls-remote --tags origin "$VERSION" 2>/dev/null | grep -q "$VERSION"; then
    err "Tag $VERSION already exists on origin. Aborting to avoid overwriting."
fi

# Check release notes file
NOTES_FILE="$NOTES_DIR/$VERSION.md"
[ -f "$NOTES_FILE" ] || err "Release notes file not found: $NOTES_FILE
       Create it before running this script. Example template:
       echo '# $VERSION' > $NOTES_FILE"

NOTES_LINES="$(wc -l < "$NOTES_FILE" | tr -d ' ')"
[ "$NOTES_LINES" -ge 5 ] || warn "Release notes file is only $NOTES_LINES lines. Continue? (Ctrl+C to abort)"
[ "$NOTES_LINES" -lt 5 ] && read -r _

# --- Confirmation ----------------------------------------------------------
info "Release plan:"
printf "  Version:    %s\n" "$VERSION"
printf "  Commit:     %s (%s)\n" "$COMMIT_SHORT" "$COMMIT_SHA"
printf "  Subject:    %s\n" "$COMMIT_SUBJECT"
printf "  Notes:      %s (%s lines)\n" "$NOTES_FILE" "$NOTES_LINES"
echo
read -r -p "Proceed with release? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

# --- Step 1: Annotated tag ------------------------------------------------
info "Creating annotated tag $VERSION at $COMMIT_SHORT..."
# Use the first line of the notes file as the tag's summary line, the rest as body
TAG_MESSAGE="$(printf 'Tekhton %s\n\n' "$VERSION"; cat "$NOTES_FILE")"
git tag -a "$VERSION" "$COMMIT_SHA" -m "$TAG_MESSAGE"
ok "Tag created locally."

# --- Step 2: Push tag ------------------------------------------------------
info "Pushing tag to origin..."
if ! git push origin "$VERSION"; then
    warn "Push failed. The tag exists locally; you can retry with:"
    printf "    git push origin %s\n" "$VERSION"
    exit 1
fi
ok "Tag pushed to origin."

# --- Step 3: GitHub Release ------------------------------------------------
if command -v gh >/dev/null 2>&1; then
    info "Creating GitHub Release via gh CLI..."

    # Determine if this should be marked as Latest. We mark Latest only when
    # the version is the highest stable semver tag in the repo (no pre-release
    # suffix, and no other tag with a higher semver exists).
    LATEST_FLAG=""
    HIGHEST_TAG="$(git tag -l 'v*.*.*' | sort -V | tail -1)"
    if [ "$HIGHEST_TAG" = "$VERSION" ]; then
        LATEST_FLAG="--latest"
        info "This is the highest semver tag — will mark as Latest."
    else
        LATEST_FLAG="--latest=false"
        info "Higher tag exists ($HIGHEST_TAG) — will NOT mark as Latest."
    fi

    if gh release create "$VERSION" \
        --title "$VERSION — $(head -1 "$NOTES_FILE" | sed 's/^#* *//')" \
        --notes-file "$NOTES_FILE" \
        $LATEST_FLAG; then
        ok "GitHub Release created."
        gh release view "$VERSION" --web 2>/dev/null || true
    else
        warn "gh release create failed. Tag is pushed; create the release manually."
    fi
else
    warn "gh CLI not found. Tag is pushed but the GitHub Release page must be created manually."
    REPO_URL="$(git config --get remote.origin.url | sed -E 's#(git@|https?://)([^:/]+)[:/]([^/]+/[^.]+)(\.git)?#https://\2/\3#')"
    info "Open: ${REPO_URL}/releases/new?tag=$VERSION"
    info "Paste the body from: $NOTES_FILE"
fi

echo
ok "Release $VERSION complete."
