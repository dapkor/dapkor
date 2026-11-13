<#
.SYNOPSIS
    Exporteert de Microsoft365DSC-configuratie van één tenant naar een Git-repo en -branch.

.DESCRIPTION
    1. Installeert/controleert Microsoft365DSC (vaste versie) en de afhankelijkheden.
    2. Clonet of update de repo en checkt de branch uit (maakt die aan als hij niet bestaat).
    3. Exporteert de tenantconfiguratie met certificate-based app-only authenticatie.
    4. Commit en pusht alleen als er wijzigingen zijn.

    Beveiliging:
    - Geen secrets in het script: app-only authenticatie met een certificaat uit de certificate store.
    - Git-authenticatie loopt via Git Credential Manager / SSH-key, of via een PAT in een
      omgevingsvariabele (bijv. vanuit een pipeline-secret of Azure Key Vault). De PAT wordt nooit gelogd.
    - Geef de app registration ALLEEN leesrechten (Read.All); voor export zijn geen schrijfrechten nodig.

.EXAMPLE
    .\Export-M365DSCToRepo.ps1 -TenantDomain contoso.onmicrosoft.com -ApplicationId <guid> `
        -CertificateThumbprint <thumbprint> -RepoUrl https://dev.azure.com/org/proj/_git/m365dsc -Branch tenant/contoso
#>

[CmdletBinding()]
param(
    # ===================== TENANT =====================
    [Parameter(Mandatory)] [string] $TenantDomain,            # bv. contoso.onmicrosoft.com
    [Parameter(Mandatory)] [string] $ApplicationId,           # App registration (client) ID
    [Parameter(Mandatory)] [string] $CertificateThumbprint,   # Cert in Cert:\CurrentUser\My of Cert:\LocalMachine\My

    # ===================== REPO =====================
    [Parameter(Mandatory)] [string] $RepoUrl,                 # HTTPS- of SSH-URL (Azure DevOps / GitHub)
    [Parameter(Mandatory)] [string] $Branch,                  # bv. tenant/contoso
    [string] $LocalRepoPath   = (Join-Path $env:TEMP 'm365dsc-repo'),
    [string] $ExportSubFolder = '',                           # leeg = <TenantDomain>
    [string] $GitUserName     = 'M365DSC Export',
    [string] $GitUserEmail    = 'm365dsc-export@noreply.local',
    [string] $GitPatEnvVar    = 'M365DSC_GIT_PAT',            # optioneel: naam van env-var met PAT / System.AccessToken
    [ValidateSet('Basic','Bearer')]
    [string] $GitAuthScheme   = 'Basic',                      # Basic = PAT, Bearer = Azure DevOps System.AccessToken

    # ===================== EXPORT =====================
    [ValidateSet('AAD','EXO','INTUNE','O365','OD','PLANNER','PP','SC','SPO','TEAMS')]
    [string[]] $Workloads     = @('AAD','EXO','INTUNE','SPO','TEAMS','SC','OD','O365'),
    [string[]] $Components    = @(),                          # indien gevuld: overschrijft Workloads
    [string]   $M365DSCVersion = ''                           # leeg = laatste; aanbevolen: vastpinnen
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments)] [string[]] $GitArgs)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs[0]) faalde (exitcode $LASTEXITCODE)" }
}

# ---------- Voorcontroles ----------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is niet geïnstalleerd of niet in PATH.' }
if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Warning 'Microsoft365DSC wordt officieel ondersteund op Windows PowerShell 5.1.'
}

$cert = Get-ChildItem -Path Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object Thumbprint -eq $CertificateThumbprint | Select-Object -First 1
if (-not $cert)                 { throw "Certificaat $CertificateThumbprint niet gevonden." }
if (-not $cert.HasPrivateKey)   { throw 'Certificaat heeft geen private key.' }
if ($cert.NotAfter -lt (Get-Date)) { throw "Certificaat is verlopen op $($cert.NotAfter)." }

# ---------- Module ----------
Write-Step 'Microsoft365DSC controleren/installeren'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$installParams = @{ Name = 'Microsoft365DSC'; Scope = 'AllUsers'; Force = $true; AllowClobber = $true }
if ($M365DSCVersion) { $installParams.RequiredVersion = $M365DSCVersion }

$installed = Get-Module -ListAvailable Microsoft365DSC | Sort-Object Version -Descending | Select-Object -First 1
if (-not $installed -or ($M365DSCVersion -and $installed.Version -ne [version]$M365DSCVersion)) {
    Install-Module @installParams
}
Import-Module Microsoft365DSC -Force
Update-M365DSCDependencies
Uninstall-M365DSCOutdatedDependencies -ErrorAction SilentlyContinue

# ---------- Repo ----------
Write-Step "Repo voorbereiden: $RepoUrl ($Branch)"
$cloneUrl = $RepoUrl
$pat = [Environment]::GetEnvironmentVariable($GitPatEnvVar)
$gitAuthArgs = @()
if ($pat -and $RepoUrl -like 'https://*') {
    # PAT via HTTP-header i.p.v. in de URL -> komt niet in .git/config of logs terecht
    if ($GitAuthScheme -eq 'Bearer') {
        $gitAuthArgs = @('-c', "http.extraHeader=Authorization: Bearer $pat")
    } else {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("pat:$pat"))
        $gitAuthArgs = @('-c', "http.extraHeader=Authorization: Basic $b64")
    }
}

if (-not (Test-Path (Join-Path $LocalRepoPath '.git'))) {
    if (Test-Path $LocalRepoPath) { Remove-Item $LocalRepoPath -Recurse -Force }
    Invoke-Git @gitAuthArgs clone $cloneUrl $LocalRepoPath
}
Push-Location $LocalRepoPath
try {
    Invoke-Git config user.name  $GitUserName
    Invoke-Git config user.email $GitUserEmail
    Invoke-Git @gitAuthArgs fetch origin --prune

    & git ls-remote --exit-code --heads origin $Branch *> $null
    if ($LASTEXITCODE -eq 0) {
        Invoke-Git checkout -B $Branch "origin/$Branch"
    } else {
        Write-Host "Branch $Branch bestaat nog niet; wordt aangemaakt."
        Invoke-Git checkout -B $Branch
    }

    # ---------- Export ----------
    $folder     = if ($ExportSubFolder) { $ExportSubFolder } else { $TenantDomain }
    $exportPath = Join-Path $LocalRepoPath $folder
    if (Test-Path $exportPath) { Remove-Item $exportPath -Recurse -Force }   # schone export -> verwijderingen zichtbaar in diff
    New-Item -ItemType Directory -Path $exportPath -Force | Out-Null

    Write-Step "Export van $TenantDomain naar $exportPath"
    $exportParams = @{
        ApplicationId         = $ApplicationId
        CertificateThumbprint = $CertificateThumbprint
        TenantId              = $TenantDomain
        Path                  = $exportPath
        FileName              = 'M365TenantConfig.ps1'
    }
    if ($Components.Count -gt 0) { $exportParams.Components = $Components }
    else                         { $exportParams.Workloads  = $Workloads }

    Export-M365DSCConfiguration @exportParams

    # Veiligheidscheck: geen private keys/secrets committen
    Get-ChildItem $exportPath -Recurse -Include *.pfx, *.key | Remove-Item -Force

    # ---------- Commit & push ----------
    Invoke-Git add -A -- $folder
    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Step 'Geen wijzigingen t.o.v. vorige export; niets te committen.'
    } else {
        $msg = "M365DSC export $TenantDomain $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        Invoke-Git commit -m $msg
        Invoke-Git @gitAuthArgs push -u origin $Branch
        Write-Step "Gepusht naar $Branch"
    }
}
finally {
    Pop-Location
    $pat = $null; $gitAuthArgs = $null
}
