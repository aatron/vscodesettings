# worktree-remove.ps1
# Delete an entire story by id: for every repo worktree in each matching story
# folder it removes via herdr (with git fallback), deletes the local branch,
# then deletes notes and the story folder.
#
# Two herdr shapes have to be handled, because worktree-make.ps1 changed:
#   * story workspace (current) - ONE plain workspace per story, no worktree
#     metadata, its panes rooted at the story folder. Closed FIRST, and only
#     when every worktree in that story is going away: its agents run at the
#     story root and hold files inside the repos open, so removing checkouts
#     underneath a live pane is what leaves undeletable debris behind.
#   * per-repo worktree workspace (legacy) - one herdr-registered worktree
#     workspace per repo, matched by checkout path. Stories created before the
#     switch still look like this, so `herdr worktree remove` stays.
#
# Environment hooks (used by az-watcher; all optional):
#   WT_ID, WT_ASSUME_YES, WT_REPO, WT_SKIP_DIRTY
#
# Exit codes:
#   0  something was removed
#   3  nothing to do (no matching story folder / no matching repo worktree)
#   5  nothing removed because every match was dirty (WT_SKIP_DIRTY=1)
#
$ErrorActionPreference = 'Stop'

function Need-Cmd([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Write-Error "missing tool: $Name"
    exit 1
  }
}

Need-Cmd herdr
Need-Cmd git
if ($env:WT_ASSUME_YES -ne '1') { Need-Cmd gum }

# ---------------------------------------------------------------------------
# Native-command plumbing.
#
# $ErrorActionPreference = 'Stop' plus a redirected native stderr (2>$null) makes
# Windows PowerShell wrap every stderr line in a NativeCommandError and THROW.
# Removal is full of calls that fail routinely - `herdr worktree remove` hits
# "Permission denied" whenever a pane still holds the directory open, and
# `git branch -D` can refuse - and each throw aborted the whole removal partway
# through, *before* the fallbacks written to handle exactly those cases could
# run. Every native call now goes through these helpers and is judged on its
# exit code.
# ---------------------------------------------------------------------------
$script:NativeExit = 0

function Invoke-Native([string]$Exe, [string[]]$ExeArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $Exe @ExeArgs 2>$null
    $script:NativeExit = $LASTEXITCODE
    if ($null -eq $out) { return @() }
    return @($out)
  } catch {
    $script:NativeExit = 1
    return @()
  } finally { $ErrorActionPreference = $prev }
}

function Invoke-Git([string]$Repo, [string[]]$GitArgs) {
  return (Invoke-Native 'git' (@('-C', $Repo) + $GitArgs))
}

# $true when the command exited 0.
function Test-Git([string]$Repo, [string[]]$GitArgs) {
  Invoke-Git $Repo $GitArgs | Out-Null
  return ($script:NativeExit -eq 0)
}

function Test-Herdr([string[]]$HerdrArgs) {
  Invoke-Native 'herdr' $HerdrArgs | Out-Null
  return ($script:NativeExit -eq 0)
}

# Delete a directory, tolerating a transient holder. On Windows a freshly
# written checkout is routinely locked for a moment by an indexer, a virus
# scanner, or a pane that is still shutting down; one attempt then reporting
# "stuck" turns a wait-half-a-second problem into a failed removal.
# Returns $true when the path is gone.
function Remove-DirRetry([string]$Path) {
  foreach ($attempt in 1..4) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    if ($attempt -lt 4) { Start-Sleep -Milliseconds (250 * $attempt) }
  }
  return (-not (Test-Path -LiteralPath $Path))
}

