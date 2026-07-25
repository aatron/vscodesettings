#!/usr/bin/env bash
#
# worktree-launch.sh — herdr-plus quick-action entrypoint.
#
# herdr-plus runs actions inside the overlay picker (stdin=/dev/null, TUI already
# tearing down). gum cannot prompt there. This opens a real tab and submits
# make-worktree.sh into that pane via `herdr pane run`.
#
set -euo pipefail

TYPE="${1:-}"
[[ "$TYPE" == "development" || "$TYPE" == "review" ]] || {
  echo "usage: $0 <development|review> [workspace_id] [cwd]" >&2
  exit 1
}

WS="${2:-}"
CWD="${3:-}"
SCRIPT="${HOME}/bin/make-worktree.sh"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need herdr
need jq
[[ -x "$SCRIPT" || -f "$SCRIPT" ]] || {
  echo "missing $SCRIPT (run install.sh)" >&2
  exit 1
}

label="New Dev Worktree"
[[ "$TYPE" == "review" ]] && label="New Review Worktree"

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
herdr pane run "$pane" "${SCRIPT} ${TYPE}"
