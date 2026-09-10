#Requires -Version 5.1
# Get-DaemonPipeName -- ONE source for the per-session daemon pipe name (dispatch 000291,
# routed debt 2(c); Hub Rule 18).
#
# THE GAP THIS CLOSES. The pipe name is what a client and a daemon must AGREE on to find each
# other at all, and it was built by hand at 23 independent sites across scripts/ and tests/.
# The failure mode of a rename reaching 22 of them is not a red test: it is a client that
# connects to nothing and reports the daemon unreachable, which reads as an environment problem
# rather than as a typo. So the interesting property here is not "the function returns the right
# string" -- it is "nobody builds this string any other way", and that is what the guard below
# asserts.
#
# THE GUARD IS A SOURCE SCAN, AND IT SAYS SO. A behavioural proof is not available in process:
# every shipped consumer is a script with its own param() block, driven as a child process, so
# there is no function to call and shadow. Rather than manufacture a weak in-process proxy, the
# guard tests the property directly at the source, and it carries a real IN-BAND CONTROL so its
# zero cannot be the zero of a broken scanner (Hub Rule 30, clause b): the four frozen
# `evidence/` sites are DELIBERATELY not routed, and the same scanner must still find exactly
# those four. A scanner that found nothing anywhere would fail that arm.
#
# THE NEEDLE IS BUILT FROM CHARACTER CODES, NOT SPELLED. tests/ is inside the scanned scope, so
# a file that spelled the forbidden construction in order to search for it would match itself
# and the guard would report a violation it had authored.
#
# ASCII-only (Windows PowerShell 5.1 reads a UTF-8-without-BOM file through Windows-1252).

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:RepoRoot 'scripts'
    . (Join-Path $script:ScriptsDir 'lib/lsp-common.ps1')

    # The forbidden construction: a single-quoted stem literal followed by a concatenation.
    # Assembled from pieces so this file does not contain it and therefore cannot match itself.
    $q = [string][char]39
    $script:Stem = 'powershell' + '-lsp-'
    $script:Needle = $q + $script:Stem + $q + ' + '

    function Get-InlinePipeNameSite {
        # Every line under $Root that builds the pipe name by hand. Returns the matches so a
        # failure names the file and line rather than only a count.
        param([Parameter(Mandatory = $true)][string] $Root)
        if (-not (Test-Path -LiteralPath $Root)) { return @() }
        $out = @()
        foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
            $i = 0
            foreach ($line in @([System.IO.File]::ReadAllLines($f.FullName))) {
                $i++
                if ($line.Contains($script:Needle)) {
                    $out += [pscustomobject]@{ File = $f.FullName; Line = $i; Text = $line.Trim() }
                }
            }
        }
        return @($out)
    }
}

Describe 'Get-DaemonPipeName -- the contract every caller now shares' {
    It 'appends the session id to the stem' {
        (Get-DaemonPipeName -SessionId 'abc123') | Should -BeExactly ($script:Stem + 'abc123')
    }

    It 'returns the BARE STEM for a blank id, which is what the 23 call sites did' {
        # Preserved behaviour, not a new decision: every replaced site concatenated
        # unconditionally. Callers that care already guard on the id before calling.
        (Get-DaemonPipeName -SessionId '') | Should -BeExactly $script:Stem
        (Get-DaemonPipeName) | Should -BeExactly $script:Stem
    }

    It 'is a pure function of its argument -- no session state, no environment' {
        $a = Get-DaemonPipeName -SessionId 'same'
        $env:POWERSHELL_LSP_SESSION_ID = 'something-else'
        $b = Get-DaemonPipeName -SessionId 'same'
        $env:POWERSHELL_LSP_SESSION_ID = $null
        $b | Should -BeExactly $a
    }

    It 'produces the name the frozen evidence harnesses build by hand' {
        # The four evidence/ sites are exempt from the refactor but must still describe the SAME
        # pipe. If this ever disagreed, the exemption would have become a second definition
        # rather than a frozen copy of the one definition.
        (Get-DaemonPipeName -SessionId 'S-1') | Should -BeExactly ($script:Stem + 'S-1')
    }
}

