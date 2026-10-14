<#
.SYNOPSIS
    Puts the demo repository back into the exact starting state for each vignette.

.DESCRIPTION
    Run it from a clone of the repository, signed in with the GitHub CLI ("gh auth status").
    It only ever touches this repository and never prints identifiers or secret values.

    V1  Secret blocked before it is saved
        Removes leftover demo/secret-push-* branches (local and remote), makes sure secret scanning and push
        protection are on, and reports any secret scanning alert (there should be none).

    V2  Vulnerable dependency and code flaw
        Closes the old pull request, deletes the branch demo/vulnerable-change and creates both again from the
        current main: it adds requests 2.19.1 (known advisories) and a deliberately injectable SQL endpoint.
        Then it waits for the checks and shows what they reported, including whether Copilot Autofix has a
        suggestion for the CodeQL alert.
        -SeedDependabot additionally puts one outdated pin (gunicorn 21.2.0) on main for a few minutes, so a real
        Dependabot alert and a Dependabot security-update pull request exist. Main is restored by a later reset.

    V3  Deploy without stored passwords, and prove what was built
        Cancels deployments that are waiting for approval, restores the "production" environment settings
        (required reviewer, self-approval allowed unless -PreventSelfReview), checks the variable names and the
        immutable-releases setting, and makes sure at least one verified release exists.

    V4  Copilot cloud agent (only with -IncludeV4)
        Checks that Copilot can be assigned issues in this repository, closes the previous demo issue and the pull
        request (copilot/* branch) the agent opened for it, and creates one fresh, unassigned issue labelled
        demo-agent. Assigning that issue to Copilot (the live step) starts one cloud agent session, which counts
        against the Copilot usage allowance (premium requests or AI credits, depending on the plan) of the person
        who assigns it.

.PARAMETER Scenario
    V1, V2, V3, V4 or All (default). All = V1, V2 and V3 (V4 only with -IncludeV4).

.PARAMETER SeedDependabot
    V2 only: also seed main with an outdated pin (see above). The alerts appear after about 1 to 2 minutes. In testing,
    Dependabot opened a fresh security-update pull request only the first time; when the same pin was seeded again the
    alerts simply came back (same alert numbers) and no new pull request followed, so after 5 minutes the script
    re-opens Dependabot's earlier pull request. Do not merge that pull request (a merged one cannot be re-opened) and
    do not close it by hand: Dependabot closes it by itself when main is restored by a later reset.

.PARAMETER PreventSelfReview
    V3 only: turn "prevent self-review" ON for the production environment. Default is OFF, so one person
    can approve a deployment alone. With it ON, a second person must approve.

.PARAMETER NoWait
    V2 only: do not wait for the pull request checks to finish.

.EXAMPLE
    .\scripts\Reset-GitHubDemo.ps1
.EXAMPLE
    .\scripts\Reset-GitHubDemo.ps1 -Scenario V2 -SeedDependabot
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'V1', 'V2', 'V3', 'V4')]
    [string] $Scenario = 'All',
    [switch] $SeedDependabot,
    [switch] $PreventSelfReview,
    [switch] $IncludeV4,
    [switch] $NoWait
)

$ErrorActionPreference = 'Stop'
$env:GIT_TERMINAL_PROMPT = '0'
$env:GIT_PAGER = ''
$env:GH_PAGER = ''
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$V2Branch = 'demo/vulnerable-change'
$SeedPackage = 'gunicorn'
$SeedPin = '21.2.0'
$CleanPin = '26.2.0'
$utf8 = New-Object Text.UTF8Encoding($false)

$V4IssueTitle = 'Filter payment status by channel (for example ?channel=mobile)'
$V4IssueBody = @'
**Goal:** let callers filter `/api/payments/status` by `channel` (`MOBILE`, `BRANCH`, `WEB`), the same way they can already filter by `status`.

**Acceptance criteria**
- `GET /api/payments/status?channel=mobile` returns only the records whose `channel` is `MOBILE` (case-insensitive).
- `channel` can be combined with `status`.
- The `summary` counts describe the filtered records.
- An unknown channel returns an empty `payments` list and the summary `{"total": 0}`.
- Add pytest tests next to the existing ones in `tests/test_app.py`.
- Do not change dependencies or anything under `.github/`.

All data in this repository is synthetic and fictional.
'@

# --- Helpers -------------------------------------------------------------------------------------------------
function Write-Section([string] $Text) { Write-Host ''; Write-Host "=== $Text ===" -ForegroundColor Cyan }
function Write-Ok([string] $Text) { Write-Host "  [ok]   $Text" -ForegroundColor Green }
function Write-Note([string] $Text) { Write-Host "  [info] $Text" -ForegroundColor Gray }
function Write-Warn([string] $Text) { Write-Host "  [warn] $Text" -ForegroundColor Yellow }

function Invoke-Native {
    # Runs a command, returns its output lines and sets $script:exit. Never throws on a non-zero exit code.
    # (Windows PowerShell 5.1 turns anything a native command writes to stderr into an error when
    # $ErrorActionPreference is 'Stop', so it is relaxed for the call.)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & $args[0] @($args | Select-Object -Skip 1) 2>&1 | ForEach-Object { "$_" }
        $script:exit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    return $lines
}

function Invoke-Gh {
    $lines = Invoke-Native gh @args
    if ($script:exit -ne 0) { throw "gh $($args -join ' ') failed: $($lines -join ' ')" }
    return $lines
}

function Invoke-GhJson {
    $text = (Invoke-Gh @args) -join "`n"
    if (-not $text.Trim()) { return }
    return ($text | ConvertFrom-Json)
}

function Invoke-GhBody([string] $Method, [string] $Path, $Body) {
    $json = $Body | ConvertTo-Json -Depth 8 -Compress
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = $json | & gh api -X $Method $Path --input - 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw "gh api $Method $Path failed: $($lines -join ' ')" }
    return $lines
}

function Invoke-Git {
    $lines = Invoke-Native git @args
    return $lines
}

function Invoke-GitStrict {
    $lines = Invoke-Native git @args
    if ($script:exit -ne 0) { throw "git $($args -join ' ') failed: $($lines -join ' ')" }
    return $lines
}

# --- Context -------------------------------------------------------------------------------------------------
Set-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)   # the scripts work from any directory
$root = (Invoke-Git rev-parse --show-toplevel | Select-Object -First 1)
if ($script:exit -ne 0 -or -not $root) { throw 'Run this script inside a clone of the demo repository.' }
Set-Location $root
$remoteUrl = (Invoke-Git remote get-url origin | Select-Object -First 1)
if ($remoteUrl -notmatch 'github\.com[:/](?<slug>[^/]+/release-lab-secure-by-default)(\.git)?/?$') {
    throw "The 'origin' remote is not the release-lab-secure-by-default repository."
}
$slug = $Matches['slug']
$owner = $slug.Split('/')[0]
Invoke-Gh auth status | Out-Null
Write-Host "Repository: $slug" -ForegroundColor Gray

# --- Shared checks -------------------------------------------------------------------------------------------
function Get-RepoSettings { return (Invoke-GhJson api "repos/$slug") }

function Confirm-SecurityFeatures {
    $repo = Get-RepoSettings
    $sa = $repo.security_and_analysis
    $needed = @(
        @{ Name = 'Secret scanning'; Value = $sa.secret_scanning.status },
        @{ Name = 'Push protection'; Value = $sa.secret_scanning_push_protection.status }
    )
    foreach ($item in $needed) {
        if ($item.Value -ne 'enabled') { Write-Warn "$($item.Name) is '$($item.Value)' - enabling it."; $script:fix = $true }
    }
    if ($script:fix) {
        Invoke-GhBody PATCH "repos/$slug" @{ security_and_analysis = @{
                secret_scanning = @{ status = 'enabled' }
                secret_scanning_push_protection = @{ status = 'enabled' } } } | Out-Null
        $script:fix = $false
    }
    Write-Ok 'Secret scanning and push protection are on'

    $null = Invoke-Native gh api "repos/$slug/vulnerability-alerts"
    if ($script:exit -ne 0) { Invoke-Gh api -X PUT "repos/$slug/vulnerability-alerts" | Out-Null; Write-Warn 'Dependabot alerts were off - enabled.' }
    Write-Ok 'Dependabot alerts are on'

    $repo = Get-RepoSettings
    if ($repo.security_and_analysis.dependabot_security_updates.status -ne 'enabled') {
        Invoke-Gh api -X PUT "repos/$slug/automated-security-fixes" | Out-Null
        Write-Warn 'Dependabot security updates were off - enabled.'
    }
    Write-Ok 'Dependabot security updates are on'

    $codeql = Invoke-GhJson api "repos/$slug/code-scanning/default-setup"
    if ($codeql.state -ne 'configured') {
        Invoke-GhBody PATCH "repos/$slug/code-scanning/default-setup" @{ state = 'configured'; query_suite = 'default' } | Out-Null
        Write-Warn 'CodeQL default setup was not configured - configured it (the first analysis takes a few minutes).'
    }
    Write-Ok 'CodeQL default setup is configured'
}

function Remove-StaleWorktree([string] $Path) {
    if (Test-Path $Path) {
        $null = Invoke-Git worktree remove --force $Path
        if (Test-Path $Path) { Remove-Item $Path -Recurse -Force }
    }
    $null = Invoke-Git worktree prune
}

function Get-MainRequirements {
    $file = Invoke-GhJson api "repos/$slug/contents/requirements.txt?ref=main"
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($file.content -replace '\s', '')))
}

# --- V1 ------------------------------------------------------------------------------------------------------
function Reset-V1 {
    Write-Section 'V1 - secret blocked before it is saved'
    Confirm-SecurityFeatures
    $removed = 0
    foreach ($line in (Invoke-Git branch --list 'demo/secret-push-*')) {
        $name = $line.Trim().TrimStart('*').Trim()
        if ($name) { $null = Invoke-Git branch -D $name; $removed++ }
    }
    foreach ($line in (Invoke-Git ls-remote --heads origin 'demo/secret-push-*')) {
        if ($line -match 'refs/heads/(?<b>\S+)$') {
            Invoke-Gh api -X DELETE "repos/$slug/git/refs/heads/$($Matches['b'])" | Out-Null
            $removed++
        }
    }
    Write-Ok "Leftover demo/secret-push-* branches removed: $removed"
    $alerts = @(Invoke-GhJson api "repos/$slug/secret-scanning/alerts?per_page=100")
    if ($alerts.Count -gt 0) { Write-Warn "$($alerts.Count) secret scanning alert(s) exist. A blocked push creates none - look at them in the Security tab." }
    else { Write-Ok 'No secret scanning alerts (a blocked push leaves none)' }
    Write-Note 'Run it live with: .\scripts\demo-secret-push.ps1'
}

# --- V2 ------------------------------------------------------------------------------------------------------
function Restore-CleanMain {
    $text = Get-MainRequirements
    if ($text -notmatch "(?m)^$SeedPackage==") { return }
    if ($text -match "(?m)^$SeedPackage==$([regex]::Escape($CleanPin))\s*$") { return }
    $current = [regex]::Match($text, "(?m)^$SeedPackage==(\S+)").Groups[1].Value
    Write-Warn "main has $SeedPackage==$current (seeded, or bumped by the Dependabot pull request) - restoring it to $CleanPin."
    $wt = Join-Path $root '.demo-work\main'
    Remove-StaleWorktree $wt
    $null = Invoke-GitStrict fetch origin main
    $null = Invoke-GitStrict worktree add --detach $wt origin/main
    try {
        $req = Join-Path $wt 'requirements.txt'
        $content = [IO.File]::ReadAllText($req) -replace "(?m)^$SeedPackage==\S+", "$SeedPackage==$CleanPin"
        [IO.File]::WriteAllText($req, $content, $utf8)
        $null = Invoke-GitStrict -C $wt add requirements.txt
        $null = Invoke-GitStrict -C $wt commit -m "Restore $SeedPackage $CleanPin after the Dependabot demo"
        Push-MainDirectly $wt
    }
    finally { Remove-StaleWorktree $wt }
    foreach ($pr in @(Invoke-GhJson pr list --repo $slug --state open --author 'app/dependabot' --json 'number,title')) {
        if ($pr.title -notmatch $SeedPackage) { continue }
        # Dependabot closes its own pull request about 2 to 3 minutes after the vulnerable pin is gone from main, so give
        # it a few minutes and close by hand only as a last resort.
        $deadline = (Get-Date).AddMinutes(5)
        $state = 'OPEN'
        while ((Get-Date) -lt $deadline) {
            $state = (Invoke-GhJson pr view $pr.number --repo $slug --json state).state
            if ($state -ne 'OPEN') { break }
            Start-Sleep -Seconds 15
        }
        if ($state -eq 'OPEN') {
            Invoke-Gh pr close $pr.number --repo $slug --delete-branch | Out-Null
            Write-Warn "Dependabot pull request #$($pr.number) was still open after 5 minutes and was closed by hand."
        }
        else { Write-Note "Dependabot closed its own pull request #$($pr.number) by itself ($state)." }
    }
    Write-Ok "main restored to $SeedPackage==$CleanPin"
}

function Push-MainDirectly([string] $Worktree) {
    # The ruleset (pull request + review required, no bypass) blocks direct pushes on purpose. For maintenance
    # only, enforcement is switched off for the duration of one push and switched back on in 'finally'.
    $toggle = Join-Path $PSScriptRoot 'Set-MainProtection.ps1'
    $hadRuleset = $false
    if (Test-Path $toggle) {
        $state = (& $toggle -Action Show -Quiet)
        $hadRuleset = ($state -eq 'active')
    }
    try {
        if ($hadRuleset) { & $toggle -Action Disable -Quiet | Out-Null }
        $null = Invoke-GitStrict -C $Worktree push origin HEAD:refs/heads/main
    }
    finally {
        if ($hadRuleset) { & $toggle -Action Enable -Quiet | Out-Null }
    }
}

function Wait-ForChecks([string] $Sha, [int] $TimeoutMinutes = 12) {
    # The five checks every pull request gets: two from the CI/dependency workflows, two CodeQL analysis jobs and
    # the "CodeQL" results check that reports the alerts.
    $expected = 'ci', 'dependency-review', 'Analyze (python)', 'Analyze (actions)', 'CodeQL'
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $runs = @()
    while ((Get-Date) -lt $deadline) {
        $resp = Invoke-GhJson api "repos/$slug/commits/$Sha/check-runs?per_page=100"
        $runs = @($resp.check_runs)
        $finished = 0
        foreach ($name in $expected) {
            if (@($runs | Where-Object { $_.name -eq $name -and $_.status -eq 'completed' }).Count -gt 0) { $finished++ }
        }
        if ($finished -eq $expected.Count) { break }
        Start-Sleep -Seconds 8
    }
    return $runs
}

function Test-AutofixOnPage([int] $PrNumber) {
    # Copilot Autofix shows its "Suggested changeset" inside the CodeQL annotation on the pull request page. The REST
    # autofix endpoints only cover alerts on the default branch, so the public page is the place to look.
    $html = (& curl.exe -s -L -A 'Mozilla/5.0' "https://github.com/$slug/pull/$PrNumber") -join "`n"
    return ($html -match 'FROM payments WHERE reference = \?')
}

function Reset-V2 {
    Write-Section 'V2 - vulnerable dependency and code flaw'
    Confirm-SecurityFeatures
    Restore-CleanMain

    foreach ($pr in @(Invoke-GhJson pr list --repo $slug --head $V2Branch --state open --json number)) {
        Invoke-Gh pr close $pr.number --repo $slug --delete-branch | Out-Null
        Write-Note "Closed the previous pull request #$($pr.number)."
    }
    $null = Invoke-Native gh api "repos/$slug/git/ref/heads/$V2Branch"
    if ($script:exit -eq 0) { Invoke-Gh api -X DELETE "repos/$slug/git/refs/heads/$V2Branch" | Out-Null; Write-Note 'Deleted the old remote branch.' }
    if (Invoke-Git branch --list $V2Branch) { $null = Invoke-Git branch -D $V2Branch }

    $assets = Join-Path $root 'scripts\assets\v2'
    foreach ($needed in 'insecure_demo.py.txt', 'test_insecure_demo.py.txt') {
        if (-not (Test-Path (Join-Path $assets $needed))) { throw "Missing asset: scripts\assets\v2\$needed" }
    }

    $wt = Join-Path $root '.demo-work\v2'
    Remove-StaleWorktree $wt
    $null = Invoke-GitStrict fetch origin main
    $null = Invoke-GitStrict worktree add -B $V2Branch $wt origin/main
    $sha = $null
    try {
        Copy-Item (Join-Path $assets 'insecure_demo.py.txt') (Join-Path $wt 'app\insecure_demo.py')
        Copy-Item (Join-Path $assets 'test_insecure_demo.py.txt') (Join-Path $wt 'tests\test_insecure_demo.py')

        $mainPy = Join-Path $wt 'app\main.py'
        $text = ([IO.File]::ReadAllText($mainPy)) -replace "`r`n", "`n"
        if ($text -notmatch 'from \.data import PAYMENTS\n' -or $text -notmatch '\n    return app\n') {
            throw 'app/main.py has changed shape; update the edit in Reset-GitHubDemo.ps1 (Reset-V2).'
        }
        $text = $text.Replace("from .data import PAYMENTS`n", "from .data import PAYMENTS`nfrom .insecure_demo import insecure_demo`n")
        $text = $text.Replace("`n    return app`n", "`n    app.register_blueprint(insecure_demo)`n`n    return app`n")
        [IO.File]::WriteAllText($mainPy, $text, $utf8)

        $req = Join-Path $wt 'requirements.txt'
        $reqText = ([IO.File]::ReadAllText($req)) -replace "`r`n", "`n"
        if ($reqText -notmatch '\n$') { $reqText += "`n" }
        [IO.File]::WriteAllText($req, $reqText + "requests==2.19.1`n", $utf8)

        $null = Invoke-GitStrict -C $wt add -A
        $null = Invoke-GitStrict -C $wt commit -m 'Add payment reference search and a partner notification client'
        $null = Invoke-GitStrict -C $wt push -u origin $V2Branch
        $sha = (Invoke-GitStrict -C $wt rev-parse HEAD | Select-Object -First 1)
    }
    finally {
        Remove-StaleWorktree $wt
        if (Invoke-Git branch --list $V2Branch) { $null = Invoke-Git branch -D $V2Branch }
    }

    $body = @'
Synthetic demo pull request for the Contoso Bank - Payments Status API. It contains two deliberate problems:

1. **An outdated dependency with known advisories**: `requests` 2.19.1. The *dependency review* check flags it
   before it can reach main. (Dependabot alerts watch the default branch, so they appear after a merge.)
2. **A SQL query built from user input**: `app/insecure_demo.py`. *CodeQL* reports it on this pull request, and
   *Copilot Autofix* can suggest the parameterised version.

Do not merge. It is created by `scripts/Reset-GitHubDemo.ps1` and replaced every time that script runs.
'@
    $bodyFile = Join-Path $root '.demo-work\pr-body.md'
    New-Item -ItemType Directory -Force -Path (Split-Path $bodyFile) | Out-Null
    [IO.File]::WriteAllText($bodyFile, $body, $utf8)
    $url = (Invoke-Gh pr create --repo $slug --base main --head $V2Branch --title 'Add payment reference search and a partner notification client' --body-file $bodyFile | Select-Object -Last 1)
    Remove-Item $bodyFile -Force
    $prNumber = [int]($url.Trim() -replace '^.*/pull/', '')
    Write-Ok "Pull request #$prNumber created: $($url.Trim())"

    if ($NoWait) { Write-Note 'Not waiting for the checks (-NoWait). They need about 3 to 5 minutes.'; return }

    Write-Note 'Waiting for the checks (CodeQL usually needs 2 to 4 minutes)...'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $runs = Wait-ForChecks $sha
    Write-Host ''
    foreach ($run in ($runs | Sort-Object name)) {
        $secs = if ($run.started_at -and $run.completed_at) { [int]((Get-Date $run.completed_at) - (Get-Date $run.started_at)).TotalSeconds } else { 0 }
        $colour = if ($run.conclusion -eq 'success') { 'Green' } elseif ($run.conclusion -in 'failure', 'action_required') { 'Red' } else { 'Yellow' }
        Write-Host ("    {0,-22} {1,-10} {2,4} s" -f $run.name, $run.conclusion, $secs) -ForegroundColor $colour
    }
    Write-Note ("All checks finished {0:N0} s after the push." -f $watch.Elapsed.TotalSeconds)

    $alerts = @(Invoke-GhJson api "repos/$slug/code-scanning/alerts?ref=refs/pull/$prNumber/head&per_page=50")
    if ($alerts.Count -eq 0) { Write-Warn 'CodeQL reported no alert on this pull request. Open the Checks tab and look at "CodeQL".' }
    foreach ($alert in $alerts) {
        $where = "$($alert.most_recent_instance.location.path):$($alert.most_recent_instance.location.start_line)"
        Write-Ok "CodeQL alert #$($alert.number): $($alert.rule.id) ($($alert.rule.security_severity_level)) at $where"
    }
    if ($alerts.Count -gt 0) {
        Write-Note 'Looking for the Copilot Autofix suggestion on the pull request (can take a few minutes)...'
        $fixWatch = [Diagnostics.Stopwatch]::StartNew()
        $found = $false
        while (-not $found -and $fixWatch.Elapsed.TotalSeconds -lt 240) {
            $found = Test-AutofixOnPage $prNumber
            if (-not $found) { Start-Sleep -Seconds 10 }
        }
        if ($found) { Write-Ok ("Copilot Autofix suggestion is on the pull request ({0:N0} s after the checks finished): Conversation tab, in the CodeQL annotation" -f $fixWatch.Elapsed.TotalSeconds) }
        else { Write-Warn 'No Copilot Autofix suggestion appeared within 4 minutes (see the runbook for the fallback).' }
    }
    Write-Note "Pull request: $($url.Trim())"
    Write-Note "Checks tab:   $($url.Trim())/checks"

    if ($SeedDependabot) { Invoke-SeedDependabot }
}

