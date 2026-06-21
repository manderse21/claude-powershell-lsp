#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pin resolved at build time against GitHub PowerShell/PowerShellEditorServices
# (latest stable release). Resolved 2026-06-01. Do not invent or hand-edit.
$PsesTag = 'v4.6.0'

$dataRoot = $env:CLAUDE_PLUGIN_DATA
if ([string]::IsNullOrWhiteSpace($dataRoot)) {
    # Hook env not present; nothing to do. Stay silent.
    return
}

$bundleDir = Join-Path $dataRoot 'PowerShellEditorServices'
$marker = Join-Path $dataRoot ('pses-' + $PsesTag + '.ok')
# The launcher (pses-stdio.ps1) starts this exact path; gate the no-op fast path on
# the start script actually being present, not just on the bundle directory existing.
$startScript = Join-Path $bundleDir 'PowerShellEditorServices/Start-EditorServices.ps1'

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
$backupDir = $bundleDir + '.old-' + $PsesTag
$url = 'https://github.com/PowerShell/PowerShellEditorServices/releases/download/' + $PsesTag + '/PowerShellEditorServices.zip'

try {
    Write-Log ('Bootstrapping PSES ' + $PsesTag)

    # NON-DESTRUCTIVE (000024): download + extract + VERIFY entirely in a temp staging area
    # FIRST. Do not touch the live $bundleDir until a verified-good module is in hand, so a
    # failed re-bootstrap (offline / proxy / corrupt zip) leaves the PRIOR working bundle
    # intact rather than deleting it before a single-attempt download (the old :34-35 hazard).
    if (Test-Path -LiteralPath $tmpZip) { Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing

    Expand-Archive -LiteralPath $tmpZip -DestinationPath $extractRoot -Force

    # Normalize the layout regardless of how the archive nests things. The PSES
    # release zip extracts to a top-level 'PowerShellEditorServices' folder that IS
    # the module itself -- Start-EditorServices.ps1 and PowerShellEditorServices.psd1
    # live directly inside it. We want that module to land at
    # $bundleDir/PowerShellEditorServices so that $bundleDir is a valid
    # -BundledModulesPath and the start script resolves at
    # $bundleDir/PowerShellEditorServices/Start-EditorServices.ps1. Locate the module
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
    # user is never left with NO bundle. ($bundleDir is absent only for the few local FS ops
    # between rename and move, and only after a verified download -- never on a network miss.)
    if (Test-Path -LiteralPath $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force }
    if (Test-Path -LiteralPath $bundleDir) { Rename-Item -LiteralPath $bundleDir -NewName (Split-Path -Leaf $backupDir) }
    try {
        New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null
        # MIT-notice preservation (dispatch 000029): the PSES release zip carries its MIT LICENSE +
        # NOTICE.txt at the distribution root (siblings of the PowerShellEditorServices module dir).
        # The module-only move below would drop them, leaving the installed bundle with NO upstream
        # notice -- an MIT violation ('included in all copies'). Capture that root BEFORE the move,
        # then copy the notices into the bundle root after. License-files only: ZERO runtime/behavior
        # change (the daemon reads the same module byte-for-byte); best-effort, so a missing or
        # uncopyable notice never aborts the install (the swap is already complete).
        $psesNoticeRoot = $startLeaf.Directory.Parent.FullName
        Move-Item -LiteralPath $startLeaf.Directory.FullName -Destination (Join-Path $bundleDir 'PowerShellEditorServices')
        foreach ($noticeName in @('LICENSE', 'NOTICE.txt')) {
            $noticeSrc = Join-Path $psesNoticeRoot $noticeName
            if (Test-Path -LiteralPath $noticeSrc -PathType Leaf) {
                Copy-Item -LiteralPath $noticeSrc -Destination (Join-Path $bundleDir $noticeName) -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        if (Test-Path -LiteralPath $bundleDir) { Remove-Item -LiteralPath $bundleDir -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backupDir) { Rename-Item -LiteralPath $backupDir -NewName (Split-Path -Leaf $bundleDir) }
        throw
    }
    if (Test-Path -LiteralPath $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue }

    Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue }

    New-Item -ItemType File -Force -Path $marker | Out-Null
    Write-Log 'PSES bootstrap complete.'
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
