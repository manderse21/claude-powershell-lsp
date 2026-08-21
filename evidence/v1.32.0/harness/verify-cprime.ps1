#Requires -Version 5.1
# verify-cprime.ps1 -- the post-merge verification of the new release identity C'.
#
# Dispatch 000267 (freeze 1B). ASCII only.
#
# Mike's ruling, 2026-08-19: the carry-forward of the C-measured quantitative
# figures is GATED ON A PROOF, not an assertion. So this script reports the
# C -> C' diff FIRST, classifies it, and only then decides whether the figures
# carry. If ANY runtime file moved -- anything under scripts/, lib/, rulesets/ --
# the figures do NOT carry and the full cache-based suite must re-run against C'.

param(
    [Parameter(Mandatory)][string] $CPrime,
    [string] $C = 'af6996f971c8e8629a7d005e83f72865f2a66112',
    [string] $Repo = 'C:\Users\mande\projects\work\nortam\claude-powershell-lsp',
    [string] $Base = 'C:\Users\mande\AppData\Local\Temp\psl-267'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Out = Join-Path $Base 'out'

Write-Host '================ STEP 1: the C -> C'' diff, reported before anything is decided ================'
$stat = @(& git -C $Repo diff --stat "$C..$CPrime")
$stat | ForEach-Object { Write-Host ('  ' + $_) }
$paths = @(& git -C $Repo diff --name-only "$C..$CPrime")
Write-Host ''
Write-Host 'changed paths:'
$paths | ForEach-Object { Write-Host ('  ' + $_) }

# --- classify -----------------------------------------------------------------
$runtime = @($paths | Where-Object {
    $_ -like 'scripts/*' -or $_ -like 'lib/*' -or $_ -like 'rulesets/*' -or $_ -like '*.psd1'
})
$docs = @($paths | Where-Object { $_ -like '*.md' })
$workflow = @($paths | Where-Object { $_ -like '.github/workflows/*' })
$other = @($paths | Where-Object {
    -not ($_ -like '*.md') -and -not ($_ -like '.github/workflows/*')
})

Write-Host ''
Write-Host ('  docs (.md)          : ' + $docs.Count + '  ' + ($docs -join ', '))
Write-Host ('  workflow YAML       : ' + $workflow.Count + '  ' + ($workflow -join ', '))
Write-Host ('  RUNTIME (scripts/lib/rulesets/psd1): ' + $runtime.Count + '  ' + ($runtime -join ', '))
Write-Host ('  other               : ' + $other.Count + '  ' + ($other -join ', '))

$carryForward = ($runtime.Count -eq 0 -and $other.Count -eq 0 -and $paths.Count -gt 0)
Write-Host ''
if ($carryForward) {
    Write-Host 'VERDICT: the C->C'' change set touches NO runtime file. The cache-based'
    Write-Host '         quantitative figures measured at C CARRY FORWARD to C'' because the'
    Write-Host '         runtime is byte-identical -- evidenced by the diff above.'
} else {
    Write-Host 'VERDICT: a RUNTIME file moved between C and C''. The C-measured figures DO NOT'
    Write-Host '         carry. The full cache-based quantitative suite must re-run against C''.'
}

# Prove the runtime claim directly, not only by path classification: every tracked
# path that is NOT one of the changed paths must have the SAME blob id at both commits.
$cTree = @{}
foreach ($l in @(& git -C $Repo ls-tree -r $C)) {
    $t = $l.IndexOf("`t"); if ($t -lt 0) { continue }
    $cTree[$l.Substring($t + 1)] = ($l.Substring(0, $t) -split '\s+')[2]
}
$pTree = @{}
foreach ($l in @(& git -C $Repo ls-tree -r $CPrime)) {
    $t = $l.IndexOf("`t"); if ($t -lt 0) { continue }
    $pTree[$l.Substring($t + 1)] = ($l.Substring(0, $t) -split '\s+')[2]
}
$runtimePaths = @($pTree.Keys | Where-Object { $_ -like 'scripts/*' -or $_ -like 'rulesets/*' })
$toolPaths = @($pTree.Keys | Where-Object { $_ -like 'release/*' -or $_ -like 'hooks/*' -or $_ -like '.claude-plugin/*' })
$toolMoved = @($toolPaths | Where-Object { -not $cTree.ContainsKey($_) -or $cTree[$_] -cne $pTree[$_] })
Write-Host ('  release/ + hooks/ + .claude-plugin/ blob check: ' + $toolPaths.Count + ' paths; ' + $toolMoved.Count + ' differ from C')
$runtimeMoved = @($runtimePaths | Where-Object { -not $cTree.ContainsKey($_) -or $cTree[$_] -cne $pTree[$_] })
Write-Host ''
Write-Host ('  runtime blob check: ' + $runtimePaths.Count + ' tracked runtime paths at C''; ' +
            $runtimeMoved.Count + ' differ from C')
# Floor DERIVED, not guessed: C' tracks 31 paths under scripts/ (scripts/lib/
# included) and 5 under rulesets/ = 36. 30 is a floor beneath that, so an
# enumeration that collapses surfaces instead of passing vacuously.
if ($runtimePaths.Count -lt 30) { throw ('payload floor: only ' + $runtimePaths.Count + ' runtime paths found -- the check is not looking at the real tree') }
if ($runtimeMoved.Count -gt 0) { Write-Host ('  MOVED: ' + ($runtimeMoved -join ', ')) }

$result = [ordered]@{
    c = $C; c_prime = $CPrime
    diff_stat = $stat
    changed_paths = $paths
    docs = $docs; workflow = $workflow; runtime = $runtime; other = $other
    runtime_paths_at_cprime = $runtimePaths.Count
    runtime_paths_differing_from_c = $runtimeMoved.Count
    runtime_identical = ($runtimeMoved.Count -eq 0)
    carry_forward_quantitative = ($carryForward -and $runtimeMoved.Count -eq 0)
}

Write-Host ''
Write-Host '================ STEP 2: re-stage C'' and re-prove the script tree ================'
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Base 'bin/stage-c.ps1') -Commit $CPrime
if ($LASTEXITCODE -ne 0) { throw 'staging C-prime failed' }
& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Base 'bin/prove-equals-c.ps1') `
    -Commit $CPrime -Label "C-prime freeze" -JsonOut (Join-Path $Out 'equality-cprime.json') -RedControl
if ($LASTEXITCODE -ne 0) { throw 'the C-prime equality proof FAILED' }
$result['equality_proof_at_cprime'] = 'PASS'

($result | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $Out 'cprime-verify.json') -Encoding UTF8
Write-Host ''
Write-Host ('C-PRIME VERIFY (steps 1-2) DONE. carry_forward_quantitative=' + $result['carry_forward_quantitative'])
