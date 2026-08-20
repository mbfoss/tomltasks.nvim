#!/usr/bin/env sh
# Generate doc/tomltasks.txt from README.md with panvimdoc.
#
#   scripts/gendoc.sh           # rewrite doc/tomltasks.txt and doc/tags
#   scripts/gendoc.sh --check   # exit 1 when the help file is out of date
#
# Needs pandoc (brew install pandoc). panvimdoc itself is fetched on first run
# and cached, pinned to the commit in PANVIMDOC_COMMIT below -- a tag can be
# moved, a commit cannot -- so the help file is reproducible. Point
# PANVIMDOC_DIR at a checkout of your own to use that instead. nvim is only
# used to refresh doc/tags, and is optional.

set -eu

PANVIMDOC_COMMIT=662fb20304d20c539fb48a0bda628f5165507de7 # v4.0.1
PANVIMDOC_URL=https://github.com/kdheepak/panvimdoc.git

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project=tomltasks
description="A project-local task runner for Neovim"
vimversion="Neovim >= 0.10"

out="$root/doc/$project.txt"
work="${TMPDIR:-/tmp}/$project-doc.$$"
trap 'rm -rf "$work"' EXIT INT TERM

command -v pandoc >/dev/null || {
    echo "gendoc: pandoc not found (brew install pandoc)" >&2
    exit 1
}

# Fetch panvimdoc at the pinned commit, once, into the user's cache. A plain
# clone cannot name a commit, so fetch that object and check it out directly.
cache="${XDG_CACHE_HOME:-$HOME/.cache}/panvimdoc-$PANVIMDOC_COMMIT"
panvimdoc="${PANVIMDOC_DIR:-$cache}"
if [ -n "${PANVIMDOC_DIR:-}" ]; then
    [ -f "$panvimdoc/panvimdoc.sh" ] || {
        echo "gendoc: no panvimdoc.sh in PANVIMDOC_DIR=$PANVIMDOC_DIR" >&2
        exit 1
    }
elif [ ! -f "$cache/panvimdoc.sh" ]; then
    echo "fetching panvimdoc $PANVIMDOC_COMMIT into $cache"
    rm -rf "$cache"
    mkdir -p "$cache"
    git -C "$cache" init --quiet
    git -C "$cache" fetch --quiet --depth 1 "$PANVIMDOC_URL" "$PANVIMDOC_COMMIT"
    git -c advice.detachedHead=false -C "$cache" checkout --quiet FETCH_HEAD
fi

# Make sure a reused cache really is the pinned commit.
if [ -z "${PANVIMDOC_DIR:-}" ]; then
    have=$(git -C "$cache" rev-parse HEAD)
    [ "$have" = "$PANVIMDOC_COMMIT" ] || {
        echo "gendoc: $cache is at $have, expected $PANVIMDOC_COMMIT" >&2
        echo "gendoc: remove that directory and re-run" >&2
        exit 1
    }
fi

# panvimdoc writes to doc/<project>.txt relative to the working directory, so
# run it in a scratch tree and compare from there.
mkdir -p "$work/doc"
(
    cd "$work"
    sh "$panvimdoc/panvimdoc.sh" \
        --project-name "$project" \
        --input-file "$root/README.md" \
        --vim-version "$vimversion" \
        --description "$description" \
        --toc true \
        --dedup-subheadings false \
        --shift-heading-level-by -1 \
        --treesitter true
) >/dev/null

if [ "${1:-}" = "--check" ]; then
    if cmp -s "$work/doc/$project.txt" "$out"; then
        echo "$out is up to date"
        exit 0
    fi
    echo "$out is out of date; run: scripts/gendoc.sh" >&2
    [ "${2:-}" = "--diff" ] && diff -u "$out" "$work/doc/$project.txt" || true
    exit 1
fi

mkdir -p "$root/doc"
cp "$work/doc/$project.txt" "$out"
echo "wrote $out"

if command -v nvim >/dev/null; then
    # helptags reports duplicate tags but still exits 0, so fail explicitly.
    nvim --headless -u NONE \
        -c "try | helptags $root/doc | catch | echomsg v:exception | cquit 1 | endtry" \
        -c qa >/dev/null
    echo "wrote $root/doc/tags"
else
    echo "nvim not found; run :helptags doc to refresh tags" >&2
fi
