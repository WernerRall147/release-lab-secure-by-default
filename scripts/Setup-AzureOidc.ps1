<#
.SYNOPSIS
    Creates (or re-uses) the Microsoft Entra app registration that lets the "production" environment of this
    repository sign in to Azure with OpenID Connect. No client secret and no certificate are created.

.DESCRIPTION
    1. Gets a Microsoft Graph token for the tenant of the named subscription (az account get-access-token).
       It never runs "az login" or "az account set" and never touches the default subscription.
    2. Creates the app registration, its service principal and one federated credential whose subject is
       repo:<owner>/<repo>:environment:<environment>.
    3. If the resource group already exists, grants the app the Reader role on that group only.
       Nothing inside the resource group is created, changed or deleted.
    4. Stores the three identifiers in repository VARIABLES (AZURE_CLIENT_ID, AZURE_TENANT_ID,
       AZURE_SUBSCRIPTION_ID). The values are never printed.

    The script is idempotent: running it again re-uses what already exists.

.PARAMETER SubscriptionName
    Display name of the Azure subscription to use. It is passed with --subscription to every az command.

.EXAMPLE
    .\scripts\Setup-AzureOidc.ps1 -SubscriptionName "<subscription display name>"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionName,
    [string] $Repository = 'WernerRall147/release-lab-secure-by-default',
    [string] $Environment = 'production',
    [string] $ResourceGroup = 'rg-release-lab',
    [string] $AppName = 'release-lab-secure-by-default-oidc',
    [switch] $SkipRoleAssignment
)

$ErrorActionPreference = 'Stop'
$graph = 'https://graph.microsoft.com/v1.0'

function Get-JwtClaim([string] $Jwt, [string] $Name) {
    $payload = $Jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
    while ($payload.Length % 4) { $payload += '=' }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    return $json.$Name
}

function Invoke-Graph([string] $Method, [string] $Path, $Body = $null) {
    $request = @{
        Method  = $Method
        Uri     = "$graph$Path"
        Headers = @{ Authorization = "Bearer $script:token" }
    }
    if ($null -ne $Body) {
        $request.Body = ($Body | ConvertTo-Json -Depth 6)
        $request.ContentType = 'application/json'
    }
    # Graph is eventually consistent: a brand-new app can take a few seconds to become visible.
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try { return Invoke-RestMethod @request }
        catch {
            $text = "$($_.Exception.Message) $($_.ErrorDetails.Message)"
            if ($attempt -eq 6 -or $text -notmatch '404|does not exist|not found|valid application') { throw }
            Start-Sleep -Seconds 4
        }
    }
}

# --- Identify the target without printing identifiers ---
$sub = az account show --subscription $SubscriptionName --query '{id:id,tenantId:tenantId}' --output json | ConvertFrom-Json
if (-not $sub) { throw "Subscription '$SubscriptionName' was not found in the Azure CLI cache." }

$script:token = az account get-access-token --subscription $SubscriptionName --resource-type ms-graph --query accessToken --output tsv
if ((Get-JwtClaim $script:token 'tid') -ne $sub.tenantId) {
    throw 'The Graph token belongs to a different tenant than the subscription. Stopping.'
}
Write-Host 'Graph token acquired for the tenant of the named subscription.'

# --- App registration ---
$filter = [uri]::EscapeDataString("displayName eq '$AppName'")
$app = (Invoke-Graph GET "/applications?`$filter=$filter").value | Select-Object -First 1
if ($app) {
    Write-Host "App registration '$AppName' already exists - re-using it."
} else {
    $app = Invoke-Graph POST '/applications' @{ displayName = $AppName; signInAudience = 'AzureADMyOrg' }
    Write-Host "Created app registration '$AppName'."
}

# --- Service principal ---
$spFilter = [uri]::EscapeDataString("appId eq '$($app.appId)'")
$sp = (Invoke-Graph GET "/servicePrincipals?`$filter=$spFilter").value | Select-Object -First 1
if (-not $sp) {
    $sp = Invoke-Graph POST '/servicePrincipals' @{ appId = $app.appId }
    Write-Host 'Created the service principal.'
} else {
    Write-Host 'Service principal already exists - re-using it.'
}

# --- Federated credential (subject = this repository + environment) ---
$subject = "repo:${Repository}:environment:${Environment}"
$credName = "github-environment-$Environment"
$existing = (Invoke-Graph GET "/applications/$($app.id)/federatedIdentityCredentials").value | Where-Object { $_.name -eq $credName }
if ($existing -and $existing.subject -ne $subject) {
    Invoke-Graph DELETE "/applications/$($app.id)/federatedIdentityCredentials/$($existing.id)" | Out-Null
    $existing = $null
}
if (-not $existing) {
    Invoke-Graph POST "/applications/$($app.id)/federatedIdentityCredentials" @{
        name        = $credName
        issuer      = 'https://token.actions.githubusercontent.com'
        subject     = $subject
        audiences   = @('api://AzureADTokenExchange')
        description = "GitHub Actions, environment '$Environment' of $Repository"
    } | Out-Null
    Write-Host "Created federated credential for subject: $subject"
} else {
    Write-Host "Federated credential already exists for subject: $subject"
}

# --- Reader on the resource group, only if it already exists ---
if ($SkipRoleAssignment) {
    Write-Host 'Role assignment skipped by request.'
} else {
    $rgExists = az group exists --name $ResourceGroup --subscription $SubscriptionName
    if ($rgExists -ne 'true') {
        Write-Warning "Resource group '$ResourceGroup' does not exist yet. Re-run this script after it has been created to grant Reader."
    } else {
        $scope = "/subscriptions/$($sub.id)/resourceGroups/$ResourceGroup"
        $assigned = @(az role assignment list --assignee-object-id $sp.id --scope $scope --role Reader --subscription $SubscriptionName --output json | ConvertFrom-Json)
        if ($assigned.Count -gt 0) {
            Write-Host "Reader on '$ResourceGroup' already assigned."
        } else {
            az role assignment create --assignee-object-id $sp.id --assignee-principal-type ServicePrincipal --role Reader --scope $scope --subscription $SubscriptionName --output none
            Write-Host "Granted Reader on '$ResourceGroup' (resource group scope only)."
        }
    }
}

# --- Repository variables (values never printed) ---
$values = [ordered]@{
    AZURE_CLIENT_ID       = $app.appId
    AZURE_TENANT_ID       = $sub.tenantId
    AZURE_SUBSCRIPTION_ID = $sub.id
}
foreach ($name in $values.Keys) {
    gh variable set $name --repo $Repository --body $values[$name]
    if ($LASTEXITCODE -ne 0) { throw "Could not set the variable $name" }
}
Write-Host ('Repository variables set: ' + ($values.Keys -join ', ') + ' (values not shown).')
Write-Host 'Done. No secret was created.'
