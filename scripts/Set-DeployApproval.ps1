<#
.SYNOPSIS
    Restores the "production" environment used by the deployment demo and sets who may approve.

.DESCRIPTION
    Required reviewer = the repository owner (plus any -AdditionalReviewer), no wait timer, administrators cannot
    skip the approval, and deployments are allowed from the main branch only.

    "Prevent self-review" decides whether the person who started a deployment may also approve it:
      OFF (default)  one presenter can start and approve a deployment alone. Use this for rehearsals.
      ON             a second person must approve. Use this to show a true two-person approval.
                     Add that person with -AdditionalReviewer <github-login>, otherwise nobody can approve.

.PARAMETER PreventSelfReview
    Turn "prevent self-review" ON. Without this switch it is turned OFF.

.PARAMETER AdditionalReviewer
    GitHub login(s) of extra required reviewers (they must have access to the repository).

.EXAMPLE
    .\scripts\Set-DeployApproval.ps1                                   # solo rehearsal: self-approval allowed
.EXAMPLE
    .\scripts\Set-DeployApproval.ps1 -PreventSelfReview -AdditionalReviewer colleague-login
#>
[CmdletBinding()]
param(
    [switch] $PreventSelfReview,
    [string[]] $AdditionalReviewer = @(),
    [string] $Environment = 'production'
)

$ErrorActionPreference = 'Stop'
$env:GH_PAGER = ''

Set-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)   # the scripts work from any directory
$remoteUrl = (& git remote get-url origin 2>&1 | Select-Object -First 1)
if ($remoteUrl -notmatch 'github\.com[:/](?<slug>[^/]+/release-lab-secure-by-default)(\.git)?/?$') {
    throw "The 'origin' remote is not the release-lab-secure-by-default repository."
}
$slug = $Matches['slug']
$owner = $slug.Split('/')[0]

function Invoke-Gh([string[]] $GhArgs, [string] $Stdin) {
    # Windows PowerShell 5.1 treats stderr output of native commands as an error under 'Stop', so relax it for the call.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Stdin) { $out = $Stdin | & gh @GhArgs 2>&1 | ForEach-Object { "$_" } }
        else { $out = & gh @GhArgs 2>&1 | ForEach-Object { "$_" } }
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) { throw "gh $($GhArgs -join ' ') failed: $($out -join ' ')" }
    return $out
}

function Get-UserId([string] $Login) {
    $id = Invoke-Gh @('api', "users/$Login", '--jq', '.id')
    return [int64]"$id"
}

$reviewers = @()
foreach ($login in (@($owner) + @($AdditionalReviewer) | Select-Object -Unique)) {
    $reviewers += @{ type = 'User'; id = (Get-UserId $login) }
}

$body = @{
    wait_timer = 0
    prevent_self_review = [bool] $PreventSelfReview
    reviewers = $reviewers
    can_admins_bypass = $false
    deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
}
$json = $body | ConvertTo-Json -Depth 6 -Compress
$null = Invoke-Gh @('api', '-X', 'PUT', "repos/$slug/environments/$Environment", '--input', '-') $json

$policies = @(Invoke-Gh @('api', "repos/$slug/environments/$Environment/deployment-branch-policies", '--jq', '.branch_policies[].name'))
if ($policies -notcontains 'main') {
    $null = Invoke-Gh @('api', '-X', 'POST', "repos/$slug/environments/$Environment/deployment-branch-policies", '--input', '-') '{"name":"main","type":"branch"}'
}

$info = (Invoke-Gh @('api', "repos/$slug/environments/$Environment")) -join "`n" | ConvertFrom-Json
$rule = $info.protection_rules | Where-Object { $_.type -eq 'required_reviewers' } | Select-Object -First 1
$names = ($rule.reviewers | ForEach-Object { $_.reviewer.login }) -join ', '
$mode = if ($rule.prevent_self_review) { 'ON - a second person must approve' } else { 'OFF - the person who starts a deployment can approve it' }
Write-Host "  [ok]   Environment '$Environment': required reviewer(s): $names" -ForegroundColor Green
Write-Host "  [ok]   Prevent self-review: $mode" -ForegroundColor Green
Write-Host "  [ok]   Deployments allowed from: main only" -ForegroundColor Green
exit 0
