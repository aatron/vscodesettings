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

$WINDOWS_WORKTREE_ROOT = ''

function Need-Cmd([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Write-Error "missing tool: $Name"
    exit 1
  }
}

Need-Cmd herdr
Need-Cmd git
Need-Cmd jq
if ($env:WT_ASSUME_YES -ne '1') { Need-Cmd gum }

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

function Get-DefaultBranch([string]$Src) {
  $d = & git -C $Src symbolic-ref -q --short refs/remotes/origin/HEAD 2>$null
  if ($d) { $d = $d -replace '^origin/', '' }
  if (-not $d) { $d = 'main' }
  return $d
}

function Get-SlugFromStoryName([string]$Name, [string]$Id) {
  $s = $Name.Substring($Id.Length)
  if ($s.StartsWith('-') -or $s.StartsWith('_')) { $s = $s.Substring(1) }
  return $s
}

function Get-WorkspaceIdForPath([string]$Path) {
  $json = & herdr workspace list 2>$null | Out-String
  $norm = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue)
  if ($norm) { $Path = $norm.Path }
  # Compare with both forward and backslash forms.
  $fwd = $Path -replace '\\', '/'
  $json | jq -r --arg p $Path --arg f $fwd '
    .result.workspaces[]? |
    select(.worktree.checkout_path == $p or .worktree.checkout_path == $f) |
    .workspace_id' | Select-Object -First 1
}

function Test-WorktreeDirty([string]$Wt) {
  $status = & git -C $Wt status --porcelain 2>$null
  return [bool]$status
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
$WIN_ROOT = if ($WINDOWS_WORKTREE_ROOT) { $WINDOWS_WORKTREE_ROOT } else { $null }

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
if ($WIN_ROOT) { Add-Glob (Join-Path $WIN_ROOT 'development') }

if ($Candidates.Count -eq 0) {
  Write-Host "No story folder matching ${ID}-* under:"
  Write-Host "  $HERDR_ROOT\development|review"
  if ($WIN_ROOT) { Write-Host "  $WIN_ROOT\development" }
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
$DirtySkipped = 0

foreach ($storyDir in $Candidates) {
  $storyName = Split-Path -Leaf $storyDir
  $slug = Get-SlugFromStoryName $storyName $ID
  $Plan.Add("story ${storyName}:") | Out-Null

  foreach ($dirEnt in (Get-ChildItem -LiteralPath $storyDir -Directory -ErrorAction SilentlyContinue)) {
    $wt = $dirEnt.FullName
    $gitMarker = Join-Path $wt '.git'
    if (-not (Test-Path -LiteralPath $gitMarker)) { continue }
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
    $branch = (& git -C $wt rev-parse --abbrev-ref HEAD 2>$null)
    if (-not $branch) { $branch = '' }
    $primary = ''
    $porcelain = & git -C $wt worktree list --porcelain 2>$null
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

if ($WtDirs.Count -eq 0) {
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
for ($i = 0; $i -lt $WtDirs.Count; $i++) {
  $wt = $WtDirs[$i]
  $repo = $WtRepoNames[$i]
  $branch = $WtBranches[$i]
  $primary = $WtPrimaries[$i]
  $ws = $WtWs[$i]
  $storyDir = $WtStoryDirs[$i]
  $slug = $WtSlugs[$i]

  if ($ws) {
    & herdr worktree remove --workspace $ws --force 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "herdr worktree remove failed for workspace $ws; closing it"
      & herdr workspace close $ws 2>$null | Out-Null
    }
  }

  if (Test-Path -LiteralPath $wt) {
    if ($primary) {
      & git -C $primary worktree remove --force $wt 2>$null
      if ($LASTEXITCODE -ne 0) {
        Write-Warning "git worktree remove failed for $wt; forcing Remove-Item"
        Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue
      }
    } else {
      Write-Warning "no primary clone for $wt; removing dir only"
      Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  if ($primary) {
    & git -C $primary worktree prune 2>$null | Out-Null
    $def = Get-DefaultBranch $primary
    if ($branch -and $branch -ne 'HEAD' -and $branch -ne $def) {
      & git -C $primary branch -D $branch 2>$null
      if ($LASTEXITCODE -ne 0) {
        Write-Warning "could not delete branch $branch in $primary"
      }
    } else {
      Write-Host "  skip: not deleting branch '$(if ($branch) { $branch } else { '<detached>' })' (empty/detached/default)"
    }
  }

  Remove-Item -LiteralPath (Join-Path $storyDir "${ID}-${slug}-${repo}.txt") -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $storyDir ".notespath-$repo") -Force -ErrorAction SilentlyContinue
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
if ($DirtySkipped -gt 0) {
  Write-Host "OK removed $($WtDirs.Count) worktree(s) for story ${ID}; kept $DirtySkipped with uncommitted changes."
} else {
  Write-Host "OK removed $($WtDirs.Count) worktree(s) for story ${ID}${repoNote}."
}
