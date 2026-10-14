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

$remoteUrl = (& git remote get-url origin 2>&1 | Select-Object -First 1)
if ($remoteUrl -notmatch 'github\.com[:/](?<slug>[^/]+/release-lab-secure-by-default)(\.git)?/?$') {
    throw "The 'origin' remote is not the release-lab-secure-by-default repository."
}
$slug = $Matches['slug']
$owner = $slug.Split('/')[0]

function Get-UserId([string] $Login) {
    $id = & gh api "users/$Login" --jq '.id' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "GitHub user '$Login' was not found." }
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
$result = $json | & gh api -X PUT "repos/$slug/environments/$Environment" --input - 2>&1
if ($LASTEXITCODE -ne 0) { throw "Could not update the environment: $result" }

$policies = @(& gh api "repos/$slug/environments/$Environment/deployment-branch-policies" --jq '.branch_policies[].name')
if ($policies -notcontains 'main') {
    '{"name":"main","type":"branch"}' | & gh api -X POST "repos/$slug/environments/$Environment/deployment-branch-policies" --input - | Out-Null
}

$info = (& gh api "repos/$slug/environments/$Environment") | ConvertFrom-Json
$rule = $info.protection_rules | Where-Object { $_.type -eq 'required_reviewers' } | Select-Object -First 1
$names = ($rule.reviewers | ForEach-Object { $_.reviewer.login }) -join ', '
$mode = if ($rule.prevent_self_review) { 'ON - a second person must approve' } else { 'OFF - the person who starts a deployment can approve it' }
Write-Host "  [ok]   Environment '$Environment': required reviewer(s): $names" -ForegroundColor Green
Write-Host "  [ok]   Prevent self-review: $mode" -ForegroundColor Green
Write-Host "  [ok]   Deployments allowed from: main only" -ForegroundColor Green
exit 0
