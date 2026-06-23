#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ensure-pssa.ps1 -- idempotent vendor of a PINNED PSScriptAnalyzer (PSSA) into
# CLAUDE_PLUGIN_DATA/modules. PSES emits only parser errors without PSSA on its
# module path; PSSA supplies the lint/semantic rule diagnostics. The daemon
# prepends this dir to the PSES child's PSModulePath so the analyzer pass runs.
#
# Pin: resolved against the PowerShell Gallery latest stable on 2026-06-05. To
# bump, change $PssaVersion (and the PSES pin lives in ensure-pses.ps1). See
# README "Pinned versions". Do not invent a version.
#
# Silent on stdout; logs to CLAUDE_PLUGIN_DATA/logs/ensure-pssa.log. No-op once a
# matching pinned version is vendored and importable.
#
# Author: Mike Andersen / powershell-lsp plugin.

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')

$PssaVersion = '1.25.0'
# SHA-256 of the pinned PSScriptAnalyzer .nupkg from the PowerShell Gallery, computed with
# Get-FileHash on the REAL 1.25.0 download (dispatch 000046, Gap B L2). The .nupkg is verified
# against this AFTER download and BEFORE expansion; a mismatch FAILS CLOSED. Recompute with
# Get-FileHash if $PssaVersion is bumped -- never invent or guess it.
$PssaSha256 = '14E634C828EB98EFB9F40B2918BA90F139ED5ECCDF663A2A747736D996995D60'

# Explicit User-Agent for the Gallery download (dispatch 000047). The PowerShell Gallery / Azure CDN
# has been observed to intermittently 403 GitHub-Actions egress IPs; an explicit UA is a cheap hedge.
# It is NOT the root cause -- both CI windows legs already fetch under pwsh 7 with the same default
# UA -- so the bounded retry on the download (Method 1) is the actual transient-403 mitigation.
$PssaUserAgent = 'powershell-lsp-plugin (ensure-pssa)'

$dataRoot = Get-PluginDataRoot
if ([string]::IsNullOrWhiteSpace($dataRoot)) { return }

$vendorDir = Get-PssaModuleDir
$logDir = Get-LogDir
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'ensure-pssa.log'
$marker = Join-Path $vendorDir ('.pssa-' + $PssaVersion + '.ok')

function Write-Log([string]$m) {
    try { ('[' + (Get-Date -Format 'o') + '] ' + $m) | Out-File -FilePath $log -Append -Encoding ascii } catch { }
}

function Find-PssaManifest([string]$searchRoot) {
    if (-not (Test-Path -LiteralPath $searchRoot)) { return $null }
    Get-ChildItem -LiteralPath $searchRoot -Recurse -Filter 'PSScriptAnalyzer.psd1' -File -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } | Select-Object -First 1
}

function Test-PssaImportable {
    $manifest = Find-PssaManifest $vendorDir
    if ($null -eq $manifest) { return $false }
    try {
        $data = Import-PowerShellDataFile -LiteralPath $manifest.FullName
        if ($data.ModuleVersion -ne $PssaVersion) {
            Write-Log ('found PSSA ' + $data.ModuleVersion + ' but pin is ' + $PssaVersion)
            return $false
        }
        Import-Module $manifest.FullName -Force -ErrorAction Stop
        return ($null -ne (Get-Command Invoke-ScriptAnalyzer -ErrorAction Stop))
    } catch {
        Write-Log ('import check failed: ' + $_.Exception.Message)
        return $false
    }
}

# Fast path: pinned version already vendored and importable.
if ((Test-Path -LiteralPath $marker) -and (Test-PssaImportable)) {
    Write-Log ('PSSA ' + $PssaVersion + ' already vendored; no-op.')
    return
}

New-Item -ItemType Directory -Force -Path $vendorDir | Out-Null
Write-Log ('vendoring PSScriptAnalyzer ' + $PssaVersion)
$installed = $false

