<#
.SYNOPSIS
    Installs the latest .NET SDK 10 and the AzureSignTool global tool.

.PARAMETER Force
    Reinstall even if already present.

.PARAMETER LogPath
    Full path to the log file.

.PARAMETER DownloadPath
    Temporary folder for the installer.

.PARAMETER ExpectedSha256
    Optional SHA-256 to enforce in addition to the official SHA-512.

.EXAMPLE
    .\install-dotnet.ps1

.EXAMPLE
    .\install-dotnet.ps1 -Force
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Force,
    [string]$LogPath,
    [string]$DownloadPath = (Join-Path $env:TEMP 'DotNetSdk10Install'),
    [string]$ExpectedSha256
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

function Test-InstallerIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedPublishers,
        [string]$ExpectedSha256,
        [string]$ExpectedSha512
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Integrity check failed: file not found: $Path"
    }

    if ($ExpectedSha512) {
        $actualSha512 = (Get-FileHash -Path $Path -Algorithm SHA512).Hash.ToUpperInvariant()
        $expected512 = $ExpectedSha512.Trim().ToUpperInvariant()
        if ($actualSha512 -ne $expected512) {
            throw "SHA-512 mismatch. Expected $expected512 but got $actualSha512"
        }
    }

    if ($ExpectedSha256) {
        $actualSha256 = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
        $expected256 = $ExpectedSha256.Trim().ToUpperInvariant()
        if ($actualSha256 -ne $expected256) {
            throw "SHA-256 mismatch. Expected $expected256 but got $actualSha256"
        }
    }

    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($sig.Status -ne 'Valid') {
        throw "Authenticode signature is not valid. Status=$($sig.Status)"
    }

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

