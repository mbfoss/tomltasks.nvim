#!/usr/bin/env bash
# decode.sh — toml-test compatible TOML decoder
# Reads TOML from stdin, writes tagged JSON to stdout.
# Exit code 0 on success, non-zero on invalid TOML.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec nvim -l "$SCRIPT_DIR/decode_runner.lua"
