<#
.SYNOPSIS
    Downloads and silently installs the latest .NET SDK 10, then installs AzureSignTool.

.DESCRIPTION
    Idempotent installer for the latest .NET 10 SDK (Windows x64 EXE) from official
    Microsoft release metadata, then installs/updates the AzureSignTool global tool.

.PARAMETER Force
    Reinstall the SDK and AzureSignTool even if already present.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the installer.

.PARAMETER ExpectedSha256
    Optional SHA-256 to enforce. Official Microsoft metadata uses SHA-512 and is
    always verified when present.

.EXAMPLE
    .\Install-DotNetSdk10-AzureSignTool.ps1

.EXAMPLE
    .\Install-DotNetSdk10-AzureSignTool.ps1 -Force
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP "DotNetSdk10Install"),
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

    if (-not $LogPath) {
        $LogPath = Join-Path $env:TEMP "SoftwareInstall_$(Get-Date -Format 'yyyyMMdd').log"
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        'WARN' { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        'DEBUG' { if ($VerbosePreference -eq 'Continue') { Write-Host $entry -ForegroundColor Gray } }
        default { Write-Host $entry }
    }

    try {
        $logDir = Split-Path $LogPath -Parent
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $LogPath -Value $entry -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to log file: $($_.Exception.Message)"
    }
}

$logDir = "C:\ProgramData\SDL\scripts\logs"
$script:LogPath = if ($LogPath) { $LogPath } else { Join-Path $logDir ("Install-DotNetSdk10_{0}.log" -f (Get-Date -Format 'yyyyMMdd')) }
Write-Log "===== Starting .NET SDK 10 + AzureSignTool installation ====="
Write-Log "Log file : $($script:LogPath)"
Write-Log "Force    : $Force"

function Test-InstallerIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedPublishers,

        [string]$ExpectedSha256,
        [string]$ExpectedSha512,
        [switch]$AllowUnsigned
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Integrity check failed: file not found: $Path"
    }

    Write-Log "Running integrity checks on: $Path"

    $actualSha256 = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    $actualSha512 = (Get-FileHash -Path $Path -Algorithm SHA512).Hash.ToUpperInvariant()
    Write-Log "SHA256: $actualSha256"
    Write-Log "SHA512: $actualSha512"

    if ($ExpectedSha512) {
        $expected512 = $ExpectedSha512.Trim().ToUpperInvariant()
        if ($actualSha512 -ne $expected512) {
            throw "SHA-512 mismatch. Expected $expected512 but got $actualSha512"
        }
        Write-Log "SHA-512 verified against official Microsoft metadata." -Level SUCCESS
    }
    else {
        Write-Log "No official SHA-512 supplied — hash recorded for audit; not enforced." -Level WARN
    }

    if ($ExpectedSha256) {
        $expected256 = $ExpectedSha256.Trim().ToUpperInvariant()
        if ($actualSha256 -ne $expected256) {
            throw "SHA-256 mismatch. Expected $expected256 but got $actualSha256"
        }
        Write-Log "SHA-256 verified against expected value." -Level SUCCESS
    }

    $sig = Get-AuthenticodeSignature -FilePath $Path
    Write-Log "Authenticode Status : $($sig.Status)"
    if ($sig.SignerCertificate) {
        Write-Log "Signer Subject      : $($sig.SignerCertificate.Subject)"
        Write-Log "Signer Thumbprint   : $($sig.SignerCertificate.Thumbprint)"
    }

    if ($sig.Status -ne 'Valid') {
        if ($AllowUnsigned) {
            Write-Log "Authenticode not valid ($($sig.Status)) but -AllowUnsigned was specified." -Level WARN
            if (-not $ExpectedSha256 -and -not $ExpectedSha512) {
                throw "Unsigned/invalid signature requires -ExpectedSha256 or an official SHA-512 so the file can still be integrity-checked."
            }
            return
        }
        throw "Authenticode signature is not valid. Status=$($sig.Status)"
    }

    $subject = $sig.SignerCertificate.Subject
    $matched = $false
    foreach ($pub in $ExpectedPublishers) {
        if ($subject -like "*$pub*") {
            $matched = $true
            Write-Log "Publisher matched: $pub" -Level SUCCESS
            break
        }
    }
    if (-not $matched) {
        throw "Unexpected publisher. Subject='$subject'. Expected one of: $($ExpectedPublishers -join ', ')"
    }

    Write-Log "Integrity checks passed." -Level SUCCESS
}

