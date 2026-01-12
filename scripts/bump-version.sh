#!/bin/bash

# Version Bumping Script for Rem
# Usage: ./scripts/bump-version.sh [major|minor|patch]

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
VERSION_FILE="$PROJECT_ROOT/VERSION"

# Read current version
if [[ ! -f "$VERSION_FILE" ]]; then
    echo "1.0.0" > "$VERSION_FILE"
fi

CURRENT_VERSION=$(cat "$VERSION_FILE" | tr -d '\n')

# Parse version components
IFS='.' read -ra VERSION_PARTS <<< "$CURRENT_VERSION"
MAJOR=${VERSION_PARTS[0]:-0}
MINOR=${VERSION_PARTS[1]:-0}
PATCH=${VERSION_PARTS[2]:-0}

# Determine bump type
BUMP_TYPE="${1:-patch}"

case $BUMP_TYPE in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch)
        PATCH=$((PATCH + 1))
        ;;
    *)
        echo "Usage: $0 [major|minor|patch]"
        echo "  major: Increment major version (breaking changes)"
        echo "  minor: Increment minor version (new features)"
        echo "  patch: Increment patch version (bug fixes)"
        exit 1
        ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"

# Update VERSION file
echo "$NEW_VERSION" > "$VERSION_FILE"

echo "Version bumped: $CURRENT_VERSION -> $NEW_VERSION"

# Update Info.plist if it exists
INFO_PLIST="$PROJECT_ROOT/rem/Info.plist"
if [[ -f "$INFO_PLIST" ]]; then
    # Use PlistBuddy on macOS
    if command -v /usr/libexec/PlistBuddy &> /dev/null; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$INFO_PLIST" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_VERSION" "$INFO_PLIST" 2>/dev/null || true
        echo "Updated Info.plist"
    fi
fi

# Create git tag if in a git repo
if git rev-parse --git-dir > /dev/null 2>&1; then
    echo ""
    echo "To create a release:"
    echo "  git add VERSION"
    echo "  git commit -m 'Bump version to $NEW_VERSION'"
    echo "  git tag -a v$NEW_VERSION -m 'Release v$NEW_VERSION'"
    echo "  git push origin main --tags"
fi
