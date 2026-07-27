#!/usr/bin/env bash
#
# make-worktree.sh
# Create a multi-repo herdr worktree structure for an Azure DevOps story.
# Three types: development, development-windows, and review.
#
# Tabs come from herdr-plus Worktree Auto-Layout (worktree-layout.toml,
# repo = "*"): notes, claude, cursor, bash at each worktree root. After create:
#   development / review   -> rename claude/cursor/bash to
#                             "{repo} claude" / "{repo} cursor" / "{repo} bash"
#                             (layouts cannot interpolate the repo name).
#   development-windows     -> close the claude/cursor tabs (leaving notes +
#                             "{repo} bash") and open a native Windows PowerShell
#                             tab per repo via wt.exe, titled {id}-{slug}-{repo}.
# Also creates worktrees + sidecars.
#
# Git behavior on create:
#   development / development-windows
#               -> fetch origin, then create the new branch
#                  feature/aaron/<id>-<slug> from the LATEST default branch
#                  (origin/<default>), checked out in the worktree. These two
#                  types differ ONLY in the worktree root (below) and tabs.
#   review      -> fetch origin, then check out each existing linked branch
#                  at its latest remote state.
#
# Folder structure produced (no feature/aaron prefix on the path):
#   <herdr [worktrees].directory>/<type>/
#       <id>-<slug>-<repo>.txt       <- per-repo notes (sibling of the story folder)
#       <id>_<slug>/
#           .notespath-<repo>        <- absolute path to that repo's notes file
#           <repo>/                  <- git worktree
#           <repo>/ ...
#
set -euo pipefail

# ===========================================================================
# EDIT THESE FOR YOUR MACHINE
# ===========================================================================
SRC_ROOT="$HOME/source/repos"       # where your primary repo clones live
BRANCH_PREFIX="feature/aaron"       # branch name only: feature/aaron/<id>-<slug>
# Story worktree base comes from Herdr config [worktrees].directory
# (this workflow uses ~/source/worktrees). Set that in ~/.config/herdr/config.toml.
#
# Optional overrides for the development-windows type. Leave BOTH empty to
# auto-derive — this keeps the script portable across machines (no hardcoded
# username; the Windows user profile is discovered at runtime).
WINDOWS_WORKTREE_ROOT=""             # empty => <WindowsUserProfile>/source/worktrees
WIN_POWERSHELL=""                    # empty => pwsh.exe if present, else powershell.exe

# ===========================================================================
# VERIFY ONCE AGAINST YOUR herdr BUILD
#   - `herdr worktree create --path` accepts a nested, not-yet-existing path.
#   - `herdr worktree create --base <ref>` accepts a remote ref like
#     "origin/main" as the new branch's start point.
# ===========================================================================

TYPE="${1:-}"
[[ "$TYPE" == "development" || "$TYPE" == "development-windows" || "$TYPE" == "review" ]] || {
  echo "usage: $0 <development|development-windows|review>" >&2; exit 1; }

# herdr-plus quick actions run with stdin = /dev/null. Prefer duplicating the
# pane PTY from stdout (fd 1); fall back to the controlling tty.
if [[ ! -t 0 ]]; then
  if [[ -t 1 ]]; then
    exec <&1
  elif [[ -r /dev/tty ]]; then
    exec </dev/tty
  else
    echo "no tty available for prompts (run from a herdr pane or terminal)" >&2
    exit 1
  fi
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need herdr; need git; need gum; need jq

# Look up a layout tab's id by its label within a workspace.
tab_id_by_label() {
  local json="$1" ws="$2" label="$3"
  jq -r --arg ws "$ws" --arg label "$label" \
    '.result.tabs[]? | select(.workspace_id==$ws and .label==$label) | .tab_id' \
    <<<"$json" | head -n1
}

