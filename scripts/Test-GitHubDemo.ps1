<#
.SYNOPSIS
    Smoke test for the demo repository: checks through `gh api` that everything the three vignettes rely on is in place.

.DESCRIPTION
    Read-only. It never prints identifiers or variable values, only names and yes/no answers.

      Repository     public, default branch main
      V1             secret scanning on, push protection on, no open secret scanning alerts, no leftover demo branches
      V2             Dependabot alerts and security updates on, CodeQL default setup configured, dependency review
                     workflow present, main is clean (no open code scanning alerts, no seeded outdated pin)
      Ruleset        "Protect main" present and active: pull request with 1 approval, required checks, no force push,
                     no deletion, no bypass actors
      V3             environment "production" with a required reviewer, deploy only from main, variables present,
                     workflows present, immutable releases on, latest release immutable with provenance and SBOM
      -Verify        also runs `gh attestation verify` and `gh release verify` on the latest release (about 30 s)

    Exit code: 0 when nothing failed (warnings are fine), 1 otherwise.

.EXAMPLE
    .\scripts\Test-GitHubDemo.ps1
.EXAMPLE
    .\scripts\Test-GitHubDemo.ps1 -Verify
#>
[CmdletBinding()]
param(
    [switch] $Verify
)

$ErrorActionPreference = 'Stop'
$env:GH_PAGER = ''
$env:NO_COLOR = '1'

Set-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)   # the scripts work from any directory
$remoteUrl = (& git remote get-url origin 2>&1 | Select-Object -First 1)
if ($remoteUrl -notmatch 'github\.com[:/](?<slug>[^/]+/release-lab-secure-by-default)(\.git)?/?$') {
    throw "The 'origin' remote is not the release-lab-secure-by-default repository."
}
$slug = $Matches['slug']
$root = (& git rev-parse --show-toplevel | Select-Object -First 1)

$script:pass = 0; $script:warn = 0; $script:fail = 0

function Invoke-GhApi([string] $Path) {
    # Returns the parsed JSON, or $null when the API answers with an error (for example 404 = feature is off).
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & gh api $Path 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { return $null }
    $text = ($out -join "`n").Trim()
    if (-not $text) { return [pscustomobject]@{ ok = $true } }
    if ($text.StartsWith('[')) {
        # An empty JSON array must stay an empty array (not $null), and Windows PowerShell 5.1 returns arrays unrolled.
        $items = @()
        foreach ($item in ($text | ConvertFrom-Json)) { $items += $item }
        return , $items
    }
    return ($text | ConvertFrom-Json)
}

function Write-Result([string] $Status, [string] $Name, [string] $Detail) {
    $colour = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$Status]
    $line = "  [{0}] {1}" -f $Status, $Name
    if ($Detail) { $line += " - $Detail" }
    Write-Host $line -ForegroundColor $colour
    switch ($Status) { 'PASS' { $script:pass++ } 'WARN' { $script:warn++ } 'FAIL' { $script:fail++ } }
}

function Check([string] $Name, [scriptblock] $Test, [switch] $WarnOnly) {
    try {
        $detail = & $Test
        Write-Result 'PASS' $Name "$detail"
    }
    catch {
        $status = if ($WarnOnly) { 'WARN' } else { 'FAIL' }
        Write-Result $status $Name $_.Exception.Message
    }
}

function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

Write-Host "Smoke test for $slug" -ForegroundColor Cyan

# --- Repository ---------------------------------------------------------------------------------------------------
Write-Host "`nRepository" -ForegroundColor Cyan
$repo = Invoke-GhApi "repos/$slug"
Check 'Repository is public' { Assert ($repo -and -not $repo.private) 'the repository is private or not reachable'; 'public' }
Check 'Default branch is main' { Assert ($repo.default_branch -eq 'main') "default branch is '$($repo.default_branch)'"; 'main' }

