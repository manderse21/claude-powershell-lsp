#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared helpers -- Test-PinnedFileHash for the WS2 download-integrity check (dispatch 000046).
# Load-silent, defines-only; dot-sourced the same way ensure-pssa.ps1 already does.
. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')

# Pin resolved at build time against GitHub PowerShell/PowerShellEditorServices
# (latest stable release). Resolved 2026-06-01. Do not invent or hand-edit.
$PsesTag = 'v4.6.0'
# SHA-256 of the pinned PowerShellEditorServices.zip release asset, computed with Get-FileHash
# on the REAL v4.6.0 download (dispatch 000046, Gap B L2). The archive is verified against this
# AFTER download and BEFORE extraction; a mismatch FAILS CLOSED (the bundle is refused, the
# prior working bundle is left intact, and SessionStart surfaces the honest 'unavailable'
# banner). Recompute with Get-FileHash if $PsesTag is bumped -- never invent or guess it.
$PsesSha256 = '0D91898F73D4FAEB64291336F6386F0C890A933DF012827571ADF7008480A04A'

$dataRoot = $env:CLAUDE_PLUGIN_DATA
if ([string]::IsNullOrWhiteSpace($dataRoot)) {
    # Hook env not present; nothing to do. Stay silent.
    return
}

# RENAMED from $bundleDir (dispatch 000244). This is the INSTALL DESTINATION -- where the
# verified module lands. Since 000244 "bundle" also names an artifact SOURCE (a pre-staged
# directory an admin points POWERSHELL_LSP_ARTIFACT_BUNDLE_DIR at), and one word meaning both
# the place bytes come FROM and the place they go TO is exactly the confusion that produces a
# wrong edit later.
$installDir = Join-Path $dataRoot 'PowerShellEditorServices'
$marker = Join-Path $dataRoot ('pses-' + $PsesTag + '.ok')
# The launcher (pses-stdio.ps1) starts this exact path; gate the no-op fast path on
# the start script actually being present, not just on the bundle directory existing.
$startScript = Join-Path $installDir 'PowerShellEditorServices/Start-EditorServices.ps1'

if ((Test-Path -LiteralPath $startScript) -and (Test-Path -LiteralPath $marker)) {
    return
}

$logDir = Join-Path $dataRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'ensure-pses.log'
function Write-Log([string]$m) {
    ('[' + (Get-Date -Format 'o') + '] ' + $m) | Out-File -FilePath $log -Append -Encoding ascii
}

# Path handles for the staging area and the swap-aside backup. Defined BEFORE the try so the
# catch can always clean them up (StrictMode: referencing an unset var would throw).
$tmpZip = Join-Path $dataRoot ('pses-' + $PsesTag + '.zip')
$extractRoot = Join-Path $dataRoot ('pses-extract-' + $PsesTag)
$backupDir = $installDir + '.old-' + $PsesTag
$url = 'https://github.com/PowerShell/PowerShellEditorServices/releases/download/' + $PsesTag + '/PowerShellEditorServices.zip'

