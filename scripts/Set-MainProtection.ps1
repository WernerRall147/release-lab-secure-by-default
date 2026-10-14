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

Set-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)   # the scripts work from any directory
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

function Find-Ruleset {
    $text = (Invoke-Gh @('api', "repos/$slug/rulesets")) -join "`n"
    $list = $text | ConvertFrom-Json
    return $list | Where-Object { $_.name -eq $rulesetName } | Select-Object -First 1
}

function Set-Enforcement([string] $Value) {
    $existing = Find-Ruleset
    if (-not $existing) { throw "Ruleset '$rulesetName' does not exist. Run with -Action Apply first." }
    $null = Invoke-Gh @('api', '-X', 'PUT', "repos/$slug/rulesets/$($existing.id)", '--input', '-') (@{ enforcement = $Value } | ConvertTo-Json -Compress)
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
            $null = Invoke-Gh @('api', '-X', 'PUT', "repos/$slug/rulesets/$($existing.id)", '--input', '-') $json
        } else {
            $null = Invoke-Gh @('api', '-X', 'POST', "repos/$slug/rulesets", '--input', '-') $json
        }
        $applied = Find-Ruleset
        Say "Ruleset '$rulesetName' applied (enforcement: $($applied.enforcement))."
    }
}
exit 0
