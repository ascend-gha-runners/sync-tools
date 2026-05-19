#!/bin/bash
# Build the GitHub Actions matrix for sync-models-datasets workflow.
# Output: writes `matrix=<json-array>` to $GITHUB_OUTPUT, where each
# element is {"project": <name>, "cluster": <runner-label>}.
#
# Project selection rules:
#   - schedule              -> all projects in projects-clusters.json
#   - workflow_dispatch     -> input.project (empty = all)
#   - push                  -> only projects whose config files changed,
#                              union with projects whose clusters list
#                              changed in projects-clusters.json. If the
#                              workflow file or matrix script itself
#                              changed, run all projects.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CLUSTERS_FILE="$ROOT/.github/workflows/config/projects-clusters.json"
PROJECTS_DIR=".github/workflows/config/projects"
WORKFLOW_FILE=".github/workflows/sync-models-datasets.yml"
MATRIX_SCRIPT=".github/scripts/build-sync-matrix.sh"

ALL_PROJECTS=$(jq -r 'keys[]' "$CLUSTERS_FILE")

select_all() {
  echo "$ALL_PROJECTS"
}

select_from_dispatch() {
  local input="${INPUT_PROJECT:-}"
  if [ -z "$input" ]; then
    select_all
  else
    if jq -e --arg p "$input" 'has($p)' "$CLUSTERS_FILE" >/dev/null; then
      echo "$input"
    else
      echo "Error: project '$input' not found in projects-clusters.json" >&2
      exit 1
    fi
  fi
}

select_from_push() {
  local before="${GITHUB_EVENT_BEFORE:-}"
  local after="${GITHUB_SHA:-HEAD}"
  local range
  if [ -z "$before" ] || [ "$before" = "0000000000000000000000000000000000000000" ]; then
    range="HEAD~1..HEAD"
  else
    range="$before..$after"
  fi

  local changed
  changed=$(git diff --name-only "$range" 2>/dev/null || git diff --name-only HEAD~1..HEAD)

  if echo "$changed" | grep -qx "$WORKFLOW_FILE\|$MATRIX_SCRIPT"; then
    select_all
    return
  fi

  local selected=""

  while IFS= read -r f; do
    case "$f" in
      "$PROJECTS_DIR"/*.json)
        local name
        name=$(basename "$f" .json)
        if jq -e --arg p "$name" 'has($p)' "$CLUSTERS_FILE" >/dev/null; then
          selected="$selected"$'\n'"$name"
        fi
        ;;
    esac
  done <<< "$changed"

  if echo "$changed" | grep -qx ".github/workflows/config/projects-clusters.json"; then
    local before_json after_json
    before_json=$(git show "$before:.github/workflows/config/projects-clusters.json" 2>/dev/null || echo '{}')
    after_json=$(cat "$CLUSTERS_FILE")
    local diff_projects
    diff_projects=$(jq -rn \
      --argjson a "$before_json" \
      --argjson b "$after_json" '
        ($a | to_entries | map({key, v: (.value.clusters // [])})) as $ae |
        ($b | to_entries | map({key, v: (.value.clusters // [])})) as $be |
        ([$ae[].key] + [$be[].key] | unique) as $keys |
        $keys[] as $k |
        ( ($ae | map(select(.key == $k)) | .[0].v // null) ) as $av |
        ( ($be | map(select(.key == $k)) | .[0].v // null) ) as $bv |
        select($av != $bv) | $k
      ')
    selected="$selected"$'\n'"$diff_projects"
  fi

  echo "$selected" | sed '/^$/d' | sort -u
}

case "${GITHUB_EVENT_NAME:-}" in
  schedule)         PROJECTS=$(select_all) ;;
  workflow_dispatch) PROJECTS=$(select_from_dispatch) ;;
  push)             PROJECTS=$(select_from_push) ;;
  *)                PROJECTS=$(select_all) ;;
esac

MATRIX=$(
  echo "$PROJECTS" | sed '/^$/d' | jq -R . | jq -sc --slurpfile c "$CLUSTERS_FILE" '
    . as $projects |
    [ $projects[] as $p
      | ($c[0][$p].clusters // [])[] as $cluster
      | {project: $p, cluster: $cluster}
    ]
  '
)

if [ -z "$MATRIX" ]; then
  MATRIX="[]"
fi

echo "Selected projects:"
echo "$PROJECTS"
echo "Matrix: $MATRIX"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "matrix=$MATRIX" >> "$GITHUB_OUTPUT"
fi