function Get-InstalledDotNetSdk10Versions {
    $versions = @()
    $dotnetExe = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'

    if (Test-Path $dotnetExe) {
        $sdkLines = & $dotnetExe --list-sdks 2>$null
        foreach ($line in $sdkLines) {
            if ($line -match '^(10\.\d+\.\d+)') {
                $versions += $Matches[1]
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
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($props.DisplayName -match 'Microsoft \.NET SDK 10' -and $props.DisplayVersion) {
                $versions += [string]$props.DisplayVersion
            }
        }
    }

    $versions | Sort-Object { [version]($_ -replace '[^\d.].*$', '') } -Unique
}

function Get-LatestDotNetSdk10Info {
    $uri = 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json'
    $headers = @{
        'User-Agent' = 'PowerShell-DotNetSdk10-Installer'
        'Accept'     = 'application/json'
    }

    $meta = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 60
    $latestSdk = [string]$meta.'latest-sdk'
    if (-not $latestSdk) {
        throw 'Could not determine latest-sdk from release metadata.'
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

    $file = $sdk.files | Where-Object { $_.rid -eq 'win-x64' -and $_.name -eq 'dotnet-sdk-win-x64.exe' } | Select-Object -First 1
    if (-not $file) {
        $file = $sdk.files | Where-Object { $_.name -match 'win-x64\.exe$' } | Select-Object -First 1
    }
    if (-not $file) {
        throw 'Could not find a Windows x64 SDK installer in the latest .NET 10 release.'
    }

    [pscustomobject]@{
        Version  = $latestSdk
        FileName = Split-Path $file.url -Leaf
        Url      = $file.url
        Sha512   = $file.hash
    }
}

function Update-SessionPath {
    $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = $machine + ';' + $user
}

function Get-DotNetExe {
    Update-SessionPath
    $dotnetExe = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
    if (Test-Path $dotnetExe) { return $dotnetExe }

    $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    return $null
}

function Get-InstalledAzureSignToolVersion {
    $dotnetExe = Get-DotNetExe
    if (-not $dotnetExe) { return $null }

    $lines = & $dotnetExe tool list --global 2>$null
    foreach ($line in $lines) {
        if ($line -match 'azuresigntool\s+(\S+)') {
            return $Matches[1]
        }
    }
    return $null
}

function Install-AzureSignTool {
    param([switch]$Force)

    $dotnetExe = Get-DotNetExe
    if (-not $dotnetExe) {
        throw 'dotnet.exe was not found after SDK install.'
    }

    $installed = Get-InstalledAzureSignToolVersion
    if ($installed -and -not $Force) {
        $action = 'update'
        Write-Log "Updating AzureSignTool from $installed"
    }
    elseif ($installed -and $Force) {
        $action = 'update'
        Write-Log "Reinstalling AzureSignTool from $installed"
    }
    else {
        $action = 'install'
        Write-Log 'Installing AzureSignTool'
    }

    & $dotnetExe tool $action --global AzureSignTool
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet tool $action AzureSignTool failed with exit code $LASTEXITCODE"
    }

    $newVersion = Get-InstalledAzureSignToolVersion
    if ($newVersion) {
        Write-Log "AzureSignTool ready: $newVersion" -Level SUCCESS
    }
    else {
        Write-Log 'AzureSignTool command completed but version was not detected.' -Level WARN
    }
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Install-DotNetSdk10_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log 'Starting .NET SDK 10 and AzureSignTool install'

try {
    $downloadInfo = Get-LatestDotNetSdk10Info
    $installedSdks = @(Get-InstalledDotNetSdk10Versions)
    $latestInstalled = $installedSdks | Select-Object -Last 1
    $sdkNeedsInstall = $true

    if ($latestInstalled -and -not $Force -and ([version]$latestInstalled -ge [version]$downloadInfo.Version)) {
        Write-Log ('.NET SDK {0} already installed' -f $latestInstalled) -Level SUCCESS
        $sdkNeedsInstall = $false
    }
    elseif ($latestInstalled -and $Force) {
        Write-Log ('.NET SDK {0} found; Force specified' -f $latestInstalled) -Level WARN
    }
    elseif ($latestInstalled) {
        Write-Log ('Upgrading .NET SDK from {0} to {1}' -f $latestInstalled, $downloadInfo.Version)
    }
    else {
        Write-Log ('.NET SDK 10 not found; installing {0}' -f $downloadInfo.Version)
    }

    if ($sdkNeedsInstall) {
        if (-not (Test-Path $DownloadPath)) {
            New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
        }

        $installerPath = Join-Path $DownloadPath $downloadInfo.FileName
        Write-Log ('Downloading .NET SDK {0}' -f $downloadInfo.Version)

        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $installerPath -UseBasicParsing

        if (-not (Test-Path $installerPath) -or (Get-Item $installerPath).Length -lt 5MB) {
            throw 'Download failed or file is too small.'
        }

        $integrityParams = @{
            Path               = $installerPath
            ExpectedPublishers = @('Microsoft Corporation', 'Microsoft')
            ExpectedSha512     = $downloadInfo.Sha512
        }
        if ($ExpectedSha256) {
            $integrityParams['ExpectedSha256'] = $ExpectedSha256
        }
        Test-InstallerIntegrity @integrityParams

        Write-Log 'Installing .NET SDK'
        $processParams = @{
            FilePath     = $installerPath
            ArgumentList = @('/install', '/quiet', '/norestart')
            Wait         = $true
            PassThru     = $true
        }
        $process = Start-Process @processParams

        if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
            throw "Installer returned non-zero exit code: $($process.ExitCode)"
        }

        Update-SessionPath
        $newSdks = @(Get-InstalledDotNetSdk10Versions)
        if ($newSdks) {
            Write-Log ('.NET SDK installed: {0}' -f ($newSdks -join ', ')) -Level SUCCESS
        }
        else {
            Write-Log 'SDK installer succeeded but version was not detected.' -Level WARN
        }

        Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    }

    Install-AzureSignTool -Force:$Force
    Write-Log 'Install finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
