# Herdr set-up

> **⚠️ IMPORTANT:** See the `Repo set-up` section for what is needed for each repo

## Init

Create config file

```
herdr --default-config > ~/.config/herdr/config.toml
micro ~/.config/herdr/config.toml
```

## Herdr settings

Set these settings in the newly created config file

```
[theme]
# Built-in themes: catppuccin, terminal, tokyo-night, dracula, nord,
#                  gruvbox, one-dark, solarized, kanagawa, rose-pine,
#                  vesper
name = "solarized"
```

```
[keys]
# Move between tabs
previous_tab = "ctrl+alt+left"
next_tab     = "ctrl+alt+right"
# Move between workspaces
previous_workspace = "ctrl+alt+up"
next_workspace     = "ctrl+alt+down"
```

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

```
[theme.custom]
overlay0 = "#93a1a1" # Lighten secondary text
```

## Apply settings

```
herdr server reload-config
```

### Settings menu

* `toasts`
    * popups - system notification
* `integrations`
    * Install agent interactions

## Plugins:

* herdr plus
    * `curl -fsSL https://raw.githubusercontent.com/cloudmanic/herdr-plus/main/install.sh | sh`

## Repo set-up

For each repo, need to create a toml file. See `repo-a.toml` as an example.