try {
    Write-Log ('Bootstrapping PSES ' + $PsesTag)

    # NON-DESTRUCTIVE (000024): download + extract + VERIFY entirely in a temp staging area
    # FIRST. Do not touch the live $installDir until a verified-good module is in hand, so a
    # failed re-bootstrap (offline / proxy / corrupt zip) leaves the PRIOR working bundle
    # intact rather than deleting it before a single-attempt download (the old :34-35 hazard).
    if (Test-Path -LiteralPath $tmpZip) { Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }

    # SOURCE LAYERING (dispatch 000244): mirror -> bundle -> this script's own download. The
    # FIRST layer that yields the archive wins, and the pin check on the very next lines then
    # runs on it byte-for-byte identically regardless of which layer that was -- the resolver
    # deliberately does NOT verify anything itself, so exactly one gate exists per artifact.
    #
    # This is the layer ensure-pssa has had since 000049 (its pinned-.nupkg cache) and PSES has
    # not: until now this script had a single unlayered download, no retry and no fallback. The
    # asymmetry is preserved on purpose -- nothing here adds a retry or a fallback, only sources.
    #
    # With NEITHER env var set, Resolve-PinnedArtifactSource returns unresolved without touching
    # the network or the disk, and the download below runs exactly as it did pre-000244.
    $artifactName = Get-PinnedArtifactFileName -Component 'pses' -Version $PsesTag
    $sourced = Resolve-PinnedArtifactSource -FileName $artifactName -Destination $tmpZip
    foreach ($note in $sourced.Notes) { Write-Log ('artifact-source: ' + $note) }
    $sourceLayer = 'download'
    if ($sourced.Resolved) {
        $sourceLayer = $sourced.Layer
        Write-Log ('artifact-source: resolved from ' + $sourceLayer + ' (' + $sourced.Source +
            '); pin is still verified before use')
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing
    }

    # WS2 (dispatch 000046, Gap B L2): FAIL CLOSED on a hash mismatch. Verify the downloaded
    # archive against the pinned SHA-256 BEFORE extracting or swapping. A mismatch means the
    # bytes are NOT the known-good pinned artifact (tampered mirror, MITM, truncation) -- refuse
    # it and throw, so the catch below cleans up the staging area, leaves the PRIOR working
    # bundle intact (non-destructive, 000024), and fails LOUD (stderr + exit 1). SessionStart
    # then surfaces the honest 'unavailable' banner and the hook still exits 0 -- editing is
    # never broken, the analyzer is just OFF until a verified bundle lands. No new status token.
    if (-not (Test-PinnedFileHash -Path $tmpZip -ExpectedSha256 $PsesSha256)) {
        $actualHash = ''
        try { $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $tmpZip -ErrorAction Stop).Hash } catch { }
        # NAME THE LAYER (000244). A mismatch fails CLOSED here and is NEVER retried against
        # another source: falling through would let whoever controls one layer force a
        # downgrade onto the next, and would turn a tamper signal into a retry. Saying WHICH
        # layer produced the bad bytes is what makes the banner actionable -- "refresh your
        # mirror" and "your bundle is corrupt" are different admin actions.
        throw ('PSES archive integrity check FAILED for the ' + $sourceLayer + ' source -- refusing ' +
            'unverified bundle. Expected SHA-256 ' + $PsesSha256 + ' but got ' + $actualHash +
            '. The artifact from the ' + $sourceLayer + ' source does not match the pinned ' + $PsesTag + ' artifact.')
    }

    Expand-Archive -LiteralPath $tmpZip -DestinationPath $extractRoot -Force

    # Normalize the layout regardless of how the archive nests things. The PSES
    # release zip extracts to a top-level 'PowerShellEditorServices' folder that IS
    # the module itself -- Start-EditorServices.ps1 and PowerShellEditorServices.psd1
    # live directly inside it. We want that module to land at
    # $installDir/PowerShellEditorServices so that $installDir is a valid
    # -BundledModulesPath and the start script resolves at
    # $installDir/PowerShellEditorServices/Start-EditorServices.ps1. Locate the module
    # by finding Start-EditorServices.ps1 (shallowest match) rather than assuming a
    # fixed nesting depth. This locate doubles as the download VERIFY -- a partial or
    # wrong archive yields no match and throws BEFORE any destructive swap.
    $startLeaf = Get-ChildItem -LiteralPath $extractRoot -Recurse -Filter 'Start-EditorServices.ps1' -File |
        Sort-Object { $_.FullName.Length } | Select-Object -First 1
    if ($null -eq $startLeaf) {
        throw 'Start-EditorServices.ps1 not found in the extracted PSES archive.'
    }

    # SWAP -- only now, with a verified-good module staged. Rename any existing bundle aside,
    # build the new one, then drop the old. On a swap failure restore the prior bundle, so the
    # user is never left with NO bundle. ($installDir is absent only for the few local FS ops
    # between rename and move, and only after a verified download -- never on a network miss.)
    if (Test-Path -LiteralPath $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force }
    if (Test-Path -LiteralPath $installDir) { Rename-Item -LiteralPath $installDir -NewName (Split-Path -Leaf $backupDir) }
    try {
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
        # MIT-notice preservation (dispatch 000029): the PSES release zip carries its MIT LICENSE +
        # NOTICE.txt at the distribution root (siblings of the PowerShellEditorServices module dir).
        # The module-only move below would drop them, leaving the installed bundle with NO upstream
        # notice -- an MIT violation ('included in all copies'). Capture that root BEFORE the move,
        # then copy the notices into the bundle root after. License-files only: ZERO runtime/behavior
        # change (the daemon reads the same module byte-for-byte); best-effort, so a missing or
        # uncopyable notice never aborts the install (the swap is already complete).
        $psesNoticeRoot = $startLeaf.Directory.Parent.FullName
        Move-Item -LiteralPath $startLeaf.Directory.FullName -Destination (Join-Path $installDir 'PowerShellEditorServices')
        foreach ($noticeName in @('LICENSE', 'NOTICE.txt')) {
            $noticeSrc = Join-Path $psesNoticeRoot $noticeName
            if (Test-Path -LiteralPath $noticeSrc -PathType Leaf) {
                Copy-Item -LiteralPath $noticeSrc -Destination (Join-Path $installDir $noticeName) -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backupDir) { Rename-Item -LiteralPath $backupDir -NewName (Split-Path -Leaf $installDir) }
        throw
    }
    if (Test-Path -LiteralPath $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue }

    Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue }

    # RECORD THE RESOLVED LAYER IN THE MARKER (dispatch 000244) so the doctor's artifact-source
    # check can report where THIS install actually came from instead of re-deriving a guess from
    # current configuration -- the env vars may have changed since the install, and a check that
    # reads today's config to describe yesterday's install would state a falsehood confidently.
    # The marker's EXISTENCE is still the only thing the fast path above tests, so writing
    # content to it changes no control flow; a marker left by an older version simply has no
    # layer recorded and the doctor reports that honestly rather than inventing one.
    Set-Content -LiteralPath $marker -Value $sourceLayer -Encoding ascii -Force
    Write-Log ('PSES bootstrap complete (source: ' + $sourceLayer + ').')
}
catch {
    $msg = $_.Exception.Message
    Write-Log ('PSES bootstrap FAILED: ' + $msg)
    # Clean up partial staging only -- NEVER the live bundle (non-destructive, 000024).
    foreach ($tmp in @($tmpZip, $extractRoot)) {
        try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
    }
    # Fail LOUD (000024, mirrors ensure-pssa.ps1 :111-114): a clear stderr line + non-zero exit
    # so the orchestration layer (session-start) can SURFACE the failure instead of swallowing a
    # silent, log-only miss. The one component without which nothing works must not fail quietly.
    [Console]::Error.WriteLine('ensure-pses: PSES bootstrap failed for ' + $PsesTag + ' (' + $msg + '); see ' + $log)
    exit 1
}
