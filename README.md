# pr-comments-fixing skill repo

This repository packages the `pr-comments-fixing` Codex skill as a standalone installable bundle.

## What this skill does

The skill helps you:
1. Fetch real PR comments from GitHub (review comments + PR-level comments).
2. Generate an actionable `plan.md` for the PR.
3. Execute fixes one task at a time from `plan.md`.
4. Commit each task separately and track status/commit hash in the plan.
5. Handle bad/unclear comments explicitly with per-item disposition + rationale.

## Repository layout

- `install.sh`: installer for the skill
- `pr-comments-fixing/SKILL.md`: skill instructions
- `pr-comments-fixing/agents/openai.yaml`: UI metadata
- `pr-comments-fixing/scripts/fetch_pr_comments.sh`: fetch comment artifacts
- `pr-comments-fixing/scripts/generate_plan_from_comments.sh`: generate implementation-focused `plan.md`

## Clone

SSH (recommended for private repo access):

```bash
GIT_SSH_COMMAND='ssh -i ~/.ssh/slingappa_git/id_rsa -o IdentitiesOnly=yes' \
git clone git@github.com:slingappa/pr-comments-fixing-skill.git
cd pr-comments-fixing-skill
```

HTTPS:

```bash
git clone https://github.com/slingappa/pr-comments-fixing-skill.git
cd pr-comments-fixing-skill
```

Checkout latest main:

```bash
git checkout main
git pull --ff-only
```

## Install

```bash
cd /path/to/pr-comments-fixing-skill
./install.sh --force
```

Optional destination:

```bash
./install.sh --dest /path/to/skills --force
```

## Required inputs when invoking skill

Provide these in your prompt:
1. Repo folder path
2. PR URL (or owner/repo + PR number)
3. Checkpatch command/path for your environment

Recommended checkpatch usage is patch-mode (not single-file mode):

```bash
git format-patch --stdout <base>..HEAD | <checkpatch-cmd> -
```

## Recommended prompt template

```text
Use $pr-comments-fixing.
Repo: /abs/path/to/repo.
PR: https://github.com/<owner>/<repo>/pull/<number>.
Checkpatch command: /abs/path/to/checkpatch.pl --no-tree.
Fetch latest comments, regenerate plan.md, then execute fixes one task at a time from plan.md with one commit per task, updating Status/Commit fields after each commit. Do not squash/amend unless I explicitly approve.
```

## Execution model

- Work top-to-bottom through `Status: todo` items in `plan.md`.
- Use `Disposition` to decide handling:
- `implement`: code change + validation + commit
- `clarify-with-reviewer`: ask/answer first, no code change until clarified
- `reject-with-rationale`: document reason and skip code change
- Implement one task (or tightly coupled subtask set) at a time.
- Validate after each task.
- Commit each task separately.
- Update `Status`, `Commit`, and `Rationale` fields in `plan.md`.
- Only squash/amend original commit after explicit user approval.

## Notes

- If GitHub API rate-limit/auth blocks comment fetch, provide `GITHUB_TOKEN` or pass `--token` to `fetch_pr_comments.sh`.
- `generate_plan_from_comments.sh` can overwrite `plan.md` via `--plan-file`.
