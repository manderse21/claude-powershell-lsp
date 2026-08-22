#Requires -Version 5.1
# replay-checks.ps1 -- run each recorded custom_check EXACTLY as the outbox records it.
#
# The commands are parsed OUT OF THE OUTBOX rather than retyped, so what runs is what
# is claimed. Each check runs in its OWN pwsh process, because a check that only passes
# because a previous check left a variable behind is not a check.

param(
    [string] $Outbox = 'C:\Users\mande\projects\work\nortam\strategic-dispatch\worktrees\s000273-freeze\projects\powershell-lsp\outbox\000273-freeze-1b-at-c-6ab2d24-v1-33-0-measured-against-the-ratified.md'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lines = [IO.File]::ReadAllLines($Outbox)
$checks = @()
$i = 0
while ($i -lt $lines.Count) {
    if ($lines[$i] -match '^    - name: "(.+)"$') {
        $name = $Matches[1]
        $expect = 0
        # walk to this entry's folded command block
        $j = $i + 1
        $cmd = $null
        while ($j -lt $lines.Count -and $lines[$j] -notmatch '^    - name: ' -and $lines[$j] -notmatch '^deviations:') {
            if ($lines[$j] -match '^      command: >-\s*$') {
                $buf = @()
                $k = $j + 1
                while ($k -lt $lines.Count -and $lines[$k] -match '^        (.*)$') {
                    $buf += $Matches[1]
                    $k++
                }
                # A folded scalar joins its lines with a single space.
                $cmd = ($buf -join ' ')
                $j = $k
                continue
            }
            if ($lines[$j] -match '^      expect_exit: (\d+)$') { $expect = [int]$Matches[1] }
            $j++
        }
        if ($cmd) { $checks += [pscustomobject]@{ name = $name; command = $cmd; expect = $expect } }
        $i = $j
        continue
    }
    $i++
}

Write-Output ('parsed ' + $checks.Count + ' custom_checks from the outbox')
if ($checks.Count -lt 6) { throw ('parser floor: expected at least 6 checks, parsed ' + $checks.Count) }

$fail = 0
foreach ($c in $checks) {
    Write-Output ''
    Write-Output ('--- ' + $c.name)
    $tmp = [IO.Path]::GetTempFileName() + '.ps1'
    [IO.File]::WriteAllText($tmp, $c.command, (New-Object Text.UTF8Encoding($false)))
    try {
        $out = & pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tmp 2>&1
        $rc = $LASTEXITCODE
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    $verdict = $(if ($rc -eq $c.expect) { 'MATCH' } else { 'MISMATCH' })
    if ($rc -ne $c.expect) { $fail++ }
    Write-Output ('    exit=' + $rc + ' expect=' + $c.expect + '  ' + $verdict)
    foreach ($l in @($out)) { Write-Output ('    | ' + $l) }
}

Write-Output ''
Write-Output ('REPLAY: ' + ($checks.Count - $fail) + ' of ' + $checks.Count + ' MATCH')
if ($fail -gt 0) { throw ($fail.ToString() + ' recorded check(s) did not reproduce') }
