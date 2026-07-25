# Herdr set-up

Shared WSL Herdr + herdr-plus workflow for multi-repo story worktrees (dev and review).

## Installation set-up

Run this first — it installs `herdr` and the other CLIs, and creates a default `config.toml` when one does not exist yet.

On each machine (home and work), clone this repo in WSL, then:

```
cd /path/to/vscodesettings/wsl/herdr
chmod +x install.sh worktree-make.sh
./install.sh
```

`install.sh` will (**never overwrites an existing `config.toml`**):

1. Install CLIs if missing: [herdr](https://herdr.dev/) (≥ 0.7.4), `gum`, `git`, `micro`, `claude`, `agent`; ensure `~/bin` and `~/.local/bin` are on `PATH`
2. If `~/.config/herdr/config.toml` is missing, create it with the documented default:
   `herdr --default-config > ~/.config/herdr/config.toml`
3. Install plugins:
   * `cloudmanic/herdr-plus` — Projects, quick actions, worktree auto-layout
   * `senna-lang/herdr-agent-usage` — Context meters + provider rate limits
4. Symlink `worktree-make.sh` → `~/bin/make-worktree.sh`
5. Copy quick actions into herdr-plus `quick-actions/`:
   * `new-worktree-dev.toml` → **New Dev Worktree**
   * `new-worktree-review.toml` → **New Review Worktree**
6. Copy `worktree-layout.toml` into herdr-plus `worktrees/` (wildcard layout for every repo)

Then edit machine-local paths at the top of `worktree-make.sh`:

* `SRC_ROOT` — primary clones (`$HOME/src/<repo>`)
* `WORKTREE_ROOT` — story worktrees base
* `BRANCH_PREFIX` — e.g. `feature/aaron`

## Herdr settings (manual `config.toml`)

`install.sh` only writes a default `config.toml` when the file is missing; it never merges the snippets below. Edit by hand:

```
micro ~/.config/herdr/config.toml
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

### Agent Usage sidebar (Herdr 0.7.4+)

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
| Claude Code status line (bottom of the Claude pane) | Optional; also feeds the plugin’s Claude utilization cache for better 5h/7d + toasts |

#### Claude Code `statusLine` (manual — Claude settings, not Herdr `config.toml`)

Resolve the plugin root (`herdr plugin list`) and add this to Claude Code settings (usually `~/.claude/settings.json`). Prefer chaining if you already have a `statusLine` command; `usagebar.setup` also prints a ready-to-paste path:

```
{
  "statusLine": {
    "type": "command",
    "command": "bash /path/to/herdr-agent-usage/bin/run-statusline.sh"
  }
}
```

Replace `/path/to/herdr-agent-usage` with the plugin root from `herdr plugin list`.

## Apply settings

1. Seed Agent Usage (resolves/builds the `usagebar` binary; prints paste snippets; does not rewrite herdr `config.toml`):

   ```
   herdr plugin action invoke usagebar.setup
   ```

   Paste any sidebar / toast / key snippets it prints if you have not already added them.
2. Add the Claude Code `statusLine` block above if you want 5h / 7d cache + toasts.
3. Reload Herdr after any `config.toml` edit:

   ```
   herdr server reload-config
   ```
4. Optional: install agent integrations from the Settings menu or CLI for better session matching.

### Settings menu

* `toasts`
    * popups - system notification
* `integrations`
    * Install agent interactions (recommended for Agent Usage session matching)

## Worktree tabs (no per-repo toml required)

Tabs come from **one** herdr-plus Worktree Auto-Layout file with `repo = "*"`. You do **not** need a toml per repository unless you want a repo-specific override.

Layout applied to every created worktree:

| Tab | What it runs |
|-----|----------------|
| notes | `micro` on the story notes file (via `../.notespath`) |
| Claude1 | `claude` at the worktree root |
| cursor | `agent` (Cursor Agent CLI) at the worktree root |
| terminal | bare shell at the worktree root |

## Daily use

* **prefix+down** → **New Dev Worktree** or **New Review Worktree**
* Dev prompts: story id, slug, comma-separated repo names
* Review uses a placeholder branch list until Azure wiring is added at work
* **ctrl+shift+u** → Agent Usage limits pane (if you added the keybind)

## Dry run (home, three repos)

Goal: confirm notes + three worktrees are created under `WORKTREE_ROOT` with the four tabs above.

1. Finish **Installation set-up** and set `SRC_ROOT` / `WORKTREE_ROOT`.
2. Clone (or place) three git repos under `SRC_ROOT`, e.g.:
   * `$SRC_ROOT/repo-a`
   * `$SRC_ROOT/repo-b`
   * `$SRC_ROOT/repo-c`
3. Ensure each has a remote `origin` and a default branch herdr can base from.
4. In herdr: **prefix+down** → **New Dev Worktree**
5. Enter a test id/slug (e.g. `99999` / `dry-run`) and repos `repo-a,repo-b,repo-c`
6. Expect:
   * Notes: `$WORKTREE_ROOT/development/99999_dry-run.txt`
   * Story dir: `$WORKTREE_ROOT/development/99999_dry-run/`
   * `.notespath` pointing at the notes file
   * Worktrees: `repo-a/`, `repo-b/`, `repo-c/` on branch `feature/aaron/99999-dry-run`
   * Each worktree workspace opens with notes / Claude1 / cursor / terminal

Cleanup after the dry run (from each primary clone): `git worktree list` then `git worktree remove <path>` as needed, and delete the story folder/notes under `WORKTREE_ROOT`.
