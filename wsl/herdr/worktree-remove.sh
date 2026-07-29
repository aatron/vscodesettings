#!/usr/bin/env bash
#
# worktree-remove.sh
# Delete an entire story by id: for every repo worktree in each matching story
# folder it
#   1. removes the worktree through herdr (`herdr worktree remove --force`),
#      which closes the workspace, deletes the checkout, AND drops the entry
#      from herdr's registry/sidebar (a plain `workspace close` leaves the
#      worktree listed),
#   2. falls back to `git worktree remove --force` (then rm -rf) when herd
#      is not running or did not remove the directory, and
#   3. deletes the local git branch that worktree was on,
# then deletes every per-repo notes file and the story folder.
#
# Input: story id only (arg $1, or WT_ID, or gum prompt). Slug is read from
# on-disk folder names matching {id}-* (current naming) or {id}_* (folders made
# before the rename) under:
#   <herdr [worktrees].directory>/development/<id>-*/   (development)
#   <herdr [worktrees].directory>/review/<id>-*/        (review)
#   <WindowsUserProfile-or-override>/source/worktrees/development/<id>-*/
#                                                            (development-windows)
# Per-repo notes files now live inside the story folder; the old location (a
# sibling of the story folder, under the type dir) is still cleaned up.
#
# Nothing machine-specific is hardcoded (Windows user profile is derived at
# runtime). Primary clones are discovered from each worktree, so SRC_ROOT is
# not needed here. Destructive — asks for confirmation first (unless
# WT_ASSUME_YES=1).
#
# Environment hooks (used by az-watcher; all optional):
#   WT_ID           story id (same as $1) — skips the prompt
#   WT_ASSUME_YES   1 = skip the gum confirmation (no tty needed)
#   WT_REPO         operate on ONLY this repo's worktree inside the story
#                   folder(s): its worktree, local branch and notes file. Othe
#                   repos are left alone; the story folder is deleted only once
#                   no worktrees remain in it. Unset = whole story.
#   WT_SKIP_DIRTY   1 = refuse to delete a worktree with uncommitted o
#                   untracked changes (leave it, and keep its story folder).
#                   Off by default: an explicit manual removal already warns.
#
# Exit codes:
#   0  something was removed
#   3  nothing to do (no matching story folder / no matching repo worktree)
#   5  nothing removed because every match was dirty (WT_SKIP_DIRTY=1)
#
set -euo pipefail

# Optional override; leave empty to auto-derive (keep in sync with
# worktree-make.sh — only matters if you overrode WINDOWS_WORKTREE_ROOT there).
WINDOWS_WORKTREE_ROOT=""

# herdr-plus quick actions run with stdin = /dev/null. Prefer the pane PTY from
# stdout (fd 1); fall back to the controlling tty. Skip when non-interactive.
if [[ "${WT_ASSUME_YES:-}" != "1" && ! -t 0 ]]; then
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
need herdr; need git; need jq
if [[ "${WT_ASSUME_YES:-}" != "1" ]]; then
  need gum
fi

ask() { gum input --prompt "$1 > " --placeholder "$2"; }

# Resolve story root from Herdr [worktrees].directory (mirrors worktree-make.sh).
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
  case "$dir" in
    "~/"*) dir="${HOME}/${dir#\~/}" ;;
    "~")   dir="${HOME}" ;;
  esac
  dir="${dir//\$HOME/$HOME}"
  dir="${dir//\$\{HOME\}/$HOME}"
  printf '%s\n' "$dir"
}

# Resolve the development-windows root (mirrors worktree-make.sh; portable).
resolve_windows_root() {
  if [[ -n "$WINDOWS_WORKTREE_ROOT" ]]; then
    printf '%s\n' "$WINDOWS_WORKTREE_ROOT"; return
  fi
  local up
  up="$(powershell.exe -NoProfile -NonInteractive \
          -Command "[Environment]::GetFolderPath('UserProfile')" 2>/dev/null | tr -d '\r')"
  [[ -n "$up" ]] || return 1
  printf '%s/source/worktrees\n' "$(wslpath -u "$up")"
}

