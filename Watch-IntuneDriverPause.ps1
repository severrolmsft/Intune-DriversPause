#requires -Version 5.1

<#
.SYNOPSIS
    Suspend ou approuve des pilotes cibles dans les profils Windows Driver Update Intune.

.DESCRIPTION
    Interroge tous les profils Windows Driver Update Intune (ou les profils limites par
    parametre), recherche les pilotes cibles et appelle Microsoft Graph pour suspendre
    ceux qui ne sont pas deja a l'etat "suspended".

    Le script est idempotent : un pilote deja suspendu n'est pas modifie. Apres chaque
    action, l'inventaire est relu afin de confirmer le nouvel etat.
    Seuls les pilotes approuves peuvent etre suspendus. Les etats needsReview,
    declined ou inconnus provoquent une erreur explicite, sans approbation implicite.
    Un refus individuel Graph est relu puis retente au maximum trois fois,
    uniquement pour les pilotes encore concernes et avec un etat compatible.
    Avec -Action Approve, les pilotes non approuves sont approuves pour un
    deploiement immediat, sans modifier les pilotes deja approuves.

    API utilisee :
    POST /beta/deviceManagement/windowsDriverUpdateProfiles/{id}/executeAction

    Permission Graph applicative requise :
    DeviceManagementConfiguration.ReadWrite.All

.PARAMETER DriverName
    Nom exact du pilote a rechercher. Plusieurs noms peuvent etre fournis.

.PARAMETER DriverId
    Identifiant Graph d'un pilote. Utiliser ce parametre a la place de DriverName pour
    cibler un pilote sans ambiguite.

.PARAMETER NameMatchMode
    Mode de comparaison du nom : Exact (par defaut), Contains ou Wildcard.

.PARAMETER Manufacturer
    Filtre exact optionnel sur le fabricant.

.PARAMETER DriverVersion
    Filtre exact optionnel sur la version.

.PARAMETER ProfileId
    Identifiants des profils a analyser. Sans ce parametre, tous les profils sont analyses.

.PARAMETER ProfileName
    Noms exacts des profils a analyser. Si ProfileId est aussi fourni, les deux filtres
    doivent correspondre.

.PARAMETER Action
    Suspend (par defaut) ou Approve. L'approbation utilise la date UTC courante
    comme date de deploiement.

.PARAMETER KeepGraphConnection
    Reserve a l'interface : reutilise le contexte Graph de son espace d'execution
    et laisse la connexion ouverte. L'appelant est responsable de la deconnexion.

.PARAMETER AuthenticationMode
    Interactive pour un compte utilisateur, ClientSecret ou Certificate pour une
    application, ManagedIdentity pour Azure Automation, ou CurrentContext apres
    une connexion Graph existante.

.PARAMETER ClientSecret
    Secret applicatif sous forme de SecureString. Il peut aussi etre transmis au
    processus avec la variable INTUNE_DRIVER_PAUSE_CLIENT_SECRET.

