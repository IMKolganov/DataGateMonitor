#!/usr/bin/env bash
set -euo pipefail

MSG_FILTER='sed -e "/^Co-authored-by: Cursor <cursoragent@cursor.com>$/d" -e "/^Made-with: Cursor$/d"'

strip_cursor_trailers() {
  local repo="$1"
  echo ">>> Rewriting commit messages in $repo"
  git -C "$repo" filter-branch -f \
    --msg-filter "$MSG_FILTER" \
    --tag-name-filter cat \
    -- --all
  git -C "$repo" for-each-ref --format='%(refname)' refs/original/ \
    | xargs -r -n1 git -C "$repo" update-ref -d
}

build_sha_map() {
  local repo="$1"
  local out="$2"
  : > "$out"
  git -C "$repo" for-each-ref --format='%(refname)' refs/original/ | while read -r origref; do
    newref="${origref#refs/original/}"
    paste \
      <(git -C "$repo" rev-list --reverse "$origref") \
      <(git -C "$repo" rev-list --reverse "$newref")
  done | awk '!seen[$1]++' >> "$out"
  echo "    map entries: $(wc -l < "$out")"
}

update_submodule_gitlinks() {
  local repo="$1"
  local map_dir="$2"
  echo ">>> Updating submodule gitlinks in $repo"

  local tree_filter=''
  tree_filter='
    for path in backend frontend openvpn xray telegrambot; do
      sha=$(git ls-tree HEAD "$path" 2>/dev/null | awk "{print \$3}")
      [ -n "$sha" ] || continue
      mapfile="'"$map_dir"'/${path}-map.txt"
      if [ -f "$mapfile" ]; then
        newsha=$(awk -v old="$sha" "$1==old {print $2; exit}" "$mapfile")
        if [ -n "$newsha" ] && [ "$newsha" != "$sha" ]; then
          git update-index --cacheinfo 160000,"$newsha","$path"
        fi
      fi
    done
  '

  git -C "$repo" filter-branch -f \
    --msg-filter "$MSG_FILTER" \
    --tree-filter "$tree_filter" \
    --tag-name-filter cat \
    -- --all

  git -C "$repo" for-each-ref --format='%(refname)' refs/original/ \
    | xargs -r -n1 git -C "$repo" update-ref -d
}

ROOT="/home/imkolganov/Projects/DataGateMonitor"
MAP_DIR=$(mktemp -d)
export FILTER_BRANCH_SQUELCH_WARNING=1

strip_cursor_trailers "$ROOT/backend"
build_sha_map "$ROOT/backend" "$MAP_DIR/backend-map.txt"

strip_cursor_trailers "$ROOT/frontend"
build_sha_map "$ROOT/frontend" "$MAP_DIR/frontend-map.txt"

update_submodule_gitlinks "$ROOT" "$MAP_DIR"

rm -rf "$MAP_DIR"

echo ">>> Verify no cursoragent left"
for repo in "$ROOT" "$ROOT/backend" "$ROOT/frontend"; do
  name=$(basename "$repo")
  [ "$repo" = "$ROOT" ] && name="monorepo"
  if git -C "$repo" log --all --format=%B | grep -qi cursoragent; then
    echo "FAIL: still found in $name"
    exit 1
  fi
  echo "OK: $name clean"
done

echo "Done. Force-push develop/main in each repo when ready."
