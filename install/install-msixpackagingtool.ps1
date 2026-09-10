<#
.SYNOPSIS
    Installs MSIX Packaging Tool and the Msix.PackagingTool.Driver capability.

.DESCRIPTION
    Combined because the driver Feature on Demand is required for the tool
    to capture installers. Uses the official offline MSIX bundle from Microsoft
    (Store-independent) plus Add-WindowsCapability for the driver.

.PARAMETER Force
    Reinstall even if the tool is already present.

.PARAMETER ExpectedSha256
    Optional SHA-256 of the MSIX Packaging Tool bundle.

.EXAMPLE
    .\install-msixpackagingtool.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP "MsixPackagingToolInstall"),
    [string]$ExpectedSha256
)

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

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
    if (-not $LogPath) { $LogPath = Join-Path $env:TEMP "SoftwareInstall_$(Get-Date -Format 'yyyyMMdd').log" }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = if ([string]::IsNullOrEmpty($Message)) { '' } else { "[$timestamp] [$Level] $Message" }
    switch ($Level) {
        'ERROR'   { Write-Host $entry -ForegroundColor Red }
        'WARN'    { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry }
    }
    try {
        $dir = Split-Path $LogPath -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $LogPath -Value $entry -ErrorAction SilentlyContinue
    } catch { }
}

function Test-InstallerIntegrity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$ExpectedPublishers,
        [string]$ExpectedSha256,
        [switch]$AllowUnsigned
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "Integrity check failed: file not found: $Path" }
    Write-Log "Running integrity checks on: $Path"
    $actualHash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    Write-Log "SHA256: $actualHash"
    if ($ExpectedSha256) {
        $expected = $ExpectedSha256.Trim().ToUpperInvariant()
        if ($actualHash -ne $expected) { throw "SHA-256 mismatch. Expected $expected but got $actualHash" }
        Write-Log "SHA-256 verified against expected value." -Level SUCCESS
    } else {
        Write-Log "No ExpectedSha256 supplied — hash recorded for audit; not enforced." -Level WARN
    }
    $sig = Get-AuthenticodeSignature -FilePath $Path
    Write-Log "Authenticode Status : $($sig.Status)"
    if ($sig.SignerCertificate) {
        Write-Log "Signer Subject      : $($sig.SignerCertificate.Subject)"
    }
    if ($sig.Status -ne 'Valid') {
        if ($AllowUnsigned) {
            Write-Log "Authenticode not valid ($($sig.Status)) but -AllowUnsigned was specified." -Level WARN
            if (-not $ExpectedSha256) { throw "Unsigned/invalid signature requires -ExpectedSha256." }
            return
        }
        throw "Authenticode signature is not valid. Status=$($sig.Status)"
    }
    $subject = $sig.SignerCertificate.Subject
    $matched = $false
    foreach ($pub in $ExpectedPublishers) {
        if ($subject -like "*$pub*") { $matched = $true; Write-Log "Publisher matched: $pub" -Level SUCCESS; break }
    }
    if (-not $matched) { throw "Unexpected publisher. Subject='$subject'. Expected: $($ExpectedPublishers -join ', ')" }
    Write-Log "Integrity checks passed." -Level SUCCESS
}

$logDir = "C:\ProgramData\SDL\scripts\logs"
if (-not $LogPath) { $LogPath = Join-Path $logDir ("Install-MsixPackagingTool_{0}.log" -f (Get-Date -Format 'yyyyMMdd')) }
$script:LogPath = $LogPath

Write-Log "===== Starting MSIX Packaging Tool + Driver ====="
Write-Log "Force : $Force"

# Official public offline package (Microsoft Learn)
$bundleUrl = "https://download.microsoft.com/download/e/2/e/e2e923b2-7a3a-4730-969d-ab37001fbb5e/MSIXPackagingtoolv1.2024.405.0.msixbundle"
$licenseUrl = "https://download.microsoft.com/download/d/1/7/d1713a31-370b-48ea-8fb3-e10e0189a916/MsixPackagingTool_License.xml"
$capabilityName = "Msix.PackagingTool.Driver~~~~0.0.1.0"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # --- Driver FOD (Windows capability) ---
    $cap = Get-WindowsCapability -Online -Name $capabilityName -ErrorAction SilentlyContinue
    if ($cap -and $cap.State -eq 'Installed' -and -not $Force) {
        Write-Log "Capability already installed: $capabilityName" -Level SUCCESS
    } else {
        Write-Log "Installing Windows capability: $capabilityName"
        Write-Log "Requires Windows Update / FOD source. On GCC High, point -Source at your FOD ISO if this fails."
        try {
            Add-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop | Out-Null
            Write-Log "Capability installed." -Level SUCCESS
        }
        catch {
            Write-Log "Capability install failed: $($_.Exception.Message)" -Level ERROR
            Write-Log "Retry with a local FOD source, for example:" -Level WARN
            Write-Log "  Add-WindowsCapability -Online -Name $capabilityName -Source D:\FoD -LimitAccess" -Level WARN
            throw
        }
    }

    $pkg = Get-AppxPackage -Name "*MSIXPackagingTool*" -ErrorAction SilentlyContinue
    if ($pkg -and -not $Force) {
        Write-Log "MSIX Packaging Tool already installed: $($pkg.Name) $($pkg.Version)" -Level SUCCESS
        Write-Log "===== MSIX Packaging Tool finished =====" -Level SUCCESS
        exit 0
    }

    if (-not (Test-Path $DownloadPath)) { New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null }
    $bundlePath  = Join-Path $DownloadPath "MSIXPackagingTool.msixbundle"
    $licensePath = Join-Path $DownloadPath "MSIXPackagingTool_License.xml"

    Write-Log "Downloading MSIX Packaging Tool bundle..."
    Write-Log "URL : $bundleUrl"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $bundleUrl -OutFile $bundlePath -UseBasicParsing

    if (-not (Test-Path $bundlePath) -or (Get-Item $bundlePath).Length -lt 1MB) {
        throw "MSIX Packaging Tool download failed or file is too small."
    }
    Write-Log "Download complete" -Level SUCCESS

    Test-InstallerIntegrity -Path $bundlePath -ExpectedPublishers @('Microsoft Corporation','Microsoft') -ExpectedSha256 $ExpectedSha256

    Write-Log "Attempting license download (required for provisioned Store-style packages)..."
    try {
        Invoke-WebRequest -Uri $licenseUrl -OutFile $licensePath -UseBasicParsing
    } catch {
        Write-Log "License download failed: $($_.Exception.Message)" -Level WARN
        $licensePath = $null
    }

    Write-Log "Installing MSIX Packaging Tool package..."
    if ($licensePath -and (Test-Path $licensePath)) {
        Add-AppxProvisionedPackage -Online -PackagePath $bundlePath -LicensePath $licensePath -ErrorAction Stop | Out-Null
        Write-Log "Provisioned with license." -Level SUCCESS
    } else {
        Add-AppxPackage -Path $bundlePath -ErrorAction Stop
        Write-Log "Installed via Add-AppxPackage (current user / no license file)." -Level SUCCESS
    }

    $pkg = Get-AppxPackage -Name "*MSIXPackagingTool*" -ErrorAction SilentlyContinue
    if ($pkg) { Write-Log "Verified: $($pkg.Name) $($pkg.Version)" -Level SUCCESS }
    else { Write-Log "Package install reported success but Get-AppxPackage did not find the tool." -Level WARN }

    Write-Log "===== MSIX Packaging Tool + Driver finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-Log "$($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