.EXAMPLE
    .\Watch-IntuneDriverPause.ps1 `
        -DriverName 'Contoso - Firmware - 1.2.3.4' `
        -AuthenticationMode Certificate `
        -TenantId '00000000-0000-0000-0000-000000000000' `
        -ClientId '11111111-1111-1111-1111-111111111111' `
        -CertificateThumbprint '0123456789ABCDEF0123456789ABCDEF01234567'

.EXAMPLE
    .\Watch-IntuneDriverPause.ps1 `
        -DriverName '*Display*31.0.101.5590*' `
        -NameMatchMode Wildcard `
        -Manufacturer 'Intel Corporation' `
        -AuthenticationMode CurrentContext `
        -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'ByName')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter',
    '',
    Justification = 'Les parametres sont utilises par les fonctions internes du script.'
)]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
    [ValidateNotNullOrEmpty()]
    [string[]] $DriverName,

    [Parameter(Mandatory = $true, ParameterSetName = 'ById')]
    [ValidateNotNullOrEmpty()]
    [string[]] $DriverId,

    [Parameter(ParameterSetName = 'ByName')]
    [ValidateSet('Exact', 'Contains', 'Wildcard')]
    [string] $NameMatchMode = 'Exact',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Manufacturer,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $DriverVersion,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]] $ProfileId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]] $ProfileName,

    [Parameter()]
    [ValidateSet('Suspend', 'Approve')]
    [string] $Action = 'Suspend',

    [Parameter()]
    [ValidateSet('Interactive', 'ClientSecret', 'Certificate', 'ManagedIdentity', 'CurrentContext')]
    [string] $AuthenticationMode = 'Certificate',

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

    [Parameter()]
    [ValidateRange(1, 10)]
    [int] $VerificationAttempts = 3,

    [Parameter()]
    [ValidateRange(0, 300)]
    [int] $VerificationDelaySeconds = 5,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $LogPath = (Join-Path -Path $env:ProgramData -ChildPath 'IntuneDriverPause\Logs\IntuneDriverPause.log'),

    [Parameter()]
    [ValidateRange(1, 1024)]
    [int] $MaxLogSizeMB = 10,

    [Parameter()]
    [ValidateRange(1, 20)]
    [int] $LogRetentionCount = 5,

    [Parameter(DontShow = $true)]
    [switch] $KeepGraphConnection
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:GraphRoot = 'https://graph.microsoft.com/beta'
$script:LogFilePath = [System.IO.Path]::GetFullPath($LogPath)
$script:ConnectedByScript = $false
$script:TargetParameterSetName = $PSCmdlet.ParameterSetName
$script:ExpectedStatus = if ($Action -eq 'Approve') { 'approved' } else { 'suspended' }
$script:ActionLogPrefix = $Action.ToUpperInvariant()
$script:StatusLogPrefix = $script:ExpectedStatus.ToUpperInvariant()

function Initialize-Log {
    $logDirectory = Split-Path -Path $script:LogFilePath -Parent
    if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
        New-Item -Path $logDirectory -ItemType Directory -Force -WhatIf:$false -Confirm:$false | Out-Null
    }

    if ((Test-Path -LiteralPath $script:LogFilePath -PathType Leaf) -and
        ((Get-Item -LiteralPath $script:LogFilePath).Length -ge ($MaxLogSizeMB * 1MB))) {
        for ($index = $LogRetentionCount; $index -ge 1; $index--) {
            $sourcePath = if ($index -eq 1) {
                $script:LogFilePath
            }
            else {
                '{0}.{1}' -f $script:LogFilePath, ($index - 1)
            }
            $destinationPath = '{0}.{1}' -f $script:LogFilePath, $index

            if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
                if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
                    Remove-Item -LiteralPath $destinationPath -Force -WhatIf:$false -Confirm:$false
                }
                Move-Item `
                    -LiteralPath $sourcePath `
                    -Destination $destinationPath `
                    -Force `
                    -WhatIf:$false `
                    -Confirm:$false
            }
        }
    }
}

function Write-DriverPauseLog {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string] $Level,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    $singleLineMessage = $Message -replace '[\r\n]+', ' '
    $line = '{0} [{1}] {2}' -f [DateTimeOffset]::UtcNow.ToString('o'), $Level, $singleLineMessage
    Add-Content `
        -LiteralPath $script:LogFilePath `
        -Value $line `
        -Encoding UTF8 `
        -WhatIf:$false `
        -Confirm:$false
    Write-Information -MessageData $line -InformationAction Continue
}

function Test-StringEqual {
    param(
        [AllowNull()]
        [string] $Left,

        [AllowNull()]
        [string] $Right
    )

    return [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase)
}

function Test-StringInList {
    param(
        [AllowNull()]
        [string] $Value,

        [Parameter(Mandatory = $true)]
        [string[]] $List
    )

    foreach ($candidate in $List) {
        if (Test-StringEqual -Left $Value -Right $candidate) {
            return $true
        }
    }

    return $false
}

