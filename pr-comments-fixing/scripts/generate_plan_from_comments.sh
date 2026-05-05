#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Generate a full implementation-focused plan.md from PR comment artifacts.

Usage:
  generate_plan_from_comments.sh --comments-dir <dir> [options]

Options:
  --comments-dir <dir>   Directory containing review_comments.json and issue_comments.json (required)
  --repo-dir <dir>       Local git repo path for diff-based scope detection
  --base-ref <ref>       Base ref for scope diff (default: upstream/main)
  --head-ref <ref>       Head ref for scope diff (default: pr-<number> if available, else HEAD)
  --checkpatch-cmd <cmd> Repo-specific checkpatch command to include in verification checklist
  --output <file>        Write markdown output to file (default: stdout)
  --plan-file <plan.md>  If provided, overwrite this file with generated markdown
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
repo_dir=""
base_ref="upstream/main"
head_ref=""
checkpatch_cmd=""
output_file=""
plan_file=""
include_reviews=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --comments-dir)
      comments_dir="${2:-}"
      shift 2
      ;;
    --repo-dir)
      repo_dir="${2:-}"
      shift 2
      ;;
    --base-ref)
      base_ref="${2:-}"
      shift 2
      ;;
    --head-ref)
      head_ref="${2:-}"
      shift 2
      ;;
    --checkpatch-cmd)
      checkpatch_cmd="${2:-}"
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

if [[ -z "$head_ref" ]]; then
  if [[ -n "$pr" ]]; then
    head_ref="pr-${pr}"
  else
    head_ref="HEAD"
  fi
fi

review_count="$(jq 'length' "$review_json")"
issue_count="$(jq 'length' "$issue_json")"

review_table="$comments_dir/.tmp_review_rows.md"
issue_table="$comments_dir/.tmp_issue_rows.md"
action_rows="$comments_dir/.tmp_action_rows.md"
paths_file="$comments_dir/.tmp_paths.txt"
scope_lines="$comments_dir/.tmp_scope_lines.txt"

: > "$paths_file"

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
  [[ -n "$path" ]] && echo "$path" >> "$paths_file"

  if [[ -n "$reply_to" ]]; then
    type="reply"
  else
    type="top-level"
  fi
  printf '| `%s` | %s | `%s:%s` | %s | %s | %s |\n' "$id" "$user" "$path" "$line" "$type" "$body_escaped" "$url" >> "$review_table"

done

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
  printf '| `%s` | %s | `%s` | %s | %s |\n' "$id" "$user" "$created_at" "$body_escaped" "$url" >> "$issue_table"

done

