#!/usr/bin/env bash
# Start the Tekken CLI in interactive mode.
#
# Builds first if binaries are missing. Automatically enters a nix
# shell if cargo/lake are not on PATH.
#
# Usage:
#   ./scripts/start.sh                      # interactive REPL
#   ./scripts/start.sh query jin mid plus   # one-shot query
#   ./scripts/start.sh chars                # list characters
#   ./scripts/start.sh --help               # CLI help
#
# Run from project root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# ── Auto-enter nix shell if needed ──────────────────────────────────

if ! command -v cargo &>/dev/null; then
  if ! command -v nix &>/dev/null; then
    echo "Error: neither cargo nor nix found on PATH."
    exit 1
  fi
  echo "Entering nix shell..."
  exec nix shell nixpkgs#elan nixpkgs#rustup -c bash "$0" "$@"
fi

# ── Build if needed ─────────────────────────────────────────────────

RUST_BIN="cli/target/release/tekken-cli"
LEAN_BIN=".lake/build/bin/tekken_query"

if [ ! -f "$RUST_BIN" ]; then
  echo "Rust binary not found, building..."
  cargo build --release --manifest-path cli/Cargo.toml
  echo ""
fi

if [ ! -f "$LEAN_BIN" ]; then
  if command -v lake &>/dev/null; then
    echo "Lean binary not found, building..."
    lake build
    echo ""
  else
    echo "Note: Lean binary not found (lake not available)."
    echo "  Queries will use unverified Rust-side evaluation."
    echo ""
  fi
fi

# ── Run ─────────────────────────────────────────────────────────────

DATA_DIR="$PROJECT_ROOT/data"

if [ $# -eq 0 ]; then
  exec "$RUST_BIN" -d "$DATA_DIR" interactive
else
  exec "$RUST_BIN" -d "$DATA_DIR" "$@"
fi