function Get-GraphStatusCode {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
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
        [ValidateSet('GET', 'POST')]
        [string] $Method,

        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [Parameter()]
        [hashtable] $Body,

        [Parameter()]
        [ValidateRange(1, 10)]
        [int] $MaximumAttempts = 4
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            $requestParameters = @{
                Method     = $Method
                Uri        = $Uri
                OutputType = 'PSObject'
            }

            if ($PSBoundParameters.ContainsKey('Body')) {
                $requestParameters.Body = $Body | ConvertTo-Json -Depth 10 -Compress
                $requestParameters.ContentType = 'application/json'
            }

            return Invoke-MgGraphRequest @requestParameters
        }
        catch {
            $statusCode = Get-GraphStatusCode -ErrorRecord $_
            $isTransient = $statusCode -in @(429, 500, 502, 503, 504)
            if (-not $isTransient -or $attempt -eq $MaximumAttempts) {
                throw
            }

            $delaySeconds = [Math]::Min(60, [Math]::Pow(2, $attempt))
            Write-DriverPauseLog -Level 'WARN' -Message (
                'GRAPH_RETRY Method={0}; Status={1}; Attempt={2}/{3}; DelaySeconds={4}; Uri="{5}"' -f
                $Method, $statusCode, $attempt, $MaximumAttempts, $delaySeconds, $Uri
            )
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Get-GraphCollection {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri
    )

    $items = New-Object 'System.Collections.Generic.List[object]'
    $nextUri = $Uri

    while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
        $response = Invoke-GraphRequestWithRetry -Method GET -Uri $nextUri
        if ($null -eq $response) {
            throw "Microsoft Graph a retourne une reponse vide pour '$nextUri'."
        }

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
    foreach ($requiredValue in @{
            TenantId = $TenantId
            ClientId = $ClientId
        }.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace([string] $requiredValue.Value)) {
            throw "Le parametre -$($requiredValue.Key) est obligatoire avec -AuthenticationMode ClientSecret."
        }
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
        throw 'Le parametre -ClientSecret ou la variable INTUNE_DRIVER_PAUSE_CLIENT_SECRET est obligatoire.'
    }

    if (-not $KeepGraphConnection) {
        Remove-Item `
            -LiteralPath 'Env:\INTUNE_DRIVER_PAUSE_CLIENT_SECRET' `
            -Force `
            -ErrorAction SilentlyContinue `
            -WhatIf:$false `
            -Confirm:$false
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

    $grantedRoles = @(Get-JwtApplicationRole -AccessToken $tokenResponse.access_token)
    if (-not $WhatIfPreference -and
        $grantedRoles -notcontains 'DeviceManagementConfiguration.ReadWrite.All') {
        throw (
            'Permission applicative manquante : DeviceManagementConfiguration.ReadWrite.All. ' +
            'Ajoutez cette permission Microsoft Graph et accordez le consentement administrateur.'
        )
    }

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

function Connect-IntuneGraph {
    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
        throw "Le module Microsoft.Graph.Authentication est absent. Installer avec : Install-Module Microsoft.Graph.Authentication -Scope AllUsers"
    }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    switch ($AuthenticationMode) {
        'Interactive' {
            $connectionParameters = @{
                Scopes       = @('DeviceManagementConfiguration.ReadWrite.All')
                ContextScope = 'Process'
            }
            if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
                $connectionParameters.TenantId = $TenantId
            }
            if (-not [string]::IsNullOrWhiteSpace($ClientId)) {
                $connectionParameters.ClientId = $ClientId
            }

            Connect-GraphCompatible -Parameters $connectionParameters
            $script:ConnectedByScript = $true
        }

        'ClientSecret' {
            Connect-GraphWithClientSecret
            $script:ConnectedByScript = $true
        }

        'Certificate' {
            foreach ($requiredValue in @{
                    TenantId             = $TenantId
                    ClientId             = $ClientId
                    CertificateThumbprint = $CertificateThumbprint
                }.GetEnumerator()) {
                if ([string]::IsNullOrWhiteSpace([string] $requiredValue.Value)) {
                    throw "Le parametre -$($requiredValue.Key) est obligatoire avec -AuthenticationMode Certificate."
                }
            }

            $normalizedThumbprint = $CertificateThumbprint -replace '\s', ''
            $certificatePath = 'Cert:\{0}\My\{1}' -f $CertificateStoreLocation, $normalizedThumbprint
            if (-not (Test-Path -LiteralPath $certificatePath -PathType Leaf)) {
                throw "Certificat introuvable : $certificatePath"
            }

            $certificate = Get-Item -LiteralPath $certificatePath
            if (-not $certificate.HasPrivateKey) {
                throw "Le certificat '$certificatePath' ne contient pas de cle privee."
            }

            Connect-GraphCompatible -Parameters @{
                TenantId    = $TenantId
                ClientId    = $ClientId
                Certificate = $certificate
            }
            $script:ConnectedByScript = $true
        }

        'ManagedIdentity' {
            $connectCommand = Get-Command Connect-MgGraph -ErrorAction Stop
            if (-not $connectCommand.Parameters.ContainsKey('Identity')) {
                throw 'La version installee de Microsoft.Graph.Authentication ne prend pas en charge ManagedIdentity.'
            }
            if ([string]::IsNullOrWhiteSpace($ClientId)) {
                Connect-GraphCompatible -Parameters @{ Identity = $true }
            }
            else {
                Connect-GraphCompatible -Parameters @{
                    Identity = $true
                    ClientId = $ClientId
                }
            }
            $script:ConnectedByScript = $true
        }

        'CurrentContext' {
            if ($null -eq (Get-MgContext)) {
                throw "Aucun contexte Graph actif. Executer d'abord : Connect-MgGraph -Scopes DeviceManagementConfiguration.ReadWrite.All"
            }
        }
    }

    $context = Get-MgContext
    if ($null -eq $context) {
        throw 'La connexion a Microsoft Graph a echoue : aucun contexte actif.'
    }

    Write-DriverPauseLog -Level 'INFO' -Message (
        'AUTHENTICATED Mode={0}; TenantId="{1}"; ClientId="{2}"; AuthType="{3}"' -f
        $AuthenticationMode, $context.TenantId, $context.ClientId, $context.AuthType
    )
}

function Get-DriverInventory {
    param(
        [Parameter(Mandatory = $true)]
        [string] $WindowsDriverUpdateProfileId
    )

    $escapedProfileId = [Uri]::EscapeDataString($WindowsDriverUpdateProfileId)
    $uri = '{0}/deviceManagement/windowsDriverUpdateProfiles/{1}/driverInventories?$top=100' -f
        $script:GraphRoot, $escapedProfileId
    return @(Get-GraphCollection -Uri $uri)
}

function Test-DriverMatch {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Driver
    )

    if ($script:TargetParameterSetName -eq 'ById') {
        if (-not (Test-StringInList -Value ([string] $Driver.id) -List $DriverId)) {
            return $false
        }
    }
    else {
        $nameMatched = $false
        foreach ($targetName in $DriverName) {
            $nameMatched = switch ($NameMatchMode) {
                'Exact' {
                    Test-StringEqual -Left ([string] $Driver.name) -Right $targetName
                }
                'Contains' {
                    ([string] $Driver.name).IndexOf($targetName, [StringComparison]::OrdinalIgnoreCase) -ge 0
                }
                'Wildcard' {
                    [System.Management.Automation.WildcardPattern]::Get($targetName, 'IgnoreCase').IsMatch([string] $Driver.name)
                }
            }

            if ($nameMatched) {
                break
            }
        }

        if (-not $nameMatched) {
            return $false
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Manufacturer) -and
        -not (Test-StringEqual -Left ([string] $Driver.manufacturer) -Right $Manufacturer)) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($DriverVersion) -and
        -not (Test-StringEqual -Left ([string] $Driver.version) -Right $DriverVersion)) {
        return $false
    }

    return $true
}

function Get-DriverDescription {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Driver
    )

    return 'Name="{0}"; Version="{1}"; Manufacturer="{2}"; DriverId="{3}"; Status="{4}"' -f
        $Driver.name, $Driver.version, $Driver.manufacturer, $Driver.id, $Driver.approvalStatus
}

function Invoke-DriverAction {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object] $DriverProfile,

        [Parameter(Mandatory = $true)]
        [object[]] $Drivers
    )

    $driverIdsToProcess = @($Drivers | ForEach-Object { [string] $_.id })
    $targetDescription = '{0} pilote(s) dans le profil "{1}" ({2})' -f
        $driverIdsToProcess.Count, $DriverProfile.displayName, $DriverProfile.id

    $actionDescription = if ($Action -eq 'Approve') { 'Approuver' } else { 'Suspendre' }
    if (-not $PSCmdlet.ShouldProcess($targetDescription, $actionDescription)) {
        Write-DriverPauseLog -Level 'INFO' -Message "$($script:ActionLogPrefix)_SKIPPED WhatIf=True; Target=$targetDescription"
        return
    }

    Write-DriverPauseLog -Level 'INFO' -Message (
        '{0}_REQUEST Profile="{1}"; ProfileId="{2}"; DriverIds="{3}"' -f
        $script:ActionLogPrefix, $DriverProfile.displayName, $DriverProfile.id, ($driverIdsToProcess -join ',')
    )

    $escapedProfileId = [Uri]::EscapeDataString([string] $DriverProfile.id)
    $uri = '{0}/deviceManagement/windowsDriverUpdateProfiles/{1}/executeAction' -f
        $script:GraphRoot, $escapedProfileId
    $body = @{
        actionName = $Action.ToLowerInvariant()
        driverIds  = $driverIdsToProcess
    }
    if ($Action -eq 'Approve') {
        $body.deploymentDate = [DateTimeOffset]::UtcNow.ToString('o')
    }

    $maximumActionAttempts = 3
    for ($actionAttempt = 1; $actionAttempt -le $maximumActionAttempts; $actionAttempt++) {
        $response = Invoke-GraphRequestWithRetry -Method POST -Uri $uri -Body $body
        $result = if ($null -ne $response -and $null -ne $response.PSObject.Properties['value']) {
            $response.value
        }
        else {
            $response
        }
        if ($null -eq $result) {
            break
        }

        $failedIds = @($result.failedDriverIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
        $notFoundIds = @($result.notFoundDriverIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
        if ($notFoundIds.Count -gt 0) {
            throw (
                'Graph a refuse certains pilotes. Failed="{0}"; NotFound="{1}"' -f
                ($failedIds -join ','), ($notFoundIds -join ',')
            )
        }
        if ($failedIds.Count -eq 0) {
            break
        }

        Write-DriverPauseLog -Level 'WARN' -Message (
            'ACTION_REJECTED Action={0}; Profile="{1}"; Attempt={2}/{3}; FailedDriverIds="{4}"' -f
            $Action, $DriverProfile.displayName, $actionAttempt, $maximumActionAttempts, ($failedIds -join ',')
        )
        if ($VerificationDelaySeconds -gt 0) {
            Start-Sleep -Seconds $VerificationDelaySeconds
        }
        $retryInventory = @(Get-DriverInventory -WindowsDriverUpdateProfileId ([string] $DriverProfile.id))
        $idsToRetry = @(
            foreach ($failedId in $failedIds) {
                if (-not (Test-StringInList -Value $failedId -List $body.driverIds)) {
                    throw "Graph a retourne un identifiant refuse hors de la requete : $failedId"
                }
                $currentDriver = $retryInventory |
                    Where-Object { Test-StringEqual -Left ([string] $_.id) -Right $failedId } |
                    Select-Object -First 1
                if ($null -eq $currentDriver) {
                    throw "Pilote introuvable avant une nouvelle tentative : $failedId"
                }
                if (Test-StringEqual -Left ([string] $currentDriver.approvalStatus) -Right $script:ExpectedStatus) {
                    continue
                }
                if ($Action -eq 'Suspend' -and
                    -not (Test-StringEqual -Left ([string] $currentDriver.approvalStatus) -Right 'approved')) {
                    throw (
                        'Suspension impossible apres relecture : le pilote doit etre approved. {0}' -f
                        (Get-DriverDescription -Driver $currentDriver)
                    )
                }
                $failedId
            }
        )
        if ($idsToRetry.Count -eq 0) {
            break
        }
        if ($actionAttempt -eq $maximumActionAttempts) {
            throw (
                'Graph a refuse certains pilotes apres {0} tentative(s). Failed="{1}"; NotFound=""' -f
                $maximumActionAttempts, ($idsToRetry -join ',')
            )
        }
        Write-DriverPauseLog -Level 'WARN' -Message (
            'ACTION_RETRY Action={0}; Profile="{1}"; NextAttempt={2}/{3}; DriverIds="{4}"' -f
            $Action, $DriverProfile.displayName, ($actionAttempt + 1), $maximumActionAttempts, ($idsToRetry -join ',')
        )
        $body.driverIds = $idsToRetry
    }

    $remainingIds = @($driverIdsToProcess)
    for ($verificationAttempt = 1;
        $verificationAttempt -le $VerificationAttempts -and $remainingIds.Count -gt 0;
        $verificationAttempt++) {
        if ($VerificationDelaySeconds -gt 0) {
            Start-Sleep -Seconds $VerificationDelaySeconds
        }

        $currentInventory = @(Get-DriverInventory -WindowsDriverUpdateProfileId ([string] $DriverProfile.id))
        $remainingIds = @(
            foreach ($driverIdToVerify in $remainingIds) {
                $currentDriver = $currentInventory |
                    Where-Object { Test-StringEqual -Left ([string] $_.id) -Right $driverIdToVerify } |
                    Select-Object -First 1

                if ($null -eq $currentDriver -or
                    -not (Test-StringEqual -Left ([string] $currentDriver.approvalStatus) -Right $script:ExpectedStatus)) {
                    $driverIdToVerify
                }
            }
        )

        if ($remainingIds.Count -gt 0 -and $verificationAttempt -lt $VerificationAttempts) {
            Write-DriverPauseLog -Level 'WARN' -Message (
                'VERIFY_RETRY Profile="{0}"; Attempt={1}/{2}; RemainingDriverIds="{3}"' -f
                $DriverProfile.displayName, $verificationAttempt, $VerificationAttempts, ($remainingIds -join ',')
            )
        }
    }

    if ($remainingIds.Count -gt 0) {
        throw (
            'Etat {0} non confirme dans le profil "{1}" pour DriverIds="{2}".' -f
            $script:ExpectedStatus, $DriverProfile.displayName, ($remainingIds -join ',')
        )
    }

    Write-DriverPauseLog -Level 'INFO' -Message (
        '{0}_CONFIRMED Profile="{1}"; ProfileId="{2}"; DriverIds="{3}"' -f
        $script:ActionLogPrefix, $DriverProfile.displayName, $DriverProfile.id, ($driverIdsToProcess -join ',')
    )
}

Initialize-Log

$targetDescription = if ($script:TargetParameterSetName -eq 'ById') {
    'DriverId="{0}"' -f ($DriverId -join ',')
}
else {
    'DriverName="{0}"; MatchMode={1}' -f ($DriverName -join ','), $NameMatchMode
}

Write-DriverPauseLog -Level 'INFO' -Message (
    'RUN_START {0}; Manufacturer="{1}"; DriverVersion="{2}"; ProfileIdFilter="{3}"; ProfileNameFilter="{4}"; Action={5}' -f
    $targetDescription, $Manufacturer, $DriverVersion, ($ProfileId -join ','), ($ProfileName -join ','), $Action
)

$profilesScanned = 0
$driversMatched = 0
$driversAlreadyInState = 0
$driversChanged = 0
$profileErrors = 0
$profileErrorDetails = New-Object 'System.Collections.Generic.List[string]'

try {
    Connect-IntuneGraph

    $profilesUri = '{0}/deviceManagement/windowsDriverUpdateProfiles?$top=100' -f $script:GraphRoot
    $profiles = @(Get-GraphCollection -Uri $profilesUri)

    if ($null -ne $ProfileId -and $ProfileId.Count -gt 0) {
        $profiles = @($profiles | Where-Object { Test-StringInList -Value ([string] $_.id) -List $ProfileId })
    }
    if ($null -ne $ProfileName -and $ProfileName.Count -gt 0) {
        $profiles = @($profiles | Where-Object { Test-StringInList -Value ([string] $_.displayName) -List $ProfileName })
    }

    if ($profiles.Count -eq 0) {
        Write-DriverPauseLog -Level 'WARN' -Message 'NO_PROFILE Aucun profil ne correspond aux filtres.'
    }

    foreach ($driverProfile in $profiles) {
        $profilesScanned++

        try {
            Write-DriverPauseLog -Level 'INFO' -Message (
                'PROFILE_SCAN Name="{0}"; ProfileId="{1}"; ApprovalType="{2}"' -f
                $driverProfile.displayName, $driverProfile.id, $driverProfile.approvalType
            )

            $inventory = @(Get-DriverInventory -WindowsDriverUpdateProfileId ([string] $driverProfile.id))
            $matchingDrivers = @($inventory | Where-Object { Test-DriverMatch -Driver $_ })

            if ($matchingDrivers.Count -eq 0) {
                Write-DriverPauseLog -Level 'INFO' -Message (
                    'NO_MATCH Profile="{0}"; ProfileId="{1}"; InventoryCount={2}' -f
                    $driverProfile.displayName, $driverProfile.id, $inventory.Count
                )
                continue
            }

            $driversMatched += $matchingDrivers.Count
            $driversToProcess = New-Object 'System.Collections.Generic.List[object]'
            $unsupportedDrivers = New-Object 'System.Collections.Generic.List[string]'

            foreach ($matchingDriver in $matchingDrivers) {
                if (Test-StringEqual -Left ([string] $matchingDriver.approvalStatus) -Right $script:ExpectedStatus) {
                    $driversAlreadyInState++
                    Write-DriverPauseLog -Level 'INFO' -Message (
                        'ALREADY_{0} Profile="{1}"; {2}' -f
                        $script:StatusLogPrefix, $driverProfile.displayName, (Get-DriverDescription -Driver $matchingDriver)
                    )
                }
                elseif ($Action -eq 'Suspend' -and
                    -not (Test-StringEqual -Left ([string] $matchingDriver.approvalStatus) -Right 'approved')) {
                    $driverDetail = Get-DriverDescription -Driver $matchingDriver
                    $unsupportedDrivers.Add($driverDetail)
                    Write-DriverPauseLog -Level 'ERROR' -Message (
                        'SUSPEND_NOT_ALLOWED Profile="{0}"; {1}; RequiredStatus="approved"' -f
                        $driverProfile.displayName, $driverDetail
                    )
                }
                else {
                    $driversToProcess.Add($matchingDriver)
                    Write-DriverPauseLog -Level 'WARN' -Message (
                        'NOT_{0} Profile="{1}"; {2}' -f
                        $script:StatusLogPrefix, $driverProfile.displayName, (Get-DriverDescription -Driver $matchingDriver)
                    )
                }
            }

            if ($driversToProcess.Count -gt 0) {
                Invoke-DriverAction `
                    -DriverProfile $driverProfile `
                    -Drivers $driversToProcess.ToArray() `
                    -WhatIf:$WhatIfPreference
                if (-not $WhatIfPreference) {
                    $driversChanged += $driversToProcess.Count
                }
            }
            if ($unsupportedDrivers.Count -gt 0) {
                throw (
                    'Suspension impossible : seuls les pilotes approved peuvent etre suspendus. ' +
                    'Les pilotes needsReview ne sont pas encore autorises au deploiement ; ' +
                    'aucun pilote non approuve ne sera approuve automatiquement. Pilotes concernes : ' +
                    ($unsupportedDrivers -join ' | ')
                )
            }
        }
        catch {
            $profileErrors++
            $profileErrorDetails.Add(('Profil "{0}" : {1}' -f $driverProfile.displayName, $_.Exception.Message))
            Write-DriverPauseLog -Level 'ERROR' -Message (
                'PROFILE_ERROR Name="{0}"; ProfileId="{1}"; Error="{2}"' -f
                $driverProfile.displayName, $driverProfile.id, $_.Exception.Message
            )
        }
    }

    Write-DriverPauseLog -Level 'INFO' -Message (
        'RUN_SUMMARY ProfilesScanned={0}; DriversMatched={1}; Already{2}={3}; {2}Now={4}; ProfileErrors={5}' -f
        $profilesScanned, $driversMatched, (Get-Culture).TextInfo.ToTitleCase($script:ExpectedStatus),
        $driversAlreadyInState, $driversChanged, $profileErrors
    )

    if ($profileErrors -gt 0) {
        throw (
            "$profileErrors profil(s) n'ont pas pu etre traites correctement.`r`n`r`n" +
            ($profileErrorDetails -join "`r`n")
        )
    }
    if ($Action -eq 'Approve' -and $driversMatched -eq 0) {
        throw 'Aucun pilote correspondant trouve dans les profils cibles pour approbation.'
    }
}
catch {
    Write-DriverPauseLog -Level 'ERROR' -Message ('RUN_FAILED Error="{0}"' -f $_.Exception.Message)
    throw
}
finally {
    if ($script:ConnectedByScript -and -not $KeepGraphConnection) {
        try {
            Disconnect-MgGraph | Out-Null
            Write-DriverPauseLog -Level 'INFO' -Message 'GRAPH_DISCONNECTED'
        }
        catch {
            Write-DriverPauseLog -Level 'WARN' -Message ('DISCONNECT_FAILED Error="{0}"' -f $_.Exception.Message)
        }
    }
}
