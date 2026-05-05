#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Generate a compact task status + validation report from plan.md.

Usage:
  plan_status_report.sh --plan-file <path> [options]

Options:
  --plan-file <path>      Path to generated plan.md (required)
  --repo-dir <path>       Repo path for validation checks
  --base-ref <ref>        Base ref for diff/checkpatch range (default: upstream/main)
  --checkpatch-cmd <cmd>  Checkpatch command/prefix (e.g. ~/git/linux/scripts/checkpatch.pl --no-tree)
  --run-validation        Run compact validation checks (build/test/checkpatch/diff)
  --output <path>         Write report to file (default: stdout)
  -h, --help              Show help
USAGE
}

err() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"
}

plan_file=""
repo_dir=""
base_ref="upstream/main"
checkpatch_cmd=""
run_validation=0
output_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-file)
      plan_file="${2:-}"
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
    --checkpatch-cmd)
      checkpatch_cmd="${2:-}"
      shift 2
      ;;
    --run-validation)
      run_validation=1
      shift
      ;;
    --output)
      output_file="${2:-}"
      shift 2
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

[[ -n "$plan_file" ]] || err "--plan-file is required"
[[ -f "$plan_file" ]] || err "Plan file not found: $plan_file"

require_cmd awk
require_cmd sed
require_cmd grep

tmp_tsv="$(mktemp)"
trap 'rm -f "$tmp_tsv" "$tmp_report"' EXIT

tmp_report="$(mktemp)"

