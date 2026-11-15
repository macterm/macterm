#!/usr/bin/env bash
# Decide which areas of .github/path-areas a commit changes, and write
# `<area>=true|false` for each area to stdout and to $GITHUB_OUTPUT.
#
# The changed files come from git, with no API call:
# - pull_request: the merge commit against its first parent (fetch-depth: 2).
# - push: $BEFORE against HEAD. A new branch, or a $BEFORE that the script
#   cannot fetch, sets every area.
# - any other event: every area.
# A change to the table or to this script also sets every area.
set -euo pipefail

cd "$(dirname "$0")/.."
table=.github/path-areas

# One entry for each area of each line.
areas=()
patterns=()
while read -r names pattern _; do
  [[ -z "$names" || "$names" == \#* ]] && continue
  IFS=, read -ra split <<<"$names"
  for area in "${split[@]}"; do
    areas+=("$area")
    patterns+=("$pattern")
  done
done <"$table"

# quotePath=false: git quotes a path with non-ASCII bytes, and no pattern
# matches a quoted path.
diff_names() { git -c core.quotePath=false diff --no-renames --name-only "$@"; }

all=false
files=""
case "${GITHUB_EVENT_NAME:-}" in
  pull_request)
    files="$(diff_names HEAD^1 HEAD)"
    ;;
  push)
    before="${BEFORE:-}"
    if [[ -z "$before" || "$before" =~ ^0+$ ]] || ! git fetch --quiet --no-tags --depth=1 origin "$before"; then
      all=true
    else
      files="$(diff_names "$before" HEAD)"
    fi
    ;;
  *)
    all=true
    ;;
esac

if grep -qxE '\.github/path-areas|scripts/changed-areas\.sh' <<<"$files"; then
  all=true
fi

output="${GITHUB_OUTPUT:-/dev/null}"
for area in $(printf '%s\n' "${areas[@]}" | sort -u); do
  changed="$all"
  if [[ "$changed" == false ]]; then
    for i in "${!areas[@]}"; do
      [[ "${areas[$i]}" == "$area" ]] || continue
      while IFS= read -r file; do
        # shellcheck disable=SC2053 # The pattern is a glob on purpose.
        if [[ -n "$file" && "$file" == ${patterns[$i]} ]]; then
          changed=true
          break 2
        fi
      done <<<"$files"
    done
  fi
  echo "$area=$changed" | tee -a "$output"
done
