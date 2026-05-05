---
name: pr-comments-fixing
description: Review pull request comments and convert them into an actionable implementation plan (typically plan.md) with file-level fix tasks, validation steps, and response workflow. Use when a user asks to review PR feedback, fetch actual reviewer comments, and prepare or update a concrete fix plan for a local checked-out repo.
---

# PR Comments Fixing

## Overview

Use this skill to gather real PR comments from GitHub (review comments + issue comments), map each comment to code-level fixes, and update a local plan document with implementation sequencing and verification gates.

## Required Inputs

Request these inputs before doing PR analysis:
1. Repo folder path
2. PR details
   - Preferred: full PR URL
   - Acceptable fallback: owner/repo + PR number
3. Checkpatch script command/path used by this repo
   - Examples: `./scripts/checkpatch.pl`, `./linux/scripts/checkpatch.pl`, or custom wrapper

If any input is missing, ask for it explicitly and do not guess checkpatch path.

## Workflow

1. Enter repo and verify context
   - Confirm git repo, remotes, current branch, and worktree status.
   - Fetch PR head into a local branch ref.

2. Fetch actual PR comments
   - Pull review comments:
     - `GET /repos/{owner}/{repo}/pulls/{number}/comments`
   - Pull PR-level comments:
     - `GET /repos/{owner}/{repo}/issues/{number}/comments`
   - Optionally pull review summaries:
     - `GET /repos/{owner}/{repo}/pulls/{number}/reviews`
   - Capture ids, file path, line, commenter, and comment text.

3. Build actionable fix map
   - Mark each comment as:
     - `actionable-code-change`
     - `non-code-process` (for example email/account setting notes)
     - `clarification-needed`
   - For actionable comments, map to:
     - target file(s)
     - expected API/behavior change
     - acceptance check

4. Update `plan.md`
   - Include actual comment inventory (counts and date fetched).
   - Add comment-by-comment implementation plan with concrete tasks.
   - Add commit sequencing plan.
   - Add verification checklist including build/test and checkpatch command supplied by user.

5. Keep plan implementation-ready
   - Use specific commands and file names.
   - Include definition of done tied to reviewer intent.

6. Execute fixes from `plan.md` (one task at a time)
   - Work strictly top-to-bottom through actionable items in `plan.md`.
   - Implement only one task (or one tightly-coupled subtask) before committing.
   - Run relevant validation for that task before committing.
   - Create one focused commit per task with message format:
     - `pr-<number>: address comment <comment-id> <short-topic>`
   - Update `plan.md` task status after each commit (`todo` -> `done` + commit hash).

7. Final history shaping (only with explicit user approval)
   - Default: keep per-task commits for review transparency.
   - If user explicitly asks, squash fix commits and amend the original PR commit.
   - Before amend/squash:
     - show user the commit list to be squashed
     - confirm tests/checks are still passing
   - Never amend/squash implicitly.

## Output Contract

When complete, `plan.md` must contain:
1. PR scope and touched files
2. Actual fetched comments summary
3. Actionable item list mapped to files/lines
4. Fix implementation sequence
5. Validation commands including repo-specific checkpatch command
6. PR update workflow (reply/resolve/re-review)
7. Task status tracking fields suitable for one-task-at-a-time execution

## Command Patterns

Use one of the following based on available tooling:
1. `curl` + GitHub REST API
2. `gh api` / `gh pr view` if authenticated

Use `jq` to normalize comments into compact tables for planning.

## Bundled Script

Use [`scripts/fetch_pr_comments.sh`](scripts/fetch_pr_comments.sh) to fetch and normalize PR comment data.

Examples:
```bash
# Using PR URL
scripts/fetch_pr_comments.sh \
  --pr-url https://github.com/riscv-software-src/librpmi/pull/78 \
  --out-dir /tmp/pr-comments-78

# Using owner/repo/number
scripts/fetch_pr_comments.sh \
  --owner riscv-software-src \
  --repo librpmi \
  --pr 78 \
  --out-dir /tmp/pr-comments-78
```

Optional auth:
- Set `GITHUB_TOKEN` in environment, or pass `--token <token>`.
- Use auth when rate limits or private repo access apply.

Use [`scripts/generate_plan_from_comments.sh`](scripts/generate_plan_from_comments.sh) to produce a `plan.md`-ready markdown section.

Examples:
```bash
# Print a full implementation-focused plan to stdout
scripts/generate_plan_from_comments.sh \
  --comments-dir /tmp/pr-comments-78 \
  --repo-dir /path/to/repo \
  --base-ref upstream/main \
  --head-ref pr-78 \
  --checkpatch-cmd "./linux/scripts/checkpatch.pl --no-tree --file lib/rpmi_service_group_logging.c" \
  --include-reviews

# Save full plan to a file
scripts/generate_plan_from_comments.sh \
  --comments-dir /tmp/pr-comments-78 \
  --repo-dir /path/to/repo \
  --base-ref upstream/main \
  --head-ref pr-78 \
  --checkpatch-cmd "<repo-checkpatch-command>" \
  --output /tmp/pr-comments-78/plan_section.md

# Overwrite plan.md directly
scripts/generate_plan_from_comments.sh \
  --comments-dir /tmp/pr-comments-78 \
  --repo-dir /path/to/repo \
  --base-ref upstream/main \
  --head-ref pr-78 \
  --checkpatch-cmd "<repo-checkpatch-command>" \
  --plan-file ./plan.md
```