# Default branch of a clone (never deleted).
default_branch() {
  local src="$1" d
  d="$(git -C "$src" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  d="${d#origin/}"
  echo "${d:-main}"
}

# --- inputs ----------------------------------------------------------------
# Prefer CLI arg, then WT_ID (quick action / automation), else prompt.
ID="${1:-${WT_ID:-}}"
if [[ -z "$ID" ]]; then
  ID="$(ask 'Story id' '12345')"
fi
[[ -n "$ID" ]] || { echo "story id required" >&2; exit 1; }

# Candidate story dirs: every {id}-* (and legacy {id}_*) under the three layouts (dedup).
HERDR_ROOT="$(resolve_worktree_root)"
WIN_ROOT="$(resolve_windows_root 2>/dev/null || true)"

declare -a CANDIDATES=()
add_candidate() {
  local d="$1" c
  [[ -d "$d" ]] || return 0
  for c in "${CANDIDATES[@]:-}"; do [[ "$c" == "$d" ]] && return 0; done
  CANDIDATES+=("$d")
}
add_glob() {
  local base="$1" d
  [[ -d "$base" ]] || return 0
  # {id}-<slug> is the current naming; {id}_<slug> is the pre-rename layout.
  for d in "$base"/"${ID}"-*/ "$base"/"${ID}"_*/; do
    [[ -d "$d" ]] || continue
    add_candidate "${d%/}"
  done
}
add_glob "${HERDR_ROOT}/development"
add_glob "${HERDR_ROOT}/review"
[[ -n "$WIN_ROOT" ]] && add_glob "${WIN_ROOT}/development"

if (( ${#CANDIDATES[@]} == 0 )); then
  echo "No story folder matching ${ID}-* under:"
  echo "  ${HERDR_ROOT}/development|review"
  [[ -n "$WIN_ROOT" ]] && echo "  ${WIN_ROOT}/development"
  exit 3
fi

# Story folder name -> slug (accepts the current "{id}-{slug}" and the olde
# "{id}_{slug}" folders).
slug_from_story_name() {
  local s="${1#"${ID}"}"
  printf '%s\n' "${s#[-_]}"
}

# Find the herdr workspace id for a worktree by its checkout path, if any.
# Matching on the path (not the label) is robust: worktree labels are now just
# "<id>-<slug>" and repeat across repos, so they can't identify a single workspace.
workspace_id_for_path() {
  local path="$1"
  herdr workspace list 2>/dev/null \
    | jq -r --arg p "$path" '.result.workspaces[]? | select(.worktree.checkout_path==$p) | .workspace_id' \
    | head -n1
}

# True when a worktree has uncommitted or untracked changes.
worktree_dirty() {
  local wt="$1"
  [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]
}

# --- plan (gather + show, then confirm) ------------------------------------
declare -a PLAN=()          # human-readable lines
declare -a WT_DIRS=() WT_REPO_NAMES=() WT_BRANCHES=() WT_PRIMARIES=() WT_WS=()
declare -a WT_STORY_DIRS=() WT_SLUGS=()
DIRTY_SKIPPED=0

for story_dir in "${CANDIDATES[@]}"; do
  story_name="${story_dir##*/}"
  slug="$(slug_from_story_name "$story_name")"
  PLAN+=("story ${story_name}:")
  for wt in "$story_dir"/*/; do
    wt="${wt%/}"
    [[ -e "$wt/.git" ]] || continue
    repo="${wt##*/}"
    # Single-repo mode: every other repo in this story is left untouched.
    if [[ -n "${WT_REPO:-}" && "$repo" != "${WT_REPO}" ]]; then
      PLAN+=("  keep     ${wt} (not ${WT_REPO})")
      continue
    fi
    if [[ "${WT_SKIP_DIRTY:-}" == "1" ]] && worktree_dirty "$wt"; then
      PLAN+=("  KEEP     ${wt} (uncommitted/untracked changes)")
      DIRTY_SKIPPED=$((DIRTY_SKIPPED + 1))
      continue
    fi
    branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
    # The main working tree is the first entry of `git worktree list`.
    primary="$( { git -C "$wt" worktree list --porcelain 2>/dev/null \
                  | awk '/^worktree /{print $2; exit}'; } || true )"
    ws="$(workspace_id_for_path "$wt" || true)"
    WT_DIRS+=("$wt"); WT_REPO_NAMES+=("$repo"); WT_BRANCHES+=("$branch")
    WT_PRIMARIES+=("$primary"); WT_WS+=("$ws")
    WT_STORY_DIRS+=("$story_dir"); WT_SLUGS+=("$slug")
    PLAN+=("  worktree ${wt}")
    PLAN+=("    branch  ${branch:-<detached>} (in ${primary:-<unknown clone>})")
    PLAN+=("    notes   ${story_dir}/${ID}-${slug}-${repo}.txt")
    [[ -n "$ws" ]] && PLAN+=("    herdr   remove worktree + workspace ${ws}")
  done
  if [[ -z "${WT_REPO:-}" ]]; then
    # Whole-story mode also clears notes left in the pre-rename location.
    type_dir="${story_dir%/*}"
    for nf in "${type_dir}/${ID}-${slug}-"*.txt; do
      [[ -e "$nf" ]] && PLAN+=("  notes    ${nf}")
    done
  fi
  PLAN+=("  folder   ${story_dir} (only once no worktrees remain in it)")
done

# Nothing this invocation can act on: report "nothing to do" instead of falling
# through to the folder cleanup, so overlapping cron runs stay silent.
if (( ${#WT_DIRS[@]} == 0 )); then
  printf '%s\n' "${PLAN[@]}"
  if (( DIRTY_SKIPPED > 0 )); then
    echo "Nothing removed for story ${ID}: ${DIRTY_SKIPPED} worktree(s) have uncommitted changes."
    exit 5
  fi
  echo "Nothing to remove for story ${ID}${WT_REPO:+ (repo ${WT_REPO})}."
  exit 3
fi

echo "About to DELETE story id ${ID}${WT_REPO:+, repo ${WT_REPO} only} (${#CANDIDATES[@]} folder(s)):"
printf '%s\n' "${PLAN[@]}"
echo
echo "WARNING: this deletes the worktree directories themselves — including any"
echo "uncommitted changes and untracked files inside them — plus their local"
echo "branches, herdr workspaces, and notes files."
echo
if [[ "${WT_ASSUME_YES:-}" == "1" ]]; then
  echo "WT_ASSUME_YES=1 — skipping confirmation"
else
  gum confirm "Delete all worktrees and files listed above? This cannot be undone." \
    || { echo "aborted."; exit 0; }
fi

# --- execute ---------------------------------------------------------------
for i in "${!WT_DIRS[@]}"; do
  wt="${WT_DIRS[$i]}"; repo="${WT_REPO_NAMES[$i]}"; branch="${WT_BRANCHES[$i]}"
  primary="${WT_PRIMARIES[$i]}"; ws="${WT_WS[$i]}"
  story_dir="${WT_STORY_DIRS[$i]}"; slug="${WT_SLUGS[$i]}"

  # Remove through herdr first: `worktree remove` closes the workspace, deletes
  # the checkout, and unregisters it (so it disappears from the sidebar).
  # `workspace close` alone leaves the worktree registered — that is why deleted
  # stories kept showing up.
  if [[ -n "$ws" ]]; then
    herdr worktree remove --workspace "$ws" --force >/dev/null 2>&1 \
      || { echo "  warn: herdr worktree remove failed for workspace ${ws}; closing it" >&2
           herdr workspace close "$ws" >/dev/null 2>&1 || true; }
  fi

  # Belt-and-braces: make sure the git worktree itself is gone (herdr not
  # running, removal failed, or no workspace was found for this path).
  if [[ -e "$wt" ]]; then
    if [[ -n "$primary" ]]; then
      git -C "$primary" worktree remove --force "$wt" \
        || { echo "  warn: git worktree remove failed for ${wt}; forcing rm" >&2; rm -rf "$wt"; }
    else
      echo "  warn: no primary clone for ${wt}; removing dir only" >&2
      rm -rf "$wt"
    fi
  fi

  if [[ -n "$primary" ]]; then
    # Clear any stale worktree registration left after an rm -rf fallback.
    git -C "$primary" worktree prune >/dev/null 2>&1 || true
    if [[ -n "$branch" && "$branch" != "HEAD" && "$branch" != "$(default_branch "$primary")" ]]; then
      git -C "$primary" branch -D "$branch" \
        || echo "  warn: could not delete branch ${branch} in ${primary}" >&2
    else
      echo "  skip: not deleting branch '${branch:-<detached>}' (empty/detached/default)"
    fi
  fi

  # That repo's notes file + notespath sidecar. Whole-story removals delete the
  # folder below anyway, but doing it here is what makes single-repo mode leave
  # the story folder correct for the repos that are still there.
  rm -f "${story_dir}/${ID}-${slug}-${repo}.txt" "${story_dir}/.notespath-${repo}"
done

# True when any repo worktree is still checked out inside a story folder.
story_has_worktrees() {
  local story_dir="$1" d
  for d in "$story_dir"/*/; do
    [[ -e "${d}.git" ]] && return 0
  done
  return 1
}

# Delete the story folder only once it holds no worktrees. This is what makes
# single-repo removals (and WT_SKIP_DIRTY keeps) safe: the folder survives until
# the last repo goes, and then it and its leftover notes/sidecars go with it.
for story_dir in "${CANDIDATES[@]}"; do
  story_name="${story_dir##*/}"
  slug="$(slug_from_story_name "$story_name")"
  type_dir="${story_dir%/*}"
  if story_has_worktrees "$story_dir"; then
    echo "-> keeping ${story_dir} (worktrees still present)"
    continue
  fi
  # In-folder notes go with the story folder below; this clears the old location.
  rm -f "${type_dir}/${ID}-${slug}-"*.txt
  # Safety: only rm -rf a path whose basename is {id}-* or {id}_*
  if [[ -n "$story_dir" && ( "$story_name" == "${ID}-"* || "$story_name" == "${ID}_"* ) ]]; then
    rm -rf "$story_dir"
    echo "-> removed folder ${story_dir}"
  fi
done

if (( DIRTY_SKIPPED > 0 )); then
  echo "OK removed ${#WT_DIRS[@]} worktree(s) for story ${ID}; kept ${DIRTY_SKIPPED} with uncommitted changes."
else
  echo "OK removed ${#WT_DIRS[@]} worktree(s) for story ${ID}${WT_REPO:+ (repo ${WT_REPO})}."
fi
