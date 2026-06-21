#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/imkolganov/Projects/DataGateMonitor"
MAP_DIR=$(mktemp -d)
trap 'rm -rf "$MAP_DIR"' EXIT

build_tree_map() {
  local repo="$1"
  local out="$2"
  : > "$out"
  git -C "$repo" rev-list --all | while read -r sha; do
    tree=$(git -C "$repo" rev-parse "$sha^{tree}")
    if ! awk -v t="$tree" '$1==t {found=1; exit} END{exit !found}' "$out"; then
      echo "$tree $sha" >> "$out"
    fi
  done
  echo "    $1 tree map: $(wc -l < "$out") entries"
}

build_tree_map "$ROOT/backend" "$MAP_DIR/backend-trees.txt"
build_tree_map "$ROOT/frontend" "$MAP_DIR/frontend-trees.txt"

lookup_new_sha() {
  local repo="$1"
  local old_sha="$2"
  local map_file="$3"
  local tree
  tree=$(git -C "$repo" rev-parse "$old_sha^{tree}" 2>/dev/null) || return 0
  awk -v t="$tree" '$1==t {print $2; exit}' "$map_file"
}

export ROOT MAP_DIR
export -f lookup_new_sha

tree_filter='
  for path in backend frontend; do
    sha=$(git ls-tree HEAD "$path" 2>/dev/null | awk "{print \$3}")
    [ -n "$sha" ] || continue
    repo="$ROOT/$path"
    map="$MAP_DIR/${path}-trees.txt"
    newsha=$(lookup_new_sha "$repo" "$sha" "$map")
    if [ -n "$newsha" ] && [ "$newsha" != "$sha" ]; then
      git update-index --cacheinfo 160000,"$newsha","$path"
    fi
  done
'

export FILTER_BRANCH_SQUELCH_WARNING=1
git -C "$ROOT" filter-branch -f --tree-filter "$tree_filter" -- --all
git -C "$ROOT" for-each-ref --format='%(refname)' refs/original/ \
  | xargs -r -n1 git -C "$ROOT" update-ref -d

echo ">>> monorepo gitlinks after fix"
git -C "$ROOT" ls-tree main backend frontend
git -C "$ROOT" ls-tree develop backend frontend
