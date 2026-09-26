#!/usr/bin/env bash
# Run the picked test suite in a headless Neovim.
#
#   scripts/test.sh                 # everything under tests/spec
#   scripts/test.sh status_spec     # a single spec file (name or path)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# plenary.nvim provides the busted-style harness. Reuse an installed copy when
# one exists so CI and a developer machine behave the same.
PLENARY_DIR=""
for candidate in \
  "$ROOT/.tests/plenary.nvim" \
  "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/plenary.nvim" \
  "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/pack/packer/start/plenary.nvim"; do
  if [ -d "$candidate" ]; then
    PLENARY_DIR="$candidate"
    break
  fi
done

if [ -z "$PLENARY_DIR" ]; then
  echo "==> installing plenary.nvim into .tests/"
  mkdir -p "$ROOT/.tests"
  git clone --depth 1 --quiet https://github.com/nvim-lua/plenary.nvim "$ROOT/.tests/plenary.nvim"
  PLENARY_DIR="$ROOT/.tests/plenary.nvim"
fi

export PLENARY_PATH="$PLENARY_DIR"

TARGET="tests/spec"
if [ $# -gt 0 ]; then
  if [ -f "$1" ]; then
    TARGET="$1"
  elif [ -f "tests/spec/$1.lua" ]; then
    TARGET="tests/spec/$1.lua"
  elif [ -f "tests/spec/${1}_spec.lua" ]; then
    TARGET="tests/spec/${1}_spec.lua"
  else
    echo "no spec matching '$1'" >&2
    exit 1
  fi
fi

# plenary's :Plenary* commands live in plugin/ files that --noplugin skips, so
# drive the harness through its Lua API instead.
if [ -d "$TARGET" ]; then
  COMMAND="lua require('plenary.test_harness').test_directory('$TARGET', { minimal_init = 'tests/minimal_init.lua', sequential = true, timeout = 120000 })"
else
  COMMAND="lua require('plenary.busted').run('$TARGET')"
fi

exec nvim --headless --noplugin -u tests/minimal_init.lua -c "$COMMAND"
