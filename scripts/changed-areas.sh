#!/usr/bin/env bash
# Decide which areas of .github/path-areas a commit changes, and write
# `<area>=true|false` for each area to stdout and to $GITHUB_OUTPUT.
#
# The changed files come from git:
# - pull_request: the merge commit against its first parent (fetch-depth: 2).
# - push: the base against HEAD. The base is the commit of the newest run of
#   this workflow on the branch that passed. It is not the commit before the
#   push: a push to main cancels the run of the commit before it, so the
#   changes of that commit get their checks in the run of the next commit.
#   Two API calls find the base (GH_TOKEN; the list of runs needs
#   `actions: read`). If no run passed, if the base is not an ancestor of
#   HEAD, if a call fails or if the script cannot fetch the base, every area
#   is set.
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
    # GITHUB_WORKFLOW_REF is owner/repo/.github/workflows/<file>@<ref>.
    workflow="${GITHUB_WORKFLOW_REF%@*}"
    workflow="${workflow##*/}"
    head="$(git rev-parse HEAD)"
    base=""
    relation=""
    if ! base="$(gh api "repos/$GITHUB_REPOSITORY/actions/workflows/$workflow/runs?branch=$GITHUB_REF_NAME&event=push&status=success&per_page=1" \
      --jq '.workflow_runs[0].head_sha // ""')"; then
      echo "Cannot list the runs of $workflow. Setting every area."
      all=true
    elif [[ -z "$base" ]]; then
      echo "No run of $workflow passed. Setting every area."
      all=true
    # "ahead" or "identical": the base is an ancestor of HEAD.
    elif ! relation="$(gh api "repos/$GITHUB_REPOSITORY/compare/$base...$head" --jq '.status')" \
      || [[ ! "$relation" =~ ^(ahead|identical)$ ]]; then
      echo "$base is not an ancestor of HEAD (${relation:-unknown}). Setting every area."
      all=true
    elif ! git fetch --quiet --no-tags --depth=1 origin "$base"; then
      echo "Cannot fetch $base. Setting every area."
      all=true
    else
      echo "Changes since $base, the newest commit whose $workflow run passed."
      files="$(diff_names "$base" HEAD)"
    fi
    ;;
  *)
    all=true
    ;;
esac

if grep -qxE '\.github/path-areas|scripts/changed-areas\.sh' <<<"$files"; then
  all=true
fi
# The maps of the code for agents (AGENTS.md and its CLAUDE.md links) are in
# no area: no build or test reads them. Checks / Agents Map checks them on
# every commit.
files="$(grep -vE '(^|/)(AGENTS|CLAUDE)\.md$' <<<"$files" || true)"

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
