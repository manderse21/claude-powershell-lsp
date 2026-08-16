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

# Pinned-.nupkg cache (dispatch 000049): the STRUCTURAL cure for the 000047 PowerShell Gallery /
# Azure-CDN egress flake. When POWERSHELL_LSP_PSSA_CACHE names a directory, the pinned .nupkg is
# restored from there on a cache HIT (so the Gallery is contacted ONLY on a miss) and saved there
# after a verified miss. CI wires this to actions/cache (keyed pssa-<os>-<version>-<sha256>) so the
# windows-powershell (5.1) leg is structurally unable to flake on Gallery egress. TWO load-bearing
# invariants keep the pin the ONLY trust anchor:
#   1. VERIFY ON EVERY HIT -- a restored .nupkg is run through the SAME Test-PinnedFileHash gate,
#      byte-for-byte as a fresh download, BEFORE use. A poisoned/stale cache entry (right name,
#      wrong bytes) fails CLOSED exactly like a tampered download. The cache is a transport
#      optimization, NEVER a trust shortcut.
#   2. KEY BINDS TO THE PIN -- the cached filename embeds BOTH $PssaVersion AND $PssaSha256, so a
#      pin bump (version or hash) yields a different filename: a guaranteed miss, never a stale
#      draw. (CI's actions/cache key binds to the same pin; the filename binds it on every path.)
# When the env var is UNSET (the default for a normal install) there is no cache and acquisition is
# byte-identical to the 000047 path.
function Get-PssaCachedNupkgPath {
    $cacheDir = $env:POWERSHELL_LSP_PSSA_CACHE
    if ([string]::IsNullOrWhiteSpace($cacheDir)) { return '' }
    return (Join-Path $cacheDir ('PSScriptAnalyzer-' + $PssaVersion + '-' + $PssaSha256 + '.nupkg'))
}

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
# Declared BEFORE the try (dispatch 000244), the same StrictMode discipline ensure-pses.ps1
# applies to its staging paths: Method 1 can throw before the layering block runs, and the
# marker write and the Method 2 fallback below both read this. Referencing an unset variable
# under Set-StrictMode -Version Latest is a terminating error, so it is initialized here once.
$sourceLayer = ''

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

    # SOURCE LAYERING (dispatch 000244): mirror -> bundle -> [the existing 000049 cache ->
    # download]. This EXTENDS the 000049 pattern rather than replacing it: the cache and its
    # bounded retry keep their exact behavior and simply become the innermost layer, reached
    # only when neither 000244 source resolved. With neither new env var set, nothing below
    # this block observes any difference and acquisition is byte-identical to pre-000244.
    #
    # The 000049 invariants are the reason this composes safely, and they now govern four
    # sources instead of two: VERIFY ON EVERY HIT (every layer feeds the one Test-PinnedFileHash
    # gate below), and the pin stays the ONLY trust root.
    $artifactName = Get-PinnedArtifactFileName -Component 'pssa' -Version $PssaVersion
    $sourced = Resolve-PinnedArtifactSource -FileName $artifactName -Destination $nupkg
    foreach ($note in $sourced.Notes) { Write-Log ('artifact-source: ' + $note) }
    if ($sourced.Resolved) {
        $sourceLayer = $sourced.Layer
        Write-Log ('artifact-source: resolved from ' + $sourceLayer + ' (' + $sourced.Source +
            '); pin is still verified before use')
    }

    # CACHE LOOKUP (000049): restore the pinned .nupkg from the cache on a HIT so the Gallery is
    # contacted ONLY on a miss. The restored bytes are NOT trusted here -- they are copied into the
    # SAME $nupkg the verify runs on and then pass through the identical Test-PinnedFileHash gate
    # below (invariant 1). A copy failure simply falls through to the download (treat as a miss).
    # 000244: skipped entirely when a mirror or bundle already produced the artifact.
    $cachedNupkg = Get-PssaCachedNupkgPath
    $fromCache = $false
    if (-not $sourced.Resolved -and -not [string]::IsNullOrWhiteSpace($cachedNupkg) -and (Test-Path -LiteralPath $cachedNupkg -PathType Leaf)) {
        try {
            Copy-Item -LiteralPath $cachedNupkg -Destination $nupkg -Force
            $fromCache = $true
            $sourceLayer = 'cache'
            Write-Log ('cache HIT: restored pinned .nupkg from ' + $cachedNupkg + ' (pin still verified before use)')
        } catch {
            $fromCache = $false
            Write-Log ('cache hit but restore-copy failed; falling through to download: ' + $_.Exception.Message)
        }
    }

    # DOWNLOAD on a cache MISS only. Bounded retry on the network fetch ONLY (000047), preserved
    # verbatim as the miss path. A genuine hash mismatch is handled below and never reaches a retry;
    # this loop only re-attempts a failed/transient DOWNLOAD before giving up to the Save-Module
    # fallback. Backoff: 2s, then 4s (last attempt does not sleep). The Gallery is never contacted
    # on a cache hit.
    if (-not $sourced.Resolved -and -not $fromCache) {
        $sourceLayer = 'download'
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
    }

    # VERIFY: the pin gate runs on the .nupkg REGARDLESS of source (cache hit OR fresh download),
    # byte-for-byte identically (invariant 1). A poisoned/stale CACHE entry fails here exactly like a
    # tampered download: FAIL CLOSED (exit 1, no expand, no fallback, no self-heal -- a genuine
    # cache poison is a tamper signal you WANT to surface loudly, not silently paper over). Unchanged
    # from 000046/000047 except that it now also guards the cache-restore path.
    if (-not (Test-PinnedFileHash -Path $nupkg -ExpectedSha256 $PssaSha256)) {
        $actualHash = ''
        try { $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $nupkg -ErrorAction Stop).Hash } catch { }
        # 000244: the label is now the resolved LAYER (mirror / bundle / cache / download) rather
        # than the two-valued cached-or-downloaded. A tampered mirror artifact must fail exactly
        # like a tampered download -- same gate, same exit -- and the only thing that may differ
        # is which layer the banner NAMES, because that is what tells the admin what to go fix.
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log ('PSSA .nupkg integrity check FAILED (' + $sourceLayer + ') -- refusing unverified package. expected ' +
            $PssaSha256 + ' got ' + $actualHash)
        # FAIL CLOSED: a tamper signal must NOT fall back to an unverified install. Exit loud so
        # SessionStart surfaces the honest 'unavailable' surface; the hook itself still exits 0.
        [Console]::Error.WriteLine('ensure-pssa: PSScriptAnalyzer ' + $PssaVersion +
            ' integrity check failed (hash mismatch) for the ' + $sourceLayer +
            ' source; refusing unverified package; see ' + $log)
        exit 1
    }

    # POPULATE the cache after a VERIFIED download (the miss path) so the next run is an egress-free
    # hit. Only on a miss -- a hit already holds the verified bytes. Best-effort: a populate failure
    # is non-fatal (the install proceeds; the next run simply re-downloads). Only verified bytes are
    # ever written to the cache.
    # 000244: TIGHTENED from `-not $fromCache` to an explicit download test. Those were the same
    # condition when download was the only alternative to a cache hit; with mirror and bundle
    # layers they are not, and the loose form would start copying mirror/bundle bytes into a CI
    # cache that 000049 defined as holding only artifacts this script itself downloaded. The
    # populate stays exactly what it was: after a VERIFIED download, on the miss path only.
    if ($sourceLayer -eq 'download' -and -not [string]::IsNullOrWhiteSpace($cachedNupkg)) {
        try {
            $cacheDir = Split-Path -Parent $cachedNupkg
            if (-not [string]::IsNullOrWhiteSpace($cacheDir) -and -not (Test-Path -LiteralPath $cacheDir)) {
                New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
            }
            Copy-Item -LiteralPath $nupkg -Destination $cachedNupkg -Force
            Write-Log ('cache POPULATED with verified .nupkg at ' + $cachedNupkg)
        } catch {
            Write-Log ('cache populate failed (non-fatal): ' + $_.Exception.Message)
        }
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
        if (Test-PssaImportable) {
            $installed = $true
            # 000244: label this path DISTINCTLY, and never as one of the pinned layers. This is
            # the one acquisition route in either ensure-script whose bytes the SHA-256 pin does
            # NOT gate -- it rests on the Gallery's own publisher/catalog integrity instead (see
            # TRUST.md). Recording it as 'gallery-fallback' means the doctor's artifact-source
            # check reports the honest thing rather than implying a pin verified this install.
            # PRE-EXISTING and deliberately NOT changed here: closing that gap is its own dispatch.
            $sourceLayer = 'gallery-fallback'
            Write-Log 'Save-Module fallback succeeded.'
        }
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

# RECORD THE RESOLVED LAYER IN THE MARKER (dispatch 000244), matching ensure-pses.ps1: the
# doctor reports where THIS install came from rather than re-deriving a guess from whatever the
# environment happens to say later. Only the marker's EXISTENCE gates the fast path above, so
# giving it content changes no control flow, and a marker written by an older version simply
# carries no layer -- which the doctor reports as unrecorded instead of inventing an answer.
Set-Content -LiteralPath $marker -Value $sourceLayer -Encoding ascii -Force
Write-Log ('PSSA ' + $PssaVersion + ' vendored at ' + (Find-PssaManifest $vendorDir).FullName +
    ' (source: ' + $sourceLayer + ')')
