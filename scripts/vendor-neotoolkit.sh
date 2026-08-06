#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/mbfoss/neotoolkit.nvim"
DEST="lua/tomltasks/util"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cd "$(dirname "$0")/.."

if [[ -n "${LOCAL:-}" ]]; then
    echo "Using local repo: $LOCAL"
    cp -r "$LOCAL" "$TMP/neotoolkit"
else
    echo "Cloning $REPO..."
    git clone --depth=1 "$REPO" "$TMP/neotoolkit"
fi

echo "Syncing files into $DEST..."
cp "$TMP/neotoolkit/lua/neotoolkit/"*.lua "$DEST/"

echo "Rewriting require paths and type annotations..."
sed -i '' 's/neotoolkit\./tomltasks.util./g' "$DEST"/*.lua

echo "Done. Vendored files in $DEST refreshed; tomltasks's own files there are untouched."
