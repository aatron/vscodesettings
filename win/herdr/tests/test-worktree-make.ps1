# Test harness for win/herdr/worktree-make.ps1
# Builds a throwaway upstream + clone per scenario, points a copy of the real
# script at it (SRC_ROOT) and at a throwaway herdr [worktrees].directory, runs
# it non-interactively, and asserts on the resulting worktree.
$ErrorActionPreference = 'Stop'

$FixtureMarker = 'herdr-wt-tests'
$Base = Join-Path ([IO.Path]::GetTempPath()) "$FixtureMarker\$PID\make"
$RealScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'worktree-make.ps1'
$script:Run = 0
$Root = ''; $Script = ''; $Repos = ''; $Trees = ''; $Cfg = ''
$script:Pass = 0
$script:Fail = 0
$script:Names = @()

function Git([string]$Repo, [string[]]$A) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & git.exe -C $Repo @A 2>$null; $global:GX = $LASTEXITCODE; return @($o) }
  finally { $ErrorActionPreference = $prev }
}
function GitLine([string]$Repo, [string[]]$A) {
  $o = Git $Repo $A
  if ($global:GX -ne 0) { return '' }
  foreach ($l in $o) { $t = "$l".Trim(); if ($t) { return $t } }
  return ''
}

function Reset-Fixture {
  # Close the workspaces this harness created, then move to a brand-new
  # directory: herdr panes keep handles open on old worktrees, so reusing one
  # path makes cleanup (not the code under test) the thing that fails.
  Close-Workspaces
  $script:Run++
  $script:Root = Join-Path $Base "run$($script:Run)"
  $script:Script = Join-Path $script:Root 'make-worktree.ps1'
  $script:Repos = Join-Path $script:Root 'repos'
  $script:Trees = Join-Path $script:Root 'worktrees'
  $script:Cfg = Join-Path $script:Root 'config.toml'
  $Root = $script:Root; $Script = $script:Script
  $Repos = $script:Repos; $Trees = $script:Trees; $Cfg = $script:Cfg
  New-Item -ItemType Directory -Force -Path $Root, $Repos, $Trees | Out-Null
  # TOML basic string, backslashes escaped exactly as the README tells the user
  # to write them: directory = "C:\\Users\\me\\source\\worktrees"
  Set-Content -LiteralPath $Cfg -Encoding utf8 -Value @(
    '[worktrees]'
    ('directory = "' + $Trees.Replace('\', '\\') + '"')
  )
  # A copy of the real script with SRC_ROOT repointed at the fixture.
  $lines = Get-Content -LiteralPath $RealScript
  $out = foreach ($l in $lines) {
    if ($l -match '^\$SRC_ROOT = ') { "`$SRC_ROOT = '$Repos'" } else { $l }
  }
  Set-Content -LiteralPath $Script -Value $out -Encoding utf8
}

# upstream bare repo + a clone under $Repos, upstream advanced past the clone.
function New-Repo([string]$Name, [string]$DefBranch, [int]$Extra) {
  $up = Join-Path $Root "$Name.git"
  $work = Join-Path $Root "$Name.work"
  $clone = Join-Path $Repos $Name
  Git $Root @('init', '-q', '--bare', $up) | Out-Null
  Git $up @('symbolic-ref', 'HEAD', "refs/heads/$DefBranch") | Out-Null
  Git $Root @('init', '-q', $work) | Out-Null
  Git $work @('config', 'user.email', 't@t.t') | Out-Null
  Git $work @('config', 'user.name', 'T') | Out-Null
  Set-Content -LiteralPath (Join-Path $work 'f.txt') -Value 'base'
  Git $work @('add', '-A') | Out-Null
  Git $work @('commit', '-qm', 'c1') | Out-Null
  Git $work @('branch', '-M', $DefBranch) | Out-Null
  Git $work @('remote', 'add', 'origin', $up) | Out-Null
  Git $work @('push', '-q', '-u', 'origin', $DefBranch) | Out-Null
  Git $Root @('clone', '-q', $up, $clone) | Out-Null
  Git $clone @('config', 'user.email', 't@t.t') | Out-Null
  Git $clone @('config', 'user.name', 'T') | Out-Null
  for ($i = 1; $i -le $Extra; $i++) {
    Add-Content -LiteralPath (Join-Path $work 'f.txt') -Value "up$i"
    Git $work @('commit', '-qam', "upstream$i") | Out-Null
  }
  if ($Extra -gt 0) { Git $work @('push', '-q', 'origin', $DefBranch) | Out-Null }
  return [pscustomobject]@{
    Name = $Name; Up = $up; Work = $work; Clone = $clone; Def = $DefBranch
    Tip = (GitLine $work @('rev-parse', 'HEAD'))
  }
}

function Invoke-Make([string]$Type, [hashtable]$Env) {
  $saved = @{}
  foreach ($k in $Env.Keys) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
    [Environment]::SetEnvironmentVariable($k, $Env[$k])
  }
  $savedCfg = $env:HERDR_CONFIG_PATH
  $env:HERDR_CONFIG_PATH = $Cfg
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script $Type 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
  } finally {
    $ErrorActionPreference = $prevEap
    foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    $env:HERDR_CONFIG_PATH = $savedCfg
  }
}

