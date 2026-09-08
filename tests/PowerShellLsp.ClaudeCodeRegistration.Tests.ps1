#Requires -Version 5.1

# The Claude Code registration assertion (dispatch 000287; ENTERPRISE-PROGRAM-DOCKET P1-3, review
# item 4, registration half; ruling R-G = Advisory).
#
# WHAT IS UNDER TEST. tests/assert-claude-code-registration.ps1 reads the text a real Claude Code
# client printed for `claude plugin details powershell-lsp` and asserts that THAT CLIENT registered
# this plugin's components. The fixture under tests/fixtures/claude-code/ is a real capture from
# claude 2.1.263, not a hand-written imitation, so the assertion is tested against the shape it
# will actually meet.
#
# WHY THIS FILE EXISTS AT ALL. The CI leg that runs the script is ADVISORY (R-G), and an advisory
# leg is exactly the kind that rots unnoticed. These tests run on every leg, required ones
# included, so the assertion's own correctness is not advisory even though its client leg is.
#
# RED CONTROLS, three, each built by substitution on the REAL capture so it cannot drift away from
# what it controls, and each proved to have LANDED before any conclusion is drawn from it:
#
#   1. the PostToolUse hook removed -- the product's own hook, the single most consequential
#      registration failure, and the one a passing-looking inventory would hide.
#   2. a command removed -- proves the derived command set is doing work rather than decorating.
#   3. an error banner instead of an inventory -- the vacuity case. Every assertion in the script
#      is a substring test, and substring tests pass trivially over a short string; this must exit
#      3 rather than reporting that nothing was missing from nothing.
#
# Run via tests/run-tests.ps1 (auto-discovered).

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot
    $script:Script = Join-Path $PSScriptRoot 'assert-claude-code-registration.ps1'
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures/claude-code/details-registered.txt'
    $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('psls-ccreg-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    function Invoke-Assert {
        # REDIRECT TO FILES, never `2>&1` into the pipeline. Windows PowerShell 5.1 converts a
        # child process's stderr into ErrorRecords, and Pester runs an `It` with
        # $ErrorActionPreference = 'Stop', so the first stderr line THROWS -- the assertion never
        # reaches $LASTEXITCODE and the failure is reported as a RemoteException carrying the
        # script's own usage message. PowerShell 7 does not do that, so a pwsh-only run cannot
        # see it: this was caught by the windows-powershell CI leg and by nothing else.
        #
        # Start-Process with -RedirectStandardError writes the stream to a file instead of into a
        # host that has an opinion about it, and -PassThru gives the real ExitCode rather than a
        # $LASTEXITCODE that a thrown record would have skipped.
        param([string] $Path)
        $exe = (Get-Process -Id $PID).Path
        $so = Join-Path $script:TempDir ([guid]::NewGuid().ToString('N') + '.out')
        $se = Join-Path $script:TempDir ([guid]::NewGuid().ToString('N') + '.err')
        $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $script:Script, '-DetailsOutput', $Path, '-PluginRoot', $script:PluginRoot)
        $p = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $so -RedirectStandardError $se
        $text = ''
        foreach ($f in @($so, $se)) {
            if (Test-Path -LiteralPath $f) { $text += [System.IO.File]::ReadAllText($f) }
        }
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $text }
    }

    function New-MutantCapture {
        param([string] $Name, [string] $Remove)
        $text = [System.IO.File]::ReadAllText($script:Fixture)
        $lines = @($text -split "`n")
        $kept = @($lines | Where-Object { $_ -notmatch [regex]::Escape($Remove) })
        $path = Join-Path $script:TempDir ($Name + '.txt')
        [System.IO.File]::WriteAllText($path, ($kept -join "`n"))
        return $path
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:TempDir) { Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'the fixture is a real client capture, not an imitation (this file cannot pass vacuously)' {
    It 'exists and carries a component inventory' {
        Test-Path -LiteralPath $script:Fixture | Should -BeTrue
        $text = [System.IO.File]::ReadAllText($script:Fixture)
        $text.Length | Should -BeGreaterThan 200
        $text.Contains('Component inventory') | Should -BeTrue
        $text.Contains('powershell-lsp') | Should -BeTrue
    }
    It 'the script under test exists and parses' {
        Test-Path -LiteralPath $script:Script | Should -BeTrue
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$errs) | Out-Null
        @($errs).Count | Should -Be 0
    }
}