# --- V1 -----------------------------------------------------------------------------------------------------------
Write-Host "`nV1  Secret blocked before it is saved" -ForegroundColor Cyan
$sa = $repo.security_and_analysis
Check 'Secret scanning is enabled' { Assert ($sa.secret_scanning.status -eq 'enabled') "status: $($sa.secret_scanning.status)"; 'enabled' }
Check 'Push protection is enabled' { Assert ($sa.secret_scanning_push_protection.status -eq 'enabled') "status: $($sa.secret_scanning_push_protection.status)"; 'enabled' }
Check 'No open secret scanning alerts' {
    $alerts = Invoke-GhApi "repos/$slug/secret-scanning/alerts?state=open&per_page=100"
    Assert ($null -ne $alerts) 'could not read the alerts'
    $n = @($alerts).Count
    Assert ($n -eq 0) "$n open alert(s): a blocked push must leave none"
    '0 (a blocked push leaves no alert)'
}
Check 'No leftover demo/secret-push-* branches' {
    $branches = Invoke-GhApi "repos/$slug/branches?per_page=100"
    $left = @($branches | Where-Object { $_.name -like 'demo/secret-push-*' })
    Assert ($left.Count -eq 0) "$($left.Count) leftover branch(es); run scripts\Reset-GitHubDemo.ps1 -Scenario V1"
    'none'
}
Check 'Push-protection script is present' { Assert (Test-Path (Join-Path $root 'scripts\demo-secret-push.ps1')) 'scripts\demo-secret-push.ps1 is missing'; 'scripts\demo-secret-push.ps1' }

# --- V2 -----------------------------------------------------------------------------------------------------------
Write-Host "`nV2  Vulnerable dependency and code flaw" -ForegroundColor Cyan
Check 'Dependabot alerts are enabled' {
    $r = Invoke-GhApi "repos/$slug/vulnerability-alerts"
    Assert ($null -ne $r) 'vulnerability alerts are off'
    'enabled'
}
Check 'Dependabot security updates are enabled' { Assert ($sa.dependabot_security_updates.status -eq 'enabled') "status: $($sa.dependabot_security_updates.status)"; 'enabled' }
Check 'CodeQL default setup is configured' {
    $d = Invoke-GhApi "repos/$slug/code-scanning/default-setup"
    Assert ($d -and $d.state -eq 'configured') "state: $($d.state)"
    "configured ($($d.languages -join ', '))"
}
Check 'Dependency review workflow is present' {
    $w = Invoke-GhApi "repos/$slug/contents/.github/workflows/dependency-review.yml?ref=main"
    Assert ($w -and $w.path) 'dependency-review.yml is missing on main'
    '.github/workflows/dependency-review.yml'
}
Check 'main has no open code scanning alerts' {
    $a = Invoke-GhApi "repos/$slug/code-scanning/alerts?state=open&ref=refs/heads/main&per_page=100"
    Assert ($null -ne $a) 'could not read the alerts'
    Assert (@($a).Count -eq 0) "$(@($a).Count) open alert(s) on main"
    '0'
}
Check 'main has no seeded outdated pin' {
    $f = Invoke-GhApi "repos/$slug/contents/requirements.txt?ref=main"
    $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($f.content -replace '\s', '')))
    Assert ($text -match '(?m)^gunicorn==26\.2\.0\s*$') 'requirements.txt does not have the clean gunicorn pin 26.2.0 (Dependabot demo seeded? run scripts\Reset-GitHubDemo.ps1 -Scenario V2)'
    Assert ($text -notmatch '(?m)^requests==2\.19') 'requirements.txt contains the vulnerable requests pin'
    'clean'
} -WarnOnly
Check 'Demo pull request from demo/vulnerable-change is open' {
    $prs = Invoke-GhApi "repos/$slug/pulls?state=open&head=$($slug.Split('/')[0]):demo/vulnerable-change"
    Assert (@($prs).Count -ge 1) 'no open pull request; run scripts\Reset-GitHubDemo.ps1 -Scenario V2'
    "#$(@($prs)[0].number)"
} -WarnOnly

