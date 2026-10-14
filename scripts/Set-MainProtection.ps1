<#
.SYNOPSIS
    Creates, shows, enables or disables the ruleset that protects the main branch.

.DESCRIPTION
    The ruleset definition lives in .github\rulesets\main.json (pull request with 1 approving review,
    required status checks, no force pushes, no branch deletion, no bypass actors).

      Apply    create the ruleset, or update it if it already exists
      Show     print the state: active, disabled or none
      Disable  switch enforcement off   (maintenance only: lets the owner push to main directly)
      Enable   switch enforcement back on

    Everything is done with `gh api` against this one repository.

.EXAMPLE
    .\scripts\Set-MainProtection.ps1 -Action Apply
.EXAMPLE
    .\scripts\Set-MainProtection.ps1 -Action Show
#>
[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Show', 'Enable', 'Disable')]
    [string] $Action = 'Show',
    [string] $RulesetFile,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
$env:GH_PAGER = ''

$remoteUrl = (& git remote get-url origin 2>&1 | Select-Object -First 1)
if ($remoteUrl -notmatch 'github\.com[:/](?<slug>[^/]+/release-lab-secure-by-default)(\.git)?/?$') {
    throw "The 'origin' remote is not the release-lab-secure-by-default repository."
}
$slug = $Matches['slug']
if (-not $RulesetFile) { $RulesetFile = Join-Path $PSScriptRoot '..\.github\rulesets\main.json' }
$rulesetName = 'Protect main'

function Say([string] $Text, [string] $Color = 'Green') {
    if (-not $Quiet) { Write-Host "  [ok]   $Text" -ForegroundColor $Color }
}

function Find-Ruleset {
    $list = (& gh api "repos/$slug/rulesets" 2>&1) | ConvertFrom-Json
    return $list | Where-Object { $_.name -eq $rulesetName } | Select-Object -First 1
}

function Set-Enforcement([string] $Value) {
    $existing = Find-Ruleset
    if (-not $existing) { throw "Ruleset '$rulesetName' does not exist. Run with -Action Apply first." }
    $out = (@{ enforcement = $Value } | ConvertTo-Json -Compress) | & gh api -X PUT "repos/$slug/rulesets/$($existing.id)" --input - 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not set enforcement to ${Value}: $out" }
}

switch ($Action) {
    'Show' {
        $existing = Find-Ruleset
        $state = if ($existing) { $existing.enforcement } else { 'none' }
        if ($Quiet) { Write-Output $state } else { Write-Host "  Ruleset '$rulesetName' on main: $state" }
    }
    'Disable' {
        Set-Enforcement 'disabled'
        Say "Ruleset '$rulesetName' is DISABLED. Enable it again when the maintenance push is done." 'Yellow'
    }
    'Enable' {
        Set-Enforcement 'active'
        Say "Ruleset '$rulesetName' is ACTIVE on main."
    }
    'Apply' {
        if (-not (Test-Path $RulesetFile)) { throw "Ruleset definition not found: $RulesetFile" }
        $json = Get-Content -Raw -Path $RulesetFile
        $existing = Find-Ruleset
        if ($existing) {
            $out = $json | & gh api -X PUT "repos/$slug/rulesets/$($existing.id)" --input - 2>&1
        } else {
            $out = $json | & gh api -X POST "repos/$slug/rulesets" --input - 2>&1
        }
        if ($LASTEXITCODE -ne 0) { throw "Could not apply the ruleset: $out" }
        $applied = Find-Ruleset
        Say "Ruleset '$rulesetName' applied (enforcement: $($applied.enforcement))."
    }
}
exit 0
