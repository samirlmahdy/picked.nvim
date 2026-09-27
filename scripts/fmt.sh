#!/usr/bin/env bash
# Format the Lua sources with stylua, using the same settings and the same
# paths CI checks.
#
#   scripts/fmt.sh            # rewrite files in place
#   scripts/fmt.sh --check    # report without writing, exactly as CI does
#
# stylua is fetched into .tests/ on first use — it is not installed system
# wide, and .tests/ is gitignored. Reuses a copy already on PATH if there is
# one, so a version you manage yourself wins.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Keep this in step with .github/workflows/ci.yml.
TARGETS=(lua/ tests/ plugin/)

find_stylua() {
  if command -v stylua >/dev/null 2>&1; then
    command -v stylua
    return
  fi
  if [ -x "$ROOT/.tests/stylua" ]; then
    echo "$ROOT/.tests/stylua"
    return
  fi
  return 1
}

install_stylua() {
  local os arch asset tag tmp
  case "$(uname -s)" in
    Darwin) os="macos" ;;
    Linux)  os="linux" ;;
    *)      echo "unsupported platform $(uname -s); install stylua yourself" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch="aarch64" ;;
    x86_64|amd64)  arch="x86_64" ;;
    *)             echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac

  tag="$(curl -fsSL https://api.github.com/repos/JohnnyMorganz/StyLua/releases/latest \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$tag" ] || { echo "could not determine the latest stylua release" >&2; exit 1; }

  asset="stylua-${os}-${arch}.zip"
  echo "==> fetching stylua ${tag} (${asset}) into .tests/"

  mkdir -p "$ROOT/.tests"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  curl -fsSL -o "$tmp/stylua.zip" \
    "https://github.com/JohnnyMorganz/StyLua/releases/download/${tag}/${asset}"
  unzip -oq "$tmp/stylua.zip" -d "$tmp"
  mv "$tmp/stylua" "$ROOT/.tests/stylua"
  chmod +x "$ROOT/.tests/stylua"
}

STYLUA="$(find_stylua || true)"
if [ -z "$STYLUA" ]; then
  install_stylua
  STYLUA="$ROOT/.tests/stylua"
fi

if [ "${1:-}" = "--check" ]; then
  echo "==> $("$STYLUA" --version) --check ${TARGETS[*]}"
  exec "$STYLUA" --check "${TARGETS[@]}"
fi

echo "==> $("$STYLUA" --version) ${TARGETS[*]}"
"$STYLUA" "${TARGETS[@]}"
echo "formatted."