# --- Ruleset ------------------------------------------------------------------------------------------------------
Write-Host "`nRuleset on main" -ForegroundColor Cyan
$ruleset = $null
$list = Invoke-GhApi "repos/$slug/rulesets"
$found = @($list | Where-Object { $_.name -eq 'Protect main' }) | Select-Object -First 1
if ($found) { $ruleset = Invoke-GhApi "repos/$slug/rulesets/$($found.id)" }
Check 'Ruleset "Protect main" exists and is active' { Assert ($ruleset) 'ruleset not found (run scripts\Set-MainProtection.ps1 -Action Apply)'; Assert ($ruleset.enforcement -eq 'active') "enforcement: $($ruleset.enforcement)"; 'active' }
Check 'Ruleset targets the default branch' { Assert (@($ruleset.conditions.ref_name.include) -contains '~DEFAULT_BRANCH') 'does not include ~DEFAULT_BRANCH'; '~DEFAULT_BRANCH' }
Check 'Pull request required, 1 approving review' {
    $rule = $ruleset.rules | Where-Object { $_.type -eq 'pull_request' }
    Assert ($rule) 'no pull_request rule'
    Assert ($rule.parameters.required_approving_review_count -ge 1) 'less than 1 approval required'
    "$($rule.parameters.required_approving_review_count) approval(s)"
}
Check 'Required status checks include ci and CodeQL' {
    $rule = $ruleset.rules | Where-Object { $_.type -eq 'required_status_checks' }
    Assert ($rule) 'no required_status_checks rule'
    $names = @($rule.parameters.required_status_checks | ForEach-Object { $_.context })
    foreach ($needed in 'ci', 'CodeQL') { Assert ($names -contains $needed) "missing required check '$needed'" }
    ($names -join ', ')
}
Check 'Force pushes and branch deletion are blocked' {
    $types = @($ruleset.rules | ForEach-Object { $_.type })
    Assert ($types -contains 'non_fast_forward') 'force pushes are not blocked'
    Assert ($types -contains 'deletion') 'branch deletion is not blocked'
    'non_fast_forward, deletion'
}
Check 'No bypass actors' { Assert (@($ruleset.bypass_actors).Count -eq 0) "$(@($ruleset.bypass_actors).Count) bypass actor(s)"; 'none' }

