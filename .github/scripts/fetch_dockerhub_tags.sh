#!/bin/bash
# ==============================================================================
# Script: fetch_dockerhub_tags.sh
# Purpose:
#   Fetches tags from a DockerHub repository and filters them based on a regex
#   pattern. Designed to avoid redundant inline bash code in GitHub Actions.
#
# Usage:
#   ./fetch_dockerhub_tags.sh <repository> <filter_pattern> [max_pages]
#
# Arguments:
#   1. repository       (Required) - The DockerHub repository (e.g., 'lmsysorg/sglang')
#   2. filter_pattern   (Required) - A regex pattern to match tags (case-insensitive).
#                                    (e.g., 'cann', 'vllm')
#   3. max_pages        (Optional) - Maximum number of pagination requests to
#                                    DockerHub API. Prevents infinite loops.
#                                    Default: 10
#
# Outputs:
#   - Prints debug information to stderr (will not affect captured stdout in Actions).
#   - Prints space-separated tags to stdout, suitable for variable assignment.
#     Example Output: "latest-cann v1.0.0-cann"
#
# Exit Codes:
#   0 - Success
#   1 - Missing arguments or cURL failure
# ==============================================================================

set -eo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <repository> <filter_pattern> [max_pages]"
    exit 1
fi

REPO=$1
PATTERN=$2
MAX_PAGES=${3:-10}

echo "Debug: Fetching tags for $REPO filtering by '$PATTERN' (max pages: $MAX_PAGES)" >&2

TAGS=""
NEXT_URL="https://hub.docker.com/v2/repositories/${REPO}/tags/?page_size=100"
PAGE=1

while [ "$NEXT_URL" != "null" ] && [ "$PAGE" -le "$MAX_PAGES" ]; do
    echo "Fetching page $PAGE: $NEXT_URL" >&2
    RESPONSE=$(curl -s -f "$NEXT_URL" || { echo "Error fetching URL" >&2; exit 1; })
    
    PAGE_TAGS=$(echo "$RESPONSE" | jq -r ".results[] | select(.name | test(\"$PATTERN\"; \"i\")) | .name" 2>/dev/null || echo "")
    
    if [ -n "$PAGE_TAGS" ]; then
        TAGS="$TAGS"$'\n'"$PAGE_TAGS"
    fi
    
    NEXT_URL=$(echo "$RESPONSE" | jq -r '.next // "null"')
    PAGE=$((PAGE + 1))
done

TAGS=$(echo "$TAGS" | sed '/^$/d' | sort -u)

echo "Debug: Number of tags found: $(echo "$TAGS" | wc -l)" >&2

if [ -n "$TAGS" ]; then
    echo "$TAGS" | tr '\n' ' ' | xargs
else
    echo ""
fi
