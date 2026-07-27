# Plan: `az-watcher` — Azure DevOps → herdr worktree automation

> Status: **planned, not yet implemented.** To be written and tested later.

## Context

The `wsl/herdr` workflow can create/remove story worktrees interactively (herdr-plus quick
actions → `worktree-make.sh` / `worktree-remove.sh`). This adds a **headless** driver,
`az-watcher`, that keeps local worktrees in sync with Azure DevOps PRs:

- **New Review** — when a PR has been assigned to me (I'm a reviewer) in the last ~5 minutes,
  create a **review** worktree for that PR's repo + source branch.
- **Remove story** — when a story's PR(s) have been completed/merged/abandoned in the last
  ~5 minutes, remove the corresponding local worktree, local git branch, and notes file(s);
  when a story folder empties, remove the folder too.

For now it's run manually; **eventually a cron job every 5 minutes**, so everything must be
non-interactive, idempotent, and stateless (the laptop can reboot with no state to lose).

### Decisions (confirmed with the user)
- **Story id = Azure Boards work item id.** The **slug is not in Azure** → az-watcher derives
  a 2–4 word slug from the work item **title** (deterministic ⇒ multi-repo PRs of one story
  share the same `{id}_{slug}` folder). Isolated in one `slug_for_story()` function the user
  can override. Removal reads the slug from the on-disk folder name, so it needs no Azure call.
- **New Review scope = just the assigned PR** (one repo/branch per assignment).
- **Auth = `az login`** + `az devops configure -d organization=… project=…` defaults (org/
  project also overridable via env). No PAT file.
- **Removal = stateless, 5-minute window, per-PR:** act on PRs that *closed* in the window;
  remove that PR's worktree/branch/notes; drop the story folder when it becomes empty.
- **"Last 5 minutes" is stateless:** New Review filters active reviewer-PRs by `creationDate`
  in the window; Remove filters reviewer-PRs by `closedDate` in the window. Window is a
  `--window <min>` flag (default 5). Idempotency (below) makes overlapping runs safe.

### Verified (Azure CLI, azure-devops extension)
- `az repos pr list --reviewer <me> --status active|completed|abandoned -o json` → PRs with
  `pullRequestId`, `title`, `status`, `sourceRefName`, `repository.name`, `creationDate`,
  `closedDate`.
- `az repos pr work-item list --id <pr> -o json` → linked work item id(s) (the story id).
- `az boards work-item show --id <id> --query "fields.\"System.Title\"" -o tsv` → title→slug.
- `az account show --query user.name -o tsv` → signed-in user (default `--reviewer` value).

## New: `wsl/herdr/az-watcher/`

```
az-watcher/
  az-watcher.sh     # entry point (new-review + remove-merged), non-interactive
  README.md         # usage, az prereqs, manual run, cron-later instructions
```

### `az-watcher.sh`
- **Config / prereqs:** requires `az` (with `azure-devops` ext), `git`, `jq`; herdr for
  creation. Reads optional env `AZDO_ORG`, `AZDO_PROJECT` (else uses `az devops` defaults) and
  `AZ_WATCHER_ME` (else `az account show`). Adds `--org/--project` to az calls only when set.
- **CLI:** `az-watcher [new-review|remove-merged|run] [--window N] [--dry-run] [--me <id>]`.
  Default `run` = both. `--dry-run` prints intended actions without creating/removing.
- **Locking:** `flock` on `${XDG_RUNTIME_DIR:-/tmp}/az-watcher.lock` so cron runs never overlap.
- **Logging:** timestamped lines to stdout (cron redirects to a log).
- **`slug_for_story()`** — `az boards work-item show` title → lowercase, strip non-alnum,
  hyphenate, keep first 4 words. Single point to customize.
- **new-review:**
  1. `me = ${AZ_WATCHER_ME:-$(az account show --query user.name -o tsv)}`.
  2. `az repos pr list --reviewer "$me" --status active -o json`; keep PRs with
     `creationDate` within the window.
  3. Per PR: `repo=.repository.name`, `branch=.sourceRefName` (strip `refs/heads/`),
     `storyId` = first `az repos pr work-item list` id, `slug=slug_for_story(storyId)`.
  4. Write a one-line `repo:branch` file and invoke the review pipeline **non-interactively**:
     `WT_ID=$storyId WT_SLUG=$slug WT_BRANCHES_FILE=$tmp "$HOME/bin/make-worktree.sh" review`.
     (Reuses all existing worktree/tab/notes logic.) Idempotency is enforced in
     `worktree-make.sh` (skips if the repo worktree already exists), so re-runs are safe.
- **remove-merged:**
  1. `az repos pr list --reviewer "$me" --status completed -o json` and `--status abandoned`;
     keep PRs with `closedDate` within the window.
  2. Per PR: `storyId` = linked work item id, `repo=.repository.name`.
  3. Invoke removal **non-interactively, per repo**:
     `WT_ID=$storyId WT_REPO=$repo WT_ASSUME_YES=1 "$HOME/bin/worktree-remove.sh"`.
     It finds the local `${storyId}_*` folder(s), removes just that repo's worktree + local
     branch + `${id}-${slug}-${repo}.txt`, and deletes the story folder when it's the last one.
     Missing = no-op (safe for overlapping runs); remote branches untouched.

## Modifications to existing scripts (small, additive)

### `wsl/herdr/worktree-make.sh` — non-interactive hooks + idempotency
- `NONINTERACTIVE=1` when `WT_ID` and `WT_SLUG` are both set. When set: skip the tty-reattach
  block and `gum`; take `ID=$WT_ID`, `SLUG=$WT_SLUG`; dev repos from `WT_REPOS`; review
  branches from `WT_BRANCHES_FILE` (use as `$BRANCHES`, skip the placeholder heredoc/warning).
  Only `need gum` in interactive mode.
- **Idempotency guard** in `make_worktree_new` / `make_worktree_existing`: if
  `${STORY_DIR}/${repo}/.git` already exists, log "exists, skipping" and return (helps both
  the watcher and manual re-runs).

### `wsl/herdr/worktree-remove.sh` — non-interactive + single-repo + id-glob
- If `WT_ID` set: use it (skip the id/slug prompts). If `WT_SLUG` empty, **glob** matching
  story folders `${ID}_*` across the candidate roots instead of an exact `${ID}_${SLUG}`.
- If `WT_ASSUME_YES=1`: skip the `gum confirm`.
- If `WT_REPO` set: operate on **only** that repo's worktree (remove worktree + local branch +
  that repo's notes file `${ID}-${SLUG}-${WT_REPO}.txt`); after removal, if the story folder
  has no remaining worktrees, delete the folder + leftover sidecars/notes. Unset ⇒ current
  whole-story behavior.

### `wsl/herdr/worktree-launch.sh` — manual trigger from herdr
- Add an `az-sync` action: `SCRIPT="${HOME}/bin/az-watcher"; RUN_ARGS="run"; label="Sync Azure Reviews"`
  so a quick action can run az-watcher in a visible tab.

### `wsl/herdr/az-watcher.toml` (new quick action)
- `name = "Sync Azure Reviews"`, `command = '"$HOME/bin/worktree-launch.sh" az-sync {{.WorkspaceId}} "{{.WorkDir}}"'`.

### `wsl/herdr/install.sh`
- `normalize_shell_script` + symlink `az-watcher/az-watcher.sh` → `~/bin/az-watcher`.
- `install_file` the `az-watcher.toml` quick action into herdr-plus `quick-actions/`.
- Add az prereq note to the "Manual next steps" echo (no auto-install of `az`).

### Docs
- `az-watcher/README.md`: `az login` + `az devops configure -d organization=… project=…`,
  manual `az-watcher run --dry-run` first, then `run`; the **cron-later** line
  (`*/5 * * * * $HOME/bin/az-watcher run >> ~/.local/state/az-watcher.log 2>&1`, guarded by
  flock); assumptions (below).
- Main `wsl/herdr/README.md`: short "Azure sync (az-watcher)" section pointing at it and the
  **Sync Azure Reviews** quick action.

## Verification
1. `bash -n` on `az-watcher.sh` and the three edited scripts; grep for username literals.
2. **Offline unit check** (no Azure): run `az-watcher.sh` with a stubbed `az` on `PATH`
   returning canned JSON (one active reviewer PR; one recently-completed PR) and `--dry-run`;
   confirm it would call `make-worktree.sh review` / `worktree-remove.sh` with the right
   `WT_*` env. (Sandbox in scratchpad; does not touch the repo.)
2b. Non-interactive hooks directly: `WT_ID=99999 WT_SLUG=dry-run WT_BRANCHES_FILE=… make-worktree.sh review`
    creates the review worktree with no prompts; a second run logs "exists, skipping".
    `WT_ID=99999 WT_REPO=repo-a WT_ASSUME_YES=1 worktree-remove.sh` removes just that repo.
3. **Live, manual, dry-run first:** `az login`; `az-watcher run --dry-run` and eyeball the
   planned actions against real assignments; then `az-watcher run`.
4. Assign yourself a test PR → `new-review` creates the review worktree (tabs `notes/claude/
   cursor/bash`). Complete/abandon it → within a window, `remove-merged` tears it down.

## Notes / assumptions / limitations
- **Azure repo name == local clone dir** under `SRC_ROOT`. Documented; a name-map can be added
  later if they diverge.
- **herdr session must be running** for creation (so `herdr worktree create` + herdr-plus
  auto-layout apply). Fine for manual use and for cron while a session is up.
- **Stateless windowing trade-off:** New Review keys on PR `creationDate`; a *reassignment* to
  an older PR isn't detected (only newly-created reviewer PRs are). Acceptable per the "keep it
  simple, no state" decision; the idempotency guard prevents duplicates.
- Removal only ever deletes **local** branches/worktrees/notes for stories tied to *your*
  reviewer PRs; remote branches and others' work are untouched. `--dry-run` shows exactly what
  would be removed.
- `az boards`/`az repos` are part of the `azure-devops` extension (auto-installs on first use).
