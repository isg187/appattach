<#
.SYNOPSIS
    Silently installs Windows SDK with only the features selected in the packaging screenshot.

.DESCRIPTION
    Downloads official winsdksetup.exe and installs:
      OptionId.SigningTools      Windows SDK Signing Tools for Desktop Apps
      OptionId.UWPManaged        Windows SDK for UWP Managed Apps
      OptionId.UWPCPP            Windows SDK for UWP C++ Apps
      OptionId.UWPLocalized      Windows SDK for UWP Apps Localization
      OptionId.DesktopCPPx86     Windows SDK for Desktop C++ x86 Apps
      OptionId.DesktopCPPx64     Windows SDK for Desktop C++ amd64 Apps
      OptionId.DesktopCPParm64   Windows SDK for Desktop C++ arm64 Apps

    Explicitly excludes Performance Toolkit, Debuggers, Application Verifier,
    .NET Framework 4.8.1 SDK, App Certification Kit, IP Over USB, and MSI Tools.

.PARAMETER Force
    Re-run the SDK installer even if signtool.exe is already present.

.PARAMETER ExpectedSha256
    Optional SHA-256 of winsdksetup.exe.

.EXAMPLE
    .\install-windowssdk.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP "WindowsSdkInstall"),
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
if (-not $LogPath) { $LogPath = Join-Path $logDir ("Install-WindowsSDK_{0}.log" -f (Get-Date -Format 'yyyyMMdd')) }
$script:LogPath = $LogPath

Write-Log "===== Starting Windows SDK (selected features) ====="
Write-Log "Force : $Force"

$features = @(
    'OptionId.SigningTools',
    'OptionId.UWPManaged',
    'OptionId.UWPCPP',
    'OptionId.UWPLocalized',
    'OptionId.DesktopCPPx86',
    'OptionId.DesktopCPPx64',
    'OptionId.DesktopCPParm64'
)

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $existing = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($existing -and -not $Force) {
        Write-Log "SignTool already present: $($existing.FullName)" -Level SUCCESS
        Write-Log "Skipping SDK install. Use -Force to reinstall selected features." -Level SUCCESS
        exit 0
    }

    if (-not (Test-Path $DownloadPath)) { New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null }

    # Official Microsoft redirect to current winsdksetup.exe
    $url  = "https://go.microsoft.com/fwlink/p/?linkid=2196241"
    $exe  = Join-Path $DownloadPath "winsdksetup.exe"

    Write-Log "Downloading Windows SDK setup..."
    Write-Log "URL : $url"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing

    if (-not (Test-Path $exe) -or (Get-Item $exe).Length -lt 1MB) {
        throw "Windows SDK download failed or file is too small."
    }
    Write-Log ("Download complete ({0:N1} MB)" -f ((Get-Item $exe).Length / 1MB)) -Level SUCCESS

    Test-InstallerIntegrity -Path $exe -ExpectedPublishers @('Microsoft Corporation','Microsoft') -ExpectedSha256 $ExpectedSha256

    $sdkLog = Join-Path $DownloadPath "winsdksetup.log"
    $featureArgs = $features -join ' '
    $argList = @(
        '/features', $featureArgs,
        '/quiet',
        '/norestart',
        '/ceip', 'off',
        '/log', "`"$sdkLog`""
    )

    Write-Log "Installing features: $($features -join ', ')"
    $p = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        throw "winsdksetup.exe exited $($p.ExitCode). See $sdkLog"
    }
    Write-Log "winsdksetup.exe exit code $($p.ExitCode)" -Level SUCCESS

    $signtool = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($signtool) {
        Write-Log "Verified SignTool: $($signtool.FullName)" -Level SUCCESS
    } else {
        Write-Log "SDK reported success but signtool.exe was not found." -Level WARN
    }

    Remove-Item $exe -Force -ErrorAction SilentlyContinue
    Write-Log "===== Windows SDK installation finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-Log "$($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