# Close every workspace this harness created. Matching is by PATH, not label:
# herdr does not always keep the --label we passed, so a label filter silently
# leaves fixture workspaces behind in the user's real herdr session.
#
# Both shapes have to be swept. worktree-make now creates a PLAIN workspace per
# story (no worktree metadata, panes rooted at the story folder) - matching only
# on .worktree, as this did originally, leaked one of those per test run.
function Close-Workspaces {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $json = (& herdr workspace list 2>$null | Out-String)
    if (-not $json) { return }
    $obj = $null
    try { $obj = $json | ConvertFrom-Json } catch { return }
    # Match on the fixture marker rather than the full path: herdr normalises
    # separators inconsistently, and the marker appears in neither a real repo
    # nor a real worktree.
    foreach ($w in @($obj.result.workspaces)) {
      if ($null -eq $w) { continue }
      $paths = @()
      if ($null -ne $w.worktree) {
        $paths = @("$($w.worktree.repo_root)", "$($w.worktree.checkout_path)")
      } else {
        # A plain workspace only reveals where it lives through its panes.
        $pj = (& herdr pane list --workspace $w.workspace_id 2>$null | Out-String)
        if ($pj) {
          try { $paths = @(($pj | ConvertFrom-Json).result.panes | ForEach-Object { "$($_.cwd)" }) } catch { }
        }
      }
      $isMine = $false
      foreach ($p in $paths) { if ($p -like "*$FixtureMarker*") { $isMine = $true } }
      if (-not $isMine) { continue }
      if ($null -ne $w.worktree) {
        & herdr worktree remove --workspace $w.workspace_id --force 2>$null | Out-Null
      }
      & herdr workspace close $w.workspace_id 2>$null | Out-Null
    }
  } catch { } finally { $ErrorActionPreference = $prev }
}

# Workspaces whose panes sit at (or under) $Path. Used to assert the story
# topology: exactly one workspace per story, with the four story tabs.
function Get-FixtureWorkspaces([string]$Path) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $found = @()
  try {
    $json = (& herdr workspace list 2>$null | Out-String)
    if (-not $json) { return @() }
    $obj = $null
    try { $obj = $json | ConvertFrom-Json } catch { return @() }
    $want = ($Path -replace '\\+', '/').TrimEnd('/').ToLowerInvariant()
    foreach ($w in @($obj.result.workspaces)) {
      if ($null -eq $w -or $null -ne $w.worktree) { continue }
      $pj = (& herdr pane list --workspace $w.workspace_id 2>$null | Out-String)
      if (-not $pj) { continue }
      $panes = @()
      try { $panes = @(($pj | ConvertFrom-Json).result.panes) } catch { continue }
      foreach ($p in $panes) {
        if ($null -eq $p) { continue }
        $have = ("$($p.cwd)" -replace '\\+', '/').TrimEnd('/').ToLowerInvariant()
        if ($have -eq $want -or $have.StartsWith("$want/")) { $found += $w; break }
      }
    }
  } catch { } finally { $ErrorActionPreference = $prev }
  return @($found)
}