Describe 'a real client capture PASSES' {
    It 'exits 0 and names every component it checked' {
        $r = Invoke-Assert -Path $script:Fixture
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'registration PASSED'
    }

    It 'derives the expected command set from commands/ rather than from a list in the script' {
        # The derivation is the anti-sample guard. Assert it reported a set the size of the
        # directory, so a script that silently derived nothing cannot report a clean pass.
        $onDisk = @(Get-ChildItem -LiteralPath (Join-Path $script:PluginRoot 'commands') -Filter '*.md' -File).Count
        $onDisk | Should -BeGreaterThan 0
        $r = Invoke-Assert -Path $script:Fixture
        $r.Output | Should -Match ('derived ' + $onDisk + ' expected command')
    }
}

Describe 'RED CONTROL 1 -- PostToolUse dropped from a Hooks line that is otherwise intact' {
    # Surgical on purpose. Deleting the whole `Hooks (` line would exercise the missing-LINE
    # branch, which is a different and easier failure; the interesting mutant is the one where the
    # inventory still looks entirely normal and one hook -- the product's own -- is simply not in
    # it. That is the registration failure a passing-looking inventory would hide.
    BeforeAll {
        $script:HookMutant = Join-Path $script:TempDir 'hooks-minus-posttooluse.txt'
        $t = [System.IO.File]::ReadAllText($script:Fixture)
        $out = @()
        foreach ($ln in @($t -split "`n")) {
            if ($ln.Trim().StartsWith('Hooks (')) {
                $out += ($ln -replace 'PostToolUse, ', '' -replace ', PostToolUse', '')
            } else { $out += $ln }
        }
        [System.IO.File]::WriteAllText($script:HookMutant, ($out -join "`n"))
    }

    It 'the mutant landed: the Hooks line survives, PostToolUse does not' {
        $t = [System.IO.File]::ReadAllText($script:HookMutant)
        $t.Contains('Hooks (') | Should -BeTrue -Because 'the line must survive, or this is the wrong mutant'
        $t.Contains('SessionStart') | Should -BeTrue
        $t.Contains('SessionEnd') | Should -BeTrue
        $t.Contains('PostToolUse') | Should -BeFalse
        $t.Contains('Component inventory') | Should -BeTrue
    }

    It 'fails, and names the hook rather than failing generically' {
        $r = Invoke-Assert -Path $script:HookMutant
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'did not enumerate .PostToolUse.'
    }

    It 'and the whole Hooks line missing is caught too, by its own branch' {
        $p = New-MutantCapture -Name 'no-hooks-line' -Remove 'Hooks ('
        $r = Invoke-Assert -Path $p
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'no "Hooks \(" line'
    }
}

Describe 'RED CONTROL 2 -- a command removed' {
    It 'the mutant really lost the command line (the mutant LANDED)' {
        $p = New-MutantCapture -Name 'no-skills' -Remove 'Skills ('
        ([System.IO.File]::ReadAllText($p)).Contains('Skills (') | Should -BeFalse
        ([System.IO.File]::ReadAllText($p)).Contains('Component inventory') | Should -BeTrue
    }
    It 'fails, and this is the control that caught a real defect' {
        # WHAT THIS CONTROL FOUND. The first version of the assertion searched the WHOLE capture
        # for each command name, and this mutant PASSED it -- because the "Per-component"
        # token-cost table further down the same output lists every command name again. The
        # assertion was green over an inventory that enumerated no commands at all. The script now
        # anchors each check to its own inventory line, and this control fails as it must.
        $p = New-MutantCapture -Name 'no-skills' -Remove 'Skills ('
        $r = Invoke-Assert -Path $p
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'no "Skills \(" line'
    }

    It 'the names DO still appear elsewhere in the mutant -- which is why a whole-file search was wrong' {
        # Proves the control is controlling for the real defect rather than for an easier one.
        $p = New-MutantCapture -Name 'no-skills' -Remove 'Skills ('
        $t = [System.IO.File]::ReadAllText($p)
        $t.Contains('Skills (') | Should -BeFalse
        $t.Contains('doctor') | Should -BeTrue -Because 'the cost table still names it'
        $t.Contains('query') | Should -BeTrue -Because 'the cost table still names it'
    }
}

