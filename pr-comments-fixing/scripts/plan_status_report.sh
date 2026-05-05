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
tmp_tsv_norm="$(mktemp)"
trap 'rm -f "$tmp_tsv" "$tmp_tsv_norm" "$tmp_report"' EXIT

tmp_report="$(mktemp)"

awk '
function btval(s,   t) {
  t=s
  sub(/^[^`]*`/, "", t)
  sub(/`.*$/, "", t)
  return t
}
function flush_task() {
  if (in_task) {
    print idx "\t" comment_id "\t" disposition "\t" status "\t" commit "\t" kind
    in_task=0
  }
}
BEGIN {
  in_task=0
  in_action=0
  in_tasks=0
}
/^### Actionable review comments and implementation plan/ {
  flush_task()
  in_action=1
  in_tasks=0
  next
}
/^## Tasks/ {
  flush_task()
  in_tasks=1
  in_action=0
  next
}
/^## 3\\. / {
  flush_task()
  in_action=0
  in_tasks=0
  next
}
/^## / {
  flush_task()
  in_tasks=0
  in_action=0
  next
}
/^[0-9]+\. \*\*/ {
  if (!in_action)
    next
  flush_task()
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
/^[0-9]+\.[[:space:]]/ {
  if (!in_tasks)
    next
  flush_task()
  in_task=1
  kind="comment"
  idx=$1
  sub(/\./, "", idx)
  comment_id=""
  disposition="unknown"
  status="unknown"
  commit="pending"
  next
}
/^- \*\*PR-level process item\*\*/ {
  if (!in_action)
    next
  flush_task()
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
in_task && /- Comment IDs:/ {
  if (match($0, /`[0-9]+`/)) {
    comment_id=substr($0, RSTART + 1, RLENGTH - 2)
  } else if (match($0, /[0-9]{6,}/)) {
    comment_id=substr($0, RSTART, RLENGTH)
  }
  next
}
in_task && /- Reference:/ {
  flush_task()
  next
}
END {
  flush_task()
}
' "$plan_file" > "$tmp_tsv"

# Normalize missing disposition values for older plans.
awk -F'\t' 'BEGIN {OFS="\t"} {
  disp=$3
  if (disp == "unknown" && $6 == "comment") {
    disp="implement"
  }
  print $1, $2, disp, $4, $5, $6
}' "$tmp_tsv" > "$tmp_tsv_norm"

valid_filter='($2 != "" || $6=="process")'
total_items="$(awk -F'\t' "${valid_filter} {c++} END {print c+0}" "$tmp_tsv_norm")"
done_items="$(awk -F'\t' "${valid_filter} && \$4==\"done\" {c++} END {print c+0}" "$tmp_tsv_norm")"
todo_items="$(awk -F'\t' "${valid_filter} && \$4==\"todo\" {c++} END {print c+0}" "$tmp_tsv_norm")"
impl_items="$(awk -F'\t' "${valid_filter} && \$3==\"implement\" {c++} END {print c+0}" "$tmp_tsv_norm")"
process_items="$(awk -F'\t' "${valid_filter} && \$6==\"process\" {c++} END {print c+0}" "$tmp_tsv_norm")"
clarify_items="$(awk -F'\t' "${valid_filter} && \$3==\"clarify-with-reviewer\" {c++} END {print c+0}" "$tmp_tsv_norm")"
reject_items="$(awk -F'\t' "${valid_filter} && \$3==\"reject-with-rationale\" {c++} END {print c+0}" "$tmp_tsv_norm")"

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
  awk -F'\t' '($2 != "" || $6=="process") {printf "| %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6}' "$tmp_tsv_norm"
} > "$tmp_report"

if [[ "$run_validation" -eq 1 ]]; then
  [[ -n "$repo_dir" ]] || err "--repo-dir is required when --run-validation is set"
  [[ -d "$repo_dir/.git" ]] || err "Invalid repo dir: $repo_dir"
  require_cmd git

  build_rc=125
  test_rc=125
  checkpatch_rc=125
  build_status="SKIPPED"
  test_status="SKIPPED"
  checkpatch_status="SKIPPED"
  checkpatch_mode="not-run"
  resolved_base_ref="$base_ref"
  build_cmd_used="(none)"
  test_cmd_used="(none)"
  checkpatch_cmd_used="(none)"

  build_log="$(mktemp)"
  test_log="$(mktemp)"
  cpatch_log="$(mktemp)"
  patch_file="$(mktemp)"
  patch_dir="$(mktemp -d)"
  trap 'rm -f "$tmp_tsv" "$tmp_tsv_norm" "$tmp_report" "$build_log" "$test_log" "$cpatch_log" "$patch_file"; rm -rf "$patch_dir"' EXIT

  # Resolve a usable base ref automatically when requested/default is unavailable.
  if ! git -C "$repo_dir" rev-parse --verify "$resolved_base_ref" >/dev/null 2>&1; then
    for cand in "upstream/main" "upstream/master" "origin/main" "origin/master" "main" "master"; do
      if git -C "$repo_dir" rev-parse --verify "$cand" >/dev/null 2>&1; then
        resolved_base_ref="$cand"
        break
      fi
    done
    if ! git -C "$repo_dir" rev-parse --verify "$resolved_base_ref" >/dev/null 2>&1; then
      origin_head="$(git -C "$repo_dir" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)"
      if [[ -n "$origin_head" ]]; then
        origin_head="${origin_head#refs/remotes/}"
        if git -C "$repo_dir" rev-parse --verify "$origin_head" >/dev/null 2>&1; then
          resolved_base_ref="$origin_head"
        fi
      fi
    fi
  fi

  # Adaptive build check.
  if [[ -f "$repo_dir/Makefile" || -f "$repo_dir/makefile" || -f "$repo_dir/GNUmakefile" ]]; then
    build_cmd_used="make -j$(nproc)"
    build_rc=0
    (cd "$repo_dir" && make -j"$(nproc)" >"$build_log" 2>&1) || build_rc=$?
    if [[ "$build_rc" -eq 0 ]]; then
      build_status="PASS"
    else
      build_status="FAIL"
    fi
  elif [[ -f "$repo_dir/build.ninja" || -f "$repo_dir/build/build.ninja" ]]; then
    build_cmd_used="ninja -C build"
    build_rc=0
    (cd "$repo_dir" && ninja -C build >"$build_log" 2>&1) || build_rc=$?
    if [[ "$build_rc" -eq 0 ]]; then
      build_status="PASS"
    else
      build_status="FAIL"
    fi
  else
    echo "No recognized generic build system (make/ninja) found; skipping build check." >"$build_log"
  fi

  # Adaptive test check.
  if [[ -f "$repo_dir/Makefile" || -f "$repo_dir/makefile" || -f "$repo_dir/GNUmakefile" ]]; then
    test_cmd_used="make test"
    test_rc=0
    (cd "$repo_dir" && make test >"$test_log" 2>&1) || test_rc=$?
    if [[ "$test_rc" -eq 0 ]]; then
      test_status="PASS"
    else
      test_status="FAIL"
    fi
  elif [[ -d "$repo_dir/build" ]] && command -v ctest >/dev/null 2>&1; then
    test_cmd_used="ctest --test-dir build --output-on-failure"
    test_rc=0
    (cd "$repo_dir" && ctest --test-dir build --output-on-failure >"$test_log" 2>&1) || test_rc=$?
    if [[ "$test_rc" -eq 0 ]]; then
      test_status="PASS"
    else
      test_status="FAIL"
    fi
  else
    echo "No recognized generic test command found; skipping test check." >"$test_log"
  fi

  # Adaptive patch check: stdin-mode first, then file-mode fallback.
  if [[ -n "$checkpatch_cmd" ]]; then
    checkpatch_exec="$checkpatch_cmd"
    if [[ "$checkpatch_exec" == *.py* ]] && [[ "$checkpatch_exec" != python* ]]; then
      checkpatch_exec="python3 $checkpatch_exec"
    fi

    if git -C "$repo_dir" rev-parse --verify "$resolved_base_ref" >/dev/null 2>&1; then
      git -C "$repo_dir" format-patch --stdout "${resolved_base_ref}..HEAD" >"$patch_file" 2>"$cpatch_log" || true
      git -C "$repo_dir" format-patch -o "$patch_dir" "${resolved_base_ref}..HEAD" >>"$cpatch_log" 2>&1 || true
      patch_files=( "$patch_dir"/*.patch )
      has_patch_files=0
      if [[ -e "${patch_files[0]}" ]]; then
        has_patch_files=1
      fi

      if [[ -s "$patch_file" || "$has_patch_files" -eq 1 ]]; then
        checkpatch_cmd_used="$checkpatch_exec"

        if [[ "$checkpatch_exec" == *"PatchCheck.py"* ]]; then
          # EDK2 PatchCheck is most reliable when passed patch file paths.
          if [[ "$has_patch_files" -eq 1 ]]; then
            checkpatch_rc=0
            (cd "$repo_dir" && eval "${checkpatch_exec} \"${patch_files[@]}\"" >>"$cpatch_log" 2>&1) || checkpatch_rc=$?
            if [[ "$checkpatch_rc" -eq 0 ]]; then
              checkpatch_status="PASS"
              checkpatch_mode="file-patch-batch"
            else
              checkpatch_status="FAIL"
              checkpatch_mode="file-patch-batch-failed"
            fi
          else
            checkpatch_rc=1
            checkpatch_status="FAIL"
            checkpatch_mode="no-patch-files-for-patchcheck"
            echo "No patch files generated for PatchCheck.py fallback." >>"$cpatch_log"
          fi
        else
          # Generic checker: try stdin patch mailbox first.
          checkpatch_rc=0
          (cd "$repo_dir" && eval "cat \"$patch_file\" | ${checkpatch_exec} -" >>"$cpatch_log" 2>&1) || checkpatch_rc=$?
          if [[ "$checkpatch_rc" -eq 0 ]]; then
            checkpatch_status="PASS"
            checkpatch_mode="stdin-patch"
          else
            # Fallback: run checker per patch file and aggregate failures.
            if [[ "$has_patch_files" -eq 1 ]]; then
              checkpatch_rc=0
              for pf in "${patch_files[@]}"; do
                (cd "$repo_dir" && eval "${checkpatch_exec} \"$pf\"" >>"$cpatch_log" 2>&1) || checkpatch_rc=1
              done
              if [[ "$checkpatch_rc" -eq 0 ]]; then
                checkpatch_status="PASS"
                checkpatch_mode="file-patch-loop-fallback"
              else
                checkpatch_status="FAIL"
                checkpatch_mode="stdin+file-loop-fallback-failed"
              fi
            else
              checkpatch_status="FAIL"
              checkpatch_mode="stdin-failed-no-file-fallback"
            fi
          fi
        fi
      else
        checkpatch_rc=1
        checkpatch_status="FAIL"
        checkpatch_mode="patch-generation-failed"
        echo "Unable to generate patch stream for ${resolved_base_ref}..HEAD" >>"$cpatch_log"
      fi
    else
      checkpatch_rc=1
      checkpatch_status="FAIL"
      checkpatch_mode="invalid-base-ref"
      echo "Invalid base ref for checkpatch: ${resolved_base_ref}" >"$cpatch_log"
    fi
  else
    echo "checkpatch command not provided" >"$cpatch_log"
  fi

  diffstat="$(git -C "$repo_dir" diff --stat "${resolved_base_ref}...HEAD" 2>/dev/null || true)"
  short_status="$(git -C "$repo_dir" status --short --branch 2>/dev/null || true)"

  {
    echo
    echo "## Validation (Compact)"
    echo "- Base ref used: ${resolved_base_ref}"
    echo "- Build: ${build_status}"
    echo "- Test: ${test_status}"
    echo "- Patch checkpatch: ${checkpatch_status}"
    echo "- Checkpatch mode: ${checkpatch_mode}"
    echo "- Build command: ${build_cmd_used}"
    echo "- Test command: ${test_cmd_used}"
    echo "- Checkpatch command: ${checkpatch_cmd_used}"
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
