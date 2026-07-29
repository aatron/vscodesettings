# Herdr set-up (Windows)

Native Windows PowerShell port of the WSL Herdr + herdr-plus workflow for
multi-repo story worktrees (dev and review). Bash source of truth lives in
[`wsl/herdr/`](../../wsl/herdr/).

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

## Worktree tabs

Wildcard layout (`repo = "*"`) opens notes / claude / cursor / pwsh. On create,
`worktree-make.ps1` owns labels and starts commands via `herdr pane run`.

| Tab | Renamed to | Command |
|-----|------------|---------|
| notes | `notes-{id}-{slug}` | `micro <notes path>` |
| claude | `{repo} claude` | `claude --permission-mode auto` |
| cursor | `{repo} cursor` | `agent --auto-review` |
| pwsh | `{repo} pwsh` | bare PowerShell |

**`development-windows`:** closes claude/cursor; keeps notes + `{repo} pwsh`
(native-Windows analogue of the WSL path that opened `wt.exe` tabs).

## Daily use

* **prefix+down** → **New Dev Worktree** / **New Dev Worktree (Windows)** /
  **New Review Worktree** / **Delete Story Worktree** / **Sync Azure Reviews**
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
4. Expect story under `<worktrees.directory>\development\<id>-<slug>\` with
   notes + worktrees + tabs as above.

Non-interactive (if test repos exist):

```powershell
$env:WT_ID='99999'; $env:WT_SLUG='dry-run'; $env:WT_REPOS='repo-a,repo-b'
& "$env:USERPROFILE\bin\make-worktree.ps1" development
```

Cleanup: `git worktree remove` from each primary clone, then delete the story
folder under `[worktrees].directory`.