# Method 1 (PRIMARY, hash-verified -- dispatch 000046 Gap B L2): download the pinned .nupkg,
# verify it against $PssaSha256, then expand. The VERIFIED path is primary on purpose so the
# integrity pin is LOAD-BEARING (it gates the install on the happy path) rather than bypassed
# by an unverified installer. A hash MISMATCH is a tamper signal -> FAIL CLOSED immediately
# (exit 1, loud, NO retry, NO fallback to an unverified install). A DOWNLOAD/expand failure
# (offline / proxy / a transient Gallery 403) falls through to the Save-Module fallback, which
# relies on the PowerShell Gallery's own publisher/catalog integrity. Layout is identical to the
# prior nupkg path (vendorDir/PSScriptAnalyzer/<version>), so Find-PssaManifest resolves it unchanged.
#
# 000047: the DOWNLOAD (only) is wrapped in a bounded retry. The PowerShell Gallery / Azure CDN
# intermittently 403s GitHub-Actions egress IPs -- observed on one CI leg while the others fetched
# the identical request (same pwsh 7, same User-Agent) fine, so it is an egress/CDN flake, NOT a
# host- or UA-specific fault. The retry lets a transient 403 self-recover; an explicit User-Agent is
# also set as a cheap hedge. CRITICAL: the retry re-attempts the network fetch ONLY -- the pin is
# still checked exactly once, AFTER a fetch succeeds, and a hash MISMATCH never retries and never
# falls back; it fails closed. The retried bytes are the SAME pinned artifact (the pin re-verifies them).
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('pssa-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $nupkg = Join-Path $tmp 'pssa.zip'
    $url = 'https://www.powershellgallery.com/api/v2/package/PSScriptAnalyzer/' + $PssaVersion
    # Bounded retry on the network fetch ONLY (000047). A genuine hash mismatch is handled below and
    # never reaches a retry; this loop only re-attempts a failed/transient DOWNLOAD before giving up
    # to the Save-Module fallback. Backoff: 2s, then 4s (last attempt does not sleep).
    $downloaded = $false
    $lastDownloadError = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing -UserAgent $PssaUserAgent
            $downloaded = $true
            break
        } catch {
            $lastDownloadError = $_.Exception.Message
            Write-Log ('verified .nupkg download attempt ' + $attempt + ' of 3 failed: ' + $lastDownloadError)
            if ($attempt -lt 3) { Start-Sleep -Seconds ($attempt * 2) }
        }
    }
    if (-not $downloaded) { throw ('download failed after 3 attempts: ' + $lastDownloadError) }

    if (-not (Test-PinnedFileHash -Path $nupkg -ExpectedSha256 $PssaSha256)) {
        $actualHash = ''
        try { $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $nupkg -ErrorAction Stop).Hash } catch { }
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log ('PSSA .nupkg integrity check FAILED -- refusing unverified package. expected ' +
            $PssaSha256 + ' got ' + $actualHash)
        # FAIL CLOSED: a tamper signal must NOT fall back to an unverified install. Exit loud so
        # SessionStart surfaces the honest 'unavailable' surface; the hook itself still exits 0.
        [Console]::Error.WriteLine('ensure-pssa: PSScriptAnalyzer ' + $PssaVersion +
            ' integrity check failed (hash mismatch); refusing unverified package; see ' + $log)
        exit 1
    }

    $expand = Join-Path $tmp 'expand'
    Expand-Archive -LiteralPath $nupkg -DestinationPath $expand -Force
    $psd1 = Get-ChildItem -LiteralPath $expand -Recurse -Filter 'PSScriptAnalyzer.psd1' -File |
        Sort-Object { $_.FullName.Length } | Select-Object -First 1
    if ($null -eq $psd1) { throw 'PSScriptAnalyzer.psd1 not found in package.' }
    $moduleSrc = $psd1.Directory.FullName

    $dest = Join-Path (Join-Path $vendorDir 'PSScriptAnalyzer') $PssaVersion
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $skip = @('_rels', 'package', '[Content_Types].xml')
    Get-ChildItem -LiteralPath $moduleSrc -Force | Where-Object {
        ($skip -notcontains $_.Name) -and ($_.Extension -ne '.nuspec')
    } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

    if (Test-PssaImportable) { $installed = $true; Write-Log 'verified .nupkg method succeeded.' }
    else { Write-Log 'verified .nupkg expanded but module not importable; will try Save-Module.' }
} catch {
    Write-Log ('verified .nupkg method failed (download/expand): ' + $_.Exception.Message)
}

# Method 2 (FALLBACK -- download/network failure only): Save-Module at the pinned version. Used
# only when the verified .nupkg path could not COMPLETE (NOT on a hash mismatch -- that already
# failed closed above and exited). Relies on the PowerShell Gallery's own publisher/catalog integrity.
if (-not $installed) {
    # 000047: register the DEFAULT PSGallery repository when it is ABSENT, idempotently and scoped to
    # this fallback path (the verified primary never reaches here). On some hosts (observed on a CI
    # runner) PSGallery is not registered, so Save-Module dies with "Unable to find repository
    # 'PSGallery'" and the fallback can never recover. Only touch the repo set when PSGallery is
    # missing -- an already-configured repository set is left untouched. Set it Trusted so the
    # non-interactive Save-Module below does not stall on an install-from-untrusted-source prompt.
    $galleryPresent = $false
    try { $galleryPresent = $null -ne (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue) } catch { $galleryPresent = $false }
    if (-not $galleryPresent) {
        Write-Log 'PSGallery repository not registered; registering the default repository for the fallback.'
        try { Register-PSRepository -Default -ErrorAction Stop } catch { Write-Log ('Register-PSRepository -Default failed: ' + $_.Exception.Message) }
        try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch { }
    }
    try {
        Save-Module -Name PSScriptAnalyzer -RequiredVersion $PssaVersion -Path $vendorDir -Repository PSGallery -Force -ErrorAction Stop
        if (Test-PssaImportable) { $installed = $true; Write-Log 'Save-Module fallback succeeded.' }
        else { Write-Log 'Save-Module fallback ran but module not importable.' }
    } catch {
        Write-Log ('Save-Module fallback failed: ' + $_.Exception.Message)
    }
}

if (-not $installed) {
    Write-Log 'FAILED to vendor PSScriptAnalyzer by any method.'
    [Console]::Error.WriteLine('ensure-pssa: failed to vendor PSScriptAnalyzer ' + $PssaVersion + '; see ' + $log)
    exit 1
}

New-Item -ItemType File -Force -Path $marker | Out-Null
Write-Log ('PSSA ' + $PssaVersion + ' vendored at ' + (Find-PssaManifest $vendorDir).FullName)
