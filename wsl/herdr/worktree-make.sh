#!/usr/bin/env bash
#
# make-worktree.sh
# Create a multi-repo herdr worktree structure for an Azure DevOps story.
# Three types: development, development-windows, and review.
#
# Tabs come from herdr-plus Worktree Auto-Layout (worktree-layout.toml,
# repo = "*"): notes, claude, cursor, bash at each worktree root. Layouts cannot
# interpolate the repo/story name, and their tab commands do not reliably start,
# so THIS SCRIPT owns the labels *and* the commands after create. Every command
# is submitted into the tab's pane with `herdr pane run`, cd'd to the worktree
# (repo) root, and skipped if that pane is already running something.
#   development / review    -> notes  -> "notes-{id}-{slug}", runs
#                                        micro <id>-<slug>-<repo>.txt
#                              claude -> "{repo} claude",    runs $CLAUDE_CMD
#                              cursor -> "{repo} cursor",    runs $CURSOR_CMD
#                              bash   -> "{repo} bash",      bare shell
#                              Both agents start in their auto permission mode
#                              (see CLAUDE_CMD / CURSOR_CMD below).
#   development-windows     -> notes as above; close the claude/cursor tabs
#                              (leaving notes + "{repo} bash") and open a native
#                              Windows PowerShell tab per repo via wt.exe,
#                              titled {id}-{slug}-{repo}.
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
#   all types   -> the branch's upstream is pointed at its OWN name on origin
#                  (see set_push_upstream), so a plain `git push` from the
#                  worktree creates/updates origin/<branch> and can neve
#                  target the default branch.
#
# Folder structure produced (no feature/aaron prefix on the path):
#   <herdr [worktrees].directory>/<type>/
#       <id>-<slug>/                 <- story folde
#           <id>-<slug>-<repo>.txt   <- per-repo notes (inside the story folder)
#           .notespath-<repo>        <- absolute path to that repo's notes file
#           <repo>/                  <- git worktree
#           <repo>/ ...
#
# Non-interactive mode (az-watcher / any automation):
#   Set BOTH WT_ID and WT_SLUG and every prompt is skipped — no tty, no gum.
#     WT_ID             story id            (required to enable this mode)
#     WT_SLUG           story slug          (required to enable this mode)
#     WT_REPOS          csv of repos        (development / development-windows)
#     WT_BRANCHES_FILE  file of "<repo>:<branch>" lines (review; replaces the
#                       placeholder branch list)
#   Creating a worktree that already exists is a no-op ("exists, skipping"), and
#   a single repo failing is a warning rather than a fatal error, so re-runs from
#   cron are safe.
#
# Exit codes:
#   0  at least one worktree was created
#   1  bad usage / missing input / nothing could be attempted
#   3  nothing to do — every requested repo already had a worktree
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
#
# Commands the claude/cursor tabs start, both in their "auto" permission mode:
#   claude --permission-mode auto  -> auto-accepts safe work, still asks for the rest
#                                     (other modes: acceptEdits, dontAsk, plan,
#                                      bypassPermissions, manual)
#   agent --auto-review            -> Cursor "Smart Auto": auto-runs safe tool calls,
#                                     prompts for the rest (--force / --yolo runs
#                                     everything unless explicitly denied)
CLAUDE_CMD="claude --permission-mode auto"
CURSOR_CMD="agent --auto-review"

# ===========================================================================
# VERIFY ONCE AGAINST YOUR herdr BUILD
#   - `herdr worktree create --path` accepts a nested, not-yet-existing path.
#   - `herdr worktree create --base <ref>` accepts a remote ref like
#     "origin/main" as the new branch's start point.
# ===========================================================================

TYPE="${1:-}"
[[ "$TYPE" == "development" || "$TYPE" == "development-windows" || "$TYPE" == "review" ]] || {
  echo "usage: $0 <development|development-windows|review>" >&2; exit 1; }

# Non-interactive when the caller supplies both the id and the slug: no tty is
# reattached, gum is never needed, and per-repo failures are non-fatal.
NONINTERACTIVE=0
if [[ -n "${WT_ID:-}" && -n "${WT_SLUG:-}" ]]; then
  NONINTERACTIVE=1
fi

# Counters that decide the exit code (see header): a run that only re-found
# existing worktrees reports 3 so automation can stay quiet about it.
CREATED=0
SKIPPED=0

# herdr-plus quick actions run with stdin = /dev/null. Prefer duplicating the
# pane PTY from stdout (fd 1); fall back to the controlling tty.
if (( ! NONINTERACTIVE )) && [[ ! -t 0 ]]; then
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
(( NONINTERACTIVE )) || need gum

# Look up a layout tab's id by its label within a workspace.
tab_id_by_label() {
  local json="$1" ws="$2" label="$3"
  jq -r --arg ws "$ws" --arg label "$label" \
    '.result.tabs[]? | select(.workspace_id==$ws and .label==$label) | .tab_id' \
    <<<"$json" | head -n1
}

# Root (only) pane of a tab. herdr `tab get` does not report panes, so map
# tab_id -> pane_id through `pane list`.
pane_id_by_tab() {
  local ws="$1" tab="$2"
  herdr pane list --workspace "$ws" 2>/dev/null \
    | jq -r --arg tab "$tab" '.result.panes[]? | select(.tab_id==$tab) | .pane_id' \
    | head -n1
}

# Wait briefly for a pane's shell to come up, then report whether the pane is
# idle (foreground process is just the shell). Non-idle means something already
# started there — e.g. an auto-layout tab command that did fire — so we must not
# submit a second command on top of it.
pane_ready_and_idle() {
  local pane="$1" deadline=$((SECONDS + 5)) names="" n
  while (( SECONDS < deadline )); do
    names="$(herdr pane process-info --pane "$pane" 2>/dev/null \
             | jq -r '.result.process_info.foreground_processes[]?.name' || true)"
    [[ -n "$names" ]] && break
    sleep 0.2
  done
  [[ -n "$names" ]] || return 0        # cannot tell — assume idle and submit
  while read -r n; do
    case "$n" in ""|bash|sh|dash|zsh|fish|"-bash"|"-sh"|"-zsh") ;; *) return 1 ;; esac
  done <<<"$names"
  return 0
}

# Submit a command into a tab's pane, cd'd to the worktree root first so it runs
# at the repo root regardless of where the pane started.
run_in_tab() {
  local ws="$1" tab="$2" dir="$3" cmd="$4" pane
  pane="$(pane_id_by_tab "$ws" "$tab")"
  [[ -n "$pane" ]] || { echo "WARNING: no pane found for tab ${tab}" >&2; return 1; }
  if ! pane_ready_and_idle "$pane"; then
    echo "-> tab ${tab}: pane busy, left as-is"
    return 0
  fi
  herdr pane run "$pane" "cd $(printf '%q' "$dir") && ${cmd}" >/dev/null
}

# Wait for worktree auto-layout (notes + claude + cursor + bash), then label the
# tabs and start their commands at the worktree root.
# Used for development and review.
setup_repo_tabs() {
  local ws="$1" repo="$2"
  local wt="${STORY_DIR}/${repo}" notes; notes="$(repo_notes_path "$repo")"
  local deadline=$((SECONDS + 20))
  local notes_tab="" claude_tab="" cursor_tab="" bash_tab="" json
  while (( SECONDS < deadline )); do
    json="$(herdr tab list --workspace "$ws" 2>/dev/null || true)"
    notes_tab="$(tab_id_by_label "$json" "$ws" notes)"
    claude_tab="$(tab_id_by_label "$json" "$ws" claude)"
    cursor_tab="$(tab_id_by_label "$json" "$ws" cursor)"
    bash_tab="$(tab_id_by_label "$json" "$ws" bash)"
    if [[ -n "$notes_tab" && -n "$claude_tab" && -n "$cursor_tab" && -n "$bash_tab" ]]; then
      herdr tab rename "$notes_tab"  "notes-${ID}-${SLUG}"
      herdr tab rename "$claude_tab" "${repo} claude"
      herdr tab rename "$cursor_tab" "${repo} cursor"
      herdr tab rename "$bash_tab"   "${repo} bash"
      run_in_tab "$ws" "$notes_tab"  "$wt" "micro $(printf '%q' "$notes")" || true
      run_in_tab "$ws" "$claude_tab" "$wt" "$CLAUDE_CMD" || true
      run_in_tab "$ws" "$cursor_tab" "$wt" "$CURSOR_CMD" || true
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

# development-windows: wait for the auto-layout tabs, close claude+curso
# (Claude/Cursor run natively on Windows instead), keep notes + "{repo} bash",
# then open the native Windows PowerShell tab.
windows_repo_tabs() {
  local ws="$1" repo="$2"
  local wt="${STORY_DIR}/${repo}" notes; notes="$(repo_notes_path "$repo")"
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
      herdr tab rename "$notes_tab" "notes-${ID}-${SLUG}"
      herdr tab rename "$bash_tab" "${repo} bash"
      run_in_tab "$ws" "$notes_tab" "$wt" "micro $(printf '%q' "$notes")" || true
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

# A repo-level problem. Fatal when a human is driving (they asked for exactly
# these repos); a warning in non-interactive mode so one bad repo cannot abort a
# cron run that still has other repos to create.
repo_fail() {
  echo "$1" >&2
  (( NONINTERACTIVE )) && return 1
  exit 1
}

# Idempotency: a worktree that is already checked out is left completely alone
# (no fetch, no herdr call, no tab churn). Makes re-runs — manual or every five
# minutes from cron — safe and silent.
worktree_present() {
  local repo="$1"
  if [[ -e "${STORY_DIR}/${repo}/.git" ]]; then
    echo "-> ${repo}: worktree exists at ${STORY_DIR}/${repo}, skipping"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  return 1
}

# Per-repo notes file: <STORY_DIR>/<id>-<slug>-<repo>.txt — inside the story
# folder, next to the repo worktrees but never inside one, so it cannot dirty a
# repo. setup_repo_tabs opens it directly by absolute path; the sideca
# ".notespath-<repo>" is kept so the auto-layout's own notes command (which reads
# "../.notespath-<repo>", repo = worktree dir name) still works on re-open.
repo_notes_path() {
  printf '%s\n' "${STORY_DIR}/${ID}-${SLUG}-${1}.txt"
}

write_repo_notes() {
  local repo="$1" notes; notes="$(repo_notes_path "$repo")"
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

# Point a branch's upstream at its own name on origin. Branching from
# origin/<default> makes git auto-track origin/<default>, so a plain
# `git push` either fails (push.default=simple: "upstream ... does not match
# the name of your current branch") or -- with push.default=upstream -- would
# push straight to the default branch. After this, `git push` from the
# worktree always creates/updates origin/<branch>, never origin/<default>.
# Idempotent, and branch config is per-branch so it cannot affect main.
# (Until the first push, `git pull` on the branch reports "no such ref" --
# expected: the remote branch does not exist yet; `git push` creates it.)
set_push_upstream() {
  local wt="$1" branch="$2"
  git -C "$wt" config "branch.${branch}.remote" origin
  git -C "$wt" config "branch.${branch}.merge" "refs/heads/${branch}"
  echo "-> push:   git push targets origin/${branch}"
}

# development: new branch from the latest default branch.
make_worktree_new() {
  local repo="$1" branch="$2" src="${SRC_ROOT}/${repo}" out ws
  worktree_present "$repo" && return 0
  [[ -d "$src/.git" || -f "$src/.git" ]] || \
    repo_fail "missing clone: $src (set SRC_ROOT or clone the repo there)" || return 1
  write_repo_notes "$repo"
  git -C "$src" fetch --prune origin
  local def; def="$(default_branch "$src")"
  out="$(herdr worktree create --cwd "$src" --branch "$branch" --base "origin/${def}" \
      --path "${STORY_DIR}/${repo}" --label "${ID}-${SLUG}" --no-focus)" || out=""
  ws="$(jq -r '.result.workspace.workspace_id // empty' <<<"$out")"
  [[ -n "$ws" ]] || {
    echo "$out" >&2
    repo_fail "herdr worktree create failed for ${repo}" || return 1
  }
  CREATED=$((CREATED + 1))
  set_push_upstream "${STORY_DIR}/${repo}" "$branch"
  if [[ "$TYPE" == "development-windows" ]]; then
    windows_repo_tabs "$ws" "$repo" || true
  else
    setup_repo_tabs "$ws" "$repo" || true
  fi
}

# review: check out an existing branch at its latest remote state.
make_worktree_existing() {
  local repo="$1" branch="$2" src="${SRC_ROOT}/${repo}" out ws
  worktree_present "$repo" && return 0
  [[ -d "$src/.git" || -f "$src/.git" ]] || \
    repo_fail "missing clone: $src (set SRC_ROOT or clone the repo there)" || return 1
  write_repo_notes "$repo"
  git -C "$src" fetch --prune origin
  out="$(herdr worktree create --cwd "$src" --branch "$branch" --base "origin/${branch}" \
      --path "${STORY_DIR}/${repo}" --label "${ID}-${SLUG}" --no-focus)" || out=""
  ws="$(jq -r '.result.workspace.workspace_id // empty' <<<"$out")"
  [[ -n "$ws" ]] || {
    echo "$out" >&2
    repo_fail "herdr worktree create failed for ${repo}" || return 1
  }
  CREATED=$((CREATED + 1))
  set_push_upstream "${STORY_DIR}/${repo}" "$branch"
  setup_repo_tabs "$ws" "$repo" || true
}

# --- shared inputs ---------------------------------------------------------
if (( NONINTERACTIVE )); then
  ID="$WT_ID"
  SLUG="$WT_SLUG"
  echo "-> non-interactive (WT_ID/WT_SLUG supplied)"
else
  ID="$(ask 'Story id' '12345')"
  SLUG="$(ask 'Slug' 'slug-example')"
fi
[[ -n "$ID" && -n "$SLUG" ]] || { echo "id and slug required" >&2; exit 1; }

BRANCH="${BRANCH_PREFIX}/${ID}-${SLUG}"     # feature/aaron/<id>-<slug> (hyphen)
TYPE_DIR="${WORKTREE_ROOT}/${SUBFOLDER}"    # .../<subfolder>  (no feature/aaron prefix)
STORY_DIR="${TYPE_DIR}/${ID}-${SLUG}"       # parent of the repo worktrees
# Per-repo notes files (<id>-<slug>-<repo>.txt) live inside STORY_DIR and are
# created per worktree by write_repo_notes(), called from make_worktree_new/existing.

mkdir -p "$STORY_DIR"
echo "-> story:  $STORY_DIR"
echo "-> branch: $BRANCH"

# ===========================================================================
# DEVELOPMENT
# ===========================================================================
if [[ "$TYPE" == "development" || "$TYPE" == "development-windows" ]]; then
  if (( NONINTERACTIVE )); then
    REPOS="${WT_REPOS:-}"
    [[ -n "$REPOS" ]] || { echo "WT_REPOS required in non-interactive mode" >&2; exit 1; }
  else
    REPOS="$(ask 'Repos (csv)' 'repo-a,repo-b,repo-c')"
    [[ -n "$REPOS" ]] || { echo "repos required" >&2; exit 1; }
  fi

  # ----- AZURE PLACEHOLDER (development) -----------------------------------
  # At WORK, you can replace prompts / fetch story text via az boards here.
  # -------------------------------------------------------------------------

  IFS=',' read -ra LIST <<< "$REPOS"
  for repo in "${LIST[@]}"; do
    repo="$(echo "$repo" | xargs)"; [[ -n "$repo" ]] || continue
    make_worktree_new "$repo" "$BRANCH" || echo "WARNING: skipped ${repo}" >&2
  done
  echo "OK development ready at ${STORY_DIR}"
fi

# ===========================================================================
# REVIEW
# ===========================================================================
if [[ "$TYPE" == "review" ]]; then
  # az-watcher (or any caller) can hand over the real "<repo>:<branch>" list and
  # bypass the placeholder below entirely.
  if (( NONINTERACTIVE )) && [[ -n "${WT_BRANCHES_FILE:-}" ]]; then
    BRANCHES="$WT_BRANCHES_FILE"
    [[ -s "$BRANCHES" ]] || { echo "WT_BRANCHES_FILE is empty: ${BRANCHES}" >&2; exit 1; }
    echo "-> branches from WT_BRANCHES_FILE: ${BRANCHES}"
  else
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
  fi

  # One worktree per linked branch. Line format: <repo>:<branch>
  # NOTE: if one repo has several linked branches, give each a distinct --path
  # (e.g. append the branch slug) so they don't collide on ${STORY_DIR}/${repo}.
  # Branches may contain ':' only in exotic names; split on the FIRST colon.
  while IFS= read -r line; do
    repo="${line%%:*}"; branch="${line#*:}"
    repo="$(echo "$repo" | xargs)"; branch="$(echo "$branch" | xargs)"
    [[ -n "$repo" && -n "$branch" ]] || continue
    make_worktree_existing "$repo" "$branch" || echo "WARNING: skipped ${repo}" >&2
  done < "$BRANCHES"
  echo "OK review ready at ${STORY_DIR}"
fi

# Nothing created but something was already there -> "nothing to do" (exit 3),
# so automation can distinguish a no-op re-run from real work or a failure.
if (( CREATED == 0 && SKIPPED > 0 )); then
  echo "-> nothing to do: all requested worktrees already exist"
  exit 3
fi
