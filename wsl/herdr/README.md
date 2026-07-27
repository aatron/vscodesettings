# Herdr set-up

Shared WSL Herdr + herdr-plus workflow for multi-repo story worktrees (dev and review).

## Installation set-up

Run this first — it installs `herdr` and the other CLIs, and creates a default `config.toml` when one does not exist yet.

On each machine (home and work), clone this repo in WSL, then:

```
cd /path/to/vscodesettings/wsl/herdr
./install.sh
```

`install.sh` will (**idempotent**; never overwrites an existing `config.toml`):

1. Install CLIs if missing: [herdr](https://herdr.dev/) (≥ 0.7.5), `gum`, `git`, `micro`, `jq`, `claude`, `agent`; ensure `~/bin` and `~/.local/bin` are on `PATH`
2. If `~/.config/herdr/config.toml` is missing, create it with the documented default:
   `herdr --default-config > ~/.config/herdr/config.toml`
3. Install plugins:
   * `cloudmanic/herdr-plus` — Projects, quick actions, worktree auto-layout
   * `senna-lang/herdr-agent-usage` — Context meters + provider rate limits
4. Symlink `worktree-make.sh` → `~/bin/make-worktree.sh` and `worktree-launch.sh` → `~/bin/worktree-launch.sh`
5. Copy quick actions into herdr-plus `quick-actions/`:
   * `new-worktree-dev.toml` → **New Dev Worktree** (opens a tab, then runs the script)
   * `new-worktree-dev-windows.toml` → **New Dev Worktree (Windows)** (worktrees under the Windows `/mnt/c` path)
   * `new-worktree-review.toml` → **New Review Worktree**
   * `remove-worktree.toml` → **Delete Story Worktree** (removes a story's worktrees, branches, and notes)
6. Copy `worktree-layout.toml` into herdr-plus `worktrees/` (wildcard layout for every repo)

Then edit machine-local values at the top of `worktree-make.sh`:

* `SRC_ROOT` — primary clones (`$HOME/source/repos/<repo>`)
* `BRANCH_PREFIX` — e.g. `feature/aaron`
* `WINDOWS_WORKTREE_ROOT` — **optional**; `development-windows` root. Leave empty to auto-derive `<WindowsUserProfile>/source/worktrees` (the Windows user profile is detected at runtime, so this is **portable across machines** — no username is hardcoded). Set only to override.
* `WIN_POWERSHELL` — **optional**; the shell for the `development-windows` Windows tabs. Leave empty to auto-pick `pwsh.exe` (PowerShell 7) if present, else `powershell.exe`.

Story worktrees use Herdr’s `[worktrees].directory` from `config.toml` (see below), except `development-windows`, which uses `WINDOWS_WORKTREE_ROOT`. Do not set a separate `WORKTREE_ROOT` in the script.

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
```

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

### Agent panel / pane labels (under `[ui]`, not sidebar)

These belong on the top-level `[ui]` table. Putting them under `[ui.sidebar.agents]` makes herdr warn `config.toml has unknown keys` (`herdr config check`).

```
[ui]
agent_panel_sort = "spaces"                 # or "priority"
show_agent_labels_on_pane_borders = true
sidebar_start_collapsed = false             # keep the story sidebar visible — it IS the worktree navigation
```

### Story navigation on the left-hand panel

The left sidebar **is** the story navigation — herdr has no plugin API for a custom
sidebar, but each repo worktree is created as a workspace labeled `{id}_{slug}/{repo}`, and
the `workspace` row token renders that label. Because the labels share the `{id}_{slug}`
prefix and sort together, the sidebar naturally groups every repo under its story. Keep it
visible (`sidebar_start_collapsed = false`) and use it to jump between worktrees; the built-in
`previous_workspace` / `next_workspace` keys (see below) move within it.

```
[ui.sidebar.spaces]
rows = [["state_icon", "workspace"], ["branch", "git_status"]]
```

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

Layout applied to every created/opened worktree (at that repo's worktree root):

| Tab (layout name) | What it runs |
|-------------------|--------------|
| notes | `micro` on that repo's notes file `<id>-<slug>-<repo>.txt` (via `../.notespath-<repo>`) |
| claude | `claude` |
| cursor | `agent` (Cursor Agent CLI) |
| bash | bare shell |

On **create** via `make-worktree.sh`, the claude/cursor/bash tabs are renamed to `{repo-name} claude`, `{repo-name} cursor`, and `{repo-name} bash` (herdr-plus layouts cannot interpolate the repo name). Notes stays `notes`. Re-opening an existing worktree keeps the layout names `notes` / `claude` / `cursor` / `bash`.

**`development-windows` exception:** for that type the script instead **closes** the claude and cursor tabs (leaving `notes` + `{repo-name} bash` in herdr) and opens a **native Windows PowerShell** tab per repo in Windows Terminal — titled `{id}-{slug}-{repo}`, started in the repo's `C:\...` path — where you run Claude/Cursor on the Windows side. Requires Windows Terminal (`wt.exe`) and native-Windows tooling; the WSL copies of claude/cursor are not used there.

## Daily use

* **Navigate** between story worktrees from the left sidebar (grouped by `{id}_{slug}`), or with `previous_workspace` / `next_workspace`
* **prefix+down** → **New Dev Worktree**, **New Dev Worktree (Windows)**, or **New Review Worktree**
* That opens a new tab and runs `make-worktree.sh` there (herdr-plus overlays cannot host interactive `gum` prompts)
* Dev prompts: story id, slug, comma-separated repo names
* **New Dev Worktree (Windows)**: same prompts as Dev, but worktrees are created under `WINDOWS_WORKTREE_ROOT` (`<WindowsUserProfile>/source/worktrees/development/…`); herdr shows only `notes` + `{repo} bash`, and a native Windows PowerShell tab `{id}-{slug}-{repo}` opens per repo. Prereqs: Windows Terminal + Claude/Cursor installed natively on Windows.
* Review uses a placeholder branch list until Azure wiring is added at work
* **prefix+down** → **Delete Story Worktree** to tear a story down (see below)
* **ctrl+shift+u** → Agent Usage limits pane (if you added the keybind)

## Delete a story

**prefix+down** → **Delete Story Worktree** opens a tab and runs `worktree-remove.sh`. Enter the story `id` and `slug`; it finds the story under all three layouts it can live in — `<[worktrees].directory>/development`, `<[worktrees].directory>/review`, and `<WindowsUserProfile>/source/worktrees/development` — and, after a `gum` confirmation, for the whole story:

* closes each repo's herdr workspace (if open),
* runs `git worktree remove --force` on each repo worktree,
* deletes each worktree's **local** git branch (never the repo's default branch; a detached HEAD is skipped),
* deletes every per-repo notes file `<id>-<slug>-<repo>.txt` and removes the story folder.

The primary clone for each worktree is discovered from the worktree itself (`git rev-parse --git-common-dir`), so no `SRC_ROOT` is needed and it stays portable. It only deletes **local** branches — remote branches are untouched.

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
   * Story dir: `$HOME/source/worktrees/development/99999_dry-run/`
   * Per-repo notes (siblings of the story dir): `99999-dry-run-repo-a.txt`, `99999-dry-run-repo-b.txt`, `99999-dry-run-repo-c.txt`
   * `.notespath-repo-a` (etc.) inside the story dir, each pointing at that repo's notes file
   * Worktrees: `repo-a/`, `repo-b/`, `repo-c/` on branch `feature/aaron/99999-dry-run`
   * Each worktree workspace opens with tabs `notes`, `{repo} claude`, `{repo} cursor`, and `{repo} bash`

### Dry run — `development-windows`

Same as above but **prefix+down** → **New Dev Worktree (Windows)**. Expect (root auto-derived; no `WINDOWS_WORKTREE_ROOT` needed):

* Notes + story dir under `<WindowsUserProfile>/source/worktrees/development/99999_dry-run/` (i.e. a `/mnt/c/Users/<you>/…` path)
* Worktrees `repo-a/`, `repo-b/`, `repo-c/` on branch `feature/aaron/99999-dry-run`
* Each herdr workspace opens with **only** `notes` + `{repo} bash`
* One **native Windows PowerShell** tab per repo in Windows Terminal, titled `99999-dry-run-repo-a` (etc.), started in the repo's `C:\Users\<you>\…` path

Cleanup after the dry run (from each primary clone): `git worktree list` then `git worktree remove <path>` as needed, and delete the story folder/notes under `[worktrees].directory` (and under `WINDOWS_WORKTREE_ROOT` for the Windows variant).