# Wait for worktree auto-layout (notes + claude + cursor + bash), then rename
# claude/cursor/bash to "{repo} …". Notes keeps its layout name.
# Used for development and review.
label_repo_tabs() {
  local ws="$1" repo="$2"
  local deadline=$((SECONDS + 20))
  local notes_tab="" claude_tab="" cursor_tab="" bash_tab="" json
  while (( SECONDS < deadline )); do
    json="$(herdr tab list --workspace "$ws" 2>/dev/null || true)"
    notes_tab="$(tab_id_by_label "$json" "$ws" notes)"
    claude_tab="$(tab_id_by_label "$json" "$ws" claude)"
    cursor_tab="$(tab_id_by_label "$json" "$ws" cursor)"
    bash_tab="$(tab_id_by_label "$json" "$ws" bash)"
    if [[ -n "$notes_tab" && -n "$claude_tab" && -n "$cursor_tab" && -n "$bash_tab" ]]; then
      herdr tab rename "$claude_tab" "${repo} claude"
      herdr tab rename "$cursor_tab" "${repo} cursor"
      herdr tab rename "$bash_tab" "${repo} bash"
      return 0
    fi
    sleep 0.2
  done
  echo "WARNING: timed out waiting for notes/claude/cursor/bash tabs in workspace ${ws}" >&2
  return 1
}

# Open a native Windows PowerShell tab in Windows Terminal for a repo worktree.
# Title: {id}-{slug}-{repo}; starting dir: the worktree's Windows (C:\...) path.
open_windows_terminal() {
  local repo="$1" winpath
  winpath="$(wslpath -w "${STORY_DIR}/${repo}")"
  wt.exe -w 0 new-tab --title "${ID}-${SLUG}-${repo}" \
    --startingDirectory "$winpath" "$WIN_POWERSHELL" 2>/dev/null \
    || "$WIN_POWERSHELL" -NoProfile -Command \
         "wt -w 0 new-tab --title '${ID}-${SLUG}-${repo}' -d '${winpath}' ${WIN_POWERSHELL}" 2>/dev/null \
    || echo "WARNING: could not open Windows Terminal tab for ${repo} (is Windows Terminal installed?)" >&2
}

# development-windows: wait for the auto-layout tabs, close claude+cursor
# (Claude/Cursor run natively on Windows instead), keep notes + "{repo} bash",
# then open the native Windows PowerShell tab.
windows_repo_tabs() {
  local ws="$1" repo="$2"
  local deadline=$((SECONDS + 20))
  local notes_tab="" claude_tab="" cursor_tab="" bash_tab="" json
  while (( SECONDS < deadline )); do
    json="$(herdr tab list --workspace "$ws" 2>/dev/null || true)"
    notes_tab="$(tab_id_by_label "$json" "$ws" notes)"
    claude_tab="$(tab_id_by_label "$json" "$ws" claude)"
    cursor_tab="$(tab_id_by_label "$json" "$ws" cursor)"
    bash_tab="$(tab_id_by_label "$json" "$ws" bash)"
    if [[ -n "$notes_tab" && -n "$claude_tab" && -n "$cursor_tab" && -n "$bash_tab" ]]; then
      herdr tab close "$claude_tab"
      herdr tab close "$cursor_tab"
      herdr tab rename "$bash_tab" "${repo} bash"
      open_windows_terminal "$repo"
      return 0
    fi
    sleep 0.2
  done
  echo "WARNING: timed out waiting for notes/claude/cursor/bash tabs in workspace ${ws}" >&2
  open_windows_terminal "$repo"   # still open the Windows tab
  return 1
}

ask() { gum input --prompt "$1 > " --placeholder "$2"; }

# Per-repo notes file: <TYPE_DIR>/<id>-<slug>-<repo>.txt (sibling of STORY_DIR).
# Each worktree's notes tab opens its own file via a per-repo sidecar written in
# STORY_DIR (kept out of the git worktree so it never dirties the repo). The
# layout's notes tab reads "../.notespath-<repo>" (repo = worktree dir name).
write_repo_notes() {
  local repo="$1" notes="${TYPE_DIR}/${ID}-${SLUG}-${repo}.txt"
  [[ -e "$notes" ]] || : > "$notes"
  printf '%s\n' "$notes" > "${STORY_DIR}/.notespath-${repo}"
  echo "-> notes:  $notes"
}

