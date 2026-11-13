<#
.SYNOPSIS
    Maakt per klant-tenant een read-only app registration voor Microsoft365DSC-export,
    met een certificaat dat in Azure Key Vault (MSP-tenant) wordt aangemaakt.

.DESCRIPTION
    1. Maakt (of vernieuwt) een certificaat in de Key Vault van de MSP. De private key verlaat de vault
       alleen via de pipeline (AzureKeyVault-task); er komt geen PFX op schijf.
    2. Maakt de app registration in de klant-tenant aan met ALLEEN de Read-permissies die
       Microsoft365DSC nodig heeft voor de gekozen workloads en geeft admin consent.
    3. Koppelt het publieke certificaat (.cer) aan de app.
    4. Kent de directory-rol 'Global Reader' toe aan de service principal (nodig voor EXO/Teams/SC export).

    Uitvoeren als: Global Administrator (of Privileged Role Admin + Cloud Application Admin)
    van de KLANT-tenant, en met 'Key Vault Certificates Officer' op de MSP Key Vault.
    Draai op Windows PowerShell 5.1 met Microsoft365DSC, Az.Accounts en Az.KeyVault geïnstalleerd.
#>

[CmdletBinding()]
param(
    # ===================== KLANT-TENANT =====================
    [Parameter(Mandatory)] [string] $TenantDomain,                    # bv. contoso.onmicrosoft.com
    [string] $ApplicationName = 'MSP-M365DSC-Export-ReadOnly',

    # ===================== MSP KEY VAULT =====================
    [Parameter(Mandatory)] [string] $KeyVaultSubscriptionId,
    [Parameter(Mandatory)] [string] $KeyVaultName,                    # bv. kv-msp-m365dsc
    [string] $CertificateName = '',                                   # leeg = m365dsc-<tenant>
    [ValidateRange(1,24)] [int] $CertificateValidityMonths = 12,

    # ===================== SCOPE =====================
    [ValidateSet('AAD','EXO','INTUNE','O365','OD','PLANNER','PP','SC','SPO','TEAMS')]
    [string[]] $Workloads = @('AAD','EXO','INTUNE','SPO','TEAMS','SC','OD','O365'),
    [switch] $SkipGlobalReader
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

if (-not $CertificateName) { $CertificateName = 'm365dsc-' + ($TenantDomain -replace '[^a-zA-Z0-9-]', '-') }
$workDir = Join-Path $env:TEMP ("m365dsc-" + [guid]::NewGuid())
New-Item -ItemType Directory $workDir | Out-Null

try {
    Import-Module Microsoft365DSC, Az.Accounts, Az.KeyVault

    # ---------- 1. Certificaat in Key Vault (MSP-tenant) ----------
    Write-Step "Certificaat '$CertificateName' in Key Vault '$KeyVaultName'"
    Connect-AzAccount -Subscription $KeyVaultSubscriptionId | Out-Null
    $policy = New-AzKeyVaultCertificatePolicy -SubjectName "CN=$CertificateName" -IssuerName Self `
        -ValidityInMonths $CertificateValidityMonths -KeyType RSA -KeySize 2048 `
        -SecretContentType 'application/x-pkcs12' -ReuseKeyOnRenewal:$false
    Add-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName -CertificatePolicy $policy | Out-Null

    do {
        Start-Sleep 5
        $op = Get-AzKeyVaultCertificateOperation -VaultName $KeyVaultName -Name $CertificateName
    } while ($op.Status -eq 'inProgress')
    if ($op.Status -ne 'completed') { throw "Certificaat aanmaken faalde: $($op.Status) $($op.ErrorMessage)" }

    $kvCert  = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName
    $cerPath = Join-Path $workDir "$CertificateName.cer"
    [IO.File]::WriteAllBytes($cerPath, $kvCert.Certificate.Export('Cert'))   # alleen publiek deel

    # ---------- 2+3. App registration + Read-permissies + consent ----------
    Write-Step "Permissies bepalen voor workloads: $($Workloads -join ', ')"
    $resources   = Get-M365DSCAllResources | Where-Object {
        $prefix = ($_ -replace '^MSFT_', '') -replace '^(AAD|EXO|INTUNE|O365|OD|PLANNER|PP|SC|SPO|TEAMS).*', '$1'
        $Workloads -contains $prefix
    }
    $permissions = Get-M365DSCCompiledPermissionList -ResourceNameList $resources -PermissionType Application -AccessType Read

    Write-Step "App registration '$ApplicationName' in $TenantDomain (interactieve login klant-tenant)"
    Update-M365DSCAzureAdApplication -ApplicationName $ApplicationName -Permissions $permissions `
        -Type Certificate -CertificatePath $cerPath -AdminConsent

    # ---------- 4. Global Reader ----------
    Connect-MgGraph -TenantId $TenantDomain -Scopes 'Application.Read.All','RoleManagement.ReadWrite.Directory' -NoWelcome
    $sp = Get-MgServicePrincipal -Filter "displayName eq '$ApplicationName'" | Select-Object -First 1
    if (-not $sp) { throw 'Service principal niet gevonden.' }

    if (-not $SkipGlobalReader) {
        Write-Step 'Global Reader toekennen aan service principal'
        $roleId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'   # Global Reader (vaste template-id)
        $exists = Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$($sp.Id)' and roleDefinitionId eq '$roleId'"
        if (-not $exists) {
            New-MgRoleManagementDirectoryRoleAssignment -PrincipalId $sp.Id -RoleDefinitionId $roleId -DirectoryScopeId '/' | Out-Null
        }
    }

    $tenantId = (Get-MgContext).TenantId
    Write-Host ''
    Write-Host 'Gereed. Gebruik deze waarden in de pipeline (tenants-lijst):' -ForegroundColor Green
    [pscustomobject]@{
        name            = ($TenantDomain -split '\.')[0]
        tenantDomain    = $TenantDomain
        tenantId        = $tenantId
        applicationId   = $sp.AppId
        certificateName = $CertificateName
        certExpires     = $kvCert.Expires
    } | Format-List
}
finally {
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