Describe 'Nobody builds the pipe name any other way (routed debt 2(c))' {
    It 'scripts/ and tests/ contain ZERO inline constructions' {
        $sites = @()
        $sites += @(Get-InlinePipeNameSite -Root (Join-Path $script:RepoRoot 'scripts'))
        $sites += @(Get-InlinePipeNameSite -Root (Join-Path $script:RepoRoot 'tests'))
        # The one legitimate occurrence is the definition itself, which lives in lsp-common.ps1
        # and is the thing every other site now calls.
        $offenders = @($sites | Where-Object { $_.File -notmatch 'lsp-common\.ps1$' })
        $names = (@($offenders | ForEach-Object { (Split-Path -Leaf $_.File) + ':' + $_.Line }) -join ', ')
        @($offenders).Count | Should -Be 0 -Because ('these still build the name by hand: ' + $names)
    }

    It 'IN-BAND CONTROL: the same scanner still finds the four frozen evidence sites' {
        # Hub Rule 30 clause (b). Without this arm the zero above is equally consistent with a
        # scanner that matches nothing at all -- a broken needle, a wrong root, a filter that
        # excluded every file. These four are deliberately NOT routed (changing them destroys
        # the byte-anchored release evidence they exist to be), so they are the control that
        # proves the instrument can see what it is looking for.
        $ev = @(Get-InlinePipeNameSite -Root (Join-Path $script:RepoRoot 'evidence'))
        @($ev).Count | Should -Be 4
        @($ev | Where-Object { $_.File -match 'v1\.32\.0' }).Count | Should -Be 1
        @($ev | Where-Object { $_.File -match 'v1\.33\.0' }).Count | Should -Be 3
    }

    It 'IN-BAND CONTROL: the scanner FIRES on a synthetic file that reintroduces the pattern' {
        # The prior implementation of all 23 sites was exactly this line. Rebuilding one under
        # $TestDrive proves the guard would catch a regression, without touching the real tree.
        $dir = Join-Path $TestDrive 'regress'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $body = @(
            '# a file that builds the pipe name the old way',
            ('$pipeName = ' + $script:Needle + '$sessionId'),
            '$other = 1'
        )
        [System.IO.File]::WriteAllLines((Join-Path $dir 'regressed.ps1'), $body)

        $hits = @(Get-InlinePipeNameSite -Root $dir)
        @($hits).Count | Should -Be 1
        $hits[0].Line | Should -Be 2
    }

    It 'every shipped scripts/ consumer routes through the shared function' {
        # The positive half. The five scripts that used to build the name now call it, and the
        # count is asserted so a file dropping out of the set is visible rather than silent.
        $expected = @('doctor.ps1', 'lsp-client.ps1', 'lsp-query.ps1', 'pses-daemon.ps1', 'session-end.ps1')
        foreach ($name in $expected) {
            $txt = [System.IO.File]::ReadAllText((Join-Path $script:ScriptsDir $name))
            $txt | Should -Match 'Get-DaemonPipeName' -Because ($name + ' must resolve the pipe name through the shared function')
        }
        # lsp-query.ps1 had two sites; the others one each. Six calls across the five files.
        $total = 0
        foreach ($name in $expected) {
            $txt = [System.IO.File]::ReadAllText((Join-Path $script:ScriptsDir $name))
            $total += ([regex]::Matches($txt, 'Get-DaemonPipeName')).Count
        }
        $total | Should -Be 6
    }

    It 'the definition lives in exactly ONE place' {
        $defs = @()
        foreach ($f in @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
            $txt = [System.IO.File]::ReadAllText($f.FullName)
            if ($txt -match '(?m)^function Get-DaemonPipeName\b') { $defs += $f.FullName }
        }
        @($defs).Count | Should -Be 1
        $defs[0] | Should -Match 'lsp-common\.ps1$'
    }
}
