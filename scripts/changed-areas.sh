#!/usr/bin/env bash
# Decide which path areas of .github/path-areas a commit changes, and write
# `<area>=true|false` for each area to stdout and to $GITHUB_OUTPUT.
#
# The changed files come from git, with no API call (dorny/paths-filter failed
# once when its API call failed with an empty message, run 42713507061):
# - pull_request: the merge commit against its first parent. Check out with
#   fetch-depth: 2.
# - push: the commit before the push ($BEFORE) against HEAD. The script
#   fetches $BEFORE. A new branch, or a $BEFORE that it cannot fetch, sets
#   every area to true.
# - any other event (workflow_dispatch, workflow_call): every area is true.
#
# A change to the table or to this script also sets every area to true.
set -euo pipefail

cd "$(dirname "$0")/.."
table=.github/path-areas

areas=()
patterns=()
while read -r area pattern _; do
  [[ -z "$area" || "$area" == \#* ]] && continue
  areas+=("$area")
  patterns+=("$pattern")
done <"$table"

all=false
files=""
case "${GITHUB_EVENT_NAME:-}" in
  pull_request)
    files="$(git diff --no-renames --name-only HEAD^1 HEAD)"
    ;;
  push)
    before="${BEFORE:-}"
    if [[ -z "$before" || "$before" =~ ^0+$ ]] || ! git fetch --quiet --no-tags --depth=1 origin "$before"; then
      all=true
    else
      files="$(git diff --no-renames --name-only "$before" HEAD)"
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