function Get-InstalledDotNetSdk10Versions {
    $versions = [System.Collections.Generic.List[string]]::new()

    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($dotnet) {
        & $dotnet.Source --list-sdks 2>$null | ForEach-Object {
            if ($_ -match '^(10\.\d+\.\d+)') {
                $versions.Add($Matches[1])
            }
        }
    }

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -match 'Microsoft \.NET SDK 10' -and $p.DisplayVersion) {
                $versions.Add([string]$p.DisplayVersion)
            }
        }
    }

    return $versions | Sort-Object { [version]($_ -replace '[^\d.].*$') } -Unique
}

function Get-LatestDotNetSdk10Info {
    $uri = 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json'
    Write-Log "Querying official .NET 10 release metadata..."
    Write-Log "URL : $uri"

    $headers = @{
        'User-Agent' = 'PowerShell-DotNetSdk10-Installer'
        'Accept'     = 'application/json'
    }

    $meta = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 60
    $latestSdk = [string]$meta.'latest-sdk'
    if (-not $latestSdk) {
        throw "Could not determine latest-sdk from release metadata."
    }

    $release = $meta.releases | Select-Object -First 1
    $sdkCandidates = @()
    if ($release.sdk) { $sdkCandidates += $release.sdk }
    if ($release.sdks) { $sdkCandidates += @($release.sdks) }

    $sdk = $sdkCandidates | Where-Object { $_.version -eq $latestSdk } | Select-Object -First 1
    if (-not $sdk) { $sdk = $release.sdk }
    if (-not $sdk) {
        throw "Could not locate SDK metadata for version $latestSdk."
    }

    $file = $sdk.files | Where-Object {
        $_.rid -eq 'win-x64' -and $_.name -match 'dotnet-sdk-win-x64\.exe$'
    } | Select-Object -First 1

    if (-not $file) {
        $file = $sdk.files | Where-Object { $_.name -match 'win-x64\.exe$' } | Select-Object -First 1
    }
    if (-not $file) {
        throw "Could not find a Windows x64 SDK installer in the latest .NET 10 release."
    }

    Write-Log "Latest .NET 10 SDK: $latestSdk"

    [pscustomobject]@{
        Version  = $latestSdk
        FileName = Split-Path $file.url -Leaf
        Url      = $file.url
        Sha512   = $file.hash
        Channel  = [string]$meta.'channel-version'
        Runtime  = [string]$meta.'latest-runtime'
    }
}

function Update-SessionPath {
    $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Get-InstalledAzureSignToolVersion {
    Update-SessionPath
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) { return $null }

    $line = & $dotnet.Source tool list --global 2>$null |
    Where-Object { $_ -match '^\s*azuresigntool\s+' } |
    Select-Object -First 1

    if ($line -match 'azuresigntool\s+(\S+)') {
        return $Matches[1]
    }
    return $null
}