# Resolve story root from Herdr [worktrees].directory (see herdr.dev/docs/configuration).
# Falls back to Herdr's documented default when unset.
resolve_worktree_root() {
  local cfg="${HERDR_CONFIG_PATH:-${HOME}/.config/herdr/config.toml}"
  local dir=""
  if [[ -f "$cfg" ]]; then
    dir="$(awk '
      /^\[worktrees\]/ { in_section = 1; next }
      /^\[/ { in_section = 0 }
      in_section && $0 ~ /^[[:space:]]*directory[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, "")
        sub(/[[:space:]]+#.*$/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        gsub(/^["'\'']|["'\'']$/, "")
        print
        exit
      }
    ' "$cfg")"
  fi
  [[ -z "$dir" ]] && dir="~/source/worktrees"
  # Escape ~ in ${var#pat}: an unescaped ~/ in the pattern is tilde-expanded to
  # $HOME/, so "${dir#~/}" would not strip a literal "~/..." prefix.
  case "$dir" in
    "~/"*) dir="${HOME}/${dir#\~/}" ;;
    "~")   dir="${HOME}" ;;
  esac
  dir="${dir//\$HOME/$HOME}"
  dir="${dir//\$\{HOME\}/$HOME}"
  printf '%s\n' "$dir"
}

# Resolve the development-windows story root as a WSL path under the Windows
# user profile. Portable: no hardcoded username — USERPROFILE is discovered at
# runtime via Windows PowerShell, then mapped to a /mnt/c/... path.
resolve_windows_root() {
  if [[ -n "$WINDOWS_WORKTREE_ROOT" ]]; then
    printf '%s\n' "$WINDOWS_WORKTREE_ROOT"; return
  fi
  local up
  up="$(powershell.exe -NoProfile -NonInteractive \
          -Command "[Environment]::GetFolderPath('UserProfile')" 2>/dev/null | tr -d '\r')"
  [[ -n "$up" ]] || { echo "cannot resolve Windows user profile from WSL" >&2; return 1; }
  printf '%s/source/worktrees\n' "$(wslpath -u "$up")"
}

# Pick the worktree root + type subfolder. development-windows lives under the
# Windows (/mnt/c) user path so Windows-native tooling can open the files; it
# still uses the "development" subfolder and the development git flow.
if [[ "$TYPE" == "development-windows" ]]; then
  WORKTREE_ROOT="$(resolve_windows_root)"
  SUBFOLDER="development"
  echo "-> worktree root (Windows user path): ${WORKTREE_ROOT}"
  # Native Windows PowerShell for the per-repo tabs (auto-pick if unset).
  if [[ -z "$WIN_POWERSHELL" ]]; then
    if command -v pwsh.exe >/dev/null 2>&1; then WIN_POWERSHELL="pwsh.exe"; else WIN_POWERSHELL="powershell.exe"; fi
  fi
else
  WORKTREE_ROOT="$(resolve_worktree_root)"
  SUBFOLDER="$TYPE"
  echo "-> worktree root (from herdr [worktrees].directory): ${WORKTREE_ROOT}"
fi

