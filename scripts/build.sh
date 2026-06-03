#!/usr/bin/env bash
# Build both the Lean core and Rust CLI.
#
# Automatically enters a nix shell if lake/cargo are not on PATH.
#
# Usage:
#   ./scripts/build.sh          # build both (release)
#   ./scripts/build.sh --debug  # build both (debug)
#   ./scripts/build.sh lean     # build Lean only
#   ./scripts/build.sh rust     # build Rust CLI only
#
# Run from project root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# ── Auto-enter nix shell if needed ──────────────────────────────────

needs_nix=false
if ! command -v lake &>/dev/null || ! command -v cargo &>/dev/null; then
  needs_nix=true
fi
if command -v nix &>/dev/null && command -v rustc &>/dev/null; then
  rust_sysroot="$(rustc --print sysroot 2>/dev/null || true)"
  if [ -e /etc/NIXOS ] && [[ "$rust_sysroot" == "$HOME/.rustup/"* ]]; then
    needs_nix=true
  fi
fi

if [ "$needs_nix" = true ]; then
  if ! command -v nix &>/dev/null; then
    echo "Error: neither lake/cargo nor nix found on PATH."
    exit 1
  fi
  echo "Entering nix shell..."
  exec nix shell nixpkgs#elan nixpkgs#cargo nixpkgs#rustc nixpkgs#clippy nixpkgs#shellcheck -c bash "$0" "$@"
fi

# ── Parse arguments ─────────────────────────────────────────────────

BUILD_LEAN=true
BUILD_RUST=true
RUST_PROFILE="--release"

for arg in "$@"; do
  case "$arg" in
    lean)
      BUILD_RUST=false
      ;;
    rust)
      BUILD_LEAN=false
      ;;
    --debug)
      RUST_PROFILE=""
      ;;
    --help|-h)
      echo "Usage: $0 [lean|rust] [--debug]"
      echo "  lean     Build Lean only"
      echo "  rust     Build Rust CLI only"
      echo "  --debug  Build Rust in debug mode (default: release)"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg"
      echo "Run '$0 --help' for usage."
      exit 1
      ;;
  esac
done

# ── Lean ────────────────────────────────────────────────────────────

if [ "$BUILD_LEAN" = true ]; then
  echo "=== Building Lean core ==="
  lake build
  echo "Lean binary: .lake/build/bin/tekken_query"
  echo ""
fi

# ── Rust ────────────────────────────────────────────────────────────

if [ "$BUILD_RUST" = true ]; then
  echo "=== Building Rust CLI ==="

  # shellcheck disable=SC2086
  cargo build $RUST_PROFILE --manifest-path cli/Cargo.toml

  if [ -n "$RUST_PROFILE" ]; then
    echo "Rust binary: cli/target/release/tekken-cli"
  else
    echo "Rust binary: cli/target/debug/tekken-cli"
  fi
  echo ""
fi

# ── Lint checks ─────────────────────────────────────────────────────

if [ "$BUILD_LEAN" = true ]; then
  echo "=== Lean checks ==="
  if grep -rn 'sorry\|unsafe\|partial\|implemented_by\|native_decide' --include='*.lean' .; then
    echo "FAIL: banned constructs found in Lean code"
    exit 1
  else
    echo "OK: no banned constructs"
  fi
  echo ""
fi

if [ "$BUILD_RUST" = true ]; then
  echo "=== Rust clippy ==="
  cargo clippy --manifest-path cli/Cargo.toml -- -D warnings
  echo ""
fi

echo "=== Build complete ==="
