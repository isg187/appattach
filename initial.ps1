#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Dynamically fetches installer scripts from a GitHub repo (install folder)
    without ZIP extraction, flattening, or manual script listing.
.DESCRIPTION
    Uses GitHub Contents API to discover and download .ps1 files in /install.
    Eliminates file corruption caused by ZIP extraction in AIB/Packer.
#>

$ErrorActionPreference = "Stop"

# === CONFIG ===
$Destination = "C:\ProgramData\SDL\scripts"
$InstallDir = Join-Path $Destination "install"
$LogDir = Join-Path $Destination "logs"
$RepoOwner = "isg187"
$RepoName = "appattach"
$Branch = "main"
$ApiUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/contents/install?ref=$Branch"
$Headers = @{ "User-Agent" = "AIB-Packer-Agent" }

function Write-Log {
    param(
        [Parameter(Position = 0)] [AllowEmptyString()] [string]$Message = "",
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    if ($Message -like '') {
        $entry = ""
    }
    else {
        $entry = "[$ts] [$Level] $Message"
    }

    switch ($Level) {
        "ERROR" { Write-Host $entry -ForegroundColor Red }
        "WARN" { Write-Host $entry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $entry -ForegroundColor Green }
        default { Write-Host $entry }
    }

    if ($script:LogPath) {
        try {
            $dir = Split-Path $script:LogPath -Parent
            if ($dir -and -not (Test-Path $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Add-Content -Path $script:LogPath -Value $entry -ErrorAction SilentlyContinue
        }
        catch { }
    }
}

try {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

    $script:LogPath = Join-Path $LogDir ("Bootstrap-And-Install_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

    Write-Log "===== Bootstrap And Install (GitHub API Version) ====="
    Write-Log "Destination : $Destination"
    Write-Log "InstallDir  : $InstallDir"
    Write-Log "API URL     : $ApiUrl"
    Write-Log "Log         : $script:LogPath"

    # === GET DIRECTORY LISTING FROM GITHUB ===
    Write-Log "Querying GitHub API for installer scripts..."
    $response = Invoke-WebRequest -Uri $ApiUrl -Headers $Headers -UseBasicParsing

    $items = $response.Content | ConvertFrom-Json
    $psScripts = $items | Where-Object { $_.type -eq "file" -and $_.name -like "*.ps1" }

    if ($psScripts.Count -eq 0) {
        Write-Log "No .ps1 installer scripts found in GitHub repo install folder." -Level ERROR
        throw "Install folder is empty."
    }

    Write-Log "Found $($psScripts.Count) installer scripts:"
    $psScripts | ForEach-Object { Write-Log "  - $($_.name)" }

    # === DOWNLOAD ALL INSTALLER SCRIPTS ===
    foreach ($s in $psScripts) {
        $outFile = Join-Path $InstallDir $s.name
        Write-Log "Downloading: $($s.name)"
        Invoke-WebRequest -Uri $s.download_url -OutFile $outFile -UseBasicParsing

        # Enforce UTF-8 (prevents any encoding weirdness)
        $raw = Get-Content $outFile -Raw
        Set-Content -Path $outFile -Value $raw -Encoding UTF8
    }

    # === DISCOVER INSTALLER SCRIPTS LOCALLY ===
    $installerScripts = Get-ChildItem -Path $InstallDir -Filter "*.ps1" -File | Sort-Object Name

    if ($installerScripts.Count -eq 0) {
        throw "Installer scripts missing after download."
    }

    Write-Log "Ready to execute installers:"
    $installerScripts | ForEach-Object { Write-Log "  - $($_.Name)" }

    # === RUN INSTALLER SCRIPTS ===
    $results = @()
    $overallSuccess = $true

    foreach ($scriptFile in $installerScripts) {
        $name = $scriptFile.BaseName
        $path = $scriptFile.FullName

        Write-Log "--------------------------------------------------"
        Write-Log "Starting installer: $name"
        Write-Log "Script: $path"

        try {
            $proc = Start-Process "powershell.exe" `
                -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $path, "-Force" -Wait -PassThru -NoNewWindow

            if ($proc.ExitCode -eq 0) {
                Write-Log "$name completed successfully." -Level SUCCESS
                $results += [pscustomobject]@{ Name = $name; Success = $true; Message = "OK" }
            }
            else {
                Write-Log "$name failed with exit code $($proc.ExitCode)." -Level ERROR
                $results += [pscustomobject]@{ Name = $name; Success = $false; Message = "Exit $($proc.ExitCode)" }
                $overallSuccess = $false
            }
        }
        catch {
            Write-Log "Exception while running $name : $($_.Exception.Message)" -Level ERROR
            $results += [pscustomobject]@{ Name = $name; Success = $false; Message = $_.Exception.Message }
            $overallSuccess = $false
        }
    }

    # === SUMMARY ===
    Write-Log "=============================================="
    Write-Log "Summary"
    Write-Log "=============================================="

    foreach ($r in $results) {
        $status = if ($r.Success) { "SUCCESS" } else { "FAILED" }
        Write-Log ("{0,-35} {1}" -f $r.Name, $status)
    }

    if ($overallSuccess) {
        Write-Log "All installers completed successfully." -Level SUCCESS
        Write-Log "===== Finished =====" -Level SUCCESS
        exit 0
    }
    else {
        Write-Log "One or more installations failed." -Level ERROR
        exit 1
    }

}
catch {
    Write-Log "MASTER SCRIPT FAILED: $($_.Exception.Message)" -Level ERROR
    exit 1
}