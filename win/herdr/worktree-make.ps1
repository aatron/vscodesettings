# make-worktree.ps1
# Create a multi-repo herdr worktree structure for an Azure DevOps story.
# Two types: development and review.
#
# Tabs come from herdr-plus Worktree Auto-Layout (worktree-layout.toml,
# repo = "*"): notes, claude, cursor, pwsh at each worktree root. Layouts cannot
# interpolate the repo/story name, and their tab commands do not reliably start,
# so THIS SCRIPT owns the labels *and* the commands after create.
#   development / review    -> notes, claude, cursor, pwsh
#
# Git behavior on create - THE SCRIPT OWNS THE BRANCH, NOT HERDR:
#   `herdr worktree create --base <ref>` silently IGNORES --base when the local
#   branch already exists: it just checks that branch out wherever it happens to
#   point and still reports success. A branch left behind by an earlier story
#   (removal that could not delete it, a worktree deleted by hand, another tool)
#   therefore produced a worktree pinned to an old commit - "you are N commits
#   behind" - with nothing in the output to say so.
#   So every worktree is now created in this order:
#     1. `git fetch --prune origin`, WITH the exit code checked (one retry).
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
#   all types -> the branch's upstream is pointed at its OWN name on origin
#                (Set-PushUpstream), so a plain `git push` can never target the
#                default branch.
#
# When the local branch already exists AND holds commits that the base does not,
# the script refuses rather than silently hand back old code or silently discard
# work. It prints those commits and two opt-ins:
#   WT_REUSE_BRANCH=1  keep the existing branch as-is (resume the story; the
#                      script reports how far behind the base it is)
#   WT_RESET_BRANCH=1  discard the unique commits and start from the base
#
# Non-interactive mode (az-watcher / any automation):
#   Set BOTH WT_ID and WT_SLUG and every prompt is skipped - no gum.
#     WT_ID, WT_SLUG, WT_REPOS, WT_BRANCHES_FILE
#
# Exit codes:
#   0  at least one worktree was created and verified
#   1  bad usage / missing input / at least one repo failed
#   3  nothing to do - every requested repo already had a worktree
#
$ErrorActionPreference = 'Stop'

# ===========================================================================
# EDIT THESE FOR YOUR MACHINE
# ===========================================================================
$SRC_ROOT = Join-Path $env:USERPROFILE 'source\repos'
$BRANCH_PREFIX = 'feature/aaron'
# Story worktree base comes from Herdr config [worktrees].directory
$CLAUDE_CMD = 'claude --permission-mode auto'
$CURSOR_CMD = 'agent --auto-review'

# ===========================================================================
$Type = if ($args.Count -ge 1) { $args[0] } else { '' }
if ($Type -notin @('development', 'review')) {
  Write-Error "usage: make-worktree.ps1 <development|review>"
  exit 1
}

$NonInteractive = ($env:WT_ID -and $env:WT_SLUG)
$script:Created = 0
$script:Skipped = 0
$script:Failed = 0

function Need-Cmd([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Write-Error "missing tool: $Name"
    exit 1
  }
}

Need-Cmd herdr
Need-Cmd git
if (-not $NonInteractive) { Need-Cmd gum }

# ---------------------------------------------------------------------------
# Native-command plumbing.
#
# $ErrorActionPreference = 'Stop' plus a redirected native stderr (2>&1) makes
# Windows PowerShell wrap every stderr line in a NativeCommandError and THROW -
# even when the tool exited 0. git and herdr both write ordinary progress to
# stderr, so all of their invocations run with the preference relaxed and are
# judged on $LASTEXITCODE alone.
# ---------------------------------------------------------------------------
$script:GitExit = 0

# Capture stdout lines. Never throws; sets $script:GitExit.
function Git-Out([string]$Repo, [string[]]$GitArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & git -C $Repo @GitArgs 2>$null
    $script:GitExit = $LASTEXITCODE
    if ($null -eq $out) { return @() }
    return @($out)
  } finally { $ErrorActionPreference = $prev }
}

# Run for effect, echoing git's own output (indented) to the console. Returns
# $true on exit 0. Emits nothing to the output stream, so the boolean is safe
# to capture.
function Git-Run([string]$Repo, [string[]]$GitArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & git -C $Repo @GitArgs 2>&1 | ForEach-Object { Write-Host "   $_" }
    $script:GitExit = $LASTEXITCODE
    return ($script:GitExit -eq 0)
  } finally { $ErrorActionPreference = $prev }
}

# First non-empty stdout line, or '' when the command failed / said nothing.
function Git-Line([string]$Repo, [string[]]$GitArgs) {
  $out = Git-Out $Repo $GitArgs
  if ($script:GitExit -ne 0) { return '' }
  foreach ($line in $out) {
    $t = "$line".Trim()
    if ($t) { return $t }
  }
  return ''
}

function Get-ShortSha([string]$Sha) {
  if ($Sha.Length -ge 9) { return $Sha.Substring(0, 9) }
  return $Sha
}

# herdr's stderr is kept OUT of the captured stdout: mixing the two corrupted
# the JSON, and a create that had actually succeeded was then reported as a
# failure. Stderr is stashed in $script:HerdrErr for the error path.
$script:HerdrErr = ''

function Invoke-HerdrCapture([string[]]$HerdrArgs) {
  $errFile = [IO.Path]::GetTempFileName()
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = (& herdr @HerdrArgs 2>$errFile | Out-String)
    $script:HerdrErr = "$(Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)"
    return $out
  } catch {
    $script:HerdrErr = "$_"
    return ''
  } finally {
    $ErrorActionPreference = $prev
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
  }
}

# Parsed herdr JSON, or $null. ConvertFrom-Json rather than jq: it cannot be
# tripped by a stray stderr line and it needs no external process (a `jq ... 2>$null`
# under $ErrorActionPreference='Stop' throws NativeCommandError on any warning).
function Invoke-HerdrJson([string[]]$HerdrArgs) {
  $out = Invoke-HerdrCapture $HerdrArgs
  if (-not $out) { return $null }
  try { return ($out | ConvertFrom-Json) } catch { return $null }
}

# Fire-and-forget herdr call (renames, closes, pane run): output discarded,
# stderr never allowed to throw.
function Invoke-HerdrQuiet([string[]]$HerdrArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & herdr @HerdrArgs 2>$null | Out-Null } catch { } finally { $ErrorActionPreference = $prev }
}

function Get-TabIdByLabel($Json, [string]$Ws, [string]$Label) {
  if ($null -eq $Json) { return '' }
  foreach ($tab in @($Json.result.tabs)) {
    if ($null -eq $tab) { continue }
    if ($tab.workspace_id -eq $Ws -and $tab.label -eq $Label) { return "$($tab.tab_id)" }
  }
  return ''
}

function Get-PaneIdByTab([string]$Ws, [string]$Tab) {
  $json = Invoke-HerdrJson @('pane', 'list', '--workspace', $Ws)
  if ($null -eq $json) { return '' }
  foreach ($pane in @($json.result.panes)) {
    if ($null -eq $pane) { continue }
    if ($pane.tab_id -eq $Tab) { return "$($pane.pane_id)" }
  }
  return ''
}

function Test-PaneReadyAndIdle([string]$Pane) {
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  $names = @()
  while ([DateTime]::UtcNow -lt $deadline) {
    $info = Invoke-HerdrJson @('pane', 'process-info', '--pane', $Pane)
    if ($null -ne $info) {
      $names = @(@($info.result.process_info.foreground_processes) |
        Where-Object { $null -ne $_ } | ForEach-Object { "$($_.name)" })
    }
    if ($names.Count -gt 0) { break }
    Start-Sleep -Milliseconds 200
  }
  if ($names.Count -eq 0) { return $true }
  foreach ($n in $names) {
    $n = $n.Trim()
    if (-not $n) { continue }
    switch -Regex ($n) {
      '^(pwsh|powershell|powershell_ise|cmd|bash|sh|dash|zsh|fish|-bash|-sh|-zsh)$' { continue }
      default { return $false }
    }
  }
  return $true
}