function Install-AzureSignTool {
    param([switch]$Force)

    Update-SessionPath
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        throw "dotnet CLI was not found on PATH after SDK install."
    }

    $installed = Get-InstalledAzureSignToolVersion
    if ($installed -and -not $Force) {
        Write-Log "AzureSignTool already installed (version $installed). Updating to latest..."
        $action = 'update'
    }
    elseif ($installed -and $Force) {
        Write-Log "AzureSignTool version $installed found. -Force specified, reinstalling latest." -Level WARN
        $action = 'update'
    }
    else {
        Write-Log "AzureSignTool not detected. Installing latest global tool."
        $action = 'install'
    }

    $toolArgs = @('tool', $action, '--global', 'AzureSignTool')
    Write-Log "Running: dotnet $($toolArgs -join ' ')"

    & $dotnet.Source @toolArgs
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet tool $action AzureSignTool failed with exit code $LASTEXITCODE"
    }

    $newVersion = Get-InstalledAzureSignToolVersion
    if ($newVersion) {
        Write-Log "AzureSignTool installed: $newVersion" -Level SUCCESS
    }
    else {
        Write-Log "AzureSignTool command completed but version could not be detected." -Level WARN
    }
}

try {
    $downloadInfo = Get-LatestDotNetSdk10Info
    $installedSdks = @(Get-InstalledDotNetSdk10Versions)
    $latestInstalled = $installedSdks | Select-Object -Last 1

    $sdkNeedsInstall = $true
    if ($latestInstalled) {
        Write-Log "Installed .NET 10 SDK version(s): $($installedSdks -join ', ')"
        if ((-not $Force) -and ([version]$latestInstalled -ge [version]$downloadInfo.Version)) {
            Write-Log ".NET SDK $($downloadInfo.Version) (or newer) is already installed. Skipping SDK install. Use -Force to reinstall." -Level SUCCESS
            $sdkNeedsInstall = $false
        }
        elseif ($Force) {
            Write-Log ".NET SDK $latestInstalled found. -Force specified, proceeding with reinstall." -Level WARN
        }
        else {
            Write-Log "Installed SDK $latestInstalled is older than latest $($downloadInfo.Version). Upgrading."
        }
    }
    else {
        Write-Log ".NET SDK 10 not detected. Proceeding with fresh install."
    }

    if ($sdkNeedsInstall) {
        if (-not (Test-Path $DownloadPath)) {
            New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
        }

        $installerPath = Join-Path $DownloadPath $downloadInfo.FileName
        Write-Log "Downloading .NET SDK $($downloadInfo.Version)..."
        Write-Log "URL : $($downloadInfo.Url)"
        Write-Log "Dest: $installerPath"

        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $installerPath -UseBasicParsing

        if (-not (Test-Path $installerPath) -or (Get-Item $installerPath).Length -lt 5MB) {
            throw "Download failed or file is too small."
        }

        $fileSizeMB = [math]::Round((Get-Item $installerPath).Length / 1MB, 2)
        Write-Log "Download complete ($fileSizeMB MB)" -Level SUCCESS

        Test-InstallerIntegrity -Path $installerPath `
            -ExpectedPublishers @('Microsoft Corporation', 'Microsoft') `
            -ExpectedSha256 $ExpectedSha256 `
            -ExpectedSha512 $downloadInfo.Sha512

        Write-Log "Starting silent SDK installation..."
        $process = Start-Process -FilePath $installerPath -ArgumentList @('/install', '/quiet', '/norestart') -Wait -PassThru

        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
            Write-Log ".NET SDK installation completed (ExitCode: $($process.ExitCode))" -Level SUCCESS
        }
        else {
            throw "Installer returned non-zero exit code: $($process.ExitCode)"
        }

        Update-SessionPath
        Start-Sleep -Seconds 2

        $newSdks = @(Get-InstalledDotNetSdk10Versions)
        if ($newSdks) {
            Write-Log "Verified installed .NET 10 SDK version(s): $($newSdks -join ', ')" -Level SUCCESS
        }
        else {
            Write-Log "Installation reported success but .NET SDK 10 could not be detected afterwards." -Level WARN
        }

        Write-Log "Cleaning up downloaded installer..."
        Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    }

    Install-AzureSignTool -Force:$Force

    Write-Log "===== .NET SDK 10 + AzureSignTool installation finished =====" -Level SUCCESS
    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}