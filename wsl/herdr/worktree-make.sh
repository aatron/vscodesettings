#!/usr/bin/env bash
#
# make-worktree.sh
# Create a multi-repo herdr worktree structure for an Azure DevOps story.
# Two types: development and review.
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
# Also creates worktrees + sidecars.
#
# Git behavior on create - THE SCRIPT OWNS THE BRANCH, NOT HERDR:
#   `herdr worktree create --base <ref>` silently IGNORES --base when the local
#   branch already exists: it just checks that branch out wherever it happens to
#   point and still reports success. A branch left behind by an earlier story
#   (a removal that could not delete it, a worktree deleted by hand, another
#   tool) therefore produced a worktree pinned to an old commit - "you are N
#   commits behind" - with nothing in the output to say so.
#   So every worktree is now created in this order:
#     1. `git fetch --prune origin`, WITH the exit status checked (one retry).
#        A failed fetch aborts the repo - never fall back to a stale origin.
#     2. `git remote set-head origin --auto` so refs/remotes/origin/HEAD (which
#        plain `git fetch` never updates) still names the real default branch.
#     3. Resolve the base to an explicit commit sha and verify it exists.
#     4. Put the local branch at exactly that sha - create it, fast-forward a
#        leftover branch that holds no unique commits, or refuse (see below).
#     5. Call herdr, then VERIFY the new worktree's HEAD is that sha, repairing
#        a clean worktree once with `git reset --hard` before giving up.
#   development -> base is origin/<default branch>
#   review      -> base is origin/<linked branch>
#   all types   -> the branch's upstream is pointed at its OWN name on origin
#                  (see set_push_upstream), so a plain `git push` from the
#                  worktree creates/updates origin/<branch> and can never
#                  target the default branch.
#
# When the local branch already exists AND holds commits that the base does not,
# the script refuses rather than silently hand back old code or silently discard
# work. It prints those commits and two opt-ins:
#   WT_REUSE_BRANCH=1  keep the existing branch as-is (resume the story; the
#                      script reports how far behind the base it is)
#   WT_RESET_BRANCH=1  discard the unique commits and start from the base
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
#     WT_REPOS          csv of repos        (development)
#     WT_BRANCHES_FILE  file of "<repo>:<branch>" lines (review; replaces the
#                       placeholder branch list)
#   Creating a worktree that already exists is a no-op ("exists, skipping"), and
#   a single repo failing is a warning rather than a fatal error, so re-runs from
#   cron are safe.
#
# Exit codes:
#   0  at least one worktree was created and verified
#   1  bad usage / missing input / at least one repo failed
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
[[ "$TYPE" == "development" || "$TYPE" == "review" ]] || {
  echo "usage: $0 <development|review>" >&2; exit 1; }

# Non-interactive when the caller supplies both the id and the slug: no tty is
# reattached, gum is never needed, and per-repo failures are non-fatal.
NONINTERACTIVE=0
if [[ -n "${WT_ID:-}" && -n "${WT_SLUG:-}" ]]; then
  NONINTERACTIVE=1
fi

# Counters that decide the exit code (see header): a run that only re-found
# existing worktrees reports 3 so automation can stay quiet about it, and any
# repo-level failure makes the whole run exit non-zero so it cannot pass unnoticed.
CREATED=0
SKIPPED=0
FAILED=0

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


ask() { gum input --prompt "$1 > " --placeholder "$2"; }