function Invoke-InTab([string]$Ws, [string]$Tab, [string]$Dir, [string]$Cmd) {
  $pane = Get-PaneIdByTab $Ws $Tab
  if (-not $pane) {
    Write-Warning "no pane found for tab $Tab"
    return
  }
  if (-not (Test-PaneReadyAndIdle $pane)) {
    Write-Host "-> tab ${Tab}: pane busy, left as-is"
    return
  }
  $dirLit = "'" + ($Dir -replace "'", "''") + "'"
  $full = "Set-Location -LiteralPath $dirLit; $Cmd"
  Invoke-HerdrQuiet @('pane', 'run', $pane, $full)
}

function Get-RepoNotesPath([string]$Repo) {
  Join-Path $script:STORY_DIR "$($script:ID)-$($script:SLUG)-$Repo.txt"
}

function Write-RepoNotes([string]$Repo) {
  $notes = Get-RepoNotesPath $Repo
  if (-not (Test-Path -LiteralPath $notes)) {
    New-Item -ItemType File -Path $notes -Force | Out-Null
  }
  Set-Content -LiteralPath (Join-Path $script:STORY_DIR ".notespath-$Repo") -Value $notes -NoNewline
  Write-Host "-> notes:  $notes"
}

function Setup-RepoTabs([string]$Ws, [string]$Repo) {
  $wt = Join-Path $script:STORY_DIR $Repo
  $notes = Get-RepoNotesPath $Repo
  $deadline = [DateTime]::UtcNow.AddSeconds(20)
  while ([DateTime]::UtcNow -lt $deadline) {
    $json = Invoke-HerdrJson @('tab', 'list', '--workspace', $Ws)
    $notesTab = Get-TabIdByLabel $json $Ws 'notes'
    $claudeTab = Get-TabIdByLabel $json $Ws 'claude'
    $cursorTab = Get-TabIdByLabel $json $Ws 'cursor'
    $pwshTab = Get-TabIdByLabel $json $Ws 'pwsh'
    if ($notesTab -and $claudeTab -and $cursorTab -and $pwshTab) {
      Invoke-HerdrQuiet @('tab', 'rename', $notesTab, "notes-$($script:ID)-$($script:SLUG)")
      Invoke-HerdrQuiet @('tab', 'rename', $claudeTab, "$Repo claude")
      Invoke-HerdrQuiet @('tab', 'rename', $cursorTab, "$Repo cursor")
      Invoke-HerdrQuiet @('tab', 'rename', $pwshTab, "$Repo pwsh")
      $notesLit = "'" + ($notes -replace "'", "''") + "'"
      Invoke-InTab $Ws $notesTab $wt "micro $notesLit"
      Invoke-InTab $Ws $claudeTab $wt $CLAUDE_CMD
      Invoke-InTab $Ws $cursorTab $wt $CURSOR_CMD
      return
    }
    Start-Sleep -Milliseconds 200
  }
  Write-Warning "timed out waiting for notes/claude/cursor/pwsh tabs in workspace $Ws"
}

function Ask-Gum([string]$Prompt, [string]$Placeholder) {
  & gum input --prompt "$Prompt > " --placeholder $Placeholder
}

# A repo-level problem. Fatal when a human is driving (they asked for exactly
# these repos); counted and reported in non-interactive mode so one bad repo
# cannot abort a cron run - but the run still exits non-zero at the end.
# Writes to the error stream only, so callers can `Repo-Fail ...; return`.
function Repo-Fail([string]$Msg) {
  $script:Failed++
  Write-Error $Msg -ErrorAction Continue
  if (-not $NonInteractive) { exit 1 }
}

