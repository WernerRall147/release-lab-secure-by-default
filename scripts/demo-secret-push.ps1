<#
.SYNOPSIS
    Shows GitHub push protection blocking a FAKE credential before it is saved in the repository.

.DESCRIPTION
    1. Creates a temporary branch.
    2. Adds a settings file that contains a FAKE credential. The value is generated at random when the script
       runs: no credential, real or fake, is stored in this repository or in this script.
    3. Commits the file and runs "git push". GitHub rejects the push, so the value never reaches the repository.
    4. Goes back to the original branch and deletes the temporary branch locally and, if it exists, on GitHub.

    Safety checks before anything is created: the script must run in a clone whose remote is this demo
    repository, the working tree must be clean, and push protection must be reported as "enabled" by GitHub.
    If a push is ever accepted, the script deletes the remote branch again and says so loudly.

    GitHub prints a one-time "allow the secret" link in the rejection. The script hides its token on purpose.
    Never use that link: bypassing push protection is not part of this demo.

.PARAMETER Provider
    Which kind of fake credential to generate. Twilio (SMS gateway key) is the default.
    AzureStorage, Databricks and Linear are alternatives, handy as a plan B.

.PARAMETER Remote
    Name of the git remote that points at the demo repository. Default: origin.

.PARAMETER Pause
    Wait for Enter before each step, so each step can be explained while presenting.

.EXAMPLE
    .\scripts\demo-secret-push.ps1
.EXAMPLE
    .\scripts\demo-secret-push.ps1 -Pause
#>
[CmdletBinding()]
param(
    [ValidateSet('Twilio', 'AzureStorage', 'Databricks', 'Linear')]
    [string] $Provider = 'Twilio',
    [string] $Remote = 'origin',
    [switch] $Pause
)

$ErrorActionPreference = 'Continue'
$env:GIT_TERMINAL_PROMPT = '0'
$env:GIT_PAGER = ''
$env:GH_PAGER = ''
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$script:gitExit = 0
$script:root = $null
function Invoke-Git {
    if ($script:root) { $text = & git -C $script:root @args 2>&1 | ForEach-Object { "$_" } }
    else { $text = & git @args 2>&1 | ForEach-Object { "$_" } }
    $script:gitExit = $LASTEXITCODE
    return $text
}

function Write-Step([string] $Title) {
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    if ($Pause) { Read-Host '   (press Enter to run this step)' | Out-Null }
}

function New-RandomText([int] $Length, [string] $Alphabet) {
    $bytes = New-Object byte[] $Length
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $chars = New-Object char[] $Length
    for ($i = 0; $i -lt $Length; $i++) { $chars[$i] = $Alphabet[$bytes[$i] % $Alphabet.Length] }
    return (-join $chars)
}

$hex = '0123456789abcdef'
$alnum = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
$base64 = $alnum + '+/'

# Fake values built at run time, in the shape GitHub's secret scanning recognises for each provider.
switch ($Provider) {
    'Twilio' {
        $settingLine = 'TWILIO_API_KEY=SK' + (New-RandomText 32 $hex)
        $expectedName = 'Twilio API Key'
        $comment = 'SMS gateway used for payment notifications (synthetic)'
    }
    'AzureStorage' {
        $settingLine = 'STATEMENTS_STORAGE_CONNECTION=DefaultEndpointsProtocol=https;AccountName=stcontosodemo;AccountKey=' +
            (New-RandomText 86 $base64) + '==;EndpointSuffix=core.windows.net'
        $expectedName = 'Azure Storage Account Access Key'
        $comment = 'Storage account for payment statements (synthetic)'
    }
    'Databricks' {
        $settingLine = 'DATABRICKS_TOKEN=dapi' + (New-RandomText 32 $hex)
        $expectedName = 'Databricks API Token'
        $comment = 'Analytics workspace (synthetic)'
    }
    'Linear' {
        $settingLine = 'LINEAR_API_KEY=lin_api_' + (New-RandomText 40 $alnum)
        $expectedName = 'Linear API Key'
        $comment = 'Issue tracker integration (synthetic)'
    }
}

$stopwatch = [Diagnostics.Stopwatch]::StartNew()

# --- Safety checks -------------------------------------------------------------------------------------------
$root = Invoke-Git rev-parse --show-toplevel | Select-Object -First 1
if ($script:gitExit -ne 0 -or -not $root) { throw 'Run this script inside a clone of the demo repository.' }
$script:root = $root

$remoteUrl = Invoke-Git remote get-url $Remote | Select-Object -First 1
if ($script:gitExit -ne 0 -or $remoteUrl -notmatch 'github\.com[:/](?<slug>[^/]+/release-lab-secure-by-default)(\.git)?/?$') {
    throw "Remote '$Remote' is not the release-lab-secure-by-default repository. Nothing was created."
}
$slug = $Matches['slug']

if (Invoke-Git status --porcelain) { throw 'The working tree has uncommitted changes. Commit or stash them first. Nothing was created.' }

$original = Invoke-Git rev-parse --abbrev-ref HEAD | Select-Object -First 1
if ($original -eq 'HEAD') { throw 'Detached HEAD. Check out a branch first. Nothing was created.' }
$originalSha = Invoke-Git rev-parse HEAD | Select-Object -First 1

$protection = & gh api "repos/$slug" --jq '.security_and_analysis.secret_scanning_push_protection.status' 2>$null
if ("$protection".Trim() -ne 'enabled') {
    throw "GitHub does not report push protection as 'enabled' for $slug (got '$protection'). Nothing was pushed."
}

