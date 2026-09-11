<#
.SYNOPSIS
    Installs the MSIX Packaging Tool Driver and the latest MSIX Packaging Tool.

.PARAMETER Force
    Reinstall even if already present.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the offline bundle fallback.

.EXAMPLE
    .\install-msix-packaging-tool.ps1

.EXAMPLE
    .\install-msix-packaging-tool.ps1 -Force
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
$script:WingetId = 'Microsoft.MSIXPackagingTool'
$script:AppxName = '*MsixPackagingTool*'
$script:OfflineBundleUrl = 'https://download.microsoft.com/download/e/2/e/e2e923b2-7a3a-4730-969d-ab37001fbb5e/MSIXPackagingtoolv1.2024.405.0.msixbundle'

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

function Get-MsixDriverState {
    $cap = Get-WindowsCapability -Online -Name $script:DriverName -ErrorAction SilentlyContinue
    if (-not $cap) { return $null }
    return $cap
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

    if ($cap.State -eq 'Installed' -and $Force) {
        Write-Log 'MSIX Packaging Tool Driver already installed; Force specified, adding again' -Level WARN
    }
    else {
        Write-Log 'Installing MSIX Packaging Tool Driver from Windows Update'
    }

    $result = Add-WindowsCapability -Online -Name $script:DriverName
    $cap = Get-MsixDriverState

    if ($cap.State -eq 'Installed') {
        Write-Log 'MSIX Packaging Tool Driver installed' -Level SUCCESS
    }
    else {
        throw ("Driver install did not complete. State={0}" -f $cap.State)
    }

    if ($result -and $result.RestartNeeded) {
        Write-Log 'A restart is required to finish the driver install.' -Level WARN
    }
}

function Get-InstalledMsixPackagingTool {
    Get-AppxPackage -Name $script:AppxName -AllUsers -ErrorAction SilentlyContinue |
        Sort-Object Version |
        Select-Object -Last 1
}

function Get-WingetExe {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $env:LocalAppData 'Microsoft\WindowsApps\winget.exe'),
        (Join-Path $env:ProgramFiles 'WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe')
    )
    foreach ($path in $candidates) {
        $resolved = Get-Item $path -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($resolved) { return $resolved.FullName }
    }
    return $null
}

function Install-MsixPackagingToolViaWinget {
    $winget = Get-WingetExe
    if (-not $winget) { return $false }

    $installed = Get-InstalledMsixPackagingTool
    if ($installed -and $Force) {
        Write-Log ('Upgrading MSIX Packaging Tool from {0} via winget' -f $installed.Version)
        $verb = 'upgrade'
    }
    elseif ($installed) {
        Write-Log ('Upgrading MSIX Packaging Tool from {0} via winget' -f $installed.Version)
        $verb = 'upgrade'
    }
    else {
        Write-Log 'Installing latest MSIX Packaging Tool via winget'
        $verb = 'install'
    }

    $wingetArgs = @(
        $verb
        '--exact'
        '--id'
        $script:WingetId
        '--silent'
        '--accept-package-agreements'
        '--accept-source-agreements'
        '--disable-interactivity'
    )

    $processParams = @{
        FilePath     = $winget
        ArgumentList = $wingetArgs
        Wait         = $true
        PassThru     = $true
        NoNewWindow  = $true
    }
    $process = Start-Process @processParams

    if ($process.ExitCode -eq 0) { return $true }

    # Already current is still success for upgrade.
    if ($verb -eq 'upgrade' -and $process.ExitCode -eq -1978335189) { return $true }

    Write-Log ('winget {0} exited {1}; trying offline bundle' -f $verb, $process.ExitCode) -Level WARN
    return $false
}

function Install-MsixPackagingToolOffline {
    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $bundlePath = Join-Path $DownloadPath (Split-Path $script:OfflineBundleUrl -Leaf)
    Write-Log 'Downloading official MSIX Packaging Tool bundle'

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $script:OfflineBundleUrl -OutFile $bundlePath -UseBasicParsing

    if (-not (Test-Path $bundlePath) -or (Get-Item $bundlePath).Length -lt 1MB) {
        throw 'Offline bundle download failed or file is too small.'
    }

    $sig = Get-AuthenticodeSignature -FilePath $bundlePath
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike '*Microsoft*') {
        throw ("Bundle signature check failed. Status={0}" -f $sig.Status)
    }

    Write-Log 'Installing MSIX Packaging Tool from offline bundle'
    Add-AppxPackage -Path $bundlePath -ForceApplicationShutdown -ErrorAction Stop
    Remove-Item -Path $bundlePath -Force -ErrorAction SilentlyContinue
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

    $wingetOk = Install-MsixPackagingToolViaWinget
    if (-not $wingetOk) {
        Install-MsixPackagingToolOffline
    }

    $installed = Get-InstalledMsixPackagingTool
    if ($installed) {
        Write-Log ('MSIX Packaging Tool ready: {0}' -f $installed.Version) -Level SUCCESS
    }
    else {
        Write-Log 'Tool install completed but package was not detected.' -Level WARN
    }

    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
