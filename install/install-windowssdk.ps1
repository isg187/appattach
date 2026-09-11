<#
.SYNOPSIS
    Downloads and silently installs the latest Windows SDK with only the selected features.

.DESCRIPTION
    Installs Windows SDK Signing Tools, UWP Managed/C++/Localization, and Desktop C++
    x86, amd64, and arm64. Other SDK features are not installed.

.PARAMETER Force
    Reinstall even if the SDK is already present.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the installer.

.EXAMPLE
    .\install-windows-sdk.ps1

.EXAMPLE
    .\install-windows-sdk.ps1 -Force
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'WindowsSdkInstall')
)

$ErrorActionPreference = 'Stop'

$script:SdkUrl = 'https://go.microsoft.com/fwlink/?linkid=2376217'
$script:Features = @(
    'OptionId.SigningTools',
    'OptionId.UWPManaged',
    'OptionId.UWPCPP',
    'OptionId.UWPLocalized',
    'OptionId.DesktopCPPx86',
    'OptionId.DesktopCPPx64',
    'OptionId.DesktopCPParm64'
)

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
        'ERROR'   { Write-Host $entry -ForegroundColor Red }
        'WARN'    { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry }
    }

    $logDir = Split-Path $script:LogPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path $script:LogPath -Value $entry
}

function Get-WindowsKitsRoot {
    $paths = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots',
        'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots'
    )
    foreach ($p in $paths) {
        if (Test-Path $p) {
            $root = (Get-ItemProperty -Path $p -ErrorAction SilentlyContinue).KitsRoot10
            if ($root -and (Test-Path $root)) { return $root }
        }
    }
    return $null
}

function Get-InstalledWindowsSdkVersion {
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $versions = @()
    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($props.DisplayName -like 'Windows Software Development Kit*' -and $props.DisplayVersion) {
                $versions += [string]$props.DisplayVersion
            }
        }
    }
    $versions | Sort-Object { [version]($_ -replace '[^\d.].*$', '') } | Select-Object -Last 1
}

function Test-SelectedSdkFeatures {
    $kitsRoot = Get-WindowsKitsRoot
    if (-not $kitsRoot) { return $false }

    $signtool = Get-ChildItem -Path (Join-Path $kitsRoot 'bin') -Filter 'signtool.exe' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $signtool) { return $false }

    $include = Join-Path $kitsRoot 'Include'
    if (-not (Test-Path $include)) { return $false }

    return $true
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-WindowsSdk_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log 'Starting Windows SDK install'

try {
    $installedVersion = Get-InstalledWindowsSdkVersion
    $featuresPresent = Test-SelectedSdkFeatures

    if ($installedVersion -and $featuresPresent -and -not $Force) {
        Write-Log ('Windows SDK already installed: {0}' -f $installedVersion) -Level SUCCESS
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    if ($installedVersion -and $Force) {
        Write-Log ('Windows SDK {0} found; Force specified' -f $installedVersion) -Level WARN
    }
    elseif ($installedVersion -and -not $featuresPresent) {
        Write-Log ('Windows SDK {0} found but selected features are missing' -f $installedVersion) -Level WARN
    }
    else {
        Write-Log 'Windows SDK not detected; installing latest'
    }

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $installerPath = Join-Path $DownloadPath 'winsdksetup.exe'
    Write-Log 'Downloading latest Windows SDK bootstrapper'

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $script:SdkUrl -OutFile $installerPath -UseBasicParsing

    if (-not (Test-Path $installerPath) -or (Get-Item $installerPath).Length -lt 1MB) {
        throw 'Download failed or file is too small.'
    }

    $sig = Get-AuthenticodeSignature -FilePath $installerPath
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike '*Microsoft*') {
        throw ("Installer signature check failed. Status={0}" -f $sig.Status)
    }

    $setupLog = Join-Path $DownloadPath 'winsdksetup.log'
    $argumentList = @('/features') + $script:Features + @('/quiet', '/norestart', '/ceip', 'off', '/log', $setupLog)

    Write-Log 'Installing selected Windows SDK features'
    $processParams = @{
        FilePath     = $installerPath
        ArgumentList = $argumentList
        Wait         = $true
        PassThru     = $true
    }
    $process = Start-Process @processParams

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "winsdksetup returned non-zero exit code: $($process.ExitCode)"
    }

    $newVersion = Get-InstalledWindowsSdkVersion
    if ($newVersion) {
        Write-Log ('Windows SDK installed: {0}' -f $newVersion) -Level SUCCESS
    }
    else {
        Write-Log 'Installer succeeded but SDK version was not detected.' -Level WARN
    }

    if (-not (Test-SelectedSdkFeatures)) {
        Write-Log 'Signing tools or SDK headers were not detected after install.' -Level WARN
    }

    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
