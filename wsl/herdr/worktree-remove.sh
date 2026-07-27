#!/usr/bin/env bash
#
# worktree-remove.sh
# Delete an entire story by id: for every repo worktree in each matching story
# folder it
#   1. closes the herdr workspace (if present),
#   2. removes the git worktree, and
#   3. deletes the local git branch that worktree was on,
# then deletes every per-repo notes file and the story folder.
#
# Input: story id only (arg $1, or WT_ID, or gum prompt). Slug is read from
# on-disk folder names matching {id}_* under:
#   <herdr [worktrees].directory>/development/<id>_*/   (development)
#   <herdr [worktrees].directory>/review/<id>_*/        (review)
#   <WindowsUserProfile-or-override>/source/worktrees/development/<id>_*/
#                                                            (development-windows)
#
# Nothing machine-specific is hardcoded (Windows user profile is derived at
# runtime). Primary clones are discovered from each worktree, so SRC_ROOT is
# not needed here. Destructive — asks for confirmation first (unless
# WT_ASSUME_YES=1).
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

# Candidate story dirs: every {id}_* under the three layouts (dedup).
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
  for d in "$base"/"${ID}"_*/; do
    [[ -d "$d" ]] || continue
    add_candidate "${d%/}"
  done
}
add_glob "${HERDR_ROOT}/development"
add_glob "${HERDR_ROOT}/review"
[[ -n "$WIN_ROOT" ]] && add_glob "${WIN_ROOT}/development"

if (( ${#CANDIDATES[@]} == 0 )); then
  echo "No story folder matching ${ID}_* under:"
  echo "  ${HERDR_ROOT}/development|review"
  [[ -n "$WIN_ROOT" ]] && echo "  ${WIN_ROOT}/development"
  exit 0
fi

# Find the herdr workspace id for a worktree by its checkout path, if any.
# Matching on the path (not the label) is robust: worktree labels are now just
# "<id>_<slug>" and repeat across repos, so they can't identify a single workspace.
workspace_id_for_path() {
  local path="$1"
  herdr workspace list 2>/dev/null \
    | jq -r --arg p "$path" '.result.workspaces[]? | select(.worktree.checkout_path==$p) | .workspace_id' \
    | head -n1
}

# --- plan (gather + show, then confirm) ------------------------------------
declare -a PLAN=()          # human-readable lines
declare -a WT_DIRS=() WT_REPOS=() WT_BRANCHES=() WT_PRIMARIES=() WT_WS=()

for story_dir in "${CANDIDATES[@]}"; do
  story_name="${story_dir##*/}"
  slug="${story_name#"${ID}"_}"
  PLAN+=("story ${story_name}:")
  for wt in "$story_dir"/*/; do
    wt="${wt%/}"
    [[ -e "$wt/.git" ]] || continue
    repo="${wt##*/}"
    branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
    # The main working tree is the first entry of `git worktree list`.
    primary="$( { git -C "$wt" worktree list --porcelain 2>/dev/null \
                  | awk '/^worktree /{print $2; exit}'; } || true )"
    ws="$(workspace_id_for_path "$wt" || true)"
    WT_DIRS+=("$wt"); WT_REPOS+=("$repo"); WT_BRANCHES+=("$branch")
    WT_PRIMARIES+=("$primary"); WT_WS+=("$ws")
    PLAN+=("  worktree ${wt}")
    PLAN+=("    branch  ${branch:-<detached>} (in ${primary:-<unknown clone>})")
    [[ -n "$ws" ]] && PLAN+=("    herdr   close workspace ${ws}")
  done
  # notes files live one level up (sibling of the story folder)
  type_dir="${story_dir%/*}"
  for nf in "${type_dir}/${ID}-${slug}-"*.txt; do
    [[ -e "$nf" ]] && PLAN+=("  notes    ${nf}")
  done
  PLAN+=("  folder   ${story_dir}")
done

echo "About to DELETE story id ${ID} (${#CANDIDATES[@]} folder(s)):"
printf '%s\n' "${PLAN[@]}"
echo
if [[ "${WT_ASSUME_YES:-}" == "1" ]]; then
  echo "WT_ASSUME_YES=1 — skipping confirmation"
else
  gum confirm "Delete all of the above? This cannot be undone." || { echo "aborted."; exit 0; }
fi

# --- execute ---------------------------------------------------------------
for i in "${!WT_DIRS[@]}"; do
  wt="${WT_DIRS[$i]}"; repo="${WT_REPOS[$i]}"; branch="${WT_BRANCHES[$i]}"
  primary="${WT_PRIMARIES[$i]}"; ws="${WT_WS[$i]}"

  [[ -n "$ws" ]] && { herdr workspace close "$ws" >/dev/null 2>&1 || \
    echo "  warn: could not close herdr workspace ${ws}" >&2; }

  if [[ -n "$primary" ]]; then
    git -C "$primary" worktree remove --force "$wt" \
      || { echo "  warn: git worktree remove failed for ${wt}; forcing rm" >&2; rm -rf "$wt"; }
    if [[ -n "$branch" && "$branch" != "HEAD" && "$branch" != "$(default_branch "$primary")" ]]; then
      git -C "$primary" branch -D "$branch" \
        || echo "  warn: could not delete branch ${branch} in ${primary}" >&2
    else
      echo "  skip: not deleting branch '${branch:-<detached>}' (empty/detached/default)"
    fi
  else
    echo "  warn: no primary clone for ${wt}; removing dir only" >&2
    rm -rf "$wt"
  fi
done

# Delete per-repo notes files and the story folders.
for story_dir in "${CANDIDATES[@]}"; do
  story_name="${story_dir##*/}"
  slug="${story_name#"${ID}"_}"
  type_dir="${story_dir%/*}"
  rm -f "${type_dir}/${ID}-${slug}-"*.txt
  # Safety: only rm -rf a path whose basename is {id}_*
  if [[ -n "$story_dir" && "$story_name" == "${ID}_"* ]]; then
    rm -rf "$story_dir"
  fi
done

echo "OK deleted story id ${ID}."
