#!/usr/bin/env bash
#
# make-worktree.sh
# Create a multi-repo herdr worktree structure for an Azure DevOps story.
# Two modes: development and review.
#
# Tabs are NOT created here. They are driven declaratively by herdr-plus
# Worktree Auto-Layout (worktree-layout.toml, installed as repo = "*").
# This script only creates worktrees + sidecar files.
#
# Git behavior on create:
#   development -> fetch origin, then create the new branch
#                  feature/aaron/<id>-<slug> from the LATEST default branch
#                  (origin/<default>), checked out in the worktree.
#   review      -> fetch origin, then check out each existing linked branch
#                  at its latest remote state.
#
# Folder structure produced (no feature/aaron prefix on the path):
#   $WORKTREE_ROOT/<type>/
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
SRC_ROOT="$HOME/src"                # where your primary repo clones live
WORKTREE_ROOT="$HOME/worktrees"     # base dir; <type>/... is created under it
BRANCH_PREFIX="feature/aaron"       # branch name only: feature/aaron/<id>-<slug>

# ===========================================================================
# VERIFY ONCE AGAINST YOUR herdr BUILD
#   - `herdr worktree create --path` accepts a nested, not-yet-existing path.
#   - `herdr worktree create --base <ref>` accepts a remote ref like
#     "origin/main" as the new branch's start point.
# ===========================================================================

TYPE="${1:-}"
[[ "$TYPE" == "development" || "$TYPE" == "review" ]] || {
  echo "usage: $0 <development|review>" >&2; exit 1; }

exec </dev/tty            # quick-action stdin is /dev/null; talk to the terminal

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need herdr; need git; need gum

ask() { gum input --prompt "$1 > " --placeholder "$2"; }

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
  local repo="$1" branch="$2" src="${SRC_ROOT}/${repo}"
  [[ -d "$src/.git" || -f "$src/.git" ]] || {
    echo "missing clone: $src (set SRC_ROOT or clone the repo there)" >&2; exit 1; }
  git -C "$src" fetch --prune origin
  local def; def="$(default_branch "$src")"
  herdr worktree create --cwd "$src" --branch "$branch" --base "origin/${def}" \
      --path "${STORY_DIR}/${repo}" --label "$repo" --no-focus
}

# review: check out an existing branch at its latest remote state.
make_worktree_existing() {
  local repo="$1" branch="$2" src="${SRC_ROOT}/${repo}"
  [[ -d "$src/.git" || -f "$src/.git" ]] || {
    echo "missing clone: $src (set SRC_ROOT or clone the repo there)" >&2; exit 1; }
  git -C "$src" fetch --prune origin
  herdr worktree create --cwd "$src" --branch "$branch" --base "origin/${branch}" \
      --path "${STORY_DIR}/${repo}" --label "$repo" --no-focus
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
