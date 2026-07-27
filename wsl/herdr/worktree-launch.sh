#!/usr/bin/env bash
#
# worktree-launch.sh — herdr-plus quick-action entrypoint.
#
# herdr-plus runs actions inside the overlay picker (stdin=/dev/null, TUI already
# tearing down). gum cannot prompt there. This opens a real tab and submits the
# target script into that pane via `herdr pane run`.
#
# Usage:
#   worktree-launch.sh <development|development-windows|review> [ws] [cwd]       -> make-worktree.sh <type>
#   worktree-launch.sh remove [ws] [cwd] [story-id]                              -> worktree-remove.sh
#
set -euo pipefail

ACTION="${1:-}"
WS="${2:-}"
CWD="${3:-}"
STORY_ID="${4:-}"

case "$ACTION" in
  development)         SCRIPT="${HOME}/bin/make-worktree.sh"; RUN_ARGS="$ACTION"; label="New Dev Worktree" ;;
  development-windows) SCRIPT="${HOME}/bin/make-worktree.sh"; RUN_ARGS="$ACTION"; label="New Dev Worktree (Windows)" ;;
  review)              SCRIPT="${HOME}/bin/make-worktree.sh"; RUN_ARGS="$ACTION"; label="New Review Worktree" ;;
  remove)              SCRIPT="${HOME}/bin/worktree-remove.sh"; RUN_ARGS="$STORY_ID"; label="Delete Story Worktree" ;;
  *)
    echo "usage: $0 <development|development-windows|review|remove> [workspace_id] [cwd] [story-id]" >&2
    exit 1 ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need herdr
need jq
[[ -x "$SCRIPT" || -f "$SCRIPT" ]] || {
  echo "missing $SCRIPT (run install.sh)" >&2
  exit 1
}

args=(tab create --label "$label" --focus)
[[ -n "$WS" ]] && args+=(--workspace "$WS")
[[ -n "$CWD" ]] && args+=(--cwd "$CWD")

out="$(herdr "${args[@]}")"
pane="$(jq -r '.result.root_pane.pane_id // empty' <<<"$out")"
[[ -n "$pane" ]] || {
  echo "herdr tab create failed:" >&2
  echo "$out" >&2
  exit 1
}

# Submit into the new pane's shell (returns immediately; script runs interactively).
herdr pane run "$pane" "${SCRIPT} ${RUN_ARGS}"
