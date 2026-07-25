# Herdr set-up

Shared WSL Herdr + herdr-plus workflow for multi-repo story worktrees (dev and review).

## Installation set-up

Run this first — it installs `herdr` and the other CLIs, and creates a default `config.toml` when one does not exist yet.

On each machine (home and work), clone this repo in WSL, then:

```
cd /path/to/vscodesettings/wsl/herdr
chmod +x install.sh worktree-make.sh claude-statusline.sh
./install.sh
```

`install.sh` will (**idempotent**; never overwrites an existing `config.toml`):

1. Install CLIs if missing: [herdr](https://herdr.dev/) (≥ 0.7.5), `gum`, `git`, `micro`, `jq`, `claude`, `agent`; ensure `~/bin` and `~/.local/bin` are on `PATH`
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
7. Claude Code native status line for 5h / 7d (`~/.claude/statusline-rate-limits.sh` + `settings.json` merge; skips if you already have a custom `statusLine`)

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
| Claude Code status line (bottom of the Claude pane) | Native Claude footer (installed by `install.sh` — unrelated to Herdr) |

On demand inside Claude: `/usage` shows the full plan windows without a persistent footer.

#### Claude Code status line (native — applied by `install.sh`)

Claude Code has no built-in “always show 5h/7d” toggle. The idiomatic footer is a `statusLine` command that reads session JSON from stdin (including native `rate_limits`). Docs: [Customize your status line](https://code.claude.com/docs/en/statusline).

`install.sh` does this automatically and idempotently (re-runs are safe):

1. Installs `jq` (apt) if missing.
2. Copies `claude-statusline.sh` → `~/.claude/statusline-rate-limits.sh` (refreshes when the source changes).
3. Merges into `~/.claude/settings.json`:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "/home/<you>/.claude/statusline-rate-limits.sh"
     }
   }
   ```

   - Creates `settings.json` if missing.
   - Adds `statusLine` when absent.
   - Refreshes the command when it already points at the managed script.
   - **Leaves a custom `statusLine.command` unchanged** (prints a note; chain the managed script yourself if you want both).

Pro/Max only; `rate_limits` appear after the first API reply in a session. Send a message (or resume) so the footer updates; `/status` confirms settings loaded. Independent of Herdr Agent Usage (sidebar / limits pane / toasts).

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
   # named session example:
   herdr --session three-repo-test server reload-config
   ```

   On herdr ≥ 0.7.5, installed plugins are global across sessions. After upgrading from 0.7.4, restart named sessions so they pick up the shared plugin registry (`herdr session stop <name>` then `herdr --session <name>`).
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

Goal: confirm notes + three worktrees are created under `[worktrees].directory` with the four tabs above.

1. Finish **Installation set-up**, set `SRC_ROOT` in `worktree-make.sh`, and set `[worktrees].directory` in `config.toml`.
2. Clone (or place) three git repos under `SRC_ROOT`, e.g.:
   * `$SRC_ROOT/repo-a`
   * `$SRC_ROOT/repo-b`
   * `$SRC_ROOT/repo-c`
3. Ensure each has a remote `origin` and a default branch herdr can base from.
4. In herdr: **prefix+down** → **New Dev Worktree**
5. Enter a test id/slug (e.g. `99999` / `dry-run`) and repos `repo-a,repo-b,repo-c`
6. Expect (with `directory = "~/source/worktrees"` → `$HOME/source/worktrees`):
   * Notes: `$HOME/source/worktrees/development/99999_dry-run.txt`
   * Story dir: `$HOME/source/worktrees/development/99999_dry-run/`
   * `.notespath` pointing at the notes file
   * Worktrees: `repo-a/`, `repo-b/`, `repo-c/` on branch `feature/aaron/99999-dry-run`
   * Each worktree workspace opens with notes / Claude1 / cursor / terminal

Cleanup after the dry run (from each primary clone): `git worktree list` then `git worktree remove <path>` as needed, and delete the story folder/notes under `[worktrees].directory`.
