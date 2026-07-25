#!/usr/bin/env bash
#
# install.sh — wire this folder's Herdr worktree workflow into the local machine.
# Run from WSL. Safe to re-run (idempotent).
#
# What it does (never overwrites an existing ~/.config/herdr/config.toml):
#   1. Installs CLI prerequisites: herdr, gum, git, micro, jq, claude, agent
#   2. Creates default config.toml if missing (herdr --default-config)
#   3. Installs herdr plugins (herdr-plus, herdr-agent-usage)
#   4. Symlinks worktree-make.sh -> ~/bin/make-worktree.sh
#      and worktree-launch.sh -> ~/bin/worktree-launch.sh
#   5. Installs quick-action TOMLs (dev + review) into herdr-plus
#   6. Installs the wildcard worktree auto-layout (repo = "*")
#   7. Claude Code native statusLine for 5h/7d (managed script + settings merge)
#
# Manual config.toml edits are listed at the end and in README.md.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/bin"
LOCAL_BIN="${HOME}/.local/bin"
TARGET_SCRIPT="${BIN_DIR}/make-worktree.sh"
TARGET_LAUNCH="${BIN_DIR}/worktree-launch.sh"
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_STATUSLINE_SCRIPT="${CLAUDE_DIR}/statusline-rate-limits.sh"
CLAUDE_SETTINGS="${CLAUDE_DIR}/settings.json"

have() { command -v "$1" >/dev/null 2>&1; }

ensure_path_dirs() {
  mkdir -p "$BIN_DIR" "$LOCAL_BIN"
  export PATH="${BIN_DIR}:${LOCAL_BIN}:${PATH}"

  local line='export PATH="$HOME/bin:$HOME/.local/bin:$PATH"'
  local rc="${HOME}/.bashrc"
  if [[ -f "$rc" ]] && ! grep -qF '$HOME/bin:$HOME/.local/bin' "$rc" 2>/dev/null; then
    {
      echo ""
      echo "# herdr workflow (added by wsl/herdr/install.sh)"
      echo "$line"
    } >> "$rc"
    echo "-> PATH: appended ~/bin and ~/.local/bin to ${rc}"
  fi
}