function Test-WorktreePresent([string]$Repo) {
  $gitPath = Join-Path $script:STORY_DIR "$Repo\.git"
  if (Test-Path -LiteralPath $gitPath) {
    Write-Host "-> ${Repo}: worktree exists at $(Join-Path $script:STORY_DIR $Repo), skipping"
    $script:Skipped++
    return $true
  }
  return $false
}

function Resolve-WorktreeRoot {
  $cfg = if ($env:HERDR_CONFIG_PATH) { $env:HERDR_CONFIG_PATH } else {
    Join-Path $env:APPDATA 'herdr\config.toml'
  }
  $dir = ''
  if (Test-Path -LiteralPath $cfg) {
    $inSection = $false
    foreach ($line in Get-Content -LiteralPath $cfg) {
      if ($line -match '^\[worktrees\]') { $inSection = $true; continue }
      if ($line -match '^\[') { $inSection = $false; continue }
      if ($inSection -and $line -match '^\s*directory\s*=') {
        $dir = ($line -replace '^[^=]*=\s*', '' -replace '\s+#.*$', '').Trim()
        $quoted = $dir.StartsWith('"')
        $dir = $dir.Trim('"').Trim("'")
        # A TOML basic string escapes backslashes, which is how the README tells
        # you to write a Windows path: "C:\\Users\\me\\source\\worktrees".
        # Un-escape it so the value is a real path rather than one with doubled
        # separators (which then leaks into every message the script prints).
        if ($quoted) { $dir = $dir.Replace('\\', '\') }
        break
      }
    }
  }
  if (-not $dir) { $dir = '~/source/worktrees' }
  if ($dir -eq '~') {
    $dir = $env:USERPROFILE
  } elseif ($dir.StartsWith('~/')) {
    $dir = Join-Path $env:USERPROFILE $dir.Substring(2)
  }
  $dir = $dir.Replace('$HOME', $env:USERPROFILE).Replace('${HOME}', $env:USERPROFILE)
  $dir = $dir.Replace('%USERPROFILE%', $env:USERPROFILE)
  return $dir
}

# ---------------------------------------------------------------------------
# Git: getting the base right
# ---------------------------------------------------------------------------

# Fetch, and MEAN it. A fetch that fails (expired credentials, network, a
# stale index.lock, a concurrent gc) used to be ignored, after which the
# worktree was cut from whatever origin/<default> happened to be - the exact
# "N commits behind" symptom. One retry, then the caller aborts the repo.
function Update-Remote([string]$Src) {
  foreach ($attempt in 1, 2) {
    $label = if ($attempt -eq 1) { '' } else { " (retry $attempt)" }
    Write-Host "-> fetch:  git fetch --prune origin in $Src$label"
    if (Git-Run $Src @('fetch', '--prune', 'origin')) { return $true }
    Write-Warning "git fetch --prune origin failed in $Src (exit $script:GitExit)"
    if ($attempt -eq 1) { Start-Sleep -Seconds 3 }
  }
  return $false
}

# `git fetch` never updates refs/remotes/origin/HEAD, so a clone made before the
# remote's default branch was renamed - or one where the ref was never written -
# keeps pointing at the wrong branch forever. Re-derive it from the remote.
# Best effort: offline, the cached ref (or the fallbacks below) still works.
function Sync-OriginHead([string]$Src) {
  Git-Out $Src @('remote', 'set-head', 'origin', '--auto') | Out-Null
}

# Resolve a ref to a full commit sha, or '' when it does not exist.
function Resolve-Commit([string]$Repo, [string]$Ref) {
  return (Git-Line $Repo @('rev-parse', '--verify', '--quiet', "$Ref^{commit}"))
}

function Get-DefaultBranch([string]$Src) {
  $d = Git-Line $Src @('symbolic-ref', '-q', '--short', 'refs/remotes/origin/HEAD')
  if ($d) { $d = $d -replace '^origin/', '' }
  if (-not $d) {
    foreach ($line in (Git-Out $Src @('ls-remote', '--symref', 'origin', 'HEAD'))) {
      if ("$line" -match '^ref:\s+refs/heads/(\S+)') {
        $d = $Matches[1]
        break
      }
    }
  }
  # Only trust it if the matching remote-tracking ref actually exists: the old
  # blind `main` fallback could name a branch that is real but is NOT the
  # default (or does not exist at all, which herdr then rejects outright).
  if ($d -and (Resolve-Commit $Src "refs/remotes/origin/$d")) { return $d }
  foreach ($candidate in @('main', 'master', 'trunk', 'develop')) {
    if (Resolve-Commit $Src "refs/remotes/origin/$candidate") {
      Write-Warning "origin/HEAD unusable in ${Src}; falling back to origin/$candidate"
      return $candidate
    }
  }
  return ''
}

# Path of the worktree that has $Branch checked out, or '' when it is free.
function Get-BranchWorktreePath([string]$Src, [string]$Branch) {
  $current = ''
  foreach ($line in (Git-Out $Src @('worktree', 'list', '--porcelain'))) {
    $t = "$line"
    if ($t -match '^worktree\s+(.+)$') { $current = $Matches[1].Trim(); continue }
    if ($t -match '^branch\s+(.+)$') {
      if ($Matches[1].Trim() -eq "refs/heads/$Branch") { return $current }
    }
  }
  return ''
}

function Get-CommitCount([string]$Repo, [string]$Range) {
  $n = Git-Line $Repo @('rev-list', '--count', $Range)
  if ($n -match '^\d+$') { return [int]$n }
  return 0
}

# Put the local branch at exactly $Base and return the sha the new worktree must
# end up on ('' means: do not create this worktree).
#
# This is the fix for the reported bug: herdr honours --base only when it has to
# create the branch, so the script guarantees the branch position itself.
function Set-BranchAtBase([string]$Src, [string]$Branch, [string]$Base, [string]$BaseLabel) {
  $existing = Resolve-Commit $Src "refs/heads/$Branch"

  if (-not $existing) {
    if (-not (Git-Run $Src @('branch', '--no-track', $Branch, $Base))) {
      Repo-Fail "could not create branch $Branch at $BaseLabel in $Src"
      return ''
    }
    Write-Host "-> branch: $Branch created at $BaseLabel ($(Get-ShortSha $Base))"
    return $Base
  }

  # An existing branch checked out somewhere else is a hard conflict: herdr
  # cannot check it out twice, and silently reusing it is what produced stale
  # worktrees before.
  $inUse = Get-BranchWorktreePath $Src $Branch
  if ($inUse) {
    Repo-Fail ("branch $Branch is already checked out at $inUse - " +
      'remove that worktree first, or use a different story slug')
    return ''
  }

  if ($existing -eq $Base) {
    Write-Host "-> branch: $Branch already at $BaseLabel ($(Get-ShortSha $Base))"
    return $Base
  }

  $unique = Get-CommitCount $Src "$Base..refs/heads/$Branch"
  $behind = Get-CommitCount $Src "refs/heads/$Branch..$Base"

  if ($unique -eq 0) {
    # Leftover branch with nothing of its own - the common case after a story
    # was removed. Nothing can be lost, so move it to the base.
    if (-not (Git-Run $Src @('branch', '--force', '--no-track', $Branch, $Base))) {
      Repo-Fail "could not move existing branch $Branch to $BaseLabel in $Src"
      return ''
    }
    Write-Host ("-> branch: $Branch was $behind commit(s) behind $BaseLabel " +
      "with no commits of its own - moved to $(Get-ShortSha $Base)")
    return $Base
  }

  if ($env:WT_RESET_BRANCH -eq '1') {
    Write-Warning "WT_RESET_BRANCH=1 - discarding $unique commit(s) on ${Branch}:"
    foreach ($line in (Git-Out $Src @('log', '--oneline', '--no-decorate', "$Base..refs/heads/$Branch"))) {
      Write-Host "     $line"
    }
    if (-not (Git-Run $Src @('branch', '--force', '--no-track', $Branch, $Base))) {
      Repo-Fail "could not reset branch $Branch to $BaseLabel in $Src"
      return ''
    }
    Write-Host "-> branch: $Branch reset to $BaseLabel ($(Get-ShortSha $Base))"
    return $Base
  }

  if ($env:WT_REUSE_BRANCH -eq '1') {
    Write-Warning ("WT_REUSE_BRANCH=1 - keeping existing $Branch at " +
      "$(Get-ShortSha $existing): $unique own commit(s), $behind behind $BaseLabel." +
      " Run 'git merge $BaseLabel' in the worktree to catch up.")
    return $existing
  }

  Repo-Fail (@(
    "branch $Branch already exists in $Src at $(Get-ShortSha $existing) with $unique commit(s)"
    "  that $BaseLabel does not have, and is $behind commit(s) behind it. Refusing to create"
    "  a worktree that would be out of date or to throw those commits away. Either:"
    "    WT_REUSE_BRANCH=1  keep the branch and resume the story on it"
    "    WT_RESET_BRANCH=1  discard its $unique commit(s) and start from $BaseLabel"
    "  or delete it yourself:  git -C `"$Src`" branch -D $Branch"
  ) -join "`n")
  foreach ($line in (Git-Out $Src @('log', '--oneline', '--no-decorate', "$Base..refs/heads/$Branch"))) {
    Write-Host "     $line"
  }
  return ''
}

# `git worktree add` refuses a path that is registered-but-missing (a worktree
# deleted by hand) or one that already has files in it. Prune the administrative
# leftovers and clear a directory that an earlier failed run left empty.
function Initialize-WorktreePath([string]$Src, [string]$Path) {
  Git-Out $Src @('worktree', 'prune') | Out-Null
  if (-not (Test-Path -LiteralPath $Path)) { return $true }
  $entries = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
  if ($entries.Count -eq 0) {
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    Write-Host "-> path:   removed empty leftover directory $Path"
    return $true
  }
  Repo-Fail ("$Path already exists, is not a worktree, and is not empty - " +
    'remove it or use a different story slug')
  return $false
}

# The safety net: whatever herdr did, the worktree must sit on $Expected.
function Assert-WorktreeAt([string]$Wt, [string]$Expected, [string]$Label) {
  $head = Resolve-Commit $Wt 'HEAD'
  if ($head -eq $Expected) {
    Write-Host "-> verify: HEAD $(Get-ShortSha $Expected) == $Label"
    return $true
  }
  Write-Warning ("worktree $Wt is at '$head' but should be at " +
    "$(Get-ShortSha $Expected) ($Label) - repairing")
  $dirty = @(Git-Out $Wt @('status', '--porcelain'))
  if ($dirty.Count -gt 0) {
    Repo-Fail "worktree $Wt is at the wrong commit and has local changes - fix it by hand"
    return $false
  }
  if (-not (Git-Run $Wt @('reset', '--hard', $Expected))) {
    Repo-Fail "could not reset $Wt to $(Get-ShortSha $Expected) ($Label)"
    return $false
  }
  $head = Resolve-Commit $Wt 'HEAD'
  if ($head -ne $Expected) {
    Repo-Fail "worktree $Wt still at '$head' after reset - expected $(Get-ShortSha $Expected)"
    return $false
  }
  Write-Host "-> verify: HEAD repaired to $(Get-ShortSha $Expected) == $Label"
  return $true
}

function Set-PushUpstream([string]$Wt, [string]$Branch) {
  Git-Out $Wt @('config', "branch.$Branch.remote", 'origin') | Out-Null
  Git-Out $Wt @('config', "branch.$Branch.merge", "refs/heads/$Branch") | Out-Null
  Write-Host "-> push:   git push targets origin/$Branch"
}

# ---------------------------------------------------------------------------
# One worktree, one shared code path.
#   development -> $BaseRef = "refs/remotes/origin/<default>"
#   review      -> $BaseRef = "refs/remotes/origin/<branch>"
# ---------------------------------------------------------------------------
function New-Worktree([string]$Repo, [string]$Branch, [string]$BaseKind) {
  if (Test-WorktreePresent $Repo) { return }

  $src = Join-Path $SRC_ROOT $Repo
  if (-not (Test-Path -LiteralPath (Join-Path $src '.git'))) {
    Repo-Fail "missing clone: $src (set SRC_ROOT or clone the repo there)"
    return
  }

  $path = Join-Path $script:STORY_DIR $Repo
  if (-not (Initialize-WorktreePath $src $path)) { return }

  if (-not (Update-Remote $src)) {
    Repo-Fail ("git fetch failed for $Repo - refusing to create a worktree from a " +
      'possibly stale origin. Check credentials/network and re-run.')
    return
  }
  Sync-OriginHead $src

  if ($BaseKind -eq 'default') {
    $def = Get-DefaultBranch $src
    if (-not $def) {
      Repo-Fail "cannot determine the default branch of $src (no usable origin/HEAD)"
      return
    }
    $baseLabel = "origin/$def"
  } else {
    $baseLabel = "origin/$Branch"
  }

  $base = Resolve-Commit $src "refs/remotes/$baseLabel"
  if (-not $base) {
    Repo-Fail "$baseLabel does not exist in $src after fetching - nothing to base $Branch on"
    return
  }
  Write-Host "-> base:   $baseLabel @ $(Get-ShortSha $base)"

  $expected = Set-BranchAtBase $src $Branch $base $baseLabel
  if (-not $expected) { return }

  Write-RepoNotes $Repo

  $created = Invoke-HerdrJson @(
    'worktree', 'create', '--cwd', $src, '--branch', $Branch, '--base', $expected,
    '--path', $path, '--label', "$($script:ID)-$($script:SLUG)", '--no-focus'
  )
  $ws = if ($null -ne $created) { "$($created.result.workspace.workspace_id)" } else { '' }
  if (-not $ws) {
    if ($script:HerdrErr) { Write-Host $script:HerdrErr }
    Repo-Fail "herdr worktree create failed for $Repo"
    return
  }

  if (-not (Assert-WorktreeAt $path $expected $baseLabel)) { return }

  $script:Created++
  Set-PushUpstream $path $Branch

  # Tab decoration is cosmetic: never let it fail an otherwise good worktree.
  try {
    Setup-RepoTabs $ws $Repo
  } catch {
    Write-Warning "worktree for $Repo is ready, but tab setup failed: $_"
  }
}

# --- roots -----------------------------------------------------------------
$WORKTREE_ROOT = Resolve-WorktreeRoot
$SUBFOLDER = $Type
Write-Host "-> worktree root (from herdr [worktrees].directory): $WORKTREE_ROOT"

# --- shared inputs ---------------------------------------------------------
if ($NonInteractive) {
  $script:ID = $env:WT_ID
  $script:SLUG = $env:WT_SLUG
  Write-Host '-> non-interactive (WT_ID/WT_SLUG supplied)'
} else {
  $script:ID = Ask-Gum 'Story id' '12345'
  $script:SLUG = Ask-Gum 'Slug' 'slug-example'
}
if (-not $script:ID -or -not $script:SLUG) {
  Write-Error 'id and slug required'
  exit 1
}

$BRANCH = "$BRANCH_PREFIX/$($script:ID)-$($script:SLUG)"
$TYPE_DIR = Join-Path $WORKTREE_ROOT $SUBFOLDER
$script:STORY_DIR = Join-Path $TYPE_DIR "$($script:ID)-$($script:SLUG)"

New-Item -ItemType Directory -Force -Path $script:STORY_DIR | Out-Null
Write-Host "-> story:  $($script:STORY_DIR)"
Write-Host "-> branch: $BRANCH"

# ===========================================================================
# DEVELOPMENT
# ===========================================================================
if ($Type -eq 'development') {
  if ($NonInteractive) {
    $REPOS = $env:WT_REPOS
    if (-not $REPOS) {
      Write-Error 'WT_REPOS required in non-interactive mode'
      exit 1
    }
  } else {
    $REPOS = Ask-Gum 'Repos (csv)' 'repo-a,repo-b,repo-c'
    if (-not $REPOS) {
      Write-Error 'repos required'
      exit 1
    }
  }

  foreach ($repo in ($REPOS -split ',')) {
    $repo = $repo.Trim()
    if (-not $repo) { continue }
    try {
      New-Worktree $repo $BRANCH 'default'
    } catch {
      $script:Failed++
      Write-Warning "skipped ${repo}: $_"
    }
  }
  Write-Host "OK development ready at $($script:STORY_DIR)"
}

# ===========================================================================
# REVIEW
# ===========================================================================
if ($Type -eq 'review') {
  if ($NonInteractive -and $env:WT_BRANCHES_FILE) {
    $BRANCHES = $env:WT_BRANCHES_FILE
    if (-not (Test-Path -LiteralPath $BRANCHES) -or (Get-Item -LiteralPath $BRANCHES).Length -eq 0) {
      Write-Error "WT_BRANCHES_FILE is empty: $BRANCHES"
      exit 1
    }
    Write-Host "-> branches from WT_BRANCHES_FILE: $BRANCHES"
  } else {
    $BRANCHES = Join-Path $script:STORY_DIR "branches-$($script:ID).txt"
    @"
repo-a:feature/aaron/$($script:ID)-$($script:SLUG)
repo-b:bugfix/$($script:ID)-example
repo-c:feature/aaron/$($script:ID)-$($script:SLUG)
"@ | Set-Content -LiteralPath $BRANCHES -Encoding utf8
    Write-Warning "placeholder branches in $BRANCHES -- replace with az output at work."
  }

  $attempted = 0
  foreach ($raw in (Get-Content -LiteralPath $BRANCHES)) {
    $line = "$raw".Trim()
    if (-not $line -or $line.StartsWith('#')) { continue }
    $idx = $line.IndexOf(':')
    if ($idx -lt 1) { continue }
    $repo = $line.Substring(0, $idx).Trim()
    $branch = $line.Substring($idx + 1).Trim()
    if (-not $repo -or -not $branch) { continue }
    $attempted++
    try {
      New-Worktree $repo $branch 'remote'
    } catch {
      $script:Failed++
      Write-Warning "skipped ${repo}: $_"
    }
  }
  # A branches file that yields nothing usable must not look like a clean run.
  if ($attempted -eq 0) {
    Write-Error "no usable '<repo>:<branch>' lines in $BRANCHES"
    exit 1
  }
  Write-Host "OK review ready at $($script:STORY_DIR)"
}

if ($script:Failed -gt 0) {
  Write-Host "-> $($script:Failed) repo(s) failed - see the errors above"
  exit 1
}
if ($script:Created -eq 0 -and $script:Skipped -gt 0) {
  Write-Host '-> nothing to do: all requested worktrees already exist'
  exit 3
}
# Explicit: falling off the end would leave $LASTEXITCODE holding the status of
# whatever native command ran last, which callers (az-watcher, the ~/bin
# forwarder) read as the script's own result.
exit 0