# Build rule-based actionable mapping per review comment.
idx=0
jq -r '
  .[] |
  [
    ((.id|tostring)),
    (.path // ""),
    ((.line // .original_line // "")|tostring),
    ((.body // "") | gsub("\\r"; "") | gsub("\\n"; " ")),
    (.html_url // "")
  ] | join("\u001f")
' "$review_json" | \
while IFS=$'\x1f' read -r id path line body url; do
  idx=$((idx + 1))
  lower="$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')"
  classification="actionable-code-change"
  plan="Review comment and implement targeted fix in ${path}."
  validation="Build project and verify behavior matches reviewer intent."

  if [[ "$lower" == *"\\defgroup"* ]]; then
    plan="Add Doxygen defgroup documentation for logging service group in header near enums and public APIs."
    validation="Header docs follow existing group style; doc build (if present) has no warnings."
  elif [[ "$lower" == *"indent"* || "$lower" == *"checkpatch"* || "$lower" == *"format"* ]]; then
    plan="Fix indentation/style in logging service implementation to match project conventions."
    if [[ -n "$checkpatch_cmd" ]]; then
      validation="Run: ${checkpatch_cmd} and ensure no new style issues in touched file(s)."
    else
      validation="Run repo-specific checkpatch command provided by user and ensure no new style issues."
    fi
  elif [[ "$lower" == *"do_set_logging == null"* || "$lower" == *"function pointer explicitly"* || "$lower" == *"ops != null"* ]]; then
    plan="Validate mandatory callback pointers during service-group creation (reject ops with missing required callbacks)."
    validation="Constructor fails cleanly when callback is NULL; valid ops path still creates group."
  elif [[ "$lower" == *"always 0"* ]]; then
    plan="Remove dead success-only status path; propagate actual callback result into RPMI response status."
    validation="Failure path returns non-zero encoded RPMI error; success path still returns success."
  elif [[ "$lower" == *"return error instead of void"* || "$lower" == *"return error instead of"* ]]; then
    plan="Change platform callback signature to return enum rpmi_error and propagate result through service handler."
    validation="Build passes; callback contract clearly documents and propagates error codes."
  elif [[ "$lower" == *"do_set_state"* && "$lower" == *"instead of"* ]]; then
    plan="Rename callback from do_set_logging to do_set_state in header and implementation."
    validation="No stale symbol references remain (for example via rg do_set_logging)."
  elif [[ "$lower" == *"know the length"* || "$lower" == *"request_datalen"* ]]; then
    plan="Pass explicit payload length to callback API so implementation can parse variable-length request data safely."
    validation="Callback receives data length parameter and can validate bounds before use."
  elif [[ "$lower" == *"endianness"* || "$lower" == *"unpacked"* || "$lower" == *"callback must be kept simple"* ]]; then
    plan="Handle request payload unpacking/endianness in service layer; pass host-endian parsed values to callback."
    validation="Callback no longer handles transport endianness; handler performs conversion and bounds checks."
  fi

  printf '%s. **`%s:%s`** (%s)\n' "$idx" "$path" "$line" "comment id ${id}" >> "$action_rows"
  printf '   - Reviewer comment: "%s"\n' "$body" >> "$action_rows"
  printf '   - Plan: %s\n' "$plan" >> "$action_rows"
  printf '   - Validation: %s\n' "$validation" >> "$action_rows"
  printf '   - Reference: %s\n\n' "$url" >> "$action_rows"

done

# Add issue comments as non-code/process actions when relevant.
jq -r '
  .[] |
  [
    ((.id|tostring)),
    ((.body // "") | gsub("\\r"; "") | gsub("\\n"; " ")),
    (.html_url // "")
  ] | join("\u001f")
' "$issue_json" | \
while IFS=$'\x1f' read -r id body url; do
  lower="$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower" == *"mailid"* || "$lower" == *"email"* ]]; then
    printf -- '- **PR-level process item** (`%s`): %s\n' "$id" "$body" >> "$action_rows"
    printf -- '  - Plan: Update git author email / GitHub noreply email to OSS identity before follow-up commits.\n' >> "$action_rows"
    printf -- '  - Validation: New commits in PR show expected OSS email identity.\n' >> "$action_rows"
    printf -- '  - Reference: %s\n\n' "$url" >> "$action_rows"
  fi

done

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

# Detect common fix intents from review comment text.
need_defgroup="$(jq -r 'any(.[]; ((.body // "") | ascii_downcase | test("\\\\defgroup")))' "$review_json")"
need_style="$(jq -r 'any(.[]; ((.body // "") | ascii_downcase | test("indent|checkpatch|format")))' "$review_json")"
need_null_check="$(jq -r 'any(.[]; ((.body // "") | ascii_downcase | test("do_set_logging == null|ops != null|function pointer explicitly")))' "$review_json")"
need_status="$(jq -r 'any(.[]; ((.body // "") | ascii_downcase | test("always 0")))' "$review_json")"
need_ret_error="$(jq -r 'any(.[]; ((.body // "") | ascii_downcase | test("return error instead of")))' "$review_json")"
need_rename="$(jq -r 'any(.[]; ((.body // "") | ascii_downcase | test("do_set_state.*instead of")))' "$review_json")"
need_datalen="$(jq -r 'any(.[]; ((.body // "") | ascii_downcase | test("request_datalen|know the length")))' "$review_json")"
need_endian="$(jq -r 'any(.[]; ((.body // "") | ascii_downcase | test("endianness|unpacked|callback must be kept simple")))' "$review_json")"

# Determine scope lines from git diff when repo context is provided; fallback to comment paths.
if [[ -n "$repo_dir" && -d "$repo_dir/.git" ]]; then
  require_cmd git
  if git -C "$repo_dir" rev-parse --verify "$base_ref" >/dev/null 2>&1 && git -C "$repo_dir" rev-parse --verify "$head_ref" >/dev/null 2>&1; then
    git -C "$repo_dir" diff --name-status "$base_ref...$head_ref" > "$scope_lines" || true
  fi
fi
if [[ ! -s "$scope_lines" ]]; then
  sort -u "$paths_file" | awk 'NF {print "M\t" $0}' > "$scope_lines" || true
fi

header_line="# Plan to Review PR and Fix Comments"
if [[ -n "$owner" && -n "$repo" && -n "$pr" ]]; then
  header_line="# Plan to Review PR #${pr} and Fix Comments"
fi

pr_line="PR details not provided"
if [[ -n "$owner" && -n "$repo" && -n "$pr" ]]; then
  pr_line="PR: https://github.com/${owner}/${repo}/pull/${pr}"
fi

checkpatch_line='[user must provide repo-specific checkpatch command]'
if [[ -n "$checkpatch_cmd" ]]; then
  checkpatch_line="$checkpatch_cmd"
fi

markdown="$comments_dir/.tmp_plan_full.md"
{
  echo "$header_line"
  echo
  echo "$pr_line  "
  if [[ -n "$head_ref" ]]; then
    echo "Target head ref: ${head_ref}  "
  fi
  echo "Fetched on: ${fetch_date}"
  echo
  echo "Scope vs ${base_ref}:"
  if [[ -s "$scope_lines" ]]; then
    while IFS=$'\t' read -r status file; do
      [[ -z "$file" ]] && continue
      echo "- ${file} (${status})"
    done < "$scope_lines"
  else
    echo "- (unable to determine changed files; provide --repo-dir/--base-ref/--head-ref)"
  fi
  echo
  echo "## 1. Prepare working branch"
  echo "1. git fetch upstream"
  if [[ -n "$pr" ]]; then
    echo "2. git fetch upstream pull/${pr}/head:pr-${pr}"
    echo "3. git switch -c pr-${pr}-fixes pr-${pr}"
    echo "4. Keep unrelated local files out of commits."
  else
    echo "2. Fetch PR head ref from remote and create a local fix branch."
    echo "3. Keep unrelated local files out of commits."
  fi
  echo
  echo "## 2. Actual comment inventory (fetched from GitHub API)"
  if [[ -n "$owner" && -n "$repo" && -n "$pr" ]]; then
    echo "Fetched on ${fetch_date} from:"
    echo "- GET /repos/${owner}/${repo}/pulls/${pr}/comments (${review_count} review comments)"
    echo "- GET /repos/${owner}/${repo}/issues/${pr}/comments (${issue_count} PR-level comments)"
  else
    echo "- Review comments: ${review_count}"
    echo "- PR-level comments: ${issue_count}"
  fi
  if [[ -n "$review_stats_block" ]]; then
    echo "$review_stats_block"
  fi
  echo
  echo "### Actionable review comments and implementation plan"
  if [[ -s "$action_rows" ]]; then
    cat "$action_rows"
  else
    echo "- No actionable comments detected from fetched data."
  fi
  echo
  echo "## 3. Implementation sequencing"
  echo "1. **Commit A: Header/API contract changes**"
  echo "   - Naming/signature updates and docs in public headers."
  echo "2. **Commit B: Service implementation changes**"
  echo "   - Behavior fixes, request parsing/endianness handling, error propagation, null checks, style cleanup."
  echo "3. **Commit C: Build wiring / integration checks (if required)**"
  echo "   - Ensure object lists/build files are aligned with source changes."
  echo
  echo "## 4. Concrete code changes to apply"
  echo "1. include/librpmi.h"
  if [[ "$need_defgroup" == "true" ]]; then
    echo "   - Add Doxygen defgroup documentation for the logging service group."
  fi
  if [[ "$need_rename" == "true" || "$need_ret_error" == "true" || "$need_datalen" == "true" ]]; then
    echo "   - Update logging platform callback contract (name/signature/arguments) per reviewer guidance."
  fi
  if [[ "$need_rename" == "true" && "$need_ret_error" == "true" && "$need_datalen" == "true" && "$need_endian" == "true" ]]; then
    echo "   - Suggested callback shape: enum rpmi_error (*do_set_state)(void *priv, rpmi_uint32_t log_type, rpmi_uint32_t datalen_bytes, const void *data)."
  fi
  if [[ "$need_defgroup" != "true" && "$need_rename" != "true" && "$need_ret_error" != "true" && "$need_datalen" != "true" ]]; then
    echo "   - Apply API/doc updates requested in header-related comments."
  fi
  echo "2. lib/rpmi_service_group_logging.c"
  if [[ "$need_null_check" == "true" ]]; then
    echo "   - Validate ops and mandatory callback pointers during service-group creation."
  fi
  if [[ "$need_status" == "true" || "$need_ret_error" == "true" ]]; then
    echo "   - Propagate callback return status into RPMI response status instead of fixed-success flow."
  fi
  if [[ "$need_endian" == "true" || "$need_datalen" == "true" ]]; then
    echo "   - Parse request payload in service layer (bounds/endian), then pass parsed host-endian fields to callback."
  fi
  if [[ "$need_style" == "true" ]]; then
    echo "   - Reformat indentation/style to pass project checkpatch expectations."
  fi
  if [[ "$need_null_check" != "true" && "$need_status" != "true" && "$need_ret_error" != "true" && "$need_endian" != "true" && "$need_datalen" != "true" && "$need_style" != "true" ]]; then
    echo "   - Apply behavior and robustness fixes requested for the service implementation."
  fi
  echo "3. Build/config files in PR scope (for example lib/objects.mk)"
  echo "   - Verify source inclusion/build wiring is still correct after implementation changes."
  echo
  echo "## 5. Verification checklist"
  echo "1. make clean && make -j\$(nproc)"
  echo "2. make test (if target exists)"
  echo "3. ${checkpatch_line}"
  echo "4. rg -n \"do_set_logging|is_be\" include lib (or repo-equivalent)"
  echo "5. git diff --stat ${base_ref}...HEAD and git status --short"
  echo
  echo "## 6. PR update workflow"
  echo "1. Push fixes to branch tied to the PR source."
  echo "2. Reply on each thread with commit hash and short resolution note."
  echo "3. Resolve threads only after code is pushed and visible."
  echo "4. Request re-review with comment-id to patch mapping."
  echo
  echo "## Definition of Done"
  echo "- Every actionable comment has either a code fix or explicit rationale."
  echo "- API/behavior updates match reviewer intent."
  echo "- Style/build checks pass with repo-specific checkpatch + tests/build commands."
  echo "- Diff is limited to PR-related changes."
} > "$markdown"

if [[ -n "$plan_file" ]]; then
  cp "$markdown" "$plan_file"
fi

if [[ -n "$output_file" ]]; then
  cp "$markdown" "$output_file"
else
  cat "$markdown"
fi

rm -f "$review_table" "$issue_table" "$action_rows" "$paths_file" "$scope_lines" "$markdown"