$branch = 'demo/secret-push-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$settingsPath = 'config/notifications.ini'
$outcome = 'error'

Write-Host ''
Write-Host "Repository : $slug   (push protection: $protection)" -ForegroundColor Gray
Write-Host "Fake secret: $expectedName (random value, generated just now)" -ForegroundColor Gray

try {
    # --- 1. Branch -------------------------------------------------------------------------------------------
    Write-Step "1. A developer starts a new branch: $branch"
    Write-Host "> git checkout -b $branch" -ForegroundColor DarkGray
    Invoke-Git checkout -b $branch | ForEach-Object { Write-Host "  $_" }
    if ($script:gitExit -ne 0) { throw 'Could not create the temporary branch.' }

    # --- 2. File with the fake credential --------------------------------------------------------------------
    Write-Step "2. ...and pastes an API key into a settings file ($settingsPath)"
    $fileText = "# Contoso Bank - Payments Status API (synthetic demo)`n" +
        "# $comment`n" +
        "# The value below is FAKE: it was generated at random a moment ago.`n" +
        "[notifications]`n" +
        "sender = Contoso Payments`n" +
        $settingLine + "`n"
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'config') | Out-Null
    [IO.File]::WriteAllText((Join-Path $root $settingsPath), $fileText, (New-Object Text.UTF8Encoding($false)))
    Get-Content (Join-Path $root $settingsPath) | ForEach-Object { Write-Host "  | $_" -ForegroundColor Yellow }

    # --- 3. Commit -------------------------------------------------------------------------------------------
    Write-Step '3. ...and commits it. Git saves it on this computer without complaint.'
    Write-Host "> git add $settingsPath" -ForegroundColor DarkGray
    Invoke-Git add $settingsPath | Out-Null
    Write-Host '> git commit -m "Add SMS notification settings"' -ForegroundColor DarkGray
    Invoke-Git commit -m 'Add SMS notification settings' | ForEach-Object { Write-Host "  $_" }
    $headSha = Invoke-Git rev-parse HEAD | Select-Object -First 1
    if ($script:gitExit -ne 0 -or $headSha -eq $originalSha) { throw 'The commit was not created. Stopping before any push.' }

    # --- 4. Push ---------------------------------------------------------------------------------------------
    Write-Step '4. Now the push: this is the moment GitHub looks inside the commit.'
    Write-Host "> git push $Remote $branch" -ForegroundColor DarkGray
    $pushStart = Get-Date
    $pushOutput = Invoke-Git push $Remote $branch
    $pushExit = $script:gitExit
    $pushSeconds = [math]::Round(((Get-Date) - $pushStart).TotalSeconds, 1)
    foreach ($line in $pushOutput) {
        $shown = $line -replace '(unblock-secret/)\S+', '$1<hidden - never use this link>'
        if ($shown -match 'GH013|rejected|error:|failed to push') { Write-Host $shown -ForegroundColor Red }
        elseif ($shown -match '^remote:\s+(\u2014\u2014|--)\s') { Write-Host $shown -ForegroundColor Yellow }
        else { Write-Host $shown -ForegroundColor Gray }
    }

    $blocked = ($pushExit -ne 0) -and (($pushOutput -join "`n") -match 'GH013|PUSH PROTECTION')
    if ($blocked) {
        $outcome = 'blocked'
        Write-Host ''
        Write-Host "BLOCKED in $pushSeconds s: GitHub push protection rejected the push." -ForegroundColor Green
        Write-Host 'The credential was never saved in the repository. Only this laptop has the commit.' -ForegroundColor Green
    }
    elseif ($pushExit -eq 0) {
        $outcome = 'accepted'
        Write-Host ''
        Write-Host 'WARNING: GitHub ACCEPTED the push. The fake value is now in the remote branch.' -ForegroundColor Red
    }
    else {
        Write-Host ''
        Write-Host 'The push failed for a reason that is not push protection (network or sign-in?). See the output above.' -ForegroundColor Red
    }
}
finally {
    # --- 5. Clean up (always runs) ---------------------------------------------------------------------------
    Write-Host ''
    Write-Host '5. Clean-up' -ForegroundColor Cyan
    if ((Invoke-Git rev-parse --abbrev-ref HEAD | Select-Object -First 1) -ne $original) {
        Invoke-Git checkout $original | Out-Null
    }
    $localBranch = Invoke-Git branch --list $branch
    if ($localBranch) {
        Invoke-Git branch -D $branch | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
    $remoteBranch = Invoke-Git ls-remote --heads $Remote $branch
    if ($remoteBranch) {
        Write-Host "  The branch exists on GitHub - deleting it now." -ForegroundColor Yellow
        Invoke-Git push $Remote --delete $branch | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
    else {
        Write-Host "  GitHub has no branch '$branch': there was nothing to delete there." -ForegroundColor Gray
    }
    $alerts = & gh api "repos/$slug/secret-scanning/alerts?per_page=100" --jq 'length' 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host "  Secret scanning alerts in the repository: $alerts (a blocked push leaves none)" -ForegroundColor Gray }
    Write-Host "  Back on branch '$original'. Local temporary branch deleted." -ForegroundColor Gray
}

Write-Host ''
Write-Host ("Total time: {0} s" -f [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)) -ForegroundColor DarkGray
if ($outcome -eq 'accepted') {
    Write-Host 'A fake value reached GitHub. The remote branch was deleted. Tell whoever owns the repository.' -ForegroundColor Red
    exit 2
}
if ($outcome -ne 'blocked') { exit 1 }
exit 0
