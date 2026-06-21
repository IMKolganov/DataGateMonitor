#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_SRC="$ROOT/.githooks/prepare-commit-msg"

resolve_git_dir() {
  local repo_path="$1"
  local git_entry="$repo_path/.git"

  if [ -d "$git_entry" ]; then
    echo "$git_entry"
    return
  fi

  if [ -f "$git_entry" ]; then
    local gitdir
    gitdir="$(sed -n 's/^gitdir: //p' "$git_entry")"
    if [[ "$gitdir" != /* ]]; then
      gitdir="$repo_path/$gitdir"
    fi
    echo "$(cd "$(dirname "$gitdir")" && pwd)/$(basename "$gitdir")"
  fi
}

install_hook() {
  local repo_path="$1"
  local git_dir
  git_dir="$(resolve_git_dir "$repo_path")"

  [ -n "$git_dir" ] && [ -d "$git_dir" ] || return 0

  local hook_dir="$git_dir/hooks"
  local hook_dst="$hook_dir/prepare-commit-msg"

  mkdir -p "$hook_dir"
  cp "$HOOK_SRC" "$hook_dst"
  chmod +x "$hook_dst"
}

install_hook "$ROOT"

while IFS= read -r path; do
  [ -n "$path" ] || continue
  install_hook "$ROOT/$path"
done < <(git -C "$ROOT" config --file .gitmodules --get-regexp path 2>/dev/null | awk '{print $2}')

echo "Installed prepare-commit-msg hook in monorepo and submodules."
