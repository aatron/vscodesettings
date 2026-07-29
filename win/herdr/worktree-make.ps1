# make-worktree.ps1
# Create a multi-repo herdr worktree structure for an Azure DevOps story.
# Three types: development, development-windows, and review.
#
# Tabs come from herdr-plus Worktree Auto-Layout (worktree-layout.toml,
# repo = "*"): notes, claude, cursor, pwsh at each worktree root. Layouts cannot
# interpolate the repo/story name, and their tab commands do not reliably start,
# so THIS SCRIPT owns the labels *and* the commands after create.
#   development / review    -> notes, claude, cursor, pwsh
#   development-windows     -> notes + pwsh only (closes claude/cursor)
#
# Non-interactive mode (az-watcher / any automation):
#   Set BOTH WT_ID and WT_SLUG and every prompt is skipped - no gum.
#     WT_ID, WT_SLUG, WT_REPOS, WT_BRANCHES_FILE
#
# Exit codes:
#   0  at least one worktree was created
#   1  bad usage / missing input / nothing could be attempted
#   3  nothing to do - every requested repo already had a worktree
#
$ErrorActionPreference = 'Stop'

# ===========================================================================
# EDIT THESE FOR YOUR MACHINE
# ===========================================================================
$SRC_ROOT = Join-Path $env:USERPROFILE 'source\repos'
$BRANCH_PREFIX = 'feature/aaron'
# Story worktree base comes from Herdr config [worktrees].directory
# Optional override for development-windows (rarely needed on native Windows -
# both types share the herdr worktrees directory). Leave empty to use the same
# root as development.
$WINDOWS_WORKTREE_ROOT = ''
$CLAUDE_CMD = 'claude --permission-mode auto'
$CURSOR_CMD = 'agent --auto-review'

# ===========================================================================
$Type = if ($args.Count -ge 1) { $args[0] } else { '' }
if ($Type -notin @('development', 'development-windows', 'review')) {
  Write-Error "usage: make-worktree.ps1 <development|development-windows|review>"
  exit 1
}

$NonInteractive = ($env:WT_ID -and $env:WT_SLUG)
$script:Created = 0
$script:Skipped = 0

function Need-Cmd([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Write-Error "missing tool: $Name"
    exit 1
  }
}

Need-Cmd herdr
Need-Cmd git
Need-Cmd jq
if (-not $NonInteractive) { Need-Cmd gum }

function Invoke-HerdrJson {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$HerdrArgs)
  $out = & herdr @HerdrArgs 2>$null | Out-String
  return $out
}

function Get-TabIdByLabel([string]$Json, [string]$Ws, [string]$Label) {
  $Json | jq -r --arg ws $Ws --arg label $Label `
    '.result.tabs[]? | select(.workspace_id==$ws and .label==$label) | .tab_id' |
    Select-Object -First 1
}

function Get-PaneIdByTab([string]$Ws, [string]$Tab) {
  $json = Invoke-HerdrJson pane list --workspace $Ws
  $json | jq -r --arg tab $Tab `
    '.result.panes[]? | select(.tab_id==$tab) | .pane_id' |
    Select-Object -First 1
}

