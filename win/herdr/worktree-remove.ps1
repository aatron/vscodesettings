# worktree-remove.ps1
# Delete an entire story by id: for every repo worktree in each matching story
# folder it removes via herdr (with git fallback), deletes the local branch,
# then deletes notes and the story folder.
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

function Get-WorkspaceIdForPath([string]$Path) {
  $lines = Invoke-Native 'herdr' @('workspace', 'list')
  if ($lines.Count -eq 0) { return '' }
  $obj = $null
  try { $obj = ($lines -join "`n") | ConvertFrom-Json } catch { return '' }
  $norm = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue)
  if ($norm) { $Path = $norm.Path }
  # herdr reports checkout_path with either separator, and sometimes with
  # doubled backslashes; compare on a normalised form.
  $want = ($Path -replace '\\', '/').TrimEnd('/')
  foreach ($w in @($obj.result.workspaces)) {
    if ($null -eq $w -or $null -eq $w.worktree) { continue }
    $have = ("$($w.worktree.checkout_path)" -replace '\\+', '/').TrimEnd('/')
    if ($have -eq $want) { return "$($w.workspace_id)" }
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
$DirtySkipped = 0
$Stuck = 0
$RemovedCount = 0

foreach ($storyDir in $Candidates) {
  $storyName = Split-Path -Leaf $storyDir
  $slug = Get-SlugFromStoryName $storyName $ID
  $Plan.Add("story ${storyName}:") | Out-Null

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
    Remove-Item -LiteralPath $storyDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "-> removed folder $storyDir"
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