function Ask-Gum([string]$Prompt, [string]$Placeholder) {
  & gum input --prompt "$Prompt > " --placeholder $Placeholder
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
        $dir = ($line -replace '^[^=]*=\s*', '' -replace '\s+#.*$', '').Trim().Trim('"').Trim("'")
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

# Names of refs that must never be deleted as a story branch. Blindly falling
# back to 'main' was unsafe here: in a repo whose default is something else
# (e.g. trade-central/root) the guard below would not recognise the real default.
function Get-ProtectedBranches([string]$Src) {
  $names = [System.Collections.Generic.List[string]]::new()
  foreach ($line in (Invoke-Git $Src @('symbolic-ref', '-q', '--short', 'refs/remotes/origin/HEAD'))) {
    $d = "$line".Trim() -replace '^origin/', ''
    if ($d) { $names.Add($d) | Out-Null }
  }
  foreach ($line in (Invoke-Git $Src @('ls-remote', '--symref', 'origin', 'HEAD'))) {
    if ("$line" -match '^ref:\s+refs/heads/(\S+)') { $names.Add($Matches[1]) | Out-Null }
  }
  foreach ($n in @('main', 'master', 'trunk', 'develop', 'HEAD')) { $names.Add($n) | Out-Null }
  return $names
}

function Get-SlugFromStoryName([string]$Name, [string]$Id) {
  $s = $Name.Substring($Id.Length)
  if ($s.StartsWith('-') -or $s.StartsWith('_')) { $s = $s.Substring(1) }
  return $s
}

# herdr reports paths with either separator, and sometimes with doubled
# backslashes; Windows paths are also case-insensitive. Compare on this form.
function Get-PathKey([string]$Path) {
  if (-not $Path) { return '' }
  return ($Path -replace '\\+', '/').TrimEnd('/').ToLowerInvariant()
}

function Get-WorkspaceList {
  $lines = Invoke-Native 'herdr' @('workspace', 'list')
  if ($lines.Count -eq 0) { return @() }
  $obj = $null
  try { $obj = ($lines -join "`n") | ConvertFrom-Json } catch { return @() }
  return @($obj.result.workspaces)
}

# Legacy shape: the herdr-registered worktree workspace for one repo checkout.
function Get-WorkspaceIdForPath([string]$Path) {
  $norm = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue)
  if ($norm) { $Path = $norm.Path }
  $want = Get-PathKey $Path
  if (-not $want) { return '' }
  foreach ($w in (Get-WorkspaceList)) {
    if ($null -eq $w -or $null -eq $w.worktree) { continue }
    if ((Get-PathKey "$($w.worktree.checkout_path)") -eq $want) { return "$($w.workspace_id)" }
  }
  return ''
}

# Current shape: the story's own workspace. Identified by the cwd of its panes,
# not by its label - a label is a display name the user can change, and a
# development story and a review story of the same id legitimately share one.
function Get-StoryWorkspaceId([string]$StoryDir) {
  $norm = (Resolve-Path -LiteralPath $StoryDir -ErrorAction SilentlyContinue)
  if ($norm) { $StoryDir = $norm.Path }
  $want = Get-PathKey $StoryDir
  if (-not $want) { return '' }
  foreach ($w in (Get-WorkspaceList)) {
    # A worktree workspace belongs to a repo checkout, never to the story root.
    if ($null -eq $w -or $null -ne $w.worktree) { continue }
    $ws = "$($w.workspace_id)"
    $lines = Invoke-Native 'herdr' @('pane', 'list', '--workspace', $ws)
    if ($lines.Count -eq 0) { continue }
    $panes = $null
    try { $panes = (($lines -join "`n") | ConvertFrom-Json).result.panes } catch { continue }
    foreach ($p in @($panes)) {
      if ($null -eq $p) { continue }
      $have = Get-PathKey "$($p.cwd)"
      # "under" as well as "equal": a pane the user cd'd into one of the repos
      # still belongs to this story.
      if ($have -eq $want -or $have.StartsWith("$want/")) { return $ws }
    }
  }
  return ''
}

function Test-WorktreeDirty([string]$Wt) {
  $status = Invoke-Git $Wt @('status', '--porcelain')
  if ($script:NativeExit -ne 0) {
    # Cannot tell -> treat as dirty so WT_SKIP_DIRTY errs on the side of keeping.
    Write-Warning "could not read git status in $Wt; treating it as dirty"
    return $true
  }
  foreach ($line in $status) { if ("$line".Trim()) { return $true } }
  return $false
}

# --- inputs ----------------------------------------------------------------
$ID = if ($args.Count -ge 1 -and $args[0]) { $args[0] } elseif ($env:WT_ID) { $env:WT_ID } else { '' }
if (-not $ID) {
  $ID = Ask-Gum 'Story id' '12345'
}
if (-not $ID) {
  Write-Error 'story id required'
  exit 1
}

$HERDR_ROOT = Resolve-WorktreeRoot

$Candidates = [System.Collections.Generic.List[string]]::new()

function Add-Candidate([string]$D) {
  if (-not (Test-Path -LiteralPath $D -PathType Container)) { return }
  $full = (Resolve-Path -LiteralPath $D).Path
  if ($Candidates -contains $full) { return }
  $Candidates.Add($full) | Out-Null
}

function Add-Glob([string]$Base) {
  if (-not (Test-Path -LiteralPath $Base -PathType Container)) { return }
  Get-ChildItem -LiteralPath $Base -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "${ID}-*" -or $_.Name -like "${ID}_*" } |
    ForEach-Object { Add-Candidate $_.FullName }
}