# Resolve a repo's default branch (main/master/...), locally if possible.
default_branch() {
  local src="$1" d
  d="$(git -C "$src" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  d="${d#origin/}"
  if [[ -z "$d" ]]; then
    d="$(git -C "$src" ls-remote --symref origin HEAD 2>/dev/null \
         | awk '/^ref:/{sub("refs/heads/","",$2); print $2; exit}')"
  fi
  echo "${d:-main}"
}

# development: new branch from the latest default branch.
make_worktree_new() {
  local repo="$1" branch="$2" src="${SRC_ROOT}/${repo}" out ws
  [[ -d "$src/.git" || -f "$src/.git" ]] || {
    echo "missing clone: $src (set SRC_ROOT or clone the repo there)" >&2; exit 1; }
  write_repo_notes "$repo"
  git -C "$src" fetch --prune origin
  local def; def="$(default_branch "$src")"
  out="$(herdr worktree create --cwd "$src" --branch "$branch" --base "origin/${def}" \
      --path "${STORY_DIR}/${repo}" --label "${ID}_${SLUG}/${repo}" --no-focus)"
  ws="$(jq -r '.result.workspace.workspace_id // empty' <<<"$out")"
  [[ -n "$ws" ]] || {
    echo "herdr worktree create failed for ${repo}:" >&2
    echo "$out" >&2
    exit 1
  }
  if [[ "$TYPE" == "development-windows" ]]; then
    windows_repo_tabs "$ws" "$repo" || true
  else
    label_repo_tabs "$ws" "$repo" || true
  fi
}

# review: check out an existing branch at its latest remote state.
make_worktree_existing() {
  local repo="$1" branch="$2" src="${SRC_ROOT}/${repo}" out ws
  [[ -d "$src/.git" || -f "$src/.git" ]] || {
    echo "missing clone: $src (set SRC_ROOT or clone the repo there)" >&2; exit 1; }
  write_repo_notes "$repo"
  git -C "$src" fetch --prune origin
  out="$(herdr worktree create --cwd "$src" --branch "$branch" --base "origin/${branch}" \
      --path "${STORY_DIR}/${repo}" --label "${ID}_${SLUG}/${repo}" --no-focus)"
  ws="$(jq -r '.result.workspace.workspace_id // empty' <<<"$out")"
  [[ -n "$ws" ]] || {
    echo "herdr worktree create failed for ${repo}:" >&2
    echo "$out" >&2
    exit 1
  }
  label_repo_tabs "$ws" "$repo" || true
}

# --- shared inputs ---------------------------------------------------------
ID="$(ask 'Story id' '12345')"
SLUG="$(ask 'Slug' 'slug-example')"
[[ -n "$ID" && -n "$SLUG" ]] || { echo "id and slug required" >&2; exit 1; }

BRANCH="${BRANCH_PREFIX}/${ID}-${SLUG}"     # feature/aaron/<id>-<slug> (hyphen)
TYPE_DIR="${WORKTREE_ROOT}/${SUBFOLDER}"    # .../<subfolder>  (no feature/aaron prefix)
STORY_DIR="${TYPE_DIR}/${ID}_${SLUG}"       # parent of the repo worktrees
# Per-repo notes files (<id>-<slug>-<repo>.txt) are created per worktree by
# write_repo_notes(), called from make_worktree_new/existing.

mkdir -p "$STORY_DIR"
echo "-> story:  $STORY_DIR"
echo "-> branch: $BRANCH"

# ===========================================================================
# DEVELOPMENT
# ===========================================================================
if [[ "$TYPE" == "development" || "$TYPE" == "development-windows" ]]; then
  REPOS="$(ask 'Repos (csv)' 'repo-a,repo-b,repo-c')"
  [[ -n "$REPOS" ]] || { echo "repos required" >&2; exit 1; }

  # ----- AZURE PLACEHOLDER (development) -----------------------------------
  # At WORK, you can replace prompts / fetch story text via az boards here.
  # -------------------------------------------------------------------------

  IFS=',' read -ra LIST <<< "$REPOS"
  for repo in "${LIST[@]}"; do
    repo="$(echo "$repo" | xargs)"; [[ -n "$repo" ]] || continue
    make_worktree_new "$repo" "$BRANCH"
  done
  echo "OK development ready at ${STORY_DIR}"
fi

# ===========================================================================
# REVIEW
# ===========================================================================
if [[ "$TYPE" == "review" ]]; then
  BRANCHES="${STORY_DIR}/branches-${ID}.txt"

  # ----- AZURE PLACEHOLDER (review) ----------------------------------------
  # At WORK, replace this block with a real az call that lists the branches
  # linked to the story, one "<repo>:<branch>" per line, into $BRANCHES.
  # Linked branches are vstfs:///Git/Ref artifact links in the work item's
  # relations, so expand relations and decode them. Sketch (needs jq):
  #
  #   az boards work-item show --id "$ID" --expand relations -o json \
  #     | jq -r '.relations[] | select(.rel=="ArtifactLink" and
  #              (.url|startswith("vstfs:///Git/Ref"))) | .url' \
  #     | while read -r u; do decode_vstfs_git_ref "$u"; done > "$BRANCHES"
  #
  cat > "$BRANCHES" <<EOF
repo-a:feature/aaron/${ID}-${SLUG}
repo-b:bugfix/${ID}-example
repo-c:feature/aaron/${ID}-${SLUG}
EOF
  echo "WARNING placeholder branches in ${BRANCHES} -- replace with az output at work."
  # -------------------------------------------------------------------------

  # One worktree per linked branch. Line format: <repo>:<branch>
  # NOTE: if one repo has several linked branches, give each a distinct --path
  # (e.g. append the branch slug) so they don't collide on ${STORY_DIR}/${repo}.
  while IFS=':' read -r repo branch; do
    repo="$(echo "$repo" | xargs)"; branch="$(echo "$branch" | xargs)"
    [[ -n "$repo" && -n "$branch" ]] || continue
    make_worktree_existing "$repo" "$branch"
  done < "$BRANCHES"
  echo "OK review ready at ${STORY_DIR}"
fi