# herdr-registered worktree workspaces whose checkout sits inside $Path. These
# are what `herdr worktree create` used to leave behind - one per repo, each
# nested under its primary clone in the sidebar. There should now be none.
function Get-WorktreeWorkspacesUnder([string]$Path) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $found = @()
  try {
    $json = (& herdr workspace list 2>$null | Out-String)
    if (-not $json) { return @() }
    $obj = $null
    try { $obj = $json | ConvertFrom-Json } catch { return @() }
    $want = ($Path -replace '\\+', '/').TrimEnd('/').ToLowerInvariant()
    foreach ($w in @($obj.result.workspaces)) {
      if ($null -eq $w -or $null -eq $w.worktree) { continue }
      $have = ("$($w.worktree.checkout_path)" -replace '\\+', '/').TrimEnd('/').ToLowerInvariant()
      if ($have.StartsWith("$want/")) { $found += $w }
    }
  } catch { } finally { $ErrorActionPreference = $prev }
  return @($found)
}

function Get-TabLabels([string]$Ws) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $json = (& herdr tab list --workspace $Ws 2>$null | Out-String)
    if (-not $json) { return @() }
    return @(($json | ConvertFrom-Json).result.tabs | ForEach-Object { "$($_.label)" })
  } catch { return @() } finally { $ErrorActionPreference = $prev }
}

function Check([string]$Name, [bool]$Ok, [string]$Detail) {
  if ($Ok) {
    $script:Pass++
    Write-Host "  PASS  $Name" -ForegroundColor Green
  } else {
    $script:Fail++
    $script:Names += $Name
    Write-Host "  FAIL  $Name  :: $Detail" -ForegroundColor Red
  }
}

function Story([string]$Id, [string]$Slug, [string]$Repo, [string]$Type = 'development') {
  $sub = if ($Type -eq 'review') { 'review' } else { 'development' }
  Join-Path (Join-Path (Join-Path $Trees $sub) "$Id-$Slug") $Repo
}