Add-Glob (Join-Path $HERDR_ROOT 'development')
Add-Glob (Join-Path $HERDR_ROOT 'review')

if ($Candidates.Count -eq 0) {
  Write-Host "No story folder matching ${ID}-* under:"
  Write-Host "  $HERDR_ROOT\development|review"
  exit 3
}

# --- plan ------------------------------------------------------------------
$Plan = [System.Collections.Generic.List[string]]::new()
$WtDirs = [System.Collections.Generic.List[string]]::new()
$WtRepoNames = [System.Collections.Generic.List[string]]::new()
$WtBranches = [System.Collections.Generic.List[string]]::new()
$WtPrimaries = [System.Collections.Generic.List[string]]::new()
$WtWs = [System.Collections.Generic.List[string]]::new()
$WtStoryDirs = [System.Collections.Generic.List[string]]::new()
$WtSlugs = [System.Collections.Generic.List[string]]::new()
$Leftovers = [System.Collections.Generic.List[string]]::new()
# Story workspaces to close up front (parallel lists: story dir / workspace id).
$StoryWsDirs = [System.Collections.Generic.List[string]]::new()
$StoryWsIds = [System.Collections.Generic.List[string]]::new()
$DirtySkipped = 0
$Stuck = 0
$RemovedCount = 0

foreach ($storyDir in $Candidates) {
  $storyName = Split-Path -Leaf $storyDir
  $slug = Get-SlugFromStoryName $storyName $ID
  $Plan.Add("story ${storyName}:") | Out-Null
  # Worktrees this story has, versus the ones this run will take out. The story
  # workspace is only closed when those two agree - a WT_REPO-scoped removal, or
  # one held back by WT_SKIP_DIRTY, leaves the story (and its agents) alive.
  $wtTotal = 0
  $wtRemoving = 0

  foreach ($dirEnt in (Get-ChildItem -LiteralPath $storyDir -Directory -ErrorAction SilentlyContinue)) {
    $wt = $dirEnt.FullName
    $gitMarker = Join-Path $wt '.git'
    if (-not (Test-Path -LiteralPath $gitMarker)) {
      # Not a worktree. An EMPTY directory is the debris a half-finished removal
      # leaves behind (herdr unregisters the worktree, then cannot delete the
      # folder because a pane still holds it); collect it so the story can be
      # finished off. Anything with content in it is left strictly alone.
      if (-not $env:WT_REPO -or $dirEnt.Name -eq $env:WT_REPO) {
        if (@(Get-ChildItem -LiteralPath $wt -Force -ErrorAction SilentlyContinue).Count -eq 0) {
          $Leftovers.Add($wt) | Out-Null
          $Plan.Add("  leftover $wt (empty, not a worktree - will delete)") | Out-Null
        } else {
          $Plan.Add("  keep     $wt (not a worktree, and not empty)") | Out-Null
        }
      }
      continue
    }
    $repo = $dirEnt.Name
    $wtTotal++
    if ($env:WT_REPO -and $repo -ne $env:WT_REPO) {
      $Plan.Add("  keep     $wt (not $($env:WT_REPO))") | Out-Null
      continue
    }
    if ($env:WT_SKIP_DIRTY -eq '1' -and (Test-WorktreeDirty $wt)) {
      $Plan.Add("  KEEP     $wt (uncommitted/untracked changes)") | Out-Null
      $DirtySkipped++
      continue
    }
    $branch = ''
    foreach ($line in (Invoke-Git $wt @('rev-parse', '--abbrev-ref', 'HEAD'))) {
      $t = "$line".Trim()
      if ($t) { $branch = $t; break }
    }
    $primary = ''
    $porcelain = Invoke-Git $wt @('worktree', 'list', '--porcelain')
    foreach ($line in $porcelain) {
      if ($line -match '^worktree\s+(.+)$') {
        $primary = $Matches[1]
        break
      }
    }
    $ws = ''
    try { $ws = Get-WorkspaceIdForPath $wt } catch { $ws = '' }
    $wtRemoving++
    $WtDirs.Add($wt) | Out-Null
    $WtRepoNames.Add($repo) | Out-Null
    $WtBranches.Add($branch) | Out-Null
    $WtPrimaries.Add($primary) | Out-Null
    $WtWs.Add($(if ($ws) { $ws } else { '' })) | Out-Null
    $WtStoryDirs.Add($storyDir) | Out-Null
    $WtSlugs.Add($slug) | Out-Null
    $Plan.Add("  worktree $wt") | Out-Null
    $Plan.Add("    branch  $(if ($branch) { $branch } else { '<detached>' }) (in $(if ($primary) { $primary } else { '<unknown clone>' }))") | Out-Null
    $Plan.Add("    notes   $storyDir\${ID}-${slug}-${repo}.txt") | Out-Null
    if ($ws) { $Plan.Add("    herdr   remove worktree + workspace $ws") | Out-Null }
  }

  if ($wtRemoving -eq $wtTotal) {
    $sws = ''
    try { $sws = Get-StoryWorkspaceId $storyDir } catch { $sws = '' }
    if ($sws) {
      $StoryWsDirs.Add($storyDir) | Out-Null
      $StoryWsIds.Add($sws) | Out-Null
      $Plan.Add("  herdr    close story workspace $sws (notes/claude/cursor/pwsh)") | Out-Null
    }
  } elseif ($wtTotal -gt 0) {
    $Plan.Add("  herdr    story workspace left open ($($wtTotal - $wtRemoving) worktree(s) staying)") | Out-Null
  }

  if (-not $env:WT_REPO) {
    $typeDir = Split-Path -Parent $storyDir
    Get-ChildItem -LiteralPath $typeDir -Filter "${ID}-${slug}-*.txt" -File -ErrorAction SilentlyContinue |
      ForEach-Object { $Plan.Add("  notes    $($_.FullName)") | Out-Null }
  }
  $Plan.Add("  folder   $storyDir (only once no worktrees remain in it)") | Out-Null
}

