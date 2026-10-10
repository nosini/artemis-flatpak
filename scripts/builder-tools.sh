#!/usr/bin/env bash
# Print the path of a flatpak-builder-tools checkout at the pinned commit,
# fetching it into .cache/ first when needed. The generators for pip, cargo,
# npm, Go and others live in its subdirectories:
# https://github.com/flatpak/flatpak-builder-tools
set -euo pipefail
cd "$(dirname "$0")/.."

commit=74697c75b630d7330e77250fc13cb5ea688d9479
dir=.cache/flatpak-builder-tools

if [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$commit" ]]; then
  rm -rf "$dir"
  git init -q "$dir"
  git -C "$dir" fetch -q --depth=1 https://github.com/flatpak/flatpak-builder-tools.git "$commit"
  git -C "$dir" checkout -q --detach FETCH_HEAD
fi
realpath "$dir"