Write-Host ''
Write-Host '================ worktree-make.ps1 test run ================'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '1. happy path: new branch lands on the LATEST default branch'
Reset-Fixture
$r = New-Repo 'mono' 'trade-central/root' 4
$res = Invoke-Make 'development' @{ WT_ID = '99001'; WT_SLUG = 'zz-happy'; WT_REPOS = 'mono' }
$wt = Story '99001' 'zz-happy' 'mono'
$head = GitLine $wt @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == upstream tip' ($head -eq $r.Tip) "head=$head want=$($r.Tip)`n$($res.Out)"
Check 'branch name correct' ((GitLine $wt @('rev-parse', '--abbrev-ref', 'HEAD')) -eq 'feature/aaron/99001-zz-happy') 'branch'
Check 'push upstream is own branch' `
  ((GitLine $wt @('config', '--get', 'branch.feature/aaron/99001-zz-happy.merge')) -eq 'refs/heads/feature/aaron/99001-zz-happy') 'upstream'
Check 'verify line printed' ($res.Out -match 'verify: HEAD') 'no verify line'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '2. stale remote-tracking ref is refreshed by the fetch'
Reset-Fixture
$r = New-Repo 'mono' 'main' 5
# roll the clone''s origin/main back to the first commit, as a broken/skipped fetch would leave it
$first = GitLine $r.Clone @('rev-list', '--max-parents=0', 'HEAD')
Git $r.Clone @('update-ref', 'refs/remotes/origin/main', $first) | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99002'; WT_SLUG = 'zz-stale'; WT_REPOS = 'mono' }
$head = GitLine (Story '99002' 'zz-stale' 'mono') @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == upstream tip (not the stale ref)' ($head -eq $r.Tip) "head=$head want=$($r.Tip)`n$($res.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '3. THE BUG: leftover branch with no unique commits is moved to the base'
Reset-Fixture
$r = New-Repo 'mono' 'main' 6
$old = GitLine $r.Clone @('rev-parse', 'origin/main')   # stale, pre-fetch tip
Git $r.Clone @('branch', 'feature/aaron/99003-zz-left', $old) | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99003'; WT_SLUG = 'zz-left'; WT_REPOS = 'mono' }
$head = GitLine (Story '99003' 'zz-left' 'mono') @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == upstream tip (was the stale branch tip before the fix)' ($head -eq $r.Tip) "head=$head want=$($r.Tip)`n$($res.Out)"
Check 'reported the move' ($res.Out -match 'no commits of its own') 'no move message'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '4. leftover branch WITH unique commits: refuse, create nothing'
Reset-Fixture
$r = New-Repo 'mono' 'main' 3
$old = GitLine $r.Clone @('rev-parse', 'origin/main')
Git $r.Clone @('branch', 'feature/aaron/99004-zz-work', $old) | Out-Null
# give the leftover branch a commit of its own, without checking it out
$tree = GitLine $r.Clone @('rev-parse', "$old^{tree}")
$newc = GitLine $r.Clone @('commit-tree', $tree, '-p', $old, '-m', 'my local work')
Git $r.Clone @('update-ref', 'refs/heads/feature/aaron/99004-zz-work', $newc) | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99004'; WT_SLUG = 'zz-work'; WT_REPOS = 'mono' }
Check 'exit 1' ($res.Code -eq 1) "exit=$($res.Code)`n$($res.Out)"
Check 'no worktree created' (-not (Test-Path -LiteralPath (Join-Path (Story '99004' 'zz-work' 'mono') '.git'))) 'worktree exists'
Check 'explains the overrides' (($res.Out -match 'WT_REUSE_BRANCH') -and ($res.Out -match 'WT_RESET_BRANCH')) 'no override hint'
Check 'branch left untouched' ((GitLine $r.Clone @('rev-parse', 'refs/heads/feature/aaron/99004-zz-work')) -eq $newc) 'branch moved'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '5. WT_RESET_BRANCH=1 discards the unique commits and uses the base'
$res = Invoke-Make 'development' @{ WT_ID = '99004'; WT_SLUG = 'zz-work'; WT_REPOS = 'mono'; WT_RESET_BRANCH = '1' }
$head = GitLine (Story '99004' 'zz-work' 'mono') @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == upstream tip' ($head -eq $r.Tip) "head=$head want=$($r.Tip)`n$($res.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '6. WT_REUSE_BRANCH=1 keeps the existing branch and says how far behind'
Reset-Fixture
$r = New-Repo 'mono' 'main' 3
$old = GitLine $r.Clone @('rev-parse', 'origin/main')
$tree = GitLine $r.Clone @('rev-parse', "$old^{tree}")
$newc = GitLine $r.Clone @('commit-tree', $tree, '-p', $old, '-m', 'my local work')
Git $r.Clone @('update-ref', 'refs/heads/feature/aaron/99006-zz-reuse', $newc) | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99006'; WT_SLUG = 'zz-reuse'; WT_REPOS = 'mono'; WT_REUSE_BRANCH = '1' }
$head = GitLine (Story '99006' 'zz-reuse' 'mono') @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == existing branch tip' ($head -eq $newc) "head=$head want=$newc`n$($res.Out)"
Check 'warns it is behind' ($res.Out -match 'behind origin/main') 'no behind warning'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '7. branch already checked out elsewhere: refuse'
Reset-Fixture
$r = New-Repo 'mono' 'main' 2
$other = Join-Path $Root 'other-wt'
Git $r.Clone @('worktree', 'add', '-b', 'feature/aaron/99007-zz-dup', $other, 'origin/main') | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99007'; WT_SLUG = 'zz-dup'; WT_REPOS = 'mono' }
Check 'exit 1' ($res.Code -eq 1) "exit=$($res.Code)`n$($res.Out)"
Check 'names the conflicting worktree' ($res.Out -match 'already checked out at') "no message`n$($res.Out)"
Check 'no worktree created' (-not (Test-Path -LiteralPath (Join-Path (Story '99007' 'zz-dup' 'mono') '.git'))) 'worktree exists'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '8. fetch failure: refuse rather than use a stale origin'
Reset-Fixture
$r = New-Repo 'mono' 'main' 4
Git $r.Clone @('remote', 'set-url', 'origin', (Join-Path $Root 'does-not-exist.git')) | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99008'; WT_SLUG = 'zz-nofetch'; WT_REPOS = 'mono' }
Check 'exit 1' ($res.Code -eq 1) "exit=$($res.Code)`n$($res.Out)"
Check 'says the fetch failed' ($res.Out -match 'fetch failed') "no message`n$($res.Out)"
Check 'no worktree created' (-not (Test-Path -LiteralPath (Join-Path (Story '99008' 'zz-nofetch' 'mono') '.git'))) 'worktree exists'
Check 'retried once' (([regex]::Matches($res.Out, 'git fetch --prune origin in')).Count -eq 2) 'no retry'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '9. missing origin/HEAD is recovered from the remote'
Reset-Fixture
$r = New-Repo 'mono' 'trade-central/root' 3
# origin/HEAD is a SYMBOLIC ref: update-ref -d does not remove it.
Git $r.Clone @('symbolic-ref', '-d', 'refs/remotes/origin/HEAD') | Out-Null
Check 'origin/HEAD really gone' ((GitLine $r.Clone @('symbolic-ref', '-q', '--short', 'refs/remotes/origin/HEAD')) -eq '') 'still there'
$res = Invoke-Make 'development' @{ WT_ID = '99009'; WT_SLUG = 'zz-nohead'; WT_REPOS = 'mono' }
$head = GitLine (Story '99009' 'zz-nohead' 'mono') @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == upstream tip of the real default branch' ($head -eq $r.Tip) "head=$head want=$($r.Tip)`n$($res.Out)"
Check 'base label names the real default' ($res.Out -match 'origin/trade-central/root @') "no base line`n$($res.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '10. empty leftover directory at the worktree path is cleaned up'
Reset-Fixture
$r = New-Repo 'mono' 'main' 2
New-Item -ItemType Directory -Force -Path (Story '99010' 'zz-empty' 'mono') | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99010'; WT_SLUG = 'zz-empty'; WT_REPOS = 'mono' }
$head = GitLine (Story '99010' 'zz-empty' 'mono') @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == upstream tip' ($head -eq $r.Tip) "head=$head want=$($r.Tip)`n$($res.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '11. re-run is idempotent (exit 3, nothing touched)'
$before = GitLine (Story '99010' 'zz-empty' 'mono') @('rev-parse', 'HEAD')
$res = Invoke-Make 'development' @{ WT_ID = '99010'; WT_SLUG = 'zz-empty'; WT_REPOS = 'mono' }
$after = GitLine (Story '99010' 'zz-empty' 'mono') @('rev-parse', 'HEAD')
Check 'exit 3' ($res.Code -eq 3) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD unchanged' ($before -eq $after) "before=$before after=$after"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '12. review: worktree lands on origin/<linked branch>, stale local branch fixed'
Reset-Fixture
$r = New-Repo 'mono' 'main' 2
# a PR branch on the remote with 2 commits, and a stale local branch of the same name
Git $r.Work @('checkout', '-q', '-b', 'feature/someone/99012-pr') | Out-Null
Add-Content -LiteralPath (Join-Path $r.Work 'f.txt') -Value 'pr1'
Git $r.Work @('commit', '-qam', 'pr1') | Out-Null
Git $r.Work @('push', '-q', 'origin', 'feature/someone/99012-pr') | Out-Null
$prMid = GitLine $r.Work @('rev-parse', 'HEAD')
Add-Content -LiteralPath (Join-Path $r.Work 'f.txt') -Value 'pr2'
Git $r.Work @('commit', '-qam', 'pr2') | Out-Null
Git $r.Work @('push', '-q', 'origin', 'feature/someone/99012-pr') | Out-Null
$prTip = GitLine $r.Work @('rev-parse', 'HEAD')
Git $r.Clone @('fetch', '-q', 'origin') | Out-Null
Git $r.Clone @('update-ref', 'refs/heads/feature/someone/99012-pr', $prMid) | Out-Null
Git $r.Clone @('update-ref', 'refs/remotes/origin/feature/someone/99012-pr', $prMid) | Out-Null
$bf = Join-Path $Root 'branches.txt'
Set-Content -LiteralPath $bf -Value 'mono:feature/someone/99012-pr' -NoNewline
$res = Invoke-Make 'review' @{ WT_ID = '99012'; WT_SLUG = 'zz-review'; WT_BRANCHES_FILE = $bf }
$wt = Story '99012' 'zz-review' 'mono' 'review'
$head = GitLine $wt @('rev-parse', 'HEAD')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'HEAD == origin PR tip (not the stale local branch)' ($head -eq $prTip) "head=$head want=$prTip mid=$prMid`n$($res.Out)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '13. multi-repo run: one bad repo does not stop the good one'
Reset-Fixture
$a = New-Repo 'aaa' 'main' 3
$b = New-Repo 'bbb' 'main' 2
Git $b.Clone @('remote', 'set-url', 'origin', (Join-Path $Root 'nope.git')) | Out-Null
$res = Invoke-Make 'development' @{ WT_ID = '99013'; WT_SLUG = 'zz-multi'; WT_REPOS = 'aaa, bbb' }
$headA = GitLine (Story '99013' 'zz-multi' 'aaa') @('rev-parse', 'HEAD')
Check 'exit 1 (a repo failed)' ($res.Code -eq 1) "exit=$($res.Code)`n$($res.Out)"
Check 'good repo still created at tip' ($headA -eq $a.Tip) "head=$headA want=$($a.Tip)`n$($res.Out)"
Check 'bad repo not created' (-not (Test-Path -LiteralPath (Join-Path (Story '99013' 'zz-multi' 'bbb') '.git'))) 'bbb exists'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '14. missing clone is reported, does not crash the run'
Reset-Fixture
$a = New-Repo 'aaa' 'main' 1
$res = Invoke-Make 'development' @{ WT_ID = '99014'; WT_SLUG = 'zz-missing'; WT_REPOS = 'aaa,ghost' }
Check 'exit 1' ($res.Code -eq 1) "exit=$($res.Code)`n$($res.Out)"
Check 'names the missing clone' ($res.Out -match 'missing clone') "no message`n$($res.Out)"
Check 'good repo created' (Test-Path -LiteralPath (Join-Path (Story '99014' 'zz-missing' 'aaa') '.git')) 'aaa missing'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '15. story topology: ONE workspace for the whole story, four tabs at its root'
Reset-Fixture
$a = New-Repo 'aaa' 'main' 1
$b = New-Repo 'bbb' 'main' 2
$res = Invoke-Make 'development' @{ WT_ID = '99015'; WT_SLUG = 'zz-topo'; WT_REPOS = 'aaa,bbb' }
$storyDir = Split-Path -Parent (Story '99015' 'zz-topo' 'aaa')
Check 'exit 0' ($res.Code -eq 0) "exit=$($res.Code)`n$($res.Out)"
Check 'both repos are folders inside the story' `
  ((Test-Path -LiteralPath (Join-Path (Story '99015' 'zz-topo' 'aaa') '.git')) -and
   (Test-Path -LiteralPath (Join-Path (Story '99015' 'zz-topo' 'bbb') '.git'))) 'a repo is missing'
$wss = @(Get-FixtureWorkspaces $storyDir)
Check 'exactly one herdr workspace for the story' ($wss.Count -eq 1) "count=$($wss.Count)`n$($res.Out)"
if ($wss.Count -eq 1) {
  Check 'labeled {id}-{slug}' ("$($wss[0].label)" -eq '99015-zz-topo') "label=$($wss[0].label)"
  # The whole point: a workspace with worktree metadata gets nested under its
  # primary clone, which is the repo-centric layout this replaced.
  Check 'not nested under a repo (no worktree metadata)' ($null -eq $wss[0].worktree) 'it is a worktree workspace'
  $labels = @(Get-TabLabels $wss[0].workspace_id)
  foreach ($want in @('notes', 'claude', 'cursor', 'pwsh')) {
    Check "has a '$want' tab" ($labels -contains $want) "tabs=$($labels -join ',')"
  }
  Check 'no stray extra tab' ($labels.Count -eq 4) "tabs=$($labels -join ',')"
}
Check 'no per-repo worktree workspace was registered' `
  ((Get-WorktreeWorkspacesUnder $storyDir).Count -eq 0) 'a repo-level worktree workspace exists'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '16. re-running the same story reuses its workspace (no duplicate)'
$res = Invoke-Make 'development' @{ WT_ID = '99015'; WT_SLUG = 'zz-topo'; WT_REPOS = 'aaa,bbb' }
$wss2 = @(Get-FixtureWorkspaces $storyDir)
Check 'exit 3 (nothing to do)' ($res.Code -eq 3) "exit=$($res.Code)`n$($res.Out)"
Check 'still exactly one workspace' ($wss2.Count -eq 1) "count=$($wss2.Count)`n$($res.Out)"
Check 'same workspace id' (($wss.Count -eq 1) -and ($wss2.Count -eq 1) -and
  ($wss2[0].workspace_id -eq $wss[0].workspace_id)) 'a second workspace was created'
Check 'said it reused it' ($res.Out -match 'reusing workspace') "no reuse line`n$($res.Out)"
Check 'still four tabs' ((@(Get-TabLabels $wss2[0].workspace_id)).Count -eq 4) 'tab count changed'

# ---------------------------------------------------------------------------
# Cleanup order matters, and one pass is not enough. herdr keeps a workspace for
# every fixture CLONE it has seen and re-lists it while the repo is still on
# disk, while its panes hold those directories open so the delete fails until
# they are closed. Each round closes what it can and deletes what it can, which
# frees the next round; in practice it converges in two or three.
$fixtureRoot = $Base
foreach ($round in 1..8) {
  Close-Workspaces
  if (Test-Path -LiteralPath $fixtureRoot) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  $remaining = 0
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $j = (& herdr workspace list 2>$null | Out-String)
    if ($j) {
      $o = $null
      try { $o = $j | ConvertFrom-Json } catch { }
      foreach ($w in @($o.result.workspaces)) {
        if ($null -ne $w -and $null -ne $w.worktree -and
            "$($w.worktree.repo_root)" -like "*$FixtureMarker*") { $remaining++ }
      }
    }
  } finally { $ErrorActionPreference = $prev }
  if ($remaining -eq 0 -and -not (Test-Path -LiteralPath $fixtureRoot)) { break }
  Start-Sleep -Seconds 2
}
if (Test-Path -LiteralPath $fixtureRoot) {
  Write-Host "note: could not fully delete fixture dir $fixtureRoot (herdr may still hold it)"
}
Write-Host ''
Write-Host '================ summary ================'
Write-Host "PASS: $script:Pass   FAIL: $script:Fail"
if ($script:Fail -gt 0) {
  Write-Host 'failed checks:'
  $script:Names | ForEach-Object { Write-Host "  - $_" }
  exit 1
}
exit 0



