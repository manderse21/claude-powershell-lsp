#Requires -Version 5.1
# RED CONTROL for dispatch 000282 leg C -- the PRIOR IMPLEMENTATION of the capture writer,
# verbatim, as it stood at the merge base 34a30f7cad875658191e8a2e39a04b938f99c783.
#
# WHAT IT IS FOR. P0-2 adds POWERSHELL_LSP_CAPTURE_MODE. The claim under test is that the MODE
# is what suppresses the offending source line -- not something else in the environment, and not
# a snippet that was never there to begin with. This file is the writer BEFORE the mode existed:
# run it with POWERSHELL_LSP_CAPTURE_MODE=metadata and it must still EMIT `snippet` and the
# absolute `file` path, because it has never heard of the variable. If it does not emit them,
# the shipped test proves nothing.
#
# IT IS THE PRIOR IMPLEMENTATION, NOT A HAND-WRITTEN MUTANT. The function body below was taken
# with `git show <merge-base>:scripts/lib/lsp-common.ps1` and sliced at the function boundary;
# nothing in it was retyped or adjusted.
#
# WHY ONLY THE FUNCTION, AND WHY THAT IS STILL FAITHFUL. The library it came from is 271,392
# bytes, and checking a copy of it in would leave a near-duplicate of the main library rotting
# beside it. Instead this fixture is dot-sourced AFTER the shipped library, so it OVERRIDES the
# one function under test and every helper it calls -- Get-DogfoodLogPath, Get-DiagnosticShapeHash,
# Get-DogfoodDir, New-ContainedDirectory, Set-ContainedFileMode -- resolves to the shipped copy.
# Those five are byte-identical between the merge base and this dispatch's tip, which the test
# that loads this file asserts rather than assumes, so the two runs differ in exactly one thing:
# the writer.
#
# RE-DERIVE THE BODY BELOW WITH:
#   git show 34a30f7cad875658191e8a2e39a04b938f99c783:scripts/lib/lsp-common.ps1 |
#     awk '/^function Add-DiagnosticCaptureEntries \{/,/^}/'

function Add-DiagnosticCaptureEntries {
    # Append one JSONL entry per SURFACED diagnostic occurrence to the dogfood log. STRICTLY
    # fail-safe and additive (see the section header): any failure is swallowed, nothing is
    # written to stdout, and the caller's surface + exit code are untouched. $Records are the
    # flat hashtables produced by New-CaptureRecordFrom*; the offending-line snippet and the
    # dedup hash are derived here so the two emit call sites stay thin. The verdict field is
    # written EMPTY, reserved for the later annotation pass.
    param([string]$File, [object[]]$Records)
    try {
        $recs = @($Records)
        if ($recs.Count -eq 0) { return }
        $logPath = Get-DogfoodLogPath
        if ([string]::IsNullOrWhiteSpace($logPath)) { return }
        $dir = Split-Path -Parent $logPath
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-ContainedDirectory -Path $dir
        }
        # Read the post-edit file ONCE for snippets; tolerate any read failure (snippet '').
        $lines = $null
        try { $lines = [System.IO.File]::ReadAllLines($File) } catch { $lines = $null }
        $ts = (Get-Date -Format 'o')
        $sb = New-Object System.Text.StringBuilder
        foreach ($r in $recs) {
            $lineNum = 0; try { $lineNum = [int]$r.line } catch { $lineNum = 0 }
            $colNum = 0; try { $colNum = [int]$r.col } catch { $colNum = 0 }
            $snippet = ''
            if ($null -ne $lines -and $lineNum -ge 1 -and $lineNum -le $lines.Count) {
                $snippet = [string]$lines[$lineNum - 1]
            }
            $ruleId = [string]$r.ruleId
            $entry = [ordered]@{
                ts       = $ts
                file     = [string]$File
                line     = $lineNum
                col      = $colNum
                ruleId   = $ruleId
                source   = [string]$r.source
                severity = [string]$r.severity
                message  = [string]$r.message
                snippet  = $snippet
                hash     = (Get-DiagnosticShapeHash -RuleId $ruleId -OffendingLine $snippet)
                verdict  = ''
            }
            [void]$sb.Append(($entry | ConvertTo-Json -Depth 5 -Compress))
            [void]$sb.Append("`n")
        }
        $enc = New-Object System.Text.UTF8Encoding($false)
        # Contain on the absent->present transition only -- see Write-StatsLine (000277 leg C).
        $bornHere = -not (Test-Path -LiteralPath $logPath)
        [System.IO.File]::AppendAllText($logPath, $sb.ToString(), $enc)
        if ($bornHere) { [void](Set-ContainedFileMode -Path $logPath) }
    } catch { }
}
