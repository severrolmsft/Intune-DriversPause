#requires -Version 5.1

<#
.SYNOPSIS
    Liste les profils Windows Driver Update Intune ou leur inventaire de pilotes.

.DESCRIPTION
    Retourne un document JSON utilise par l'interface graphique. Ce script est
    strictement en lecture seule.

.PARAMETER KeepGraphConnection
    Reserve a l'interface : reutilise le contexte Graph et laisse la connexion
    ouverte. L'appelant est responsable de la deconnexion.
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    '',
    Justification = 'Les parametres sont utilises par les fonctions internes du script.'
)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Profiles', 'Drivers', 'Snapshot')]
    [string] $Resource,

    [Parameter()]
    [string] $ProfileId,

    [Parameter()]
    [ValidateSet('Interactive', 'ClientSecret', 'Certificate', 'ManagedIdentity', 'CurrentContext')]
    [string] $AuthenticationMode = 'Interactive',

    [Parameter()]
    [string] $TenantId,

    [Parameter()]
    [string] $ClientId,

    [Parameter()]
    [securestring] $ClientSecret,

    [Parameter()]
    [string] $CertificateThumbprint,

    [Parameter()]
    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string] $CertificateStoreLocation = 'LocalMachine',

    [Parameter(DontShow = $true)]
    [switch] $KeepGraphConnection
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$graphRoot = 'https://graph.microsoft.com/beta'
$connectedByScript = $false
$grantedApplicationRoles = @()
$canWriteDriverConfiguration = $true

function Get-GraphStatusCode {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.ErrorRecord] $ErrorRecord
    )

    foreach ($propertyName in @('ResponseStatusCode', 'StatusCode')) {
        $property = $ErrorRecord.Exception.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $null -ne $property.Value) {
            return [int] $property.Value
        }
    }

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
        $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
        if ($null -ne $statusProperty -and $null -ne $statusProperty.Value) {
            return [int] $statusProperty.Value
        }
    }

    return $null
}

function Invoke-GraphRequestWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [ValidateRange(1, 10)]
        [int] $MaximumAttempts = 4
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            return Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject
        }
        catch {
            $statusCode = Get-GraphStatusCode -ErrorRecord $_
            $isTransient = $statusCode -in @(429, 500, 502, 503, 504)
            if (-not $isTransient -or $attempt -eq $MaximumAttempts) {
                throw
            }

            Start-Sleep -Seconds ([Math]::Min(60, [Math]::Pow(2, $attempt)))
        }
    }
}

function Get-GraphCollection {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri
    )

    $items = New-Object 'Collections.Generic.List[object]'
    $nextUri = $Uri

    while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
        $response = Invoke-GraphRequestWithRetry -Uri $nextUri
        foreach ($item in @($response.value)) {
            if ($null -ne $item) {
                $items.Add($item)
            }
        }

        $nextLinkProperty = $response.PSObject.Properties['@odata.nextLink']
        $nextUri = if ($null -ne $nextLinkProperty) {
            [string] $nextLinkProperty.Value
        }
        else {
            $null
        }
    }

    return $items.ToArray()
}

function Connect-GraphCompatible {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Parameters
    )

    $connectCommand = Get-Command Connect-MgGraph -ErrorAction Stop
    if ($KeepGraphConnection -and -not $Parameters.ContainsKey('AccessToken')) {
        $Parameters.ContextScope = 'Process'
    }
    if ($connectCommand.Parameters.ContainsKey('NoWelcome')) {
        $Parameters.NoWelcome = $true
    }
    Connect-MgGraph @Parameters | Out-Null
}

function Get-JwtApplicationRole {
    param(
        [Parameter(Mandatory = $true)]
        [string] $AccessToken
    )

    $payloadPart = $AccessToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
    while (($payloadPart.Length % 4) -ne 0) {
        $payloadPart += '='
    }
    $payloadJson = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($payloadPart)
    )
    return @((ConvertFrom-Json -InputObject $payloadJson).roles)
}