function Restore-ClosedDependabotPr {
    # Dependabot does not open a second pull request for an update whose pull request was closed earlier. Its own comment
    # says what to do: re-open that pull request (here on a restored branch, because closing deleted the branch).
    $closed = @(Invoke-GhJson pr list --repo $slug --state closed --author 'app/dependabot' --limit 20 --json 'number,title,headRefName,headRefOid,mergedAt' |
            Where-Object { $_.title -match $SeedPackage -and -not $_.mergedAt }) | Select-Object -First 1
    if (-not $closed) { return $null }
    $null = Invoke-Native gh api "repos/$slug/git/ref/heads/$($closed.headRefName)"
    if ($script:exit -ne 0) {
        $null = Invoke-Gh api -X POST "repos/$slug/git/refs" -f "ref=refs/heads/$($closed.headRefName)" -f "sha=$($closed.headRefOid)"
    }
    $null = Invoke-Gh pr reopen $closed.number --repo $slug
    Write-Note "Dependabot did not open a new pull request for this update - re-opened its earlier pull request #$($closed.number) instead."
    return $closed
}

function Invoke-SeedDependabot {
    Write-Section 'V2 (optional) - seed one outdated pin on main for Dependabot'
    $text = Get-MainRequirements
    if ($text -notmatch "(?m)^$SeedPackage==") { throw "$SeedPackage is not pinned in requirements.txt on main." }
    $alreadySeeded = $text -match "(?m)^$SeedPackage==$([regex]::Escape($SeedPin))\s*$"
    if (-not $alreadySeeded) {
        $wt = Join-Path $root '.demo-work\seed'
        Remove-StaleWorktree $wt
        $null = Invoke-GitStrict fetch origin main
        $null = Invoke-GitStrict worktree add --detach $wt origin/main
        try {
            $req = Join-Path $wt 'requirements.txt'
            $content = [IO.File]::ReadAllText($req)
            $content = $content -replace "(?m)^$SeedPackage==\S+", "$SeedPackage==$SeedPin"
            [IO.File]::WriteAllText($req, $content, $utf8)
            $null = Invoke-GitStrict -C $wt add requirements.txt
            $null = Invoke-GitStrict -C $wt commit -m "Pin $SeedPackage $SeedPin (outdated, for the Dependabot demo)"
            Push-MainDirectly $wt
        }
        finally { Remove-StaleWorktree $wt }
        Write-Ok "Pushed the outdated pin $SeedPackage==$SeedPin to main."
    }
    else { Write-Note 'main already has the outdated pin.' }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $alertSeen = $false
    $prSeen = $null
    $reopenTried = $false
    $deadline = (Get-Date).AddMinutes(20)
    while ((Get-Date) -lt $deadline -and (-not $alertSeen -or -not $prSeen)) {
        if (-not $alertSeen) {
            $found = @(Invoke-GhJson api "repos/$slug/dependabot/alerts?state=open&package=$SeedPackage&per_page=20")
            if ($found.Count -gt 0) { $alertSeen = $true; Write-Ok ("Dependabot alert(s) for {0}: {1} (after {2:N0} s)" -f $SeedPackage, $found.Count, $clock.Elapsed.TotalSeconds) }
        }
        if (-not $prSeen) {
            $prs = @(Invoke-GhJson pr list --repo $slug --state open --author 'app/dependabot' --json 'number,title,url')
            $match = $prs | Where-Object { $_.title -match $SeedPackage } | Select-Object -First 1
            if ($match) { $prSeen = $match; Write-Ok ("Dependabot security-update pull request: {0} (after {1:N0} s)" -f $match.url, $clock.Elapsed.TotalSeconds) }
            elseif ($alertSeen -and -not $reopenTried -and $clock.Elapsed.TotalSeconds -gt 300) {
                $reopenTried = $true
                $null = Restore-ClosedDependabotPr
            }
        }
        if (-not $alertSeen -or -not $prSeen) { Start-Sleep -Seconds 15 }
    }
    if (-not $alertSeen) { Write-Warn 'No Dependabot alert after 20 minutes. Check Security > Dependabot.' }
    if (-not $prSeen) { Write-Warn 'No Dependabot pull request after 20 minutes. Open one of the alerts under Security > Dependabot and click Create Dependabot security update, or check Insights > Dependency graph > Dependabot.' }
    Write-Note 'Run this script again (without -SeedDependabot) after the demo to restore a clean main.'
}

