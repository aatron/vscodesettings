# Herdr set-up

Shared WSL Herdr + herdr-plus workflow for multi-repo story worktrees (dev and review).

## Installation set-up

Run this first — it installs `herdr` and the other CLIs, and creates a default `config.toml` when one does not exist yet.

On each machine (home and work), clone this repo in WSL, then:

```
cd /path/to/vscodesettings/wsl/herdr
./install.sh
```

`install.sh` will (**idempotent**; never overwrites the root Herdr `config.toml`):

1. Install CLIs if missing: [herdr](https://herdr.dev/) (≥ 0.7.5), `gum`, `git`, `micro`, `jq`, `claude`, `agent`; ensure `~/bin` and `~/.local/bin` are on `PATH`
2. If `~/.config/herdr/config.toml` is missing, create it with the documented default:
   `herdr --default-config > ~/.config/herdr/config.toml`
3. Install plugins:
   * `cloudmanic/herdr-plus` — Projects, quick actions, worktree auto-layout
   * `senna-lang/herdr-agent-usage` — Context meters + provider rate limits
   * `persiyanov/herdr-reviewr` — Review workflow helpers
4. Apply managed `herdr-reviewr` plugin config (in the plugin config dir only; the root Herdr `config.toml` is never overwritten)
5. Symlink `worktree-make.sh` → `~/bin/make-worktree.sh` and `worktree-launch.sh` → `~/bin/worktree-launch.sh`
6. Copy quick actions into herdr-plus `quick-actions/`:
   * `new-worktree-dev.toml` → **New Dev Worktree** (opens a tab, then runs the script)
   * `new-worktree-review.toml` → **New Review Worktree**
   * `remove-worktree.toml` → **Delete Story Worktree** (form: story id → removes matching `{id}-*` worktrees, branches, and notes)
7. Copy `worktree-layout.toml` into herdr-plus `worktrees/` (wildcard layout for every repo)

Then edit machine-local values at the top of `worktree-make.sh`:

* `SRC_ROOT` — primary clones (`$HOME/source/repos/<repo>`)
* `BRANCH_PREFIX` — e.g. `feature/aaron`

Story worktrees use Herdr’s `[worktrees].directory` from `config.toml` (see below). Do not set a separate `WORKTREE_ROOT` in the script.

## Herdr settings (manual `config.toml`)

`install.sh` only writes a default `config.toml` when the file is missing; it never merges the snippets below. Edit by hand:

```
micro ~/.config/herdr/config.toml
```

### Worktree directory

Used by Herdr’s built-in worktree actions **and** by `worktree-make.sh` for story folders (`development/…`, `review/…`). Set this (recommended for this workflow). If omitted, `worktree-make.sh` falls back to `~/source/worktrees`.

```
[worktrees]
directory = "~/source/worktrees"
```

### Theme

```
[theme]
# Built-in themes: catppuccin, terminal, tokyo-night, dracula, nord,
#                  gruvbox, one-dark, solarized, kanagawa, rose-pine,
#                  vesper
name = "solarized"
```

```
[theme.custom]
overlay0 = "#93a1a1" # Lighten secondary text
accent   = "#5fff5f" # Brighter green for the highlighted/selected sidebar row (and other accents)
```

`accent` is the token herdr uses for highlights, borders, and navigation UI, so
overriding it here is what turns the selected left-panel row bright green. Tweak the
hex to taste.

### Navigation keys

```
[keys]
# Move between tabs
previous_tab = "ctrl+alt+left"
next_tab     = "ctrl+alt+right"
# Move between workspaces
previous_workspace = "ctrl+alt+up"
next_workspace     = "ctrl+alt+down"
```

### Herdr Plus keybinds

```
[[keys.command]]
key = "prefix+up"
type = "plugin_action"
command = "cloudmanic.herdr-plus.projects"
description = "herdr-plus: projects"

[[keys.command]]
key = "prefix+down"
type = "plugin_action"
command = "cloudmanic.herdr-plus.quick-actions"
description = "herdr-plus: quick actions"
```

### herdr-reviewr keybinds

Bind one Herdr-level key to show/hide the review pane. This belongs in
`~/.config/herdr/config.toml` (not the plugin config):

```
[[keys.command]]
key = "prefix+r"
type = "plugin_action"
command = "persiyanov.reviewr.toggle"
description = "reviewr: toggle reviewer"
```

Use **prefix+r** to show/hide the reviewer. Inside reviewr, press **?** for the
active shortcut list. Common defaults:

* **u** / **b** / **t** — scopes: uncommitted / branch / last turn
* **1** / **2** / **3** — tabs: Changes / All files / PR
* **v** — select lines
* **c** — comment on the selection/current line
* **s** — send all comments to the agent
* **q** — quit the reviewer pane

Manual commands when a keybind is not available:

```
herdr plugin action invoke open --plugin persiyanov.reviewr
herdr plugin action invoke close --plugin persiyanov.reviewr
herdr plugin action invoke toggle --plugin persiyanov.reviewr
```

### herdr-reviewr config

reviewr has its own config file:

```
~/.config/herdr/plugins/config/persiyanov.reviewr/config.toml
```

`install.sh` writes this managed block automatically and preserves other plugin
settings such as `[keybindings]`:

```
# BEGIN vscodesettings herdr-reviewr defaults
auto_open = false
toggle_placement = "overlay" # split | overlay | zoomed | tab
toggle_direction = "right"   # right | down; split only
default_scope = "branch"
# END vscodesettings herdr-reviewr defaults
```

`auto_open = false` keeps reviewr from racing herdr-plus while a new worktree
layout is being built; open it explicitly with **prefix+r** when ready. Use
`toggle_placement = "split"` if you prefer a persistent side pane instead of an
overlay.

### Agent panel / pane labels (under `[ui]`, not sidebar)

These belong on the top-level `[ui]` table. Putting them under `[ui.sidebar.agents]` makes herdr warn `config.toml has unknown keys` (`herdr config check`).

```
[ui]
agent_panel_sort = "spaces"                 # or "priority"
show_agent_labels_on_pane_borders = true
sidebar_start_collapsed = false             # keep the story sidebar visible — it IS the worktree navigation
```

### Story navigation on the left-hand panel

The left sidebar **is** the story navigation. herdr groups every workspace by its
**source repository** (`worktree.repo_key`) and always nests linked worktrees under
their primary clone. This grouping is built in — herdr offers no config to group by the
story folder instead — so the panel reads **repo → its story worktrees**:

```
herdrtest1
  111-example-first
  222-example-second
herdrtest2
  222-example-second
```

Two cleanups make that readable:

* **Label = `{id}-{slug}` only.** Because the repo is already the group header, each
  worktree is labeled just `{id}-{slug}` (no repeated `/{repo}` suffix — set by
  `--label` in `worktree-make.sh`). Labels are display names, so repeating `{id}-{slug}`
  across repos is fine.
* **No branch row.** The second sidebar row (`branch` / `git_status`) is dropped, so the
  primary-clone header no longer prints a misleading `main` — the worktrees under it are
  each on their own `feature/aaron/{id}-{slug}` branch, so the clone's own branch is not
  representative of the group.

The selected row is highlighted in bright green via `[theme.custom].accent` (see Theme
above). Keep the panel visible (`sidebar_start_collapsed = false`) and use
`previous_workspace` / `next_workspace` (below) to move within it.

```
[ui.sidebar.spaces]
# One row per entry: state icon + workspace label ({id}-{slug}).
# Each repo's header row is its primary clone (the repo name, e.g. "herdrtest1").
rows = [["state_icon", "workspace"]]
```

> Want per-worktree git ahead/behind back? Add a second row:
> `rows = [["state_icon", "workspace"], ["git_status"]]`. Avoid the `branch` token — that
> is what printed the misleading `main`.

### Agent Usage sidebar (Herdr 0.7.5+)

Only `row_gap` / `rows` (and optional `rows_by_agent`) go here:

```
[ui.sidebar.agents]
row_gap = 0
rows = [
  ["state_icon", "tab", "pane"],
  ["$provider", "$limit"],
  ["$context"],
]
```

### Agent Usage keybinds (optional)

```
[[keys.command]]
key = "ctrl+shift+u"
type = "plugin_action"
command = "usagebar.open-limits"
description = "Agent Usage: open limits pane"

[[keys.command]]
key = "ctrl+shift+m"
type = "plugin_action"
command = "usagebar.refresh"
description = "Agent Usage: refresh sidebar meters"
```

### Toast delivery (optional, for low-allowance warnings)

Prefer pasting this by hand rather than running `usagebar.enable-toast` (that action can append to `config.toml`):

```
[ui.toast]
delivery = "herdr" # or "system" / "terminal"

[ui.toast.herdr]
position = "bottom-left"
```

### Claude global usage (5h / 7d) — where it shows

Agent Usage **cannot** draw on Herdr’s global bottom status bar (plugins have no hook there). Claude account usage shows in these places instead:

| Surface | What you see |
|---------|----------------|
| Agent sidebar `$limit` / `$provider` | Shortest remaining plan window for the focused Claude pane (needs the sidebar rows above) |
| **ctrl+shift+u** → limits pane | Full Claude 5h / 7d (and other providers) account windows |

On demand inside Claude: `/usage` shows the full plan windows without a persistent footer.

## Apply settings

1. Validate config after pasting snippets:

   ```
   herdr config check
   ```

   Fix any `unknown config key` lines before relying on keybinds or the sidebar.
2. Seed Agent Usage (resolves/builds the `usagebar` binary; prints paste snippets; does not rewrite herdr `config.toml`):

   ```
   herdr plugin action invoke usagebar.setup
   ```

   Paste any sidebar / toast / key snippets it prints if you have not already added them.
3. Reload Herdr after any `config.toml` edit (each named session has its own server — reload or restart that session too):

   ```
   herdr server reload-config
   # named session (required when that session is the one you are using):
   herdr --session three-repo-test server reload-config
   ```

   Bare `herdr server reload-config` only talks to the **default** session. If that session is stopped you get `No such file or directory` (missing socket) — pass `--session <name>` for the running session (`herdr session list`).
   On herdr ≥ 0.7.5, installed plugins are global across sessions. After upgrading from 0.7.4, restart named sessions so they pick up the shared plugin registry (`herdr session stop <name>` then `herdr --session <name>`).
4. Optional: install agent integrations from the Settings menu or CLI for better session matching.

### Settings menu

* `toasts`
    * popups - system notification
* `integrations`
    * Install agent interactions (recommended for Agent Usage session matching)

## Worktree tabs (no per-repo toml required)

Tabs come from **one** herdr-plus Worktree Auto-Layout file with `repo = "*"`. You do **not** need a toml per repository unless you want a repo-specific override.

The layout opens four tabs at that repo's worktree root. Layouts cannot interpolate the repo/story name, and their tab **commands do not reliably start** on create — so `make-worktree.sh` owns both the labels and the commands, submitting each one into the tab's pane with `herdr pane run` after `cd`-ing to the worktree (repo) root:

| Tab (layout name) | Renamed to | What the script runs (at the repo root) |
|-------------------|------------|-----------------------------------------|
| notes | `notes-{id}-{slug}` | `micro <id>-<slug>-<repo>.txt` (that repo's notes file, absolute path) |
| claude | `{repo} claude` | `claude --permission-mode auto` (`$CLAUDE_CMD`) |
| cursor | `{repo} cursor` | `agent --auto-review` (`$CURSOR_CMD`, Cursor Agent CLI) |
| bash | `{repo} bash` | nothing — bare shell |

Both agents start in their **auto** permission mode — Claude's `auto` mode, and Cursor's `--auto-review` ("Smart Auto"): safe tool calls run on their own, anything riskier still prompts. Change `CLAUDE_CMD` / `CURSOR_CMD` at the top of `worktree-make.sh` to adjust (e.g. `agent --yolo` / `claude --permission-mode bypassPermissions` to stop prompting entirely), and keep `worktree-layout.toml`'s tab commands in sync.

A pane that is already running something (i.e. the layout's own command did fire) is left alone, so nothing gets launched twice. Re-opening an existing worktree does not re-run the script, so those tabs keep the layout names `notes` / `claude` / `cursor` / `bash` and whatever the layout itself manages to start.

## Daily use

* **Navigate** between story worktrees from the left sidebar (grouped by repo; each worktree row is labeled `{id}-{slug}`), or with `previous_workspace` / `next_workspace`
* **prefix+down** → **New Dev Worktree** or **New Review Worktree**
* That opens a new tab and runs `make-worktree.sh` there (herdr-plus overlays cannot host interactive `gum` prompts)
* Dev prompts: story id, slug, comma-separated repo names
* **Commit & push**: from any worktree, a plain `git commit` + `git push` just works — the script points each branch's upstream at its **own name** on origin, so the first `git push` creates `origin/feature/aaron/{id}-{slug}` and can never target the default branch (even with `push.default=upstream`). Without this, git would auto-track `origin/main` (the branch's base) and a plain push would fail — or worse, aim at main.
* Review prompts for id + slug and then uses a placeholder branch list — for real branches, let **az-watcher** create review worktrees from your Azure assignments instead (see below)
* **prefix+down** → **Delete Story Worktree** to tear a story down (enter story id only; see below)
* **prefix+down** → **Sync Azure Reviews** to run az-watcher once in a visible tab
* **ctrl+shift+u** → Agent Usage limits pane (if you added the keybind)

## Delete a story

**prefix+down** → **Delete Story Worktree** asks for the story `id` only (herdr-plus form), then opens a tab and runs `worktree-remove.sh`. The script globs every `{id}-*` folder (plus legacy `{id}_*` folders from before the rename) under both layouts a story can live in — `<[worktrees].directory>/development` and `<[worktrees].directory>/review` — and, after a `gum` confirmation, for each matching story:

* removes each repo worktree through herdr (`herdr worktree remove --force`) — this closes the workspace, deletes the checkout, **and unregisters the worktree from herdr's sidebar** (a plain `workspace close` leaves it listed),
* falls back to `git worktree remove --force` (then `rm -rf`) when herdr is not running or the directory survives, and prunes stale worktree registrations in the primary clone,
* deletes each worktree's **local** git branch (never the repo's default branch; a detached HEAD is skipped),
* deletes every per-repo notes file `<id>-<slug>-<repo>.txt` (slug taken from the folder name; inside the story folder, and in the old sibling location for pre-rename stories) and removes the story folder.

The confirmation prompt warns explicitly that the worktree directories themselves are deleted — including any **uncommitted changes and untracked files** inside them — along with branches, herdr workspaces, and notes.

The primary clone for each worktree is discovered from the worktree itself (`git rev-parse --git-common-dir`), so no `SRC_ROOT` is needed and it stays portable. It only deletes **local** branches — remote branches are untouched.

## Azure sync (`az-watcher`)

`az-watcher/` is a headless driver that keeps local worktrees in step with Azure DevOps pull requests, by calling the same two scripts you drive by hand:

* **A PR is assigned to you for review** → creates a **review** worktree for that PR's repo + source branch (`make-worktree.sh review`, non-interactively).
* **A PR you created or reviewed is completed/abandoned** → removes that repo's worktree, local branch and notes (`worktree-remove.sh`, single-repo), and drops the story folder once no worktrees remain in it.

The story folder comes from the PR source branch when its last segment looks like `{id}-{slug}` (`.../22831-order-entry-fctg-forms` → `22831-order-entry-fctg-forms`), otherwise from the linked work item id + title. Azure repo names map to clone directories by turning spaces into underscores (`FCTG Monorepo` → `FCTG_Monorepo`). Every outcome — created, cleaned up, skipped, failed — arrives as a `herdr notification` as well as a log line.

**prefix+down** → **Sync Azure Reviews** runs it once in a visible tab. It is built for `*/5 * * * *` cron: stateless, idempotent, `flock`-guarded, and it keeps (never deletes) worktrees with uncommitted changes.

`az` is **not** installed by `install.sh`. Set it up once, then dry-run before trusting it:

```bash
az login
az devops configure -d organization=https://dev.azure.com/<org> project='<project>'
az-watcher run --dry-run --window 0
```

Full details, cron line, and limitations: [`az-watcher/README.md`](az-watcher/README.md).

## Dry run (home, three repos)

Goal: confirm notes + three worktrees are created under `[worktrees].directory` with per-repo claude/cursor/bash tabs.

1. Finish **Installation set-up**, set `SRC_ROOT` in `worktree-make.sh`, and set `[worktrees].directory` in `config.toml`.
2. Clone (or place) three git repos under `SRC_ROOT`, e.g.:
   * `$SRC_ROOT/repo-a`
   * `$SRC_ROOT/repo-b`
   * `$SRC_ROOT/repo-c`
3. Ensure each has a remote `origin` and a default branch herdr can base from.
4. In herdr: **prefix+down** → **New Dev Worktree**
5. Enter a test id/slug (e.g. `99999` / `dry-run`) and repos `repo-a,repo-b,repo-c`
6. Expect (with `directory = "~/source/worktrees"` → `$HOME/source/worktrees`):
   * Story dir: `$HOME/source/worktrees/development/99999-dry-run/`
   * Per-repo notes **inside** the story dir: `99999-dry-run-repo-a.txt`, `99999-dry-run-repo-b.txt`, `99999-dry-run-repo-c.txt`
   * `.notespath-repo-a` (etc.) inside the story dir, each pointing at that repo's notes file
   * Worktrees: `repo-a/`, `repo-b/`, `repo-c/` on branch `feature/aaron/99999-dry-run`
   * Each worktree workspace opens with tabs `notes-99999-dry-run` (micro on that repo's notes file), `{repo} claude` (running `claude`), `{repo} cursor` (running `agent`), and `{repo} bash` — all at the worktree root

Cleanup after the dry run (from each primary clone): `git worktree list` then `git worktree remove <path>` as needed, and delete the story folder/notes under `[worktrees].directory`.
