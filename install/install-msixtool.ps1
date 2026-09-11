<#
.SYNOPSIS
    Installs the MSIX Packaging Tool Driver and the offline MSIX Packaging Tool.

.PARAMETER Force
    Reinstall even if already present.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the offline bundle and license.

.EXAMPLE
    .\install-msix-packaging-tool.ps1
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'MsixPackagingToolInstall')
)

$ErrorActionPreference = 'Stop'

$script:DriverName = 'Msix.PackagingTool.Driver~~~~0.0.1.0'
$script:AppxName = '*MsixPackagingTool*'
$script:BundleUrl = 'https://download.microsoft.com/download/e/2/e/e2e923b2-7a3a-4730-969d-ab37001fbb5e/MSIXPackagingtoolv1.2024.405.0.msixbundle'
$script:LicenseUrl = 'https://download.microsoft.com/download/e/2/e/e2e923b2-7a3a-4730-969d-ab37001fbb5e/MSIXPackagingtoolv1.2024.405.0.License.xml'

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    if (-not $script:LogPath) {
        $script:LogPath = Join-Path $env:TEMP ("SoftwareInstall_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    }

    $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    switch ($Level) {
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        'WARN' { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default { Write-Host $entry }
    }

    $logDir = Split-Path $script:LogPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path $script:LogPath -Value $entry
}

function Get-MsixDriverState {
    Get-WindowsCapability -Online -Name $script:DriverName -ErrorAction SilentlyContinue
}

function Install-MsixDriver {
    $cap = Get-MsixDriverState
    if (-not $cap) {
        throw ("Windows capability not found: {0}" -f $script:DriverName)
    }

    if ($cap.State -eq 'Installed' -and -not $Force) {
        Write-Log 'MSIX Packaging Tool Driver already installed' -Level SUCCESS
        return
    }

    Write-Log 'Installing MSIX Packaging Tool Driver'
    $result = Add-WindowsCapability -Online -Name $script:DriverName
    $cap = Get-MsixDriverState

    if ($cap.State -ne 'Installed') {
        throw ("Driver install did not complete. State={0}" -f $cap.State)
    }

    Write-Log 'MSIX Packaging Tool Driver installed' -Level SUCCESS
    if ($result -and $result.RestartNeeded) {
        Write-Log 'A restart is required to finish the driver install.' -Level WARN
    }
}

function Get-InstalledMsixPackagingTool {
    Get-AppxPackage -Name $script:AppxName -AllUsers -ErrorAction SilentlyContinue |
    Sort-Object Version |
    Select-Object -Last 1
}

function Test-BundleIntegrity {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Integrity check failed: file not found: $Path"
    }

    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike '*Microsoft*') {
        throw ("Bundle signature check failed. Status={0}" -f $sig.Status)
    }
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-MsixPackagingTool_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log 'Starting MSIX Packaging Tool and driver install'

try {
    Install-MsixDriver

    $installed = Get-InstalledMsixPackagingTool
    if ($installed -and -not $Force) {
        Write-Log ('MSIX Packaging Tool already installed: {0}' -f $installed.Version) -Level SUCCESS
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $bundlePath = Join-Path $DownloadPath (Split-Path $script:BundleUrl -Leaf)
    $licensePath = Join-Path $DownloadPath (Split-Path $script:LicenseUrl -Leaf)

    Write-Log 'Downloading official MSIX Packaging Tool bundle and license'
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $script:BundleUrl -OutFile $bundlePath -UseBasicParsing
    Invoke-WebRequest -Uri $script:LicenseUrl -OutFile $licensePath -UseBasicParsing

    if (-not (Test-Path $bundlePath) -or (Get-Item $bundlePath).Length -lt 1MB) {
        throw 'Offline bundle download failed or file is too small.'
    }
    if (-not (Test-Path $licensePath)) {
        throw 'Offline license download failed.'
    }

    Test-BundleIntegrity -Path $bundlePath

    Write-Log 'Installing MSIX Packaging Tool from offline bundle'
    $provisionParams = @{
        Online      = $true
        PackagePath = $bundlePath
        LicensePath = $licensePath
    }
    Add-AppxProvisionedPackage @provisionParams | Out-Null

    $addParams = @{
        Path                     = $bundlePath
        ForceApplicationShutdown = $true
        ErrorAction              = 'SilentlyContinue'
    }
    Add-AppxPackage @addParams

    $installed = Get-InstalledMsixPackagingTool
    if ($installed) {
        Write-Log ('MSIX Packaging Tool ready: {0}' -f $installed.Version) -Level SUCCESS
    }
    else {
        Write-Log 'Tool install completed but package was not detected.' -Level WARN
    }

    Remove-Item -Path $bundlePath, $licensePath -Force -ErrorAction SilentlyContinue
    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