function Test-PaneReadyAndIdle([string]$Pane) {
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  $names = ''
  while ([DateTime]::UtcNow -lt $deadline) {
    $info = Invoke-HerdrJson pane process-info --pane $Pane
    $names = ($info | jq -r '.result.process_info.foreground_processes[]?.name' 2>$null) -join "`n"
    if ($names) { break }
    Start-Sleep -Milliseconds 200
  }
  if (-not $names) { return $true }
  foreach ($n in ($names -split "`n")) {
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
  & herdr pane run $pane $full 2>$null | Out-Null
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
    $json = Invoke-HerdrJson tab list --workspace $Ws
    $notesTab = Get-TabIdByLabel $json $Ws 'notes'
    $claudeTab = Get-TabIdByLabel $json $Ws 'claude'
    $cursorTab = Get-TabIdByLabel $json $Ws 'cursor'
    $pwshTab = Get-TabIdByLabel $json $Ws 'pwsh'
    if ($notesTab -and $claudeTab -and $cursorTab -and $pwshTab) {
      & herdr tab rename $notesTab "notes-$($script:ID)-$($script:SLUG)" | Out-Null
      & herdr tab rename $claudeTab "$Repo claude" | Out-Null
      & herdr tab rename $cursorTab "$Repo cursor" | Out-Null
      & herdr tab rename $pwshTab "$Repo pwsh" | Out-Null
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

function Setup-WindowsRepoTabs([string]$Ws, [string]$Repo) {
  $wt = Join-Path $script:STORY_DIR $Repo
  $notes = Get-RepoNotesPath $Repo
  $deadline = [DateTime]::UtcNow.AddSeconds(20)
  while ([DateTime]::UtcNow -lt $deadline) {
    $json = Invoke-HerdrJson tab list --workspace $Ws
    $notesTab = Get-TabIdByLabel $json $Ws 'notes'
    $claudeTab = Get-TabIdByLabel $json $Ws 'claude'
    $cursorTab = Get-TabIdByLabel $json $Ws 'cursor'
    $pwshTab = Get-TabIdByLabel $json $Ws 'pwsh'
    if ($notesTab -and $claudeTab -and $cursorTab -and $pwshTab) {
      & herdr tab close $claudeTab | Out-Null
      & herdr tab close $cursorTab | Out-Null
      & herdr tab rename $notesTab "notes-$($script:ID)-$($script:SLUG)" | Out-Null
      & herdr tab rename $pwshTab "$Repo pwsh" | Out-Null
      $notesLit = "'" + ($notes -replace "'", "''") + "'"
      Invoke-InTab $Ws $notesTab $wt "micro $notesLit"
      return
    }
    Start-Sleep -Milliseconds 200
  }
  Write-Warning "timed out waiting for notes/claude/cursor/pwsh tabs in workspace $Ws"
}

function Ask-Gum([string]$Prompt, [string]$Placeholder) {
  & gum input --prompt "$Prompt > " --placeholder $Placeholder
}

function Repo-Fail([string]$Msg) {
  Write-Error $Msg -ErrorAction Continue
  if ($NonInteractive) { return $false }
  exit 1
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
  if (-not $d) {
    $remote = & git -C $Src ls-remote --symref origin HEAD 2>$null
    foreach ($line in $remote) {
      if ($line -match '^ref:\s+refs/heads/(\S+)') {
        $d = $Matches[1]
        break
      }
    }
  }
  if (-not $d) { $d = 'main' }
  return $d
}

function Set-PushUpstream([string]$Wt, [string]$Branch) {
  & git -C $Wt config "branch.$Branch.remote" origin
  & git -C $Wt config "branch.$Branch.merge" "refs/heads/$Branch"
  Write-Host "-> push:   git push targets origin/$Branch"
}

function New-WorktreeBranch([string]$Repo, [string]$Branch) {
  if (Test-WorktreePresent $Repo) { return }
  $src = Join-Path $SRC_ROOT $Repo
  $gitMarker = Join-Path $src '.git'
  if (-not (Test-Path -LiteralPath $gitMarker)) {
    if (-not (Repo-Fail "missing clone: $src (set SRC_ROOT or clone the repo there)")) { return }
  }
  Write-RepoNotes $Repo
  & git -C $src fetch --prune origin
  $def = Get-DefaultBranch $src
  $path = Join-Path $script:STORY_DIR $Repo
  $out = ''
  try {
    $out = & herdr worktree create --cwd $src --branch $Branch --base "origin/$def" `
      --path $path --label "$($script:ID)-$($script:SLUG)" --no-focus 2>&1 | Out-String
  } catch {
    $out = "$_"
  }
  $ws = ($out | jq -r '.result.workspace.workspace_id // empty' 2>$null)
  if (-not $ws) {
    Write-Host $out
    if (-not (Repo-Fail "herdr worktree create failed for $Repo")) { return }
  }
  $script:Created++
  Set-PushUpstream $path $Branch
  if ($Type -eq 'development-windows') {
    Setup-WindowsRepoTabs $ws $Repo
  } else {
    Setup-RepoTabs $ws $Repo
  }
}

function New-WorktreeExisting([string]$Repo, [string]$Branch) {
  if (Test-WorktreePresent $Repo) { return }
  $src = Join-Path $SRC_ROOT $Repo
  $gitMarker = Join-Path $src '.git'
  if (-not (Test-Path -LiteralPath $gitMarker)) {
    if (-not (Repo-Fail "missing clone: $src (set SRC_ROOT or clone the repo there)")) { return }
  }
  Write-RepoNotes $Repo
  & git -C $src fetch --prune origin
  $path = Join-Path $script:STORY_DIR $Repo
  $out = ''
  try {
    $out = & herdr worktree create --cwd $src --branch $Branch --base "origin/$Branch" `
      --path $path --label "$($script:ID)-$($script:SLUG)" --no-focus 2>&1 | Out-String
  } catch {
    $out = "$_"
  }
  $ws = ($out | jq -r '.result.workspace.workspace_id // empty' 2>$null)
  if (-not $ws) {
    Write-Host $out
    if (-not (Repo-Fail "herdr worktree create failed for $Repo")) { return }
  }
  $script:Created++
  Set-PushUpstream $path $Branch
  Setup-RepoTabs $ws $Repo
}

# --- roots -----------------------------------------------------------------
if ($Type -eq 'development-windows') {
  if ($WINDOWS_WORKTREE_ROOT) {
    $WORKTREE_ROOT = $WINDOWS_WORKTREE_ROOT
  } else {
    $WORKTREE_ROOT = Resolve-WorktreeRoot
  }
  $SUBFOLDER = 'development'
  Write-Host "-> worktree root (Windows): $WORKTREE_ROOT"
} else {
  $WORKTREE_ROOT = Resolve-WorktreeRoot
  $SUBFOLDER = $Type
  Write-Host "-> worktree root (from herdr [worktrees].directory): $WORKTREE_ROOT"
}

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
if ($Type -in @('development', 'development-windows')) {
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
      New-WorktreeBranch $repo $BRANCH
    } catch {
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

  Get-Content -LiteralPath $BRANCHES | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith('#')) { return }
    $idx = $line.IndexOf(':')
    if ($idx -lt 1) { return }
    $repo = $line.Substring(0, $idx).Trim()
    $branch = $line.Substring($idx + 1).Trim()
    if (-not $repo -or -not $branch) { return }
    try {
      New-WorktreeExisting $repo $branch
    } catch {
      Write-Warning "skipped ${repo}: $_"
    }
  }
  Write-Host "OK review ready at $($script:STORY_DIR)"
}

if ($script:Created -eq 0 -and $script:Skipped -gt 0) {
  Write-Host '-> nothing to do: all requested worktrees already exist'
  exit 3
}