# --- V3 ------------------------------------------------------------------------------------------------------
function Get-NextVersion {
    $tags = @(Invoke-GhJson api "repos/$slug/git/matching-refs/tags/v" | ForEach-Object { $_.ref -replace '^refs/tags/v', '' })
    $releases = @(Invoke-GhJson release list --repo $slug --limit 100 --json tagName | ForEach-Object { $_.tagName -replace '^v', '' })
    $all = @($tags + $releases | Where-Object { $_ -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_ } -Unique)
    if ($all.Count -eq 0) { return '1.0.0' }
    $last = [version]$all[-1]
    return "$($last.Major).$($last.Minor).$($last.Build + 1)"
}

function Reset-V3 {
    Write-Section 'V3 - deploy without stored passwords, and prove what was built'

    $cancelled = 0
    foreach ($workflow in 'deploy.yml', 'release.yml') {
        foreach ($status in 'waiting', 'queued', 'in_progress') {
            foreach ($run in @(Invoke-GhJson run list --repo $slug --workflow $workflow --status $status --json databaseId)) {
                $null = Invoke-Native gh run cancel $run.databaseId --repo $slug
                $cancelled++
            }
        }
    }
    Write-Ok "Runs waiting for approval or in progress, cancelled: $cancelled"

    & (Join-Path $PSScriptRoot 'Set-DeployApproval.ps1') -PreventSelfReview:$PreventSelfReview
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw 'Set-DeployApproval.ps1 failed.' }

    $names = @(Invoke-GhJson api "repos/$slug/actions/variables?per_page=100" | ForEach-Object { $_.variables.name })
    foreach ($needed in 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID') {
        if ($names -contains $needed) { Write-Ok "Repository variable $needed exists (value not shown)" }
        else { Write-Warn "Repository variable $needed is missing. Run scripts\Setup-AzureOidc.ps1 (see the README)." }
    }

    $immutable = Invoke-GhJson api "repos/$slug/immutable-releases"
    if (-not $immutable.enabled) {
        Invoke-Gh api -X PUT "repos/$slug/immutable-releases" | Out-Null
        Write-Warn 'Immutable releases were off - turned on.'
    }
    Write-Ok 'Immutable releases are on (a published release and its tag cannot be changed)'

    $latest = $null
    $out = Invoke-Native gh release view --repo $slug --json 'tagName,isImmutable'
    if ($script:exit -eq 0) { $latest = (($out -join "`n") | ConvertFrom-Json) }
    if ($latest) { Write-Ok "Latest release: $($latest.tagName) (immutable: $($latest.isImmutable))" }
    else { Write-Warn 'No release exists yet. Publish one with: gh workflow run release.yml -f version=<next>.' }
    Write-Note "Next free release version: $(Get-NextVersion)"
    Write-Note 'Live run: Actions > Deploy to Azure > Run workflow, then approve in the production environment.'
}