if ($WtDirs.Count -eq 0 -and $Leftovers.Count -eq 0) {
  $Plan | ForEach-Object { Write-Host $_ }
  if ($DirtySkipped -gt 0) {
    Write-Host "Nothing removed for story ${ID}: $DirtySkipped worktree(s) have uncommitted changes."
    exit 5
  }
  $repoNote = if ($env:WT_REPO) { " (repo $($env:WT_REPO))" } else { '' }
  Write-Host "Nothing to remove for story ${ID}${repoNote}."
  exit 3
}

$repoOnly = if ($env:WT_REPO) { ", repo $($env:WT_REPO) only" } else { '' }
Write-Host "About to DELETE story id ${ID}${repoOnly} ($($Candidates.Count) folder(s)):"
$Plan | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host 'WARNING: this deletes the worktree directories themselves - including any'
Write-Host 'uncommitted changes and untracked files inside them - plus their local'
Write-Host 'branches, herdr workspaces, and notes files.'
Write-Host ''

if ($env:WT_ASSUME_YES -eq '1') {
  Write-Host 'WT_ASSUME_YES=1 - skipping confirmation'
} else {
  & gum confirm 'Delete all worktrees and files listed above? This cannot be undone.'
  if ($LASTEXITCODE -ne 0) {
    Write-Host 'aborted.'
    exit 0
  }
}

# --- execute ---------------------------------------------------------------
# Close each story's own workspace BEFORE touching any checkout. Its tabs run at
# the story root, so claude/cursor there hold files inside the repos open; pull
# the checkouts out from under them and `git worktree remove` fails on locked
# files, leaving exactly the half-deleted debris this script then has to mop up.
for ($i = 0; $i -lt $StoryWsIds.Count; $i++) {
  $sws = $StoryWsIds[$i]
  $sname = Split-Path -Leaf $StoryWsDirs[$i]
  if (Test-Herdr @('workspace', 'close', $sws)) {
    Write-Host "-> closed herdr workspace $sws ($sname)"
  } else {
    Write-Warning "could not close herdr workspace $sws ($sname); carrying on"
  }
}
# Panes do not die the instant the workspace closes; give their handles a moment.
if ($StoryWsIds.Count -gt 0) { Start-Sleep -Milliseconds 500 }

# Empty non-worktree debris first, so the story folder can actually go away.
foreach ($leftover in $Leftovers) {
  $lws = ''
  try { $lws = Get-WorkspaceIdForPath $leftover } catch { $lws = '' }
  if ($lws) { Test-Herdr @('workspace', 'close', $lws) | Out-Null }
  if (Remove-DirRetry $leftover) {
    Write-Host "-> removed leftover directory $leftover"
  } else {
    Write-Warning "could not delete leftover directory $leftover"
    $Stuck++
  }
}

