#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/mbfoss/neotoolkit.nvim"
DEST="lua/easytasks/tk"
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
mkdir -p "$DEST"
rm -f "$DEST"/*.lua
cp "$TMP/neotoolkit/lua/neotoolkit/"*.lua "$DEST/"

echo "Rewriting require paths and type annotations..."
sed -i '' 's/neotoolkit\./easytasks.tk./g' "$DEST"/*.lua

echo "Done. $DEST is fully vendored; lua/easytasks/util/ (easytasks's own files) is untouched."