# --- V3 -----------------------------------------------------------------------------------------------------------
Write-Host "`nV3  Deploy without stored passwords, prove what was built" -ForegroundColor Cyan
$envInfo = Invoke-GhApi "repos/$slug/environments/production"
Check 'Environment "production" exists with a required reviewer' {
    Assert ($envInfo) 'environment not found'
    $rule = $envInfo.protection_rules | Where-Object { $_.type -eq 'required_reviewers' }
    Assert ($rule -and @($rule.reviewers).Count -ge 1) 'no required reviewer'
    $mode = if ($rule.prevent_self_review) { 'prevent self-review ON: a second person must approve' } else { 'prevent self-review OFF: one person can approve (single-reviewer demo mode)' }
    "reviewers: $(@($rule.reviewers | ForEach-Object { $_.reviewer.login }) -join ', '); $mode"
}
Check 'Environment deploys from main only' {
    $p = Invoke-GhApi "repos/$slug/environments/production/deployment-branch-policies"
    $names = @($p.branch_policies | ForEach-Object { $_.name })
    Assert ($names -contains 'main' -and $names.Count -eq 1) "allowed branches: $($names -join ', ')"
    'main'
}
Check 'Azure variables exist (names only, values never shown)' {
    $v = Invoke-GhApi "repos/$slug/actions/variables?per_page=100"
    $names = @($v.variables | ForEach-Object { $_.name })
    foreach ($needed in 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID') { Assert ($names -contains $needed) "missing variable $needed" }
    'AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID'
}
Check 'No repository secrets are needed for the deployment' {
    $s = Invoke-GhApi "repos/$slug/actions/secrets"
    Assert ($s.total_count -eq 0) "$($s.total_count) repository secret(s) exist"
    '0 stored secrets'
}
Check 'Workflows are present and active' {
    $w = Invoke-GhApi "repos/$slug/actions/workflows?per_page=100"
    $paths = @($w.workflows | Where-Object { $_.state -eq 'active' } | ForEach-Object { $_.path })
    foreach ($needed in 'ci.yml', 'dependency-review.yml', 'release.yml', 'deploy.yml', 'azure-deploy.yml') {
        Assert ($paths -contains ".github/workflows/$needed") "workflow $needed is missing or disabled"
    }
    'ci, dependency-review, release, deploy, azure-deploy'
}
Check 'Immutable releases are enabled' {
    $i = Invoke-GhApi "repos/$slug/immutable-releases"
    Assert ($i -and $i.enabled) 'immutable releases are off'
    'enabled'
}
$latest = Invoke-GhApi "repos/$slug/releases/latest"
Check 'Latest release is immutable with provenance and SBOM assets' {
    Assert ($latest) 'no release yet (run the release workflow)'
    Assert ($latest.immutable) "release $($latest.tag_name) is not immutable"
    $assets = @($latest.assets | ForEach-Object { $_.name })
    Assert (@($assets | Where-Object { $_ -like '*.whl' }).Count -ge 1) 'no wheel asset'
    Assert ($assets -contains 'provenance.intoto.jsonl') 'no provenance.intoto.jsonl asset'
    Assert ($assets -contains 'sbom.spdx.json') 'no sbom.spdx.json asset'
    "$($latest.tag_name): $($assets.Count) assets"
}
Check 'Latest CI run on main succeeded' {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $json = & gh run list --repo $slug --workflow ci.yml --branch main --limit 5 --json 'conclusion,status' 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $old }
    $runs = @(); foreach ($item in (($json -join "`n") | ConvertFrom-Json)) { $runs += $item }
    Assert ($runs.Count -gt 0) 'no CI run on main'
    $done = $runs | Where-Object { $_.status -eq 'completed' } | Select-Object -First 1
    Assert ($done) 'no completed CI run on main yet'
    Assert ($done.conclusion -eq 'success') "latest completed run: $($done.conclusion)"
    if ($runs[0].status -ne 'completed') { 'success (a newer run is still in progress)' } else { 'success' }
}

if ($Verify -and $latest) {
    Write-Host "`nVerification of $($latest.tag_name) (this takes about 30 seconds)" -ForegroundColor Cyan
    $dir = Join-Path $root '.demo-work\verify'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $env:GH_FORCE_TTY = '100'
    try {
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $null = & gh release download $latest.tag_name --repo $slug --pattern '*.whl' --dir $dir --clobber 2>&1
        $wheel = Get-ChildItem $dir -Filter *.whl | Select-Object -First 1
        Check 'gh attestation verify (build provenance)' {
            $null = & gh attestation verify $wheel.FullName --repo $slug 2>&1
            Assert ($LASTEXITCODE -eq 0) "exit code $LASTEXITCODE"
            $wheel.Name
        }
        Check 'gh attestation verify (SBOM, SPDX)' {
            $null = & gh attestation verify $wheel.FullName --repo $slug --predicate-type https://spdx.dev/Document/v2.3 2>&1
            Assert ($LASTEXITCODE -eq 0) "exit code $LASTEXITCODE"
            'https://spdx.dev/Document/v2.3'
        }
        Check 'gh release verify' {
            $null = & gh release verify $latest.tag_name --repo $slug 2>&1
            Assert ($LASTEXITCODE -eq 0) "exit code $LASTEXITCODE"
            $latest.tag_name
        }
        $ErrorActionPreference = $old
    }
    finally {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\GH_FORCE_TTY -ErrorAction SilentlyContinue
    }
}

Write-Host ''
$colour = if ($script:fail -gt 0) { 'Red' } elseif ($script:warn -gt 0) { 'Yellow' } else { 'Green' }
Write-Host ("Result: {0} passed, {1} warning(s), {2} failed" -f $script:pass, $script:warn, $script:fail) -ForegroundColor $colour
if ($script:fail -gt 0) { exit 1 }
exit 0
