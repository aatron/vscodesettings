#!/usr/bin/env bash
# Exercises the shell logic of wsl/herdr/worktree-make.sh (set -e behaviour, awk
# helpers, branch handling) by running it against throwaway fixtures. Runs under
# Git Bash on Windows, where `herdr` is on PATH; the git logic under test is the
# same code WSL runs.
set -uo pipefail

FIXTURE_MARKER="herdr-wt-tests"
BASE="${TMPDIR:-/tmp}/${FIXTURE_MARKER}/$$/make"
REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/worktree-make.sh"
PASS=0; FAIL=0; FAILED_NAMES=()
RUN=0

# Close every workspace this harness created. Matching is by PATH, not label:
# herdr does not always keep the --label we passed (it often shows the repo
# name), so a label filter silently leaves fixture workspaces behind in the
# user's real herdr session.
close_workspaces() {
  local json ids id mine
  json="$(herdr workspace list 2>/dev/null || true)"
  [[ -n "$json" ]] || return 0
  # Match on the fixture marker rather than the full path: herdr reports native
  # Windows paths under Git Bash (and POSIX ones under WSL), and the marker
  # appears in neither a real repo nor a real worktree.
  mine="$FIXTURE_MARKER"
  ids="$(jq -r --arg mine "$mine" '
      .result.workspaces[]?
      | select(.worktree != null)
      | select(((.worktree.repo_root // "") | contains($mine))
            or ((.worktree.checkout_path // "") | contains($mine)))
      | .workspace_id' <<<"$json" 2>/dev/null || true)"
  for id in $ids; do
    herdr worktree remove --workspace "$id" --force >/dev/null 2>&1 || true
    herdr workspace close "$id" >/dev/null 2>&1 || true
  done
}

reset_fixture() {
  close_workspaces
  RUN=$((RUN + 1))
  ROOT="$BASE/run$RUN"
  REPOS="$ROOT/repos"; TREES="$ROOT/worktrees"; CFG="$ROOT/config.toml"
  SCRIPT="$ROOT/make-worktree.sh"
  mkdir -p "$REPOS" "$TREES"
  printf '[worktrees]\ndirectory = "%s"\n' "$TREES" > "$CFG"
  sed "s|^SRC_ROOT=.*|SRC_ROOT=\"$REPOS\"|" "$REAL" > "$SCRIPT"
  chmod +x "$SCRIPT"
}

# $1 name  $2 default branch  $3 extra upstream commits
new_repo() {
  local name="$1" def="$2" extra="$3" i
  UP="$ROOT/$name.git"; WORK="$ROOT/$name.work"; CLONE="$REPOS/$name"
  git init -q --bare "$UP"
  git -C "$UP" symbolic-ref HEAD "refs/heads/$def"
  git init -q "$WORK"
  git -C "$WORK" config user.email t@t.t; git -C "$WORK" config user.name T
  echo base > "$WORK/f.txt"
  git -C "$WORK" add -A; git -C "$WORK" commit -qm c1
  git -C "$WORK" branch -M "$def"
  git -C "$WORK" remote add origin "$UP"
  git -C "$WORK" push -q -u origin "$def"
  git -q clone -q "$UP" "$CLONE" 2>/dev/null || git clone -q "$UP" "$CLONE"
  git -C "$CLONE" config user.email t@t.t; git -C "$CLONE" config user.name T
  for ((i = 1; i <= extra; i++)); do
    echo "up$i" >> "$WORK/f.txt"
    git -C "$WORK" commit -qam "upstream$i"
  done
  (( extra > 0 )) && git -C "$WORK" push -q origin "$def"
  TIP="$(git -C "$WORK" rev-parse HEAD)"
}

run_make() {   # run_make <type> [VAR=VAL ...]
  local type="$1"; shift
  local out rc
  set +e
  out="$(env HERDR_CONFIG_PATH="$CFG" "$@" bash "$SCRIPT" "$type" 2>&1)"
  rc=$?
  set -e
  OUT="$out"; RC=$rc
}

story() {   # story <id> <slug> <repo> [type]
  local sub="${4:-development}"
  [[ "$sub" == "review" ]] || sub="development"
  printf '%s/%s/%s-%s/%s\n' "$TREES" "$sub" "$1" "$2" "$3"
}

check() {   # check <name> <condition-result 0/1> <detail>
  if [[ "$2" == "0" ]]; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1")
    printf '  FAIL  %s :: %s\n' "$1" "$3"
  fi
}
ok() { [[ "$1" == "$2" ]] && echo 0 || echo 1; }

echo
echo '================ worktree-make.sh (shell logic) test run ================'

echo
echo '1. happy path: new branch lands on the LATEST default branch'
reset_fixture; new_repo mono 'trade-central/root' 4
run_make development WT_ID=99301 WT_SLUG=zz-happy WT_REPOS=mono
WT="$(story 99301 zz-happy mono)"
HEAD="$(git -C "$WT" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == upstream tip' "$(ok "$HEAD" "$TIP")" "head=$HEAD want=$TIP
$OUT"
check 'verify line printed' "$(grep -q 'verify: HEAD' <<<"$OUT" && echo 0 || echo 1)" 'no verify line'

echo
echo '2. stale remote-tracking ref is refreshed by the fetch'
reset_fixture; new_repo mono main 5
FIRST="$(git -C "$CLONE" rev-list --max-parents=0 HEAD)"
git -C "$CLONE" update-ref refs/remotes/origin/main "$FIRST"
run_make development WT_ID=99302 WT_SLUG=zz-stale WT_REPOS=mono
HEAD="$(git -C "$(story 99302 zz-stale mono)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == upstream tip' "$(ok "$HEAD" "$TIP")" "head=$HEAD want=$TIP
$OUT"

echo
echo '3. THE BUG: leftover branch with no unique commits is moved to the base'
reset_fixture; new_repo mono main 6
STALE="$(git -C "$CLONE" rev-parse origin/main)"
git -C "$CLONE" branch feature/aaron/99303-zz-left "$STALE"
run_make development WT_ID=99303 WT_SLUG=zz-left WT_REPOS=mono
HEAD="$(git -C "$(story 99303 zz-left mono)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == upstream tip (not the stale branch tip)' "$(ok "$HEAD" "$TIP")" "head=$HEAD want=$TIP stale=$STALE
$OUT"
check 'reported the move' "$(grep -q 'no commits of its own' <<<"$OUT" && echo 0 || echo 1)" 'no move message'

echo
echo '4. leftover branch WITH unique commits: refuse, create nothing'
reset_fixture; new_repo mono main 3
STALE="$(git -C "$CLONE" rev-parse origin/main)"
TREE="$(git -C "$CLONE" rev-parse "$STALE^{tree}")"
MINE="$(git -C "$CLONE" commit-tree "$TREE" -p "$STALE" -m 'my local work')"
git -C "$CLONE" update-ref refs/heads/feature/aaron/99304-zz-work "$MINE"
run_make development WT_ID=99304 WT_SLUG=zz-work WT_REPOS=mono
check 'exit 1' "$(ok "$RC" 1)" "rc=$RC
$OUT"
check 'no worktree created' "$([[ -e "$(story 99304 zz-work mono)/.git" ]] && echo 1 || echo 0)" 'worktree exists'
check 'explains the overrides' "$(grep -q 'WT_REUSE_BRANCH' <<<"$OUT" && grep -q 'WT_RESET_BRANCH' <<<"$OUT" && echo 0 || echo 1)" "no hint
$OUT"
check 'branch left untouched' "$(ok "$(git -C "$CLONE" rev-parse refs/heads/feature/aaron/99304-zz-work)" "$MINE")" 'branch moved'

echo
echo '5. WT_RESET_BRANCH=1 discards the unique commits and uses the base'
run_make development WT_ID=99304 WT_SLUG=zz-work WT_REPOS=mono WT_RESET_BRANCH=1
HEAD="$(git -C "$(story 99304 zz-work mono)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == upstream tip' "$(ok "$HEAD" "$TIP")" "head=$HEAD want=$TIP
$OUT"

echo
echo '6. WT_REUSE_BRANCH=1 keeps the existing branch and says how far behind'
reset_fixture; new_repo mono main 3
STALE="$(git -C "$CLONE" rev-parse origin/main)"
TREE="$(git -C "$CLONE" rev-parse "$STALE^{tree}")"
MINE="$(git -C "$CLONE" commit-tree "$TREE" -p "$STALE" -m 'my local work')"
git -C "$CLONE" update-ref refs/heads/feature/aaron/99306-zz-reuse "$MINE"
run_make development WT_ID=99306 WT_SLUG=zz-reuse WT_REPOS=mono WT_REUSE_BRANCH=1
HEAD="$(git -C "$(story 99306 zz-reuse mono)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == existing branch tip' "$(ok "$HEAD" "$MINE")" "head=$HEAD want=$MINE
$OUT"
check 'warns it is behind' "$(grep -q 'behind origin/main' <<<"$OUT" && echo 0 || echo 1)" 'no behind warning'

echo
echo '7. branch already checked out elsewhere: refuse'
reset_fixture; new_repo mono main 2
git -C "$CLONE" worktree add -q -b feature/aaron/99307-zz-dup "$ROOT/other-wt" origin/main >/dev/null 2>&1
run_make development WT_ID=99307 WT_SLUG=zz-dup WT_REPOS=mono
check 'exit 1' "$(ok "$RC" 1)" "rc=$RC
$OUT"
check 'names the conflicting worktree' "$(grep -q 'already checked out at' <<<"$OUT" && echo 0 || echo 1)" "no message
$OUT"

echo
echo '8. fetch failure: refuse rather than use a stale origin'
reset_fixture; new_repo mono main 4
git -C "$CLONE" remote set-url origin "$ROOT/nope.git"
run_make development WT_ID=99308 WT_SLUG=zz-nofetch WT_REPOS=mono
check 'exit 1' "$(ok "$RC" 1)" "rc=$RC
$OUT"
check 'says the fetch failed' "$(grep -q 'fetch failed' <<<"$OUT" && echo 0 || echo 1)" "no message
$OUT"
check 'no worktree created' "$([[ -e "$(story 99308 zz-nofetch mono)/.git" ]] && echo 1 || echo 0)" 'worktree exists'
check 'retried once' "$(ok "$(grep -c 'git fetch --prune origin in' <<<"$OUT")" 2)" 'no retry'

echo
echo '9. missing origin/HEAD is recovered from the remote'
reset_fixture; new_repo mono 'trade-central/root' 3
git -C "$CLONE" symbolic-ref -d refs/remotes/origin/HEAD
check 'origin/HEAD really gone' "$([[ -z "$(git -C "$CLONE" symbolic-ref -q --short refs/remotes/origin/HEAD || true)" ]] && echo 0 || echo 1)" 'still there'
run_make development WT_ID=99309 WT_SLUG=zz-nohead WT_REPOS=mono
HEAD="$(git -C "$(story 99309 zz-nohead mono)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == tip of the real default branch' "$(ok "$HEAD" "$TIP")" "head=$HEAD want=$TIP
$OUT"
check 'base label names the real default' "$(grep -q 'origin/trade-central/root @' <<<"$OUT" && echo 0 || echo 1)" "no base line
$OUT"

echo
echo '10. empty leftover directory at the worktree path is cleaned up'
reset_fixture; new_repo mono main 2
mkdir -p "$(story 99310 zz-empty mono)"
run_make development WT_ID=99310 WT_SLUG=zz-empty WT_REPOS=mono
HEAD="$(git -C "$(story 99310 zz-empty mono)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == upstream tip' "$(ok "$HEAD" "$TIP")" "head=$HEAD want=$TIP
$OUT"

echo
echo '11. re-run is idempotent (exit 3)'
run_make development WT_ID=99310 WT_SLUG=zz-empty WT_REPOS=mono
check 'exit 3' "$(ok "$RC" 3)" "rc=$RC
$OUT"

echo
echo '12. review: worktree lands on origin/<linked branch>, stale local branch fixed'
reset_fixture; new_repo mono main 2
git -C "$WORK" checkout -q -b feature/someone/99312-pr
echo pr1 >> "$WORK/f.txt"; git -C "$WORK" commit -qam pr1
git -C "$WORK" push -q origin feature/someone/99312-pr
PRMID="$(git -C "$WORK" rev-parse HEAD)"
echo pr2 >> "$WORK/f.txt"; git -C "$WORK" commit -qam pr2
git -C "$WORK" push -q origin feature/someone/99312-pr
PRTIP="$(git -C "$WORK" rev-parse HEAD)"
git -C "$CLONE" fetch -q origin
git -C "$CLONE" update-ref refs/heads/feature/someone/99312-pr "$PRMID"
git -C "$CLONE" update-ref refs/remotes/origin/feature/someone/99312-pr "$PRMID"
printf 'mono:feature/someone/99312-pr' > "$ROOT/branches.txt"
run_make review WT_ID=99312 WT_SLUG=zz-review WT_BRANCHES_FILE="$ROOT/branches.txt"
HEAD="$(git -C "$(story 99312 zz-review mono review)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 0' "$(ok "$RC" 0)" "rc=$RC
$OUT"
check 'HEAD == origin PR tip (not the stale local branch)' "$(ok "$HEAD" "$PRTIP")" "head=$HEAD want=$PRTIP mid=$PRMID
$OUT"

echo
echo '13. multi-repo: one bad repo does not stop the good one'
reset_fixture
new_repo aaa main 3; TIP_A="$TIP"
new_repo bbb main 2
git -C "$REPOS/bbb" remote set-url origin "$ROOT/nope.git"
run_make development WT_ID=99313 WT_SLUG=zz-multi WT_REPOS='aaa, bbb'
HEAD_A="$(git -C "$(story 99313 zz-multi aaa)" rev-parse HEAD 2>/dev/null || echo none)"
check 'exit 1 (a repo failed)' "$(ok "$RC" 1)" "rc=$RC
$OUT"
check 'good repo created at tip' "$(ok "$HEAD_A" "$TIP_A")" "head=$HEAD_A want=$TIP_A
$OUT"
check 'bad repo not created' "$([[ -e "$(story 99313 zz-multi bbb)/.git" ]] && echo 1 || echo 0)" 'bbb exists'

# Cleanup order matters, and one pass is not enough. herdr keeps a workspace for
# every fixture CLONE it has seen and re-lists it while the repo is still on
# disk, while its panes hold those directories open so the delete fails until
# they are closed. Each round closes what it can and deletes what it can, which
# frees the next round; in practice it converges in two or three.
for _round in 1 2 3 4 5 6 7 8; do
  close_workspaces
  rm -rf "$BASE" 2>/dev/null || true
  remaining="$(herdr workspace list 2>/dev/null \
    | jq -r --arg m "$FIXTURE_MARKER" '[.result.workspaces[]?
        | select(.worktree != null)
        | select(((.worktree.repo_root // "") | contains($m)))] | length' 2>/dev/null || echo 0)"
  [[ "$remaining" == "0" && ! -e "$BASE" ]] && break
  sleep 2
done
if [[ -e "$BASE" ]]; then
  echo "note: could not fully delete fixture dir ${BASE} (herdr may still hold it)" >&2
fi
echo
echo '================ summary ================'
echo "PASS: $PASS   FAIL: $FAIL"
if (( FAIL > 0 )); then
  printf 'failed checks:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
exit 0
