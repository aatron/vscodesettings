#!/usr/bin/env bash
#
# make-worktree.sh
# Create a multi-repo herdr worktree structure for an Azure DevOps story.
# Two modes: development and review.
#
# Tabs come from herdr-plus Worktree Auto-Layout (worktree-layout.toml,
# repo = "*"): notes, then "claude" + "bash" at each worktree root. After
# create, this script renames claude/bash to "{repo} claude" / "{repo} bash"
# (layouts cannot interpolate the repo name). Also creates worktrees + sidecars.
#
# Git behavior on create:
#   development -> fetch origin, then create the new branch
#                  feature/aaron/<id>-<slug> from the LATEST default branch
#                  (origin/<default>), checked out in the worktree.
#   review      -> fetch origin, then check out each existing linked branch
#                  at its latest remote state.
#
# Folder structure produced (no feature/aaron prefix on the path):
#   <herdr [worktrees].directory>/<type>/
#       <id>_<slug>.txt              <- notes (sibling of the story folder)
#       <id>_<slug>/
#           .notespath               <- absolute path to the notes file
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

# ===========================================================================
# VERIFY ONCE AGAINST YOUR herdr BUILD
#   - `herdr worktree create --path` accepts a nested, not-yet-existing path.
#   - `herdr worktree create --base <ref>` accepts a remote ref like
#     "origin/main" as the new branch's start point.
# ===========================================================================

TYPE="${1:-}"
[[ "$TYPE" == "development" || "$TYPE" == "review" ]] || {
  echo "usage: $0 <development|review>" >&2; exit 1; }

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

# Wait for worktree auto-layout (notes + claude + bash), then rename
# claude/bash to "{repo} …". Notes keeps its layout name.
label_repo_tabs() {
  local ws="$1" repo="$2"
  local deadline=$((SECONDS + 20))
  local notes_tab="" claude_tab="" bash_tab="" json
  while (( SECONDS < deadline )); do
    json="$(herdr tab list --workspace "$ws" 2>/dev/null || true)"
    notes_tab="$(jq -r --arg ws "$ws" \
      '.result.tabs[]? | select(.workspace_id==$ws and .label=="notes") | .tab_id' \
      <<<"$json" | head -n1)"
    claude_tab="$(jq -r --arg ws "$ws" \
      '.result.tabs[]? | select(.workspace_id==$ws and .label=="claude") | .tab_id' \
      <<<"$json" | head -n1)"
    bash_tab="$(jq -r --arg ws "$ws" \
      '.result.tabs[]? | select(.workspace_id==$ws and .label=="bash") | .tab_id' \
      <<<"$json" | head -n1)"
    if [[ -n "$notes_tab" && -n "$claude_tab" && -n "$bash_tab" ]]; then
      herdr tab rename "$claude_tab" "${repo} claude"
      herdr tab rename "$bash_tab" "${repo} bash"
      return 0
    fi
    sleep 0.2
  done
  echo "WARNING: timed out waiting for notes/claude/bash tabs in workspace ${ws}" >&2
  return 1
}

ask() { gum input --prompt "$1 > " --placeholder "$2"; }

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

WORKTREE_ROOT="$(resolve_worktree_root)"
echo "-> worktree root (from herdr [worktrees].directory): ${WORKTREE_ROOT}"

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
  label_repo_tabs "$ws" "$repo" || true
}

# review: check out an existing branch at its latest remote state.
make_worktree_existing() {
  local repo="$1" branch="$2" src="${SRC_ROOT}/${repo}" out ws
  [[ -d "$src/.git" || -f "$src/.git" ]] || {
    echo "missing clone: $src (set SRC_ROOT or clone the repo there)" >&2; exit 1; }
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
TYPE_DIR="${WORKTREE_ROOT}/${TYPE}"         # .../<type>   (no feature/aaron prefix)
STORY_DIR="${TYPE_DIR}/${ID}_${SLUG}"       # parent of the repo worktrees
NOTES_FILE="${TYPE_DIR}/${ID}_${SLUG}.txt"  # sibling of STORY_DIR

mkdir -p "$STORY_DIR"
: > "$NOTES_FILE"
echo "$NOTES_FILE" > "${STORY_DIR}/.notespath"    # the notes tab reads this
echo "-> notes:  $NOTES_FILE"
echo "-> story:  $STORY_DIR"
echo "-> branch: $BRANCH"

# ===========================================================================
# DEVELOPMENT
# ===========================================================================
if [[ "$TYPE" == "development" ]]; then
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