awk '
function btval(s,   t) {
  t=s
  sub(/^[^`]*`/, "", t)
  sub(/`.*$/, "", t)
  return t
}
BEGIN {
  in_task=0
  in_action=0
}
/^### Actionable review comments and implementation plan/ {
  in_action=1
  next
}
/^## 3\\. / {
  in_action=0
  if (in_task) {
    print idx "\t" comment_id "\t" disposition "\t" status "\t" commit "\t" kind
    in_task=0
  }
  next
}
/^[0-9]+\. \*\*/ {
  if (!in_action)
    next
  if (in_task) {
    print idx "\t" comment_id "\t" disposition "\t" status "\t" commit "\t" kind
  }
  in_task=1
  kind="comment"
  idx=$1
  sub(/\./, "", idx)
  comment_id=""
  if (match($0, /comment id [0-9]+/)) {
    comment_id=substr($0, RSTART + 11, RLENGTH - 11)
  }
  disposition="unknown"
  status="unknown"
  commit="pending"
  next
}
/^- \*\*PR-level process item\*\*/ {
  if (!in_action)
    next
  if (in_task) {
    print idx "\t" comment_id "\t" disposition "\t" status "\t" commit "\t" kind
  }
  in_task=1
  kind="process"
  idx="P"
  comment_id=""
  if (match($0, /`[0-9]+`/)) {
    comment_id=substr($0, RSTART + 1, RLENGTH - 2)
  }
  disposition="non-code-process"
  status="unknown"
  commit="n/a"
  next
}
in_task && /- Disposition:/ {
  disposition=btval($0)
  next
}
in_task && /- Status:/ {
  status=btval($0)
  next
}
in_task && /- Commit:/ {
  commit=btval($0)
  next
}
in_task && /- Reference:/ {
  print idx "\t" comment_id "\t" disposition "\t" status "\t" commit "\t" kind
  in_task=0
  next
}
END {
  if (in_task) {
    print idx "\t" comment_id "\t" disposition "\t" status "\t" commit "\t" kind
  }
}
' "$plan_file" > "$tmp_tsv"

valid_filter='($2 != "" || $6=="process")'
total_items="$(awk -F'\t' "${valid_filter} {c++} END {print c+0}" "$tmp_tsv")"
done_items="$(awk -F'\t' "${valid_filter} && \$4==\"done\" {c++} END {print c+0}" "$tmp_tsv")"
todo_items="$(awk -F'\t' "${valid_filter} && \$4==\"todo\" {c++} END {print c+0}" "$tmp_tsv")"
impl_items="$(awk -F'\t' "${valid_filter} && \$3==\"implement\" {c++} END {print c+0}" "$tmp_tsv")"
process_items="$(awk -F'\t' "${valid_filter} && \$6==\"process\" {c++} END {print c+0}" "$tmp_tsv")"
clarify_items="$(awk -F'\t' "${valid_filter} && \$3==\"clarify-with-reviewer\" {c++} END {print c+0}" "$tmp_tsv")"
reject_items="$(awk -F'\t' "${valid_filter} && \$3==\"reject-with-rationale\" {c++} END {print c+0}" "$tmp_tsv")"

{
  echo "# Compact PR Plan Status Report"
  echo
  echo "Plan: ${plan_file}"
  echo
  echo "## Summary"
  echo "- Total tracked items: ${total_items}"
  echo "- Done: ${done_items}"
  echo "- Todo: ${todo_items}"
  echo "- Implement disposition: ${impl_items}"
  echo "- Clarify disposition: ${clarify_items}"
  echo "- Reject disposition: ${reject_items}"
  echo "- Non-code/process items: ${process_items}"
  echo
  echo "## Task Table"
  echo "| Item | Comment ID | Disposition | Status | Commit | Kind |"
  echo "| --- | --- | --- | --- | --- | --- |"
  awk -F'\t' '($2 != "" || $6=="process") {printf "| %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6}' "$tmp_tsv"
} > "$tmp_report"

if [[ "$run_validation" -eq 1 ]]; then
  [[ -n "$repo_dir" ]] || err "--repo-dir is required when --run-validation is set"
  [[ -d "$repo_dir/.git" ]] || err "Invalid repo dir: $repo_dir"
  require_cmd git

  build_rc=0
  test_rc=0
  checkpatch_rc=0

  build_log="$(mktemp)"
  test_log="$(mktemp)"
  cpatch_log="$(mktemp)"
  trap 'rm -f "$tmp_tsv" "$tmp_report" "$build_log" "$test_log" "$cpatch_log"' EXIT

  (cd "$repo_dir" && make -j"$(nproc)" >"$build_log" 2>&1) || build_rc=$?
  (cd "$repo_dir" && make test >"$test_log" 2>&1) || test_rc=$?

  if [[ -n "$checkpatch_cmd" ]]; then
    (cd "$repo_dir" && eval "git format-patch --stdout ${base_ref}..HEAD | ${checkpatch_cmd} -" >"$cpatch_log" 2>&1) || checkpatch_rc=$?
  else
    checkpatch_rc=125
    echo "checkpatch command not provided" >"$cpatch_log"
  fi

  diffstat="$(git -C "$repo_dir" diff --stat "${base_ref}...HEAD" 2>/dev/null || true)"
  short_status="$(git -C "$repo_dir" status --short --branch 2>/dev/null || true)"

  {
    echo
    echo "## Validation (Compact)"
    echo "- Build: $([[ $build_rc -eq 0 ]] && echo PASS || echo FAIL)"
    echo "- Test: $([[ $test_rc -eq 0 ]] && echo PASS || echo FAIL)"
    if [[ "$checkpatch_rc" -eq 125 ]]; then
      echo "- Patch checkpatch: SKIPPED (missing --checkpatch-cmd)"
    else
      echo "- Patch checkpatch: $([[ $checkpatch_rc -eq 0 ]] && echo PASS || echo FAIL)"
    fi
    echo
    echo "### Validation Snippets"
    echo "- Build log (first 10 lines):"
    sed -n '1,10p' "$build_log" | sed 's/^/  /'
    echo "- Test log (first 10 lines):"
    sed -n '1,10p' "$test_log" | sed 's/^/  /'
    echo "- Checkpatch log (first 12 lines):"
    sed -n '1,12p' "$cpatch_log" | sed 's/^/  /'
    echo
    echo "### Git Diffstat (${base_ref}...HEAD)"
    if [[ -n "$diffstat" ]]; then
      printf '%s\n' "$diffstat" | sed 's/^/  /'
    else
      echo "  (none)"
    fi
    echo
    echo "### Git Status"
    if [[ -n "$short_status" ]]; then
      printf '%s\n' "$short_status" | sed 's/^/  /'
    else
      echo "  (clean)"
    fi
  } >> "$tmp_report"
fi

if [[ -n "$output_file" ]]; then
  cp "$tmp_report" "$output_file"
else
  cat "$tmp_report"
fi
