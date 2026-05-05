#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Generate a plan.md-ready markdown section from PR comment artifacts.

Usage:
  generate_plan_from_comments.sh --comments-dir <dir> [--output <file>] [--plan-file <plan.md>] [--include-reviews]

Options:
  --comments-dir <dir>   Directory containing review_comments.json and issue_comments.json
  --output <file>        Write markdown output to file (default: stdout)
  --plan-file <plan.md>  If provided, append the generated markdown to this plan file
  --include-reviews      Include review summary count/state breakdown when reviews.json exists
  -h, --help             Show help
USAGE
}

err() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"
}

comments_dir=""
output_file=""
plan_file=""
include_reviews=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --comments-dir)
      comments_dir="${2:-}"
      shift 2
      ;;
    --output)
      output_file="${2:-}"
      shift 2
      ;;
    --plan-file)
      plan_file="${2:-}"
      shift 2
      ;;
    --include-reviews)
      include_reviews=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      ;;
  esac
done

require_cmd jq

[[ -n "$comments_dir" ]] || err "--comments-dir is required"
review_json="$comments_dir/review_comments.json"
issue_json="$comments_dir/issue_comments.json"
reviews_json="$comments_dir/reviews.json"
summary_txt="$comments_dir/summary.txt"

[[ -f "$review_json" ]] || err "Missing $review_json"
[[ -f "$issue_json" ]] || err "Missing $issue_json"

fetch_date="$(date -u +"%Y-%m-%d")"
owner=""
repo=""
pr=""
if [[ -f "$summary_txt" ]]; then
  owner="$(awk -F= '/^owner=/{print $2}' "$summary_txt" || true)"
  repo="$(awk -F= '/^repo=/{print $2}' "$summary_txt" || true)"
  pr="$(awk -F= '/^pr=/{print $2}' "$summary_txt" || true)"
  fetched_raw="$(awk -F= '/^fetched_at_utc=/{print $2}' "$summary_txt" || true)"
  if [[ -n "$fetched_raw" ]]; then
    fetch_date="${fetched_raw%%T*}"
  fi
fi

review_count="$(jq 'length' "$review_json")"
issue_count="$(jq 'length' "$issue_json")"

review_table="$comments_dir/.tmp_review_rows.md"
issue_table="$comments_dir/.tmp_issue_rows.md"

jq -r '
  .[] |
  [
    ((.id|tostring)),
    (.user.login // ""),
    (.path // ""),
    ((.line // .original_line // "")|tostring),
    ((.in_reply_to_id // "")|tostring),
    ((.body // "") | gsub("\\r"; "") | gsub("\\n"; " ")),
    (.html_url // "")
  ] | join("\u001f")
' "$review_json" | \
while IFS=$'\x1f' read -r id user path line reply_to body url; do
  body_escaped="${body//|/\\|}"
  if [[ -n "$reply_to" ]]; then
    type="reply"
  else
    type="top-level"
  fi
  printf '| `%s` | %s | `%s:%s` | %s | %s | %s |\n' "$id" "$user" "$path" "$line" "$type" "$body_escaped" "$url"
done > "$review_table"

jq -r '
  .[] |
  [
    ((.id|tostring)),
    (.user.login // ""),
    (.created_at // ""),
    ((.body // "") | gsub("\\r"; "") | gsub("\\n"; " ")),
    (.html_url // "")
  ] | join("\u001f")
' "$issue_json" | \
while IFS=$'\x1f' read -r id user created_at body url; do
  body_escaped="${body//|/\\|}"
  printf '| `%s` | %s | `%s` | %s | %s |\n' "$id" "$user" "$created_at" "$body_escaped" "$url"
done > "$issue_table"

review_stats_block=""
if [[ $include_reviews -eq 1 && -f "$reviews_json" ]]; then
  reviews_count="$(jq 'length' "$reviews_json")"
  state_lines="$(jq -r 'group_by(.state)[] | "- " + (.[0].state // "UNKNOWN") + ": " + (length|tostring)' "$reviews_json" 2>/dev/null || true)"
  review_stats_block=$(cat <<STATS
- Review summaries: ${reviews_count}
${state_lines}
STATS
)
fi

header_line="# PR Comment Inventory and Fix Implementation Plan"
if [[ -n "$owner" && -n "$repo" && -n "$pr" ]]; then
  header_line="# PR Comment Inventory and Fix Implementation Plan (${owner}/${repo}#${pr})"
fi

markdown="$comments_dir/.tmp_plan_section.md"
{
  echo "$header_line"
  echo
  printf 'Fetched on: `%s`\n' "$fetch_date"
  echo
  echo "## Comment Counts"
  echo "- Review comments: ${review_count}"
  echo "- PR-level issue comments: ${issue_count}"
  if [[ -n "$review_stats_block" ]]; then
    echo "$review_stats_block"
  fi
  echo
  echo "## Review Comments (Raw Inventory)"
  echo "| ID | Reviewer | File:Line | Type | Comment | URL |"
  echo "| --- | --- | --- | --- | --- | --- |"
  if [[ -s "$review_table" ]]; then
    cat "$review_table"
  else
    echo "| - | - | - | - | No review comments found | - |"
  fi
  echo
  echo "## PR-level Issue Comments (Raw Inventory)"
  echo "| ID | User | Created | Comment | URL |"
  echo "| --- | --- | --- | --- | --- |"
  if [[ -s "$issue_table" ]]; then
    cat "$issue_table"
  else
    echo "| - | - | - | No issue comments found | - |"
  fi
  echo
  echo "## Actionable Implementation Plan"
  echo '1. Classify each review comment as `actionable-code-change`, `clarification-needed`, or `non-code-process`.'
  echo "2. For each actionable code comment, map to target file(s), expected behavior/API change, and validation command."
  echo "3. Group fixes into small commits by concern (API/header, implementation, build integration/style)."
  echo "4. Add a reviewer response mapping (comment ID -> commit hash -> short resolution note)."
  echo "5. Verify with build/tests and repo-specific checkpatch command before requesting re-review."
} > "$markdown"

if [[ -n "$plan_file" ]]; then
  cat "$markdown" >> "$plan_file"
fi

if [[ -n "$output_file" ]]; then
  cp "$markdown" "$output_file"
else
  cat "$markdown"
fi

rm -f "$review_table" "$issue_table" "$markdown"