function Connect-GraphWithClientSecret {
    if ([string]::IsNullOrWhiteSpace($TenantId) -or
        [string]::IsNullOrWhiteSpace($ClientId)) {
        throw 'TenantId et ClientId sont obligatoires avec ClientSecret.'
    }

    $plainTextSecret = $null
    if ($null -ne $ClientSecret) {
        $secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ClientSecret)
        try {
            $plainTextSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer)
        }
    }
    else {
        $plainTextSecret = [Environment]::GetEnvironmentVariable(
            'INTUNE_DRIVER_PAUSE_CLIENT_SECRET',
            [EnvironmentVariableTarget]::Process
        )
    }
    if ([string]::IsNullOrWhiteSpace($plainTextSecret)) {
        throw 'Aucun secret client fourni.'
    }

    if (-not $KeepGraphConnection) {
        Remove-Item `
            -LiteralPath 'Env:\INTUNE_DRIVER_PAUSE_CLIENT_SECRET' `
            -Force `
            -ErrorAction SilentlyContinue
    }

    try {
        $tokenResponse = Invoke-RestMethod `
            -Method POST `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body @{
                client_id     = $ClientId
                client_secret = $plainTextSecret
                scope         = 'https://graph.microsoft.com/.default'
                grant_type    = 'client_credentials'
            }
    }
    finally {
        $plainTextSecret = $null
    }

    $script:grantedApplicationRoles = @(
        Get-JwtApplicationRole -AccessToken $tokenResponse.access_token
    )
    $script:canWriteDriverConfiguration = $script:grantedApplicationRoles -contains
        'DeviceManagementConfiguration.ReadWrite.All'

    $connectCommand = Get-Command Connect-MgGraph -ErrorAction Stop
    $accessTokenType = $connectCommand.Parameters['AccessToken'].ParameterType
    $accessToken = if ($accessTokenType -eq [securestring]) {
        $secureToken = New-Object Security.SecureString
        foreach ($tokenCharacter in $tokenResponse.access_token.ToCharArray()) {
            $secureToken.AppendChar($tokenCharacter)
        }
        $secureToken.MakeReadOnly()
        $secureToken
    }
    else {
        [string] $tokenResponse.access_token
    }

    Connect-GraphCompatible -Parameters @{ AccessToken = $accessToken }
    $accessToken = $null
    $tokenResponse = $null
}

function Connect-DriverCatalogGraph {
    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
        throw 'Le module Microsoft.Graph.Authentication est absent.'
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    switch ($AuthenticationMode) {
        'Interactive' {
            $parameters = @{
                Scopes       = @('DeviceManagementConfiguration.ReadWrite.All')
                ContextScope = 'Process'
            }
            if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
                $parameters.TenantId = $TenantId
            }
            if (-not [string]::IsNullOrWhiteSpace($ClientId)) {
                $parameters.ClientId = $ClientId
            }

            Connect-GraphCompatible -Parameters $parameters
            $script:connectedByScript = $true
        }

        'ClientSecret' {
            Connect-GraphWithClientSecret
            $script:connectedByScript = $true
        }

        'Certificate' {
            if ([string]::IsNullOrWhiteSpace($TenantId) -or
                [string]::IsNullOrWhiteSpace($ClientId) -or
                [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
                throw 'TenantId, ClientId et CertificateThumbprint sont obligatoires avec Certificate.'
            }

            $normalizedThumbprint = $CertificateThumbprint -replace '\s', ''
            $certificatePath = 'Cert:\{0}\My\{1}' -f
                $CertificateStoreLocation, $normalizedThumbprint
            if (-not (Test-Path -LiteralPath $certificatePath -PathType Leaf)) {
                throw "Certificat introuvable : $certificatePath"
            }

            $certificate = Get-Item -LiteralPath $certificatePath
            if (-not $certificate.HasPrivateKey) {
                throw "Le certificat '$certificatePath' ne contient pas de cle privee."
            }

            Connect-GraphCompatible -Parameters @{
                TenantId     = $TenantId
                ClientId     = $ClientId
                Certificate  = $certificate
                ContextScope = 'Process'
            }
            $script:connectedByScript = $true
        }

        'ManagedIdentity' {
            $connectCommand = Get-Command Connect-MgGraph -ErrorAction Stop
            if (-not $connectCommand.Parameters.ContainsKey('Identity')) {
                throw 'La version installee de Microsoft.Graph.Authentication ne prend pas en charge ManagedIdentity.'
            }
            if ([string]::IsNullOrWhiteSpace($ClientId)) {
                Connect-GraphCompatible -Parameters @{
                    Identity     = $true
                    ContextScope = 'Process'
                }
            }
            else {
                Connect-GraphCompatible -Parameters @{
                    Identity     = $true
                    ClientId     = $ClientId
                    ContextScope = 'Process'
                }
            }
            $script:connectedByScript = $true
        }

        'CurrentContext' {
            if ($null -eq (Get-MgContext)) {
                throw 'Aucun contexte Microsoft Graph actif.'
            }
        }
    }
}

if ($Resource -eq 'Drivers' -and [string]::IsNullOrWhiteSpace($ProfileId)) {
    throw 'ProfileId est obligatoire pour lister les pilotes.'
}

try {
    Connect-DriverCatalogGraph

    if ($Resource -eq 'Snapshot') {
        $profilesUri = "$graphRoot/deviceManagement/windowsDriverUpdateProfiles?`$top=100"
        $profiles = @(Get-GraphCollection -Uri $profilesUri)
        $inventories = @(
            foreach ($driverProfile in $profiles) {
                $escapedProfileId = [Uri]::EscapeDataString([string] $driverProfile.id)
                $driversUri = "$graphRoot/deviceManagement/windowsDriverUpdateProfiles/$escapedProfileId/driverInventories?`$top=100"
                [ordered] @{
                    profileId = [string] $driverProfile.id
                    value     = @(Get-GraphCollection -Uri $driversUri)
                }
            }
        )

        [ordered] @{
            resource    = $Resource
            profiles    = $profiles
            inventories = $inventories
            capabilities = [ordered] @{
                canWrite           = $script:canWriteDriverConfiguration
                requiredPermission = 'DeviceManagementConfiguration.ReadWrite.All'
            }
        } | ConvertTo-Json -Depth 8 -Compress
        return
    }

    $uri = if ($Resource -eq 'Profiles') {
        "$graphRoot/deviceManagement/windowsDriverUpdateProfiles?`$top=100"
    }
    else {
        $escapedProfileId = [Uri]::EscapeDataString($ProfileId)
        "$graphRoot/deviceManagement/windowsDriverUpdateProfiles/$escapedProfileId/driverInventories?`$top=100"
    }

    $items = @(Get-GraphCollection -Uri $uri)
    [ordered] @{
        resource     = $Resource
        value        = $items
        capabilities = [ordered] @{
            canWrite           = $script:canWriteDriverConfiguration
            requiredPermission = 'DeviceManagementConfiguration.ReadWrite.All'
        }
    } | ConvertTo-Json -Depth 8 -Compress
}
finally {
    if ($script:connectedByScript -and -not $KeepGraphConnection) {
        Disconnect-MgGraph | Out-Null
    }
}
