#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Enregistre une tache planifiee qui execute le controle Intune toutes les heures.

.DESCRIPTION
    Cree une tache Windows executee par SYSTEM. L'authentification Graph utilise une
    application Entra ID et un certificat present dans Cert:\LocalMachine\My.

    Le module Microsoft.Graph.Authentication doit etre installe pour tous les utilisateurs :
    Install-Module Microsoft.Graph.Authentication -Scope AllUsers

.PARAMETER DriverName
    Nom du pilote cible. Utilise pour une saisie manuelle.

.PARAMETER DriverId
    Identifiant Graph du pilote selectionne dans l'inventaire Intune.

.EXAMPLE
    .\Register-IntuneDriverPauseScheduledTask.ps1 `
        -DriverName 'Contoso - Firmware - 1.2.3.4' `
        -TenantId '00000000-0000-0000-0000-000000000000' `
        -ClientId '11111111-1111-1111-1111-111111111111' `
        -CertificateThumbprint '0123456789ABCDEF0123456789ABCDEF01234567'
#>

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'ByName')]
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

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $TenantId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $ClientId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9 ]{40,}$')]
    [string] $CertificateThumbprint,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $TaskName = 'Intune - Suspension pilote cible',

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $ScriptPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Watch-IntuneDriverPause.ps1'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $LogPath = (Join-Path -Path $env:ProgramData -ChildPath 'IntuneDriverPause\Logs\IntuneDriverPause.log'),

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $PowerShellExecutable = (Get-Process -Id $PID).Path,

    [Parameter()]
    [ValidateRange(5, 120)]
    [int] $ExecutionTimeLimitMinutes = 30,

    [Parameter()]
    [bool] $StartImmediately = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$targetParameterSetName = $PSCmdlet.ParameterSetName

function ConvertTo-PowerShellStringLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Value
    )

    return "'{0}'" -f $Value.Replace("'", "''")
}

function ConvertTo-PowerShellArrayLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Value
    )

    $items = @($Value | ForEach-Object { ConvertTo-PowerShellStringLiteral -Value $_ })
    return '@({0})' -f ($items -join ',')
}

$resolvedScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$resolvedPowerShellExecutable = (Resolve-Path -LiteralPath $PowerShellExecutable).Path
$normalizedThumbprint = $CertificateThumbprint -replace '\s', ''
$certificatePath = 'Cert:\LocalMachine\My\{0}' -f $normalizedThumbprint

if (-not (Test-Path -LiteralPath $certificatePath -PathType Leaf)) {
    throw "Certificat introuvable : $certificatePath"
}

$certificate = Get-Item -LiteralPath $certificatePath
if (-not $certificate.HasPrivateKey) {
    throw "Le certificat '$certificatePath' ne contient pas de cle privee."
}

$allUsersModule = Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication' |
    Where-Object {
        $_.Path.StartsWith(
            [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
            [StringComparison]::OrdinalIgnoreCase
        )
    } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if ($null -eq $allUsersModule) {
    throw 'Microsoft.Graph.Authentication doit etre installe avec -Scope AllUsers pour etre visible par SYSTEM.'
}

$commandParts = New-Object 'System.Collections.Generic.List[string]'
$commandParts.Add('$ErrorActionPreference = ''Stop''; & {0}' -f (ConvertTo-PowerShellStringLiteral -Value $resolvedScriptPath))
if ($targetParameterSetName -eq 'ById') {
    $commandParts.Add('-DriverId {0}' -f (ConvertTo-PowerShellArrayLiteral -Value $DriverId))
}
else {
    $commandParts.Add('-DriverName {0}' -f (ConvertTo-PowerShellArrayLiteral -Value $DriverName))
    $commandParts.Add('-NameMatchMode {0}' -f (ConvertTo-PowerShellStringLiteral -Value $NameMatchMode))
}

if (-not [string]::IsNullOrWhiteSpace($Manufacturer)) {
    $commandParts.Add('-Manufacturer {0}' -f (ConvertTo-PowerShellStringLiteral -Value $Manufacturer))
}
if (-not [string]::IsNullOrWhiteSpace($DriverVersion)) {
    $commandParts.Add('-DriverVersion {0}' -f (ConvertTo-PowerShellStringLiteral -Value $DriverVersion))
}
if ($null -ne $ProfileId -and $ProfileId.Count -gt 0) {
    $commandParts.Add('-ProfileId {0}' -f (ConvertTo-PowerShellArrayLiteral -Value $ProfileId))
}
if ($null -ne $ProfileName -and $ProfileName.Count -gt 0) {
    $commandParts.Add('-ProfileName {0}' -f (ConvertTo-PowerShellArrayLiteral -Value $ProfileName))
}

$commandParts.Add('-AuthenticationMode ''Certificate''')
$commandParts.Add('-TenantId {0}' -f (ConvertTo-PowerShellStringLiteral -Value $TenantId))
$commandParts.Add('-ClientId {0}' -f (ConvertTo-PowerShellStringLiteral -Value $ClientId))
$commandParts.Add('-CertificateThumbprint {0}' -f (ConvertTo-PowerShellStringLiteral -Value $normalizedThumbprint))
$commandParts.Add('-CertificateStoreLocation ''LocalMachine''')
$commandParts.Add('-LogPath {0}' -f (ConvertTo-PowerShellStringLiteral -Value ([System.IO.Path]::GetFullPath($LogPath))))

$encodedCommand = [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes(($commandParts -join ' '))
)

$action = New-ScheduledTaskAction `
    -Execute $resolvedPowerShellExecutable `
    -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"

$trigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Hours 1)

$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes $ExecutionTimeLimitMinutes) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 5)

if ($PSCmdlet.ShouldProcess($TaskName, 'Creer ou remplacer la tache planifiee horaire')) {
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Suspend automatiquement le pilote cible dans les profils Windows Driver Update Intune.' `
        -Force | Out-Null

    if ($StartImmediately) {
        Start-ScheduledTask -TaskName $TaskName
    }
}

$registeredTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $registeredTask) {
    $registeredTask
}