# A repo-level problem. Fatal when a human is driving (they asked for exactly
# these repos); counted and reported in non-interactive mode so one bad repo
# cannot abort a cron run — but the run still exits non-zero at the end.
# Always returns 1, so every call site reads `repo_fail "..." || return 1`.
repo_fail() {
  FAILED=$((FAILED + 1))
  echo "ERROR: $1" >&2
  (( NONINTERACTIVE )) || exit 1
  return 1
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

# Pick the worktree root + type subfolder.
WORKTREE_ROOT="$(resolve_worktree_root)"
SUBFOLDER="$TYPE"
echo "-> worktree root (from herdr [worktrees].directory): ${WORKTREE_ROOT}"

# ---------------------------------------------------------------------------
# Git: getting the base right
# ---------------------------------------------------------------------------

# Resolve a ref to a full commit sha; prints nothing and fails when it does not
# exist.
resolve_commit() {
  git -C "$1" rev-parse --verify --quiet "$2^{commit}" 2>/dev/null
}

# Fetch, and MEAN it. A fetch that fails (expired credentials, network, a stale
# index.lock, a concurrent gc) used to be ignored, after which the worktree was
# cut from whatever origin/<default> happened to be — the exact "N commits
# behind" symptom. One retry, then the caller aborts the repo.
update_remote() {
  local src="$1" attempt
  for attempt in 1 2; do
    if (( attempt == 1 )); then
      echo "-> fetch:  git fetch --prune origin in ${src}"
    else
      echo "-> fetch:  git fetch --prune origin in ${src} (retry ${attempt})"
    fi
    if git -C "$src" fetch --prune origin; then
      return 0
    fi
    echo "WARNING: git fetch --prune origin failed in ${src}" >&2
    (( attempt == 1 )) && sleep 3
  done
  return 1
}

# `git fetch` never updates refs/remotes/origin/HEAD, so a clone made before the
# remote's default branch was renamed — or one where the ref was never written —
# keeps pointing at the wrong branch forever. Re-derive it from the remote.
# Best effort: offline, the cached ref (or the fallbacks below) still works.
sync_origin_head() {
  git -C "$1" remote set-head origin --auto >/dev/null 2>&1 || true
}

# Resolve a repo's default branch (main/master/...), locally if possible.
default_branch() {
  local src="$1" d candidate
  d="$(git -C "$src" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  d="${d#origin/}"
  if [[ -z "$d" ]]; then
    d="$(git -C "$src" ls-remote --symref origin HEAD 2>/dev/null \
         | awk '/^ref:/{sub("refs/heads/","",$2); print $2; exit}')"
  fi
  # Only trust it if the matching remote-tracking ref actually exists: the old
  # blind `main` fallback could name a branch that is real but is NOT the
  # default (or does not exist at all, which herdr then rejects outright).
  if [[ -n "$d" ]] && resolve_commit "$src" "refs/remotes/origin/${d}" >/dev/null; then
    printf '%s\n' "$d"; return 0
  fi
  for candidate in main master trunk develop; do
    if resolve_commit "$src" "refs/remotes/origin/${candidate}" >/dev/null; then
      echo "WARNING: origin/HEAD unusable in ${src}; falling back to origin/${candidate}" >&2
      printf '%s\n' "$candidate"; return 0
    fi
  done
  return 1
}

# Path of the worktree that has $2 checked out, or empty when it is free.
branch_worktree_path() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$2" '
    /^worktree /  { path = substr($0, 10) }
    $0 == "branch " b { print path; exit }
  '
}

commit_count() {
  local n
  n="$(git -C "$1" rev-list --count "$2" 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' "$n"
}

# Put the local branch at exactly $3 and set EXPECTED_SHA to the commit the new
# worktree must end up on. Returns non-zero to mean "do not create this one".
#
# This is the fix for the reported bug: herdr honours --base only when it has to
# create the branch, so the script guarantees the branch position itself.
EXPECTED_SHA=""
set_branch_at_base() {
  local src="$1" branch="$2" base="$3" base_label="$4"
  local existing in_use unique behind
  EXPECTED_SHA=""
  existing="$(resolve_commit "$src" "refs/heads/${branch}" || true)"

  if [[ -z "$existing" ]]; then
    git -C "$src" branch --no-track "$branch" "$base" \
      || repo_fail "could not create branch ${branch} at ${base_label} in ${src}" || return 1
    echo "-> branch: ${branch} created at ${base_label} (${base:0:9})"
    EXPECTED_SHA="$base"
    return 0
  fi

  # An existing branch checked out somewhere else is a hard conflict: herdr
  # cannot check it out twice, and silently reusing it is what produced stale
  # worktrees before.
  in_use="$(branch_worktree_path "$src" "$branch")"
  if [[ -n "$in_use" ]]; then
    repo_fail "branch ${branch} is already checked out at ${in_use} - remove that worktree first, or use a different story slug" || return 1
  fi

  if [[ "$existing" == "$base" ]]; then
    echo "-> branch: ${branch} already at ${base_label} (${base:0:9})"
    EXPECTED_SHA="$base"
    return 0
  fi

  unique="$(commit_count "$src" "${base}..refs/heads/${branch}")"
  behind="$(commit_count "$src" "refs/heads/${branch}..${base}")"

  if (( unique == 0 )); then
    # Leftover branch with nothing of its own — the common case after a story
    # was removed. Nothing can be lost, so move it to the base.
    git -C "$src" branch --force --no-track "$branch" "$base" \
      || repo_fail "could not move existing branch ${branch} to ${base_label} in ${src}" || return 1
    echo "-> branch: ${branch} was ${behind} commit(s) behind ${base_label} with no commits of its own - moved to ${base:0:9}"
    EXPECTED_SHA="$base"
    return 0
  fi

  if [[ "${WT_RESET_BRANCH:-}" == "1" ]]; then
    echo "WARNING: WT_RESET_BRANCH=1 - discarding ${unique} commit(s) on ${branch}:" >&2
    git -C "$src" log --oneline --no-decorate "${base}..refs/heads/${branch}" 2>/dev/null | sed 's/^/     /' || true
    git -C "$src" branch --force --no-track "$branch" "$base" \
      || repo_fail "could not reset branch ${branch} to ${base_label} in ${src}" || return 1
    echo "-> branch: ${branch} reset to ${base_label} (${base:0:9})"
    EXPECTED_SHA="$base"
    return 0
  fi

  if [[ "${WT_REUSE_BRANCH:-}" == "1" ]]; then
    echo "WARNING: WT_REUSE_BRANCH=1 - keeping existing ${branch} at ${existing:0:9}: ${unique} own commit(s), ${behind} behind ${base_label}. Run 'git merge ${base_label}' in the worktree to catch up." >&2
    EXPECTED_SHA="$existing"
    return 0
  fi

  git -C "$src" log --oneline --no-decorate "${base}..refs/heads/${branch}" 2>/dev/null | sed 's/^/     /' || true
  repo_fail "$(printf '%s\n' \
    "branch ${branch} already exists in ${src} at ${existing:0:9} with ${unique} commit(s)" \
    "  that ${base_label} does not have, and is ${behind} commit(s) behind it. Refusing to create" \
    "  a worktree that would be out of date or to throw those commits away. Either:" \
    "    WT_REUSE_BRANCH=1  keep the branch and resume the story on it" \
    "    WT_RESET_BRANCH=1  discard its ${unique} commit(s) and start from ${base_label}" \
    "  or delete it yourself:  git -C '${src}' branch -D ${branch}")" || return 1
}

# `git worktree add` refuses a path that is registered-but-missing (a worktree
# deleted by hand) or one that already has files in it. Prune the administrative
# leftovers and clear a directory an earlier failed run left empty.
init_worktree_path() {
  local src="$1" path="$2"
  git -C "$src" worktree prune >/dev/null 2>&1 || true
  [[ -e "$path" ]] || return 0
  if [[ -d "$path" ]] && [[ -z "$(ls -A "$path" 2>/dev/null)" ]]; then
    rmdir "$path" 2>/dev/null || true
    echo "-> path:   removed empty leftover directory ${path}"
    return 0
  fi
  repo_fail "${path} already exists, is not a worktree, and is not empty - remove it or use a different story slug" || return 1
}

# The safety net: whatever herdr did, the worktree must sit on $2.
assert_worktree_at() {
  local wt="$1" expected="$2" label="$3" head
  head="$(resolve_commit "$wt" HEAD || true)"
  if [[ "$head" == "$expected" ]]; then
    echo "-> verify: HEAD ${expected:0:9} == ${label}"
    return 0
  fi
  echo "WARNING: worktree ${wt} is at '${head}' but should be at ${expected:0:9} (${label}) - repairing" >&2
  if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null || true)" ]]; then
    repo_fail "worktree ${wt} is at the wrong commit and has local changes - fix it by hand" || return 1
  fi
  git -C "$wt" reset --hard "$expected" \
    || repo_fail "could not reset ${wt} to ${expected:0:9} (${label})" || return 1
  head="$(resolve_commit "$wt" HEAD || true)"
  if [[ "$head" != "$expected" ]]; then
    repo_fail "worktree ${wt} still at '${head}' after reset - expected ${expected:0:9}" || return 1
  fi
  echo "-> verify: HEAD repaired to ${expected:0:9} == ${label}"
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

# One worktree, one shared code path.
#   $3 = default -> base is origin/<default branch>   (development types)
#   $3 = remote  -> base is origin/<branch>           (review)
make_worktree() {
  local repo="$1" branch="$2" base_kind="$3"
  local src="${SRC_ROOT}/${repo}" path="${STORY_DIR}/${repo}"
  local out ws base base_label def
  worktree_present "$repo" && return 0
  [[ -d "$src/.git" || -f "$src/.git" ]] || \
    repo_fail "missing clone: $src (set SRC_ROOT or clone the repo there)" || return 1

  init_worktree_path "$src" "$path" || return 1

  update_remote "$src" || \
    repo_fail "git fetch failed for ${repo} - refusing to create a worktree from a possibly stale origin. Check credentials/network and re-run." || return 1
  sync_origin_head "$src"

  if [[ "$base_kind" == "default" ]]; then
    def="$(default_branch "$src")" || \
      repo_fail "cannot determine the default branch of ${src} (no usable origin/HEAD)" || return 1
    base_label="origin/${def}"
  else
    base_label="origin/${branch}"
  fi

  base="$(resolve_commit "$src" "refs/remotes/${base_label}" || true)"
  [[ -n "$base" ]] || \
    repo_fail "${base_label} does not exist in ${src} after fetching - nothing to base ${branch} on" || return 1
  echo "-> base:   ${base_label} @ ${base:0:9}"

  set_branch_at_base "$src" "$branch" "$base" "$base_label" || return 1

  write_repo_notes "$repo"

  # herdr's stderr is kept OUT of the captured stdout: mixing the two corrupts
  # the JSON, and a create that had actually succeeded then looks like a failure.
  local errfile; errfile="$(mktemp)"
  out="$(herdr worktree create --cwd "$src" --branch "$branch" --base "$EXPECTED_SHA" \
      --path "$path" --label "${ID}-${SLUG}" --no-focus 2>"$errfile")" || out=""
  ws="$(jq -r '.result.workspace.workspace_id // empty' <<<"$out" 2>/dev/null || true)"
  if [[ -z "$ws" ]]; then
    cat "$errfile" >&2 || true
    [[ -n "$out" ]] && echo "$out" >&2
    rm -f "$errfile"
    repo_fail "herdr worktree create failed for ${repo}" || return 1
  fi
  rm -f "$errfile"

  assert_worktree_at "$path" "$EXPECTED_SHA" "$base_label" || return 1

  CREATED=$((CREATED + 1))
  set_push_upstream "$path" "$branch"

  # Tab decoration is cosmetic: never let it fail an otherwise good worktree.
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
# created per worktree by write_repo_notes(), called from make_worktree().

mkdir -p "$STORY_DIR"
echo "-> story:  $STORY_DIR"
echo "-> branch: $BRANCH"

# ===========================================================================
# DEVELOPMENT
# ===========================================================================
if [[ "$TYPE" == "development" ]]; then
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
    make_worktree "$repo" "$BRANCH" default || echo "WARNING: skipped ${repo}" >&2
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
  # `|| [[ -n "$line" ]]` so a file whose LAST line has no trailing newline is
  # still processed: `read` returns non-zero at EOF, which silently dropped the
  # only line of a single-PR file (and the run then exited 0 having done nothing).
  ATTEMPTED=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                     # tolerate CRLF
    [[ -n "$line" && "${line:0:1}" != "#" ]] || continue
    repo="${line%%:*}"; branch="${line#*:}"
    repo="$(echo "$repo" | xargs)"; branch="$(echo "$branch" | xargs)"
    [[ -n "$repo" && -n "$branch" ]] || continue
    ATTEMPTED=$((ATTEMPTED + 1))
    make_worktree "$repo" "$branch" remote || echo "WARNING: skipped ${repo}" >&2
  done < "$BRANCHES"
  if (( ATTEMPTED == 0 )); then
    echo "no usable '<repo>:<branch>' lines in ${BRANCHES}" >&2
    exit 1
  fi
  echo "OK review ready at ${STORY_DIR}"
fi

# Any repo-level failure exits non-zero so automation notices — a partially
# successful run must never look like a clean one.
if (( FAILED > 0 )); then
  echo "-> ${FAILED} repo(s) failed - see the errors above"
  exit 1
fi

# Nothing created but something was already there -> "nothing to do" (exit 3),
# so automation can distinguish a no-op re-run from real work or a failure.
if (( CREATED == 0 && SKIPPED > 0 )); then
  echo "-> nothing to do: all requested worktrees already exist"
  exit 3
fi

exit 0