for ($i = 0; $i -lt $WtDirs.Count; $i++) {
  $wt = $WtDirs[$i]
  $repo = $WtRepoNames[$i]
  $branch = $WtBranches[$i]
  $primary = $WtPrimaries[$i]
  $ws = $WtWs[$i]
  $storyDir = $WtStoryDirs[$i]
  $slug = $WtSlugs[$i]

  if ($ws) {
    # Fails routinely (a pane still has the directory open) - that is what the
    # close-and-carry-on fallback is for, so it must not be able to throw.
    if (-not (Test-Herdr @('worktree', 'remove', '--workspace', $ws, '--force'))) {
      Write-Warning "herdr worktree remove failed for workspace $ws; closing it"
      Test-Herdr @('workspace', 'close', $ws) | Out-Null
    }
  }

  if (Test-Path -LiteralPath $wt) {
    if ($primary) {
      if (-not (Test-Git $primary @('worktree', 'remove', '--force', $wt))) {
        Write-Warning "git worktree remove failed for $wt; forcing Remove-Item"
        Remove-DirRetry $wt | Out-Null
      }
    } else {
      Write-Warning "no primary clone for $wt; removing dir only"
      Remove-DirRetry $wt | Out-Null
    }
  }
  # git may report success yet leave the directory behind if a file was locked.
  if (Test-Path -LiteralPath $wt) { Remove-DirRetry $wt | Out-Null }

  # Report honestly if the directory survived all of that, rather than going on
  # to delete the branch and the notes as though the worktree were gone.
  if (Test-Path -LiteralPath $wt) {
    Write-Warning ("could not delete $wt (something still has it open - a pane, " +
      'an editor, or a running agent). Close it and re-run; leaving the branch ' +
      'and notes in place.')
    $Stuck++
    continue
  }

  if ($primary) {
    Test-Git $primary @('worktree', 'prune') | Out-Null
    $protected = Get-ProtectedBranches $primary
    if ($branch -and $branch -ne 'HEAD' -and -not $protected.Contains($branch)) {
      if (-not (Test-Git $primary @('branch', '-D', $branch))) {
        Write-Warning "could not delete branch $branch in $primary (it will be reused by a future story of the same name, and worktree-make will fast-forward it)"
      }
    } else {
      Write-Host "  skip: not deleting branch '$(if ($branch) { $branch } else { '<detached>' })' (empty/detached/protected)"
    }
  }

  Remove-Item -LiteralPath (Join-Path $storyDir "${ID}-${slug}-${repo}.txt") -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $storyDir ".notespath-$repo") -Force -ErrorAction SilentlyContinue
  $RemovedCount++
}

function Test-StoryHasWorktrees([string]$StoryDir) {
  foreach ($d in (Get-ChildItem -LiteralPath $StoryDir -Directory -ErrorAction SilentlyContinue)) {
    if (Test-Path -LiteralPath (Join-Path $d.FullName '.git')) { return $true }
  }
  return $false
}

foreach ($storyDir in $Candidates) {
  $storyName = Split-Path -Leaf $storyDir
  $slug = Get-SlugFromStoryName $storyName $ID
  $typeDir = Split-Path -Parent $storyDir
  if (Test-StoryHasWorktrees $storyDir) {
    Write-Host "-> keeping $storyDir (worktrees still present)"
    continue
  }
  Get-ChildItem -LiteralPath $typeDir -Filter "${ID}-${slug}-*.txt" -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
  if ($storyName -like "${ID}-*" -or $storyName -like "${ID}_*") {
    # Retry: the story workspace was closed moments ago and its panes may still
    # be letting go of the folder they were rooted in.
    if (Remove-DirRetry $storyDir) {
      Write-Host "-> removed folder $storyDir"
    } else {
      Write-Warning "could not delete story folder $storyDir (something still has it open)"
      $Stuck++
    }
  }
}

$repoNote = if ($env:WT_REPO) { " (repo $($env:WT_REPO))" } else { '' }
$leftNote = if ($Leftovers.Count -gt 0) { " (plus $($Leftovers.Count) empty leftover dir(s))" } else { '' }
if ($DirtySkipped -gt 0) {
  Write-Host "OK removed $RemovedCount worktree(s) for story ${ID}${leftNote}; kept $DirtySkipped with uncommitted changes."
} else {
  Write-Host "OK removed $RemovedCount worktree(s) for story ${ID}${repoNote}${leftNote}."
}
# A worktree that could not be deleted must not report success: the story is
# still half there, and a later worktree-make would trip over it.
if ($Stuck -gt 0) {
  Write-Host "-> $Stuck worktree(s) could not be deleted - see the warnings above"
  exit 1
}
# Explicit: without this, $LASTEXITCODE still holds the status of the last native
# command run above (e.g. a benign `git branch -D` that could not delete a
# branch), and az-watcher reads that as "worktree-remove failed".
exit 0
