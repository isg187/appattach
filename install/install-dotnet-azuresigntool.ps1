<#
.SYNOPSIS
    Installs .NET 10 SDK (x64) and AzureSignTool 7.0.1 as a global dotnet tool.

.DESCRIPTION
    Combined because AzureSignTool requires the dotnet CLI (SDK).
    Sources: official Microsoft .NET 10 SDK installer + nuget.org via "dotnet tool install".
    Designed for GCC High / CMMC packaging workstations and golden images.

.PARAMETER Force
    Reinstall even if already present.

.PARAMETER ExpectedSha256
    Optional SHA-256 of the .NET SDK installer. Enforced when supplied.

.EXAMPLE
    .\install-dotnet-azuresigntool.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP "DotNetInstall"),
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
if (-not $LogPath) { $LogPath = Join-Path $logDir ("Install-DotNet-AzureSignTool_{0}.log" -f (Get-Date -Format 'yyyyMMdd')) }
$script:LogPath = $LogPath

Write-Log "===== Starting .NET 10 SDK + AzureSignTool installation ====="
Write-Log "Force : $Force"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $dotnetOk = $false
    $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($dotnetCmd) {
        $ver = & dotnet --version 2>$null
        Write-Log "Existing dotnet CLI: $ver"
        if ($ver -like '10.*' -and -not $Force) { $dotnetOk = $true }
    }

    if (-not $dotnetOk) {
        if (-not (Test-Path $DownloadPath)) { New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null }

        # Official channel installer (resolves to current 10.0.x SDK x64 EXE)
        $sdkUrl  = "https://aka.ms/dotnet/10.0/dotnet-sdk-win-x64.exe"
        $sdkPath = Join-Path $DownloadPath "dotnet-sdk-win-x64.exe"

        Write-Log "Downloading .NET 10 SDK..."
        Write-Log "URL : $sdkUrl"
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $sdkUrl -OutFile $sdkPath -UseBasicParsing

        if (-not (Test-Path $sdkPath) -or (Get-Item $sdkPath).Length -lt 1MB) {
            throw "NET SDK download failed or file is too small."
        }

        Test-InstallerIntegrity -Path $sdkPath -ExpectedPublishers @('Microsoft Corporation','Microsoft') -ExpectedSha256 $ExpectedSha256

        Write-Log "Installing .NET 10 SDK silently..."
        $p = Start-Process -FilePath $sdkPath -ArgumentList @('/install','/quiet','/norestart') -Wait -PassThru
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
            throw "NET SDK installer exited $($p.ExitCode)"
        }
        Write-Log "NET SDK installer exit code $($p.ExitCode)" -Level SUCCESS

        $machinePath = [Environment]::GetEnvironmentVariable('Path','Machine')
        $userPath    = [Environment]::GetEnvironmentVariable('Path','User')
        $env:Path    = "$machinePath;$userPath"
        Remove-Item $sdkPath -Force -ErrorAction SilentlyContinue
    } else {
        Write-Log ".NET 10 SDK already present. Skipping SDK install. Use -Force to reinstall." -Level SUCCESS
    }

    $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnetCmd) { throw "dotnet CLI not found after SDK install. Open a new elevated session and retry." }

    $toolList = & dotnet tool list --global 2>$null
    $hasTool = $toolList -match 'azuresigntool'
    if ($hasTool -and -not $Force) {
        Write-Log "AzureSignTool already installed globally. Skipping. Use -Force to reinstall." -Level SUCCESS
    } else {
        Write-Log "Installing AzureSignTool 7.0.1 as a global dotnet tool..."
        & dotnet tool uninstall --global AzureSignTool 2>$null | Out-Null
        & dotnet tool install --global AzureSignTool --version 7.0.1
        if ($LASTEXITCODE -ne 0) { throw "dotnet tool install AzureSignTool failed with $LASTEXITCODE" }
        Write-Log "AzureSignTool 7.0.1 installed." -Level SUCCESS
    }

    $az = Get-Command AzureSignTool -ErrorAction SilentlyContinue
    if ($az) { Write-Log "AzureSignTool path: $($az.Source)" -Level SUCCESS }
    else { Write-Log "AzureSignTool not on PATH yet. New shells will pick up %USERPROFILE%\.dotnet\tools." -Level WARN }

    Write-Log "===== .NET 10 SDK + AzureSignTool finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-Log "$($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
