<#
.SYNOPSIS
    Installs the .NET SDK required for AzureSignTool.

.DESCRIPTION
    - Detects whether the required .NET SDK version is already installed.
    - Downloads the latest stable .NET SDK (x64) from Microsoft’s official sources.
    - Uses silent MSI/EXE installation options suitable for enterprise automation.
    - Performs Authenticode and SHA-256 integrity checks.
    - Idempotent unless -Force is supplied.
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP "DotNetSdkInstall"),
    [string]$ExpectedSha256,
    [string]$RequiredMajorVersion = "8.0"   # Adjust as needed
)

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# LOGGING (matches your PowerShell7 installer exactly)
# ---------------------------------------------------------------------------
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$Message = '',

        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string]$Level = 'INFO',

        [string]$LogPath = $script:LogPath
    )

    if (-not $LogPath) {
        $LogPath = Join-Path $env:TEMP "SoftwareInstall_$(Get-Date -Format 'yyyyMMdd').log"
    }

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts] [$Level] $Message"

    switch ($Level) {
        'ERROR'   { Write-Host $entry -ForegroundColor Red }
        'WARN'    { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        'DEBUG'   { if ($VerbosePreference -eq 'Continue') { Write-Host $entry -ForegroundColor Gray } }
        default   { Write-Host $entry }
    }

    try {
        $dir = Split-Path $LogPath -Parent
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -Path $LogPath -Value $entry -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to log file: $($_.Exception.Message)"
    }
}

$logDir = "C:\ProgramData\SDL\scripts\logs"
$LogPath = Join-Path $logDir ("Install-DotNetSdk_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
Write-Log "===== Starting .NET SDK installation ====="
Write-Log "Log file : $LogPath"
Write-Log "Force    : $Force"
Write-Log "Required : $RequiredMajorVersion"

# ---------------------------------------------------------------------------
# Helper: Integrity checks (SHA256 + Authenticode)
# ---------------------------------------------------------------------------
function Test-InstallerIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [string]$ExpectedSha256,
        [string[]]$ExpectedPublishers = @("Microsoft Corporation", "Microsoft"),
        [switch]$AllowUnsigned
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Integrity check failed: file not found: $Path"
    }

    Write-Log "Running integrity checks on: $Path"

    # SHA-256
    $actualHash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    Write-Log "SHA256: $actualHash"

    if ($ExpectedSha256) {
        $expected = $ExpectedSha256.Trim().ToUpperInvariant()
        if ($actualHash -ne $expected) {
            throw "SHA-256 mismatch. Expected $expected but got $actualHash"
        }
        Write-Log "SHA-256 verified." -Level SUCCESS
    }
    else {
        Write-Log "ExpectedSha256 not supplied — recording hash only." -Level WARN
    }

    # Authenticode
    $sig = Get-AuthenticodeSignature $Path
    Write-Log "Authenticode Status : $($sig.Status)"

    if ($sig.SignerCertificate) {
        Write-Log "Signer Subject      : $($sig.SignerCertificate.Subject)"
        Write-Log "Signer Thumbprint   : $($sig.SignerCertificate.Thumbprint)"
    }

    if ($sig.Status -ne "Valid") {
        if ($AllowUnsigned) {
            Write-Log "Signature invalid but -AllowUnsigned specified." -Level WARN
            if (-not $ExpectedSha256) { throw "Unsigned file requires ExpectedSha256 for integrity." }
            return
        }
        throw "Authenticode signature is not valid. Status=$($sig.Status)"
    }

    $subject = $sig.SignerCertificate.Subject
    foreach ($pub in $ExpectedPublishers) {
        if ($subject -like "*$pub*") {
            Write-Log "Publisher matched: $pub" -Level SUCCESS
            return
        }
    }

    throw "Unexpected publisher: $subject"
}

# ---------------------------------------------------------------------------
# Detect installed .NET SDK
# ---------------------------------------------------------------------------
function Get-InstalledDotNetSdkVersions {
    $dotnet = "$env:ProgramFiles\dotnet\dotnet.exe"
    if (-not (Test-Path $dotnet)) { return @() }

    try {
        $sdkList = & $dotnet --list-sdks 2>$null
        return $sdkList
    }
    catch { return @() }
}

$installedSdks = Get-InstalledDotNetSdkVersions
$alreadyInstalled = $installedSdks | Where-Object { $_ -like "$RequiredMajorVersion*" }

if ($alreadyInstalled -and -not $Force) {
    Write-Log ".NET SDK $RequiredMajorVersion is already installed." -Level SUCCESS
    exit 0
}

if ($alreadyInstalled -and $Force) {
    Write-Log "Existing .NET SDK detected; -Force specified — reinstalling." -Level WARN
}
else {
    Write-Log "Required .NET SDK not detected — proceeding with install."
}

# ---------------------------------------------------------------------------
# Get latest SDK installer from Microsoft (stable)
# ---------------------------------------------------------------------------
function Get-DotNetSdkDownloadInfo {
    Write-Log "Querying download info from Microsoft..."

    $url = "https://dotnetcli.blob.core.windows.net/dotnet/Sdk/${RequiredMajorVersion}/latest.version"
    $latestVersion = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30
    $latestVersion = $latestVersion.Content.Trim()

    Write-Log "Latest available SDK version: $latestVersion"

    $installerName = "dotnet-sdk-$latestVersion-win-x64.exe"
    $downloadUrl   = "https://download.visualstudio.microsoft.com/download/pr/${installerName}"

    # Some organizations prefer MSI instead of EXE — update here if needed

    return [pscustomobject]@{
        Version  = $latestVersion
        FileName = $installerName
        Url      = $downloadUrl
    }
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
try {
    # Prep temp directory
    if (-not (Test-Path $DownloadPath)) {
        New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
    }

    $info = Get-DotNetSdkDownloadInfo
    $installerPath = Join-Path $DownloadPath $info.FileName

    Write-Log "Downloading .NET SDK..."
    Write-Log "URL : $($info.Url)"
    Write-Log "Dest: $installerPath"

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $info.Url -OutFile $installerPath -UseBasicParsing

    if (-not (Test-Path $installerPath) -or (Get-Item $installerPath).Length -lt 5MB) {
        throw "Download failed or file is too small."
    }

    $sizeMB = :Round((Get-Item $installerPath).Length / 1MB, 2)
    Write-Log "Download complete ($sizeMB MB)" -Level SUCCESS

    # Integrity checks
    Test-InstallerIntegrity -Path $installerPath -ExpectedSha256 $ExpectedSha256

    Write-Log "Starting silent .NET SDK installation..."

    $args = @(
        "/install"
        "/quiet"
        "/norestart"
        "/log `"$installerPath.install.log`""
    )

    $proc = Start-Process -FilePath $installerPath -ArgumentList $args -Wait -PassThru

    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
        Write-Log ".NET SDK installation succeeded (ExitCode=$($proc.ExitCode))" -Level SUCCESS
    }
    else {
        throw ".NET SDK installer returned non-zero exit code: $($proc.ExitCode)"
    }

    # Verify install
    $installed = Get-InstalledDotNetSdkVersions | Where-Object { $_ -like "$RequiredMajorVersion*" }
    if ($installed) {
        Write-Log "SDK installation verified: $($installed -join ', ')" -Level SUCCESS
    }
    else {
        Write-Log "SDK expected to install but not found afterward." -Level WARN
    }

    Write-Log "Cleaning up installer..."
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

    Write-Log "===== .NET SDK installation finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}