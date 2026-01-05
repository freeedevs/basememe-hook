#!/usr/bin/env bash
set -euo pipefail

if ! command -v forge >/dev/null 2>&1; then
  echo "error: 'forge' not found; install Foundry first" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "error: 'git' not found; required for submodules" >&2
  exit 1
fi

if [[ ! -f ".gitmodules" ]]; then
  echo "error: .gitmodules not found; this repo expects dependencies as git submodules" >&2
  echo "hint: run 'forge install ...' to add submodules (repo maintainer), or re-clone with submodules" >&2
  exit 1
fi

git submodule sync --recursive
git submodule update --init --recursive

echo "done: submodules initialized under ./lib"