# --- V4 ------------------------------------------------------------------------------------------------------
function Reset-V4 {
    Write-Section 'V4 - Copilot cloud agent (optional)'

    $query = 'query($o:String!,$n:String!){ repository(owner:$o,name:$n){ suggestedActors(capabilities:[CAN_BE_ASSIGNED], first:20){ nodes{ login } } } }'
    $logins = @(Invoke-Native gh api graphql -f "query=$query" -F "o=$owner" -F "n=$($slug.Split('/')[1])" --jq '.data.repository.suggestedActors.nodes[].login')
    if ($script:exit -ne 0) { Write-Warn 'Could not ask GitHub whether Copilot can be assigned issues here.' }
    elseif ($logins -contains 'copilot-swe-agent') { Write-Ok 'Copilot cloud agent can be assigned issues in this repository' }
    else { Write-Warn 'Copilot cloud agent is NOT available for this repository or account - skip V4.' }

    foreach ($pr in @(Invoke-GhJson pr list --repo $slug --state open --json 'number,headRefName')) {
        if ($pr.headRefName -like 'copilot/*') {
            Invoke-Gh pr close $pr.number --repo $slug --delete-branch --comment 'Closed by scripts/Reset-GitHubDemo.ps1 (demo reset).' | Out-Null
            Write-Note "Closed the agent pull request #$($pr.number)."
        }
    }
    foreach ($line in (Invoke-Git ls-remote --heads origin 'copilot/*')) {
        if ($line -match 'refs/heads/(?<b>\S+)$') {
            Invoke-Gh api -X DELETE "repos/$slug/git/refs/heads/$($Matches['b'])" | Out-Null
            Write-Note "Deleted the leftover branch $($Matches['b'])."
        }
    }
    foreach ($issue in @(Invoke-GhJson issue list --repo $slug --state open --label demo-agent --json number)) {
        Invoke-Gh issue close $issue.number --repo $slug --reason 'not planned' --comment 'Closed by scripts/Reset-GitHubDemo.ps1 (demo reset).' | Out-Null
        Write-Note "Closed issue #$($issue.number)."
    }

    $null = Invoke-Gh label create demo-agent --repo $slug --color 5319E7 --description 'Issue used for the Copilot cloud agent demo' --force
    $work = Join-Path $root '.demo-work'
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $bodyFile = Join-Path $work 'v4-issue.md'
    [IO.File]::WriteAllText($bodyFile, ($V4IssueBody -replace "`r`n", "`n"), $utf8)
    try { $created = @(Invoke-Gh issue create --repo $slug --title $V4IssueTitle --body-file $bodyFile --label demo-agent) }
    finally { Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue }
    $url = ($created | Select-Object -Last 1).Trim()
    Write-Ok "Fresh issue created, not assigned yet: $url"
    Write-Note "Live step: gh issue edit $(($url -split '/')[-1]) --add-assignee '@copilot'   (or assign Copilot in the issue sidebar)"
    Write-Note 'The draft pull request appears about 10 seconds after assigning; the agent needs about 3 minutes.'
}

# --- Run -----------------------------------------------------------------------------------------------------
$timer = [Diagnostics.Stopwatch]::StartNew()
switch ($Scenario) {
    'V1' { Reset-V1 }
    'V2' { Reset-V2 }
    'V3' { Reset-V3 }
    'V4' { Reset-V4 }
    'All' {
        Reset-V1
        Reset-V2
        Reset-V3
        if ($IncludeV4) { Reset-V4 }
    }
}
Write-Host ''
Write-Host ("Reset finished in {0:N0} s." -f $timer.Elapsed.TotalSeconds) -ForegroundColor Cyan