# Compare dotted versions: true if $1 >= $2 (numeric segments only).
version_ge() {
  local a="$1" b="$2"
  local IFS=.
  # shellcheck disable=SC2206
  local -a aa=($a) bb=($b)
  local i n="${#aa[@]}"
  (( ${#bb[@]} > n )) && n="${#bb[@]}"
  for ((i = 0; i < n; i++)); do
    local x="${aa[i]:-0}" y="${bb[i]:-0}"
    x="${x%%[^0-9]*}" y="${y%%[^0-9]*}"
    ((10#${x:-0} > 10#${y:-0})) && return 0
    ((10#${x:-0} < 10#${y:-0})) && return 1
  done
  return 0
}

ensure_apt_pkgs() {
  local pkgs=() p
  for p in "$@"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
      pkgs+=("$p")
    fi
  done
  if ((${#pkgs[@]} == 0)); then
    echo "-> apt: already present ($*)"
    return
  fi
  echo "-> apt: installing ${pkgs[*]}"
  sudo apt-get update -y
  sudo apt-get install -y "${pkgs[@]}"
}

ensure_herdr() {
  local ver=""
  if have herdr; then
    ver="$(herdr --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
    if [[ -n "$ver" ]] && version_ge "$ver" "0.7.5"; then
      echo "-> herdr: ${ver} (>= 0.7.5)"
      return
    fi
    echo "-> herdr: found ${ver:-unknown}, need >= 0.7.5 — upgrading"
  else
    echo "-> herdr: not found — installing"
  fi
  curl -fsSL https://herdr.dev/install.sh | sh
  hash -r 2>/dev/null || true
  export PATH="${BIN_DIR}:${LOCAL_BIN}:${PATH}"
  have herdr || { echo "herdr install finished but 'herdr' is not on PATH" >&2; exit 1; }
  ver="$(herdr --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
  echo "-> herdr: ${ver:-installed}"
}

# Official default: https://herdr.dev/docs/configuration/
#   herdr --default-config > ~/.config/herdr/config.toml
# Only create when missing — never overwrite an existing file.
ensure_herdr_config() {
  local cfg="${HERDR_CONFIG_PATH:-${HOME}/.config/herdr/config.toml}"
  if [[ -f "$cfg" ]]; then
    echo "-> config: exists (left unchanged): ${cfg}"
    return
  fi
  mkdir -p "$(dirname "$cfg")"
  herdr --default-config > "$cfg"
  echo "-> config: created default at ${cfg}"
}

ensure_gum() {
  if have gum; then
    echo "-> gum: $(command -v gum)"
    return
  fi
  echo "-> gum: installing from GitHub Releases into ${BIN_DIR}"
  local arch uname_m tag ver asset url tmp gum_bin
  uname_m="$(uname -m)"
  case "$uname_m" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "unsupported arch for gum: $uname_m" >&2; exit 1 ;;
  esac
  tag="$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest \
    | grep -oE '"tag_name":[[:space:]]*"v[^"]+"' | head -1 | grep -oE 'v[0-9.]+')"
  ver="${tag#v}"
  [[ -n "$ver" ]] || { echo "could not resolve latest gum version" >&2; exit 1; }
  asset="gum_${ver}_Linux_${arch}.tar.gz"
  url="https://github.com/charmbracelet/gum/releases/download/${tag}/${asset}"
  tmp="$(mktemp -d)"
  curl -fsSL "$url" | tar -xzf - -C "$tmp"
  gum_bin="$(find "$tmp" -type f -name gum | head -1)"
  [[ -n "$gum_bin" ]] || { echo "gum binary missing from ${asset}" >&2; exit 1; }
  install -m 755 "$gum_bin" "${BIN_DIR}/gum"
  rm -rf "$tmp"
  echo "-> gum: ${BIN_DIR}/gum"
}

ensure_claude() {
  if have claude; then
    echo "-> claude: $(command -v claude)"
    return
  fi
  echo "-> claude: installing (Claude Code CLI)"
  curl -fsSL https://claude.ai/install.sh | bash
  hash -r 2>/dev/null || true
  export PATH="${BIN_DIR}:${LOCAL_BIN}:${PATH}"
  have claude || {
    echo "claude install finished but 'claude' is not on PATH (open a new shell or check ~/.local/bin)" >&2
    exit 1
  }
  echo "-> claude: $(command -v claude)"
}

ensure_agent() {
  if have agent; then
    echo "-> agent: $(command -v agent)"
    return
  fi
  echo "-> agent: installing (Cursor Agent CLI)"
  curl -fsS https://cursor.com/install | bash
  hash -r 2>/dev/null || true
  export PATH="${BIN_DIR}:${LOCAL_BIN}:${PATH}"
  have agent || {
    echo "agent install finished but 'agent' is not on PATH (open a new shell or check ~/.local/bin)" >&2
    exit 1
  }
  echo "-> agent: $(command -v agent)"
}

# --- plugins (idempotent; does not touch config.toml) ----------------------
install_plugin() {
  local spec="$1"
  echo "-> plugin: herdr plugin install ${spec}"
  if herdr plugin install --help 2>&1 | grep -q -- '--yes'; then
    herdr plugin install --yes "$spec"
  else
    herdr plugin install "$spec"
  fi
}

install_file() {
  local src="$1" dest="$2"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    echo "-> unchanged: ${dest}"
    return
  fi
  cp "$src" "$dest"
  echo "-> installed: ${dest}"
}

# Claude Code native statusLine for 5h/7d (unrelated to Herdr Agent Usage).
# Idempotent: refreshes managed script; only writes statusLine when missing or
# already pointing at this managed script (never replaces a custom command).
ensure_claude_statusline() {
  local src="${SCRIPT_DIR}/claude-statusline.sh"
  local cmd="${CLAUDE_STATUSLINE_SCRIPT}"
  local current="" tmp

  [[ -f "$src" ]] || { echo "missing ${src}" >&2; exit 1; }
  have jq || { echo "jq is required for Claude statusLine setup" >&2; exit 1; }

  mkdir -p "$CLAUDE_DIR"
  install_file "$src" "$CLAUDE_STATUSLINE_SCRIPT"
  chmod +x "$CLAUDE_STATUSLINE_SCRIPT"

  if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
    jq -n --arg cmd "$cmd" \
      '{statusLine: {type: "command", command: $cmd}}' > "$CLAUDE_SETTINGS"
    echo "-> claude settings: created ${CLAUDE_SETTINGS} with statusLine"
    return
  fi

  if ! jq empty "$CLAUDE_SETTINGS" 2>/dev/null; then
    echo "-> claude settings: invalid JSON at ${CLAUDE_SETTINGS} — left unchanged" >&2
    return
  fi

  current="$(jq -r '.statusLine.command // empty' "$CLAUDE_SETTINGS")"
  if [[ -z "$current" ]]; then
    tmp="$(mktemp)"
    jq --arg cmd "$cmd" \
      '.statusLine = {type: "command", command: $cmd}' \
      "$CLAUDE_SETTINGS" > "$tmp"
    mv "$tmp" "$CLAUDE_SETTINGS"
    echo "-> claude settings: added statusLine -> ${cmd}"
    return
  fi

  case "$current" in
    "$cmd"|"~/.claude/statusline-rate-limits.sh"|"$HOME/.claude/statusline-rate-limits.sh")
      tmp="$(mktemp)"
      jq --arg cmd "$cmd" \
        '.statusLine = {type: "command", command: $cmd}' \
        "$CLAUDE_SETTINGS" > "$tmp"
      if cmp -s "$tmp" "$CLAUDE_SETTINGS"; then
        rm -f "$tmp"
        echo "-> claude settings: statusLine already set -> ${cmd}"
      else
        mv "$tmp" "$CLAUDE_SETTINGS"
        echo "-> claude settings: refreshed statusLine -> ${cmd}"
      fi
      ;;
    *)
      echo "-> claude settings: left existing statusLine unchanged: ${current}"
      echo "   (managed script is at ${cmd}; chain it from your custom statusLine if desired)"
      ;;
  esac
}

# ===========================================================================
echo "=== 1/4 Prerequisites ==="
ensure_path_dirs
ensure_apt_pkgs curl git micro jq
ensure_herdr
ensure_herdr_config
ensure_gum
ensure_claude
ensure_agent

echo
echo "=== 2/4 Herdr plugins ==="
install_plugin "cloudmanic/herdr-plus"
install_plugin "senna-lang/herdr-agent-usage"

PLUGIN_DIR="$(herdr plugin config-dir cloudmanic.herdr-plus)"
QA_DIR="${PLUGIN_DIR}/quick-actions"
LAYOUT_DIR="${PLUGIN_DIR}/worktrees"

echo "herdr-plus config: ${PLUGIN_DIR}"
mkdir -p "$QA_DIR" "$LAYOUT_DIR"

echo
echo "=== 3/4 Worktree workflow files ==="
ln -sfn "${SCRIPT_DIR}/worktree-make.sh" "$TARGET_SCRIPT"
chmod +x "${SCRIPT_DIR}/worktree-make.sh"
echo "-> script:  ${TARGET_SCRIPT} -> ${SCRIPT_DIR}/worktree-make.sh"

ln -sfn "${SCRIPT_DIR}/worktree-launch.sh" "$TARGET_LAUNCH"
chmod +x "${SCRIPT_DIR}/worktree-launch.sh"
echo "-> launch:  ${TARGET_LAUNCH} -> ${SCRIPT_DIR}/worktree-launch.sh"

install_file "${SCRIPT_DIR}/new-worktree-dev.toml"    "${QA_DIR}/new-worktree-dev.toml"
install_file "${SCRIPT_DIR}/new-worktree-review.toml" "${QA_DIR}/new-worktree-review.toml"
install_file "${SCRIPT_DIR}/worktree-layout.toml"     "${LAYOUT_DIR}/worktree-layout.toml"

echo
echo "=== 4/4 Claude Code status line (5h / 7d) ==="
ensure_claude_statusline

echo
echo "=== Automated install finished ==="
echo "  (Existing config.toml is never overwritten; defaults are written only if missing.)"
echo "  (Claude statusLine is managed under ~/.claude/; custom statusLine commands are left alone.)"
echo
echo "Manual next steps — see README.md for full snippets:"
echo "  1. Edit machine paths at the top of:"
echo "       ${SCRIPT_DIR}/worktree-make.sh"
echo "     (SRC_ROOT, BRANCH_PREFIX)"
echo "  2. Merge README Herdr settings into config.toml by hand, including:"
echo "       [worktrees] directory = \"~/source/worktrees\""
echo "       ${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}"
echo "  3. Seed Agent Usage (prints snippets; does not rewrite herdr config.toml):"
echo "       herdr plugin action invoke usagebar.setup"
echo "     Paste any sidebar/toast/key snippets it prints if not already in config."
echo "  4. Optional toast delivery — prefer pasting the README [ui.toast] block"
echo "     instead of usagebar.enable-toast (that command can append to config.toml)."
echo "  5. herdr config check   # fix any unknown keys before continuing"
echo "  6. herdr server reload-config"
echo "     (named sessions: herdr --session <name> server reload-config;"
echo "      bare 'herdr server reload-config' only hits the default session)"
echo "  7. Dry-run: prefix+down -> New Dev Worktree"
echo
echo "If 'claude' or 'agent' is missing in a new terminal, source ~/.bashrc or reopen WSL."
echo "Primary clones must exist under SRC_ROOT/<repo-name>."
echo
herdr plugin list
echo
echo "CLI check:"
for c in herdr gum git micro jq claude agent; do
  printf "  %-8s %s\n" "$c" "$(command -v "$c" 2>/dev/null || echo MISSING)"
done