Describe 'RED CONTROL 3 -- an error banner instead of an inventory (the vacuity case)' {
    It 'exits 3 rather than reporting that nothing was missing from nothing' {
        $p = Join-Path $script:TempDir 'banner.txt'
        [System.IO.File]::WriteAllText($p, "Error: unknown plugin 'powershell-lsp'`n")
        $r = Invoke-Assert -Path $p
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Match 'no "Component inventory" section'
    }
    It 'exits 3 on an empty capture too' {
        $p = Join-Path $script:TempDir 'empty.txt'
        [System.IO.File]::WriteAllText($p, '')
        (Invoke-Assert -Path $p).ExitCode | Should -Be 3
    }
    It 'exits 3 when the capture file does not exist at all' {
        (Invoke-Assert -Path (Join-Path $script:TempDir 'nope.txt')).ExitCode | Should -Be 3
    }
}

Describe 'the leg is ADVISORY in the workflow, which is a ruling and not a preference' {
    It 'the claude-code-compat job carries continue-on-error and its own name' {
        $wf = [System.IO.File]::ReadAllText((Join-Path $script:PluginRoot '.github/workflows/powershell-lsp-ci.yml'))
        $wf.Contains('claude-code-compat:') | Should -BeTrue
        $wf.Contains('name: claude-code-compat') | Should -BeTrue
        $wf | Should -Match 'continue-on-error: true'
    }

    It 'the five existing leg identities are untouched, and the pester job is still matrix-named' {
        # The 000286 trap, asserted rather than remembered: adding a dimension to the pester job
        # re-keys the four legs it covers and silently removes required checks.
        $wf = [System.IO.File]::ReadAllText((Join-Path $script:PluginRoot '.github/workflows/powershell-lsp-ci.yml'))
        $wf.Contains('name: ${{ matrix.label }}') | Should -BeTrue
        foreach ($leg in @('windows-pwsh', 'windows-powershell', 'ubuntu-pwsh', 'macos-pwsh')) {
            $wf.Contains($leg) | Should -BeTrue -Because ($leg + ' must still be named in the matrix')
        }
        $wf.Contains('container-pwsh:') | Should -BeTrue
    }

    It 'pins exact client versions rather than a dist-tag, and the runner script refuses one' {
        $wf = [System.IO.File]::ReadAllText((Join-Path $script:PluginRoot '.github/workflows/powershell-lsp-ci.yml'))
        $wf | Should -Match "CLAUDE_CODE_VERSION: '2\.1\.\d+'"
        $sh = [System.IO.File]::ReadAllText((Join-Path $script:PluginRoot '.github/scripts/claude-code-compat.sh'))
        $sh.Contains('refusing to run against a dist-tag') | Should -BeTrue
        # and it verifies the client it actually got, so a compatibility claim is never attributed
        # to a version that was not the one exercised
        $sh.Contains('refusing to attribute this run to that version') | Should -BeTrue
    }

    It 'invokes the runner in a way the Windows executable bit cannot break' {
        # The leg's FIRST run failed with exit 126 -- "command found, not executable" -- before a
        # line of the script ran, because this repository is authored on Windows where the exec
        # bit is not a filesystem property and the file reached git as mode 100644. Invoking
        # through bash makes the mode irrelevant; this asserts the invocation rather than the mode,
        # because the mode is the thing that can silently regress.
        $wf = [System.IO.File]::ReadAllText((Join-Path $script:PluginRoot '.github/workflows/powershell-lsp-ci.yml'))
        ([regex]::Matches($wf, 'run: bash \./\.github/scripts/claude-code-compat\.sh')).Count |
            Should -Be 2 -Because 'both client steps must be mode-independent'
        $wf | Should -Not -Match 'run: \./\.github/scripts/claude-code-compat\.sh'
    }

    It 'writes no claudeCodeCompatibility declaration -- the matrix has not earned one' {
        # The docket requires the declaration be written from what the matrix PROVED, and this leg
        # proves registration only. docs/SUPPORT-POLICY.md refuses to declare an untested floor.
        $manifest = (Get-Content -LiteralPath (Join-Path $script:PluginRoot '.claude-plugin/plugin.json') -Raw) | ConvertFrom-Json
        @($manifest.PSObject.Properties.Name) | Should -Not -Contain 'claudeCodeCompatibility'
        $policy = [System.IO.File]::ReadAllText((Join-Path $script:PluginRoot 'docs/SUPPORT-POLICY.md'))
        $policy.Contains('No minimum or maximum Claude Code version is declared') | Should -BeTrue
    }
}
