<#
.SYNOPSIS
    Installs AzureSignTool from the official standalone Windows x64 binary.

.PARAMETER Force
    Replace the binary even if already present.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the download.

.PARAMETER InstallDir
    Destination folder for AzureSignTool.exe.

.EXAMPLE
    .\install-azuresigntool.ps1
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'AzureSignToolInstall'),
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'AzureSignTool')
)

$ErrorActionPreference = 'Stop'

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

function Test-BinaryIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string[]]$ExpectedPublishers
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Integrity check failed: file not found: $Path"
    }

    $actualHash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    Write-Log ('SHA256: {0}' -f $actualHash)

    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') {
        Write-Log ('Authenticode not valid ({0})' -f $sig.Status) -Level WARN
        return
    }

    if (-not $ExpectedPublishers) { return }

    $subject = $sig.SignerCertificate.Subject
    $matched = $false
    foreach ($pub in $ExpectedPublishers) {
        if ($subject -like "*$pub*") {
            $matched = $true
            break
        }
    }
    if (-not $matched) {
        throw "Unexpected publisher. Subject='$subject'"
    }
}

function Add-MachinePath {
    param([string]$Directory)

    if (-not (Test-Path $Directory)) { return }

    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = $current -split ';' | Where-Object { $_ }
    if ($parts -contains $Directory) { return }

    [Environment]::SetEnvironmentVariable('Path', (($parts + $Directory) -join ';'), 'Machine')
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Get-InstalledAzureSignToolVersion {
    $exe = Join-Path $InstallDir 'AzureSignTool.exe'
    if (-not (Test-Path $exe)) { return $null }

    $ver = & $exe --version 2>$null
    if ($ver) { return ([string]$ver).Trim() }
    return (Get-Item $exe).VersionInfo.ProductVersion
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-AzureSignTool_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log 'Starting AzureSignTool install'

try {
    $installed = Get-InstalledAzureSignToolVersion
    if ($installed -and -not $Force) {
        Write-Log ('AzureSignTool already installed: {0}' -f $installed) -Level SUCCESS
        Write-Log 'Install finished' -Level SUCCESS
        exit 0
    }

    if ($installed -and $Force) {
        Write-Log ('AzureSignTool {0} found; Force specified' -f $installed) -Level WARN
    }
    else {
        Write-Log 'AzureSignTool not detected; installing latest standalone binary'
    }

    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    $headers = @{
        'User-Agent' = 'PowerShell-AzureSignTool-Installer'
        'Accept'     = 'application/vnd.github+json'
    }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/vcsjones/AzureSignTool/releases/latest' -Headers $headers -TimeoutSec 30
    $asset = $release.assets | Where-Object { $_.name -eq 'AzureSignTool-x64.exe' } | Select-Object -First 1
    if (-not $asset) {
        throw 'Could not find AzureSignTool-x64.exe in the latest release.'
    }

    $tmp = Join-Path $DownloadPath 'AzureSignTool-x64.exe'
    $dest = Join-Path $InstallDir 'AzureSignTool.exe'
    Write-Log ('Downloading AzureSignTool {0}' -f ($release.tag_name -replace '^v', ''))

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing

    if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt 1MB) {
        throw 'Download failed or file is too small.'
    }

    Test-BinaryIntegrity -Path $tmp -ExpectedPublishers @('Kevin Jones', 'vcsjones', 'AzureSignTool')
    Copy-Item -Path $tmp -Destination $dest -Force
    Add-MachinePath -Directory $InstallDir

    $newVersion = Get-InstalledAzureSignToolVersion
    if ($newVersion) {
        Write-Log ('AzureSignTool ready: {0}' -f $newVersion) -Level SUCCESS
    }
    else {
        Write-Log 'Binary copied but version was not detected.' -Level WARN
    }

    Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
