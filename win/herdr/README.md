# Herdr set-up (Windows)

Native Windows PowerShell port of the WSL Herdr + herdr-plus workflow for
multi-repo story worktrees (dev and review). Bash source of truth lives in
[`wsl/herdr/`](../../wsl/herdr/).

> **Diverged from `wsl/herdr/`.** The Windows scripts are now **task-centric**:
> the story is the root row in the sidebar, with one indented row per repo under
> it. The bash scripts are still repo-centric (one workspace per repo worktree,
> nested under its clone).
> See [Story navigation](#story-navigation-the-task-is-the-root-item).

> **Windows beta.** Plugins are **preview**; `herdr --remote` is unsupported.
> See [Windows beta](https://herdr.dev/docs/windows-beta/).

## Installation set-up

```powershell
cd C:\path\to\vscodesettings\win\herdr
.\install.ps1
```

`install.ps1` will (**idempotent**; never overwrites `%APPDATA%\herdr\config.toml`):

1. Ensure `%USERPROFILE%\bin` and `%USERPROFILE%\.local\bin` on the user `PATH`
2. Ensure CLIs: [herdr](https://herdr.dev/) (≥ 0.7.5; skips reinstall if present),
   `gum` (Charm Windows zip), `jq`, `micro`, `git`; checks `claude` / `agent` /
   `az` (does **not** auto-install Azure CLI)
3. If `%APPDATA%\herdr\config.toml` is missing, create it with
   `herdr --default-config`
4. Install plugins: `cloudmanic/herdr-plus`, `senna-lang/herdr-agent-usage`,
   `persiyanov/herdr-reviewr`
5. Apply managed `herdr-reviewr` plugin config (plugin dir only)
6. Install shims into `%USERPROFILE%\bin`: `make-worktree.ps1`,
   `worktree-launch.ps1`, `worktree-remove.ps1`, `az-watcher.ps1`
7. Copy Windows quick-action TOMLs + `worktree-layout.toml` into herdr-plus

Then edit machine-local values at the top of `worktree-make.ps1`:

* `SRC_ROOT` - primary clones (`$HOME\source\repos\<repo>`)
* `BRANCH_PREFIX` - e.g. `feature/aaron`

Story worktrees use Herdr's `[worktrees].directory` from config.toml.

## Herdr settings (manual `config.toml`)

`install.ps1` only writes a default `config.toml` when the file is missing; it
never merges the snippets below. Edit by hand:

```powershell
micro $env:APPDATA\herdr\config.toml
```

### Worktree directory

```toml
[worktrees]
directory = "C:\\Users\\<you>\\source\\worktrees"
```

### Herdr Plus keybinds (Windows)

On Windows, herdr-plus exposes **platform-specific** action ids. The Linux/macOS
ids (`cloudmanic.herdr-plus.projects` / `...quick-actions`) are filtered to
`linux`/`macos` only. Use the `-windows` variants:

```toml
[[keys.command]]
key = "prefix+up"
type = "plugin_action"
command = "cloudmanic.herdr-plus.projects-windows"
description = "herdr-plus: projects"

[[keys.command]]
key = "prefix+down"
type = "plugin_action"
command = "cloudmanic.herdr-plus.quick-actions-windows"
description = "herdr-plus: quick actions"
```

If your existing config still binds the non-`-windows` ids, prefix+up/down will
not open the pickers on native Windows until you update them. `install.ps1` does
**not** rewrite your root `config.toml`.

Verify:

```powershell
herdr plugin action list --plugin cloudmanic.herdr-plus
herdr plugin action invoke projects-windows --plugin cloudmanic.herdr-plus
herdr plugin action invoke quick-actions-windows --plugin cloudmanic.herdr-plus
```

### Theme / navigation / reviewr / Agent Usage

Same snippets as the WSL README (`wsl/herdr/README.md`): theme, nav keys,
`persiyanov.reviewr.toggle`, Agent Usage sidebar rows, toast delivery. Config
path on Windows is `%APPDATA%\herdr\config.toml` (not `~/.config/herdr/`).

reviewr plugin config dir:

```powershell
herdr plugin config-dir persiyanov.reviewr
```

Manual reviewr invoke:

```powershell
herdr plugin action invoke toggle --plugin persiyanov.reviewr
```

### Plugin platform caveats (Windows beta)

`herdr-plus` ships Windows-native actions (`*-windows`). **Agent Usage** (`usagebar`)
and **reviewr** currently declare `platforms = ["macos","linux"]` only — their
`bash …` action commands will not run on native Windows until those plugins add
Windows variants. They still install; seeding/toggling from Windows may need WSL
or a future plugin update.

Seed Agent Usage when a Windows action exists (or from WSL):

```powershell
herdr plugin action invoke usagebar.setup
```

## Story navigation: the task is the root item

The story folder on disk has always been task-first:

```
<worktrees.directory>\development\{id}-{slug}\
    repo1\                      git worktree
    repo2\                      git worktree
    {id}-{slug}-repo1.txt       notes, one per repo
    {id}-{slug}-repo2.txt
```

herdr's sidebar used to read the other way round, because it groups workspaces
by their source repository (`worktree.repo_key`) and nests linked worktrees under
their primary clone — grouping that is built in, with no config for it:

```
repo1
  {id}-{slug}
repo2
  {id}-{slug}
```

A story across four repos was therefore four unrelated rows in four different
groups. `herdr worktree create --workspace <ID>` is not a way out: `--workspace`
and `--cwd` are mutually exclusive, and `--workspace` only says which workspace
to take the *source repo* from — it still creates a workspace of its own.

So `worktree-make.ps1` adds the worktrees with plain `git worktree add` and builds
the rows itself. A workspace with no worktree metadata is not grouped at all, so
the sidebar now reads task-first, matching the folders — a story row with one
indented row per repo under it:

```
{id}-{slug}                 cwd = the story folder
  repo1                     cwd = {id}-{slug}\repo1
  repo2                     cwd = {id}-{slug}\repo2
{other-id}-{other-slug}
  repo1
```

### Tabs

The **story row** carries four tabs at the story root, where one agent sees every
repo in the story at once (`cd repo1` from any of them):

| Tab | Command |
|-----|---------|
| notes | `micro <notes file of the first repo requested>` |
| claude | `claude --permission-mode auto` |
| cursor | `agent --auto-review` |
| pwsh | bare PowerShell |

Each **repo row** carries three tabs at that repo's worktree root:

| Tab | Command |
|-----|---------|
| notes | `micro <that repo's own notes file>` |
| claude | `claude --permission-mode auto` |
| pwsh | bare PowerShell |

Repos are discovered by scanning the story folder for worktrees, so a repo added
to an existing story picks up its own row on the next run. Re-running reuses every
row it already has, creates only the tabs that are missing, and starts commands
**only in tabs it just created** — a tab you are already working in is never typed
into.

### The nesting is cosmetic

herdr has no parent/child workspaces. Its sidebar is a flat list of spaces, and
the only automatic grouping is the repo grouping described above. So:

* **The indent is part of the repo row's label** (`'  ' + repo`, set by
  `$CHILD_LABEL_PREFIX` at the top of `worktree-make.ps1`). Keep it ASCII — a
  box-drawing character renders as mojibake on a non-UTF-8 code page.
* **Adjacency comes from creation order**, which is what the sidebar sorts by.
  The repo rows are created back to back with their story row, so they sit
  together. A repo added to an existing story lands at the **bottom** of the
  sidebar rather than under its story until herdr is restarted.

If you would rather not rely on that, the alternative is one tab per repo inside
the single story workspace (`repo1 claude`, `repo2 claude`, …) — real containment,
but the grouping then only shows in the agent panel, not the space list.

### What this gives up

Story and repo workspaces are not registered with herdr as worktrees, so:

* `herdr worktree remove` / the worktree picker do not see them.
  `worktree-remove.ps1` closes every row of the story and uses `git worktree
  remove` instead (it still handles the old per-repo workspaces of existing
  stories).
* [`worktree-layout.toml`](worktree-layout.toml) no longer fires for them. It is
  still installed and still correct for worktrees opened through herdr's own UI.
* `branch` / `git_status` sidebar tokens are blank on a story row — there is no
  single branch for a four-repo story. (They would work on a repo row, but the
  same layout applies to every space.) Keep the one-row layout:

  ```toml
  [ui.sidebar.spaces]
  rows = [["state_icon", "workspace"]]
  ```

The checkouts themselves are ordinary git worktrees, unchanged.

## Daily use

* **prefix+down** → **New Dev Worktree** / **New Review Worktree** /
  **Delete Story Worktree** / **Sync Azure Reviews**
* Quick actions invoke PowerShell via herdr-plus's Windows runner
  (`powershell -NoProfile -NonInteractive -Command`). Commands must be
  PowerShell syntax using `{{.Home}}\bin\...` - **not** cmd `%USERPROFILE%` and
  **not** a nested `powershell.exe -File ...` wrapper.

## Azure sync (`az-watcher`)

```powershell
az login
az devops configure -d organization=https://dev.azure.com/<org> project='<project>'
az-watcher.ps1 run --dry-run --window 0
```

Details: [`az-watcher/README.md`](az-watcher/README.md).

## Apply settings / validation

```powershell
herdr config check
herdr plugin list
herdr plugin action list --plugin cloudmanic.herdr-plus
herdr plugin action list --plugin senna-lang.herdr-agent-usage
herdr plugin action list --plugin persiyanov.reviewr
herdr server reload-config
```

### Dry run

1. Set `SRC_ROOT` in `worktree-make.ps1` and `[worktrees].directory` in config.
2. Place test repos under `SRC_ROOT`.
3. In herdr: **prefix+down** → **New Dev Worktree** (or invoke
   `quick-actions-windows`).
4. Expect story under `<worktrees.directory>\development\<id>-<slug>\` with notes
   + worktrees as above, and sidebar rows `<id>-<slug>` (four tabs) followed by an
   indented row per repo (three tabs each).

Non-interactive (if test repos exist):

```powershell
$env:WT_ID='99999'; $env:WT_SLUG='dry-run'; $env:WT_REPOS='repo-a,repo-b'
& "$env:USERPROFILE\bin\make-worktree.ps1" development
```

Cleanup: `worktree-remove.ps1 <id>` (or `git worktree remove` from each primary
clone, then delete the story folder under `[worktrees].directory`).

### Always creating from the latest default branch

`worktree-make.ps1` guarantees a new worktree sits on the tip of
`origin/<default branch>`, and prints a `-> verify: HEAD <sha> == origin/<branch>`
line proving it. It gets there by owning the branch itself rather than trusting
`herdr worktree create --base`, which silently ignored `--base` whenever the
local branch already existed and just checked it out wherever it happened to
point. (The worktree is now added with `git worktree add` — see
[Story navigation](#story-navigation-the-task-is-the-root-item) — but the branch is
still positioned by this script, not by whatever checks it out.)

What it does per repo:

1. `git fetch --prune origin`, **exit status checked**, one retry. A failed fetch
   aborts that repo instead of falling back to a stale `origin/<default>`.
2. `git remote set-head origin --auto` — plain `git fetch` never updates
   `refs/remotes/origin/HEAD`, so a clone made before the remote's default branch
   was renamed would otherwise keep branching from the wrong one.
3. Resolves the base to an explicit commit sha.
4. Puts the local branch at exactly that sha.
5. Verifies the new worktree's `HEAD`, repairing a clean worktree once with
   `git reset --hard` before failing.

If a branch of that name already exists **and holds commits the base does not**,
the script refuses rather than hand back old code or throw work away. It lists
those commits and offers:

| variable | effect |
| --- | --- |
| `WT_REUSE_BRANCH=1` | keep the existing branch (resume the story); reports how far behind the base it is |
| `WT_RESET_BRANCH=1` | discard its unique commits and start from the base |

A leftover branch with **no** commits of its own is simply moved to the base
(nothing can be lost) and the move is logged.

Exit codes: `0` created and verified · `1` bad input or at least one repo failed
· `3` nothing to do (every worktree already existed).

### Tests

```powershell
powershell -File win\herdr\tests\test-worktree-make.ps1     # needs herdr running
powershell -File win\herdr\tests\test-worktree-remove.ps1   # no herdr needed
```

Both build throwaway repos under the temp directory and assert on real behaviour
(stale origin refs, leftover branches, fetch failure, protected default
branches, dirty-worktree keeps, and the one-workspace-per-story topology). They
never touch your real repos or worktrees, and the make suite closes every
workspace it created.
