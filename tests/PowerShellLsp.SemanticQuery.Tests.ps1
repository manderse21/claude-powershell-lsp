#Requires -Version 5.1

# The first-party semantic query surface (dispatch 000287; ENTERPRISE-PROGRAM-DOCKET P1-2, review
# items 9 and 10).
#
# WHAT IS UNDER TEST. `scripts/lsp-query.ps1 <op> <file> <line> <col>` asks the warm daemon a
# POSITION question and the daemon forwards it to PSES as the LSP request PSES already serves. The
# one piece of real logic on that path is Get-QueryRequestPlan: it decides the method, builds the
# params, and -- the part that carries all the risk -- converts the 1-BASED position the wire
# carries into the 0-BASED position LSP requires.
#
# WHY THE POSITION BASE IS THE RISK. Every editor, every PowerShell stack trace and every
# diagnostics record this plugin emits is 1-based. LSP is 0-based. A forwarder that passes the
# position through unchanged returns a real, well-formed, confident answer about the PREVIOUS
# character -- which for a symbol at the start of a line is frequently the previous LINE. Nothing
# about the response looks wrong. The docket names exactly this mutant: "a mutant that returns the
# request unchanged must fail every assertion."
#
# RED CONTROL: Get-QueryRequestPlanPassThroughMutant, below, is the shipped function with the two
# subtractions removed -- the prior implementation in the only sense that matters here, since
# "forward it unchanged" is what this code replaces. It is asserted to FAIL the position assertions
# the shipped one passes, and the mutant is PROVED to have landed (its own plan is read back and
# shown to carry the un-converted numbers) before any conclusion is drawn from it.
#
# The daemon's functions are loaded by extracting their definitions from pses-daemon.ps1's AST and
# defining them here, so what runs is the SHIPPED text verbatim -- dot-sourcing the script itself
# would start a daemon. A test asserts the extraction found real functions rather than nothing.
#
# Run via tests/run-tests.ps1 (auto-discovered).

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:PluginRoot 'scripts'
    $script:DaemonPath = Join-Path $script:ScriptsDir 'pses-daemon.ps1'
    $script:QueryPath = Join-Path $script:ScriptsDir 'lsp-query.ps1'
    . (Join-Path $script:ScriptsDir 'lib/lsp-common.ps1')

    $script:DaemonAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:DaemonPath, [ref]$null, [ref]$null)

    function Get-DaemonFunctionText {
        param([string] $Name)
        $fn = $script:DaemonAst.Find({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq $Name }, $true)
        if ($null -eq $fn) { return '' }
        return [string]$fn.Extent.Text
    }

    $script:OpsText = Get-DaemonFunctionText -Name 'Get-QueryOps'
    $script:PlanText = Get-DaemonFunctionText -Name 'Get-QueryRequestPlan'
    . ([scriptblock]::Create($script:OpsText))
    . ([scriptblock]::Create($script:PlanText))

    # THE RED CONTROL. Identical to the shipped planner except that the position is forwarded
    # UNCHANGED -- 1-based numbers handed to a 0-based protocol. Built by textual substitution on
    # the shipped source so it cannot drift away from what it is a control for: if the shipped
    # line ever changes shape, the substitution finds nothing and the guard below fails loudly
    # rather than testing a mutant that no longer mutates anything.
    $script:MutantSourceAnchor = '$position = @{ line = ($Line - 1); character = ($Col - 1) }'
    $script:MutantSourceReplacement = '$position = @{ line = $Line; character = $Col }'
    $script:MutantAnchorCount = ([regex]::Matches(
            $script:PlanText, [regex]::Escape($script:MutantSourceAnchor))).Count
    $script:MutantText = $script:PlanText.
        Replace($script:MutantSourceAnchor, $script:MutantSourceReplacement).
        Replace('function Get-QueryRequestPlan', 'function Get-QueryRequestPlanPassThroughMutant')
    . ([scriptblock]::Create($script:MutantText))
}

Describe 'the extraction found real shipped functions (this file cannot pass vacuously)' {
    It 'pulled a non-empty body for both daemon functions' {
        $script:OpsText | Should -Not -BeNullOrEmpty
        $script:PlanText | Should -Not -BeNullOrEmpty
        $script:PlanText | Should -Match 'Get-QueryRequestPlan'
    }
    It 'the extracted text is present verbatim in the shipped daemon' {
        $src = [System.IO.File]::ReadAllText($script:DaemonPath)
        $src.Contains($script:OpsText) | Should -BeTrue
        $src.Contains($script:PlanText) | Should -BeTrue
    }
    It 'the mutant substitution had exactly one anchor to bite on' {
        # One, not "at least one": two anchors would mean the mutant changed something the control
        # was not designed to change, and zero would mean it changed nothing at all while still
        # defining a function that looks like a control.
        $script:MutantAnchorCount | Should -Be 1
        $script:MutantText | Should -Not -Be $script:PlanText
    }
}

Describe 'Get-QueryOps is the one op vocabulary' {
    It 'names the three operations the docket prices, and nothing it cannot serve' {
        @(Get-QueryOps) | Should -Be @('definition', 'references', 'hover')
    }
    It 'every op it names produces a plan' {
        foreach ($op in @(Get-QueryOps)) {
            (Get-QueryRequestPlan -Op $op -Uri 'file:///C:/x.ps1' -Line 1 -Col 1).ok |
                Should -BeTrue -Because ($op + ' is advertised, so it must plan')
        }
    }
}

Describe 'Get-QueryRequestPlan -- the method mapping' {
    It 'maps <Op> to <Method>' -TestCases @(
        @{ Op = 'definition'; Method = 'textDocument/definition' }
        @{ Op = 'references'; Method = 'textDocument/references' }
        @{ Op = 'hover'; Method = 'textDocument/hover' }
    ) {
        param($Op, $Method)
        $plan = Get-QueryRequestPlan -Op $Op -Uri 'file:///C:/x.ps1' -Line 4 -Col 9
        $plan.ok | Should -BeTrue
        $plan.method | Should -BeExactly $Method
    }

    It 'accepts an op in any case or padding, because a CLI argument arrives as typed' {
        (Get-QueryRequestPlan -Op '  Definition ' -Uri 'file:///C:/x.ps1' -Line 1 -Col 1).method |
            Should -BeExactly 'textDocument/definition'
    }

    It 'refuses an unknown op by NAME rather than guessing a nearby one' {
        $plan = Get-QueryRequestPlan -Op 'rename' -Uri 'file:///C:/x.ps1' -Line 1 -Col 1
        $plan.ok | Should -BeFalse
        $plan.error | Should -Match 'unknown query op: rename'
        # The message must name what IS available, or the caller has to read the source to recover.
        foreach ($op in @(Get-QueryOps)) { $plan.error.Contains($op) | Should -BeTrue }
    }

    It 'asks for the declaration too when asked where a symbol is used' {
        $plan = Get-QueryRequestPlan -Op 'references' -Uri 'file:///C:/x.ps1' -Line 1 -Col 1
        $plan.params.context.includeDeclaration | Should -BeTrue
    }

    It 'sends no references context on the ops that have none' {
        foreach ($op in @('definition', 'hover')) {
            $plan = Get-QueryRequestPlan -Op $op -Uri 'file:///C:/x.ps1' -Line 1 -Col 1
            $plan.params.ContainsKey('context') | Should -BeFalse
        }
    }
}

Describe 'Get-QueryRequestPlan -- the 1-based to 0-based conversion, which is the whole risk' {
    It 'converts <Line>:<Col> to LSP <ExpLine>:<ExpChar>' -TestCases @(
        @{ Line = 1; Col = 1; ExpLine = 0; ExpChar = 0 }
        @{ Line = 4; Col = 9; ExpLine = 3; ExpChar = 8 }
        @{ Line = 120; Col = 1; ExpLine = 119; ExpChar = 0 }
    ) {
        param($Line, $Col, $ExpLine, $ExpChar)
        $plan = Get-QueryRequestPlan -Op 'definition' -Uri 'file:///C:/x.ps1' -Line $Line -Col $Col
        $plan.ok | Should -BeTrue
        $plan.params.position.line | Should -Be $ExpLine
        $plan.params.position.character | Should -Be $ExpChar
    }

    It 'refuses a position below 1 rather than clamping it' {
        # Clamping would answer confidently about position 1 when the caller asked about something
        # it could not name -- a wrong answer dressed as a right one.
        (Get-QueryRequestPlan -Op 'definition' -Uri 'file:///C:/x.ps1' -Line 0 -Col 5).ok | Should -BeFalse
        (Get-QueryRequestPlan -Op 'definition' -Uri 'file:///C:/x.ps1' -Line 5 -Col 0).ok | Should -BeFalse
        (Get-QueryRequestPlan -Op 'definition' -Uri 'file:///C:/x.ps1' -Line -3 -Col 5).error |
            Should -Match 'line must be 1-based'
    }

    It 'refuses an empty uri' {
        (Get-QueryRequestPlan -Op 'definition' -Uri '' -Line 1 -Col 1).ok | Should -BeFalse
    }

    It 'carries the uri through verbatim, including a Windows drive letter' {
        $uri = 'file:///C:/Users/mande/x%20y.ps1'
        (Get-QueryRequestPlan -Op 'hover' -Uri $uri -Line 2 -Col 2).params.textDocument.uri |
            Should -BeExactly $uri
    }
}

Describe 'RED CONTROL -- the pass-through mutant is wrong, and is proved to have landed' {
    It 'the mutant really does forward the position unchanged (the mutant LANDED)' {
        # Assert the mutant IS mutated before concluding anything from it failing. A control that
        # silently did not apply reports the same green as a correct implementation.
        $m = Get-QueryRequestPlanPassThroughMutant -Op 'definition' -Uri 'file:///C:/x.ps1' -Line 4 -Col 9
        $m.ok | Should -BeTrue
        $m.params.position.line | Should -Be 4
        $m.params.position.character | Should -Be 9
    }

    It 'the mutant fails the assertion the shipped planner passes' {
        $shipped = Get-QueryRequestPlan -Op 'definition' -Uri 'file:///C:/x.ps1' -Line 4 -Col 9
        $mutant = Get-QueryRequestPlanPassThroughMutant -Op 'definition' -Uri 'file:///C:/x.ps1' -Line 4 -Col 9
        $shipped.params.position.line | Should -Be 3
        $mutant.params.position.line | Should -Not -Be $shipped.params.position.line
        $mutant.params.position.character | Should -Not -Be $shipped.params.position.character
    }

    It 'the mutant is wrong on EVERY op, not just the one it was demonstrated on' {
        # A control that only bites one arm leaves the others unguarded (banked: a red control must
        # mutate every arm of the check it controls).
        foreach ($op in @(Get-QueryOps)) {
            $shipped = Get-QueryRequestPlan -Op $op -Uri 'file:///C:/x.ps1' -Line 7 -Col 3
            $mutant = Get-QueryRequestPlanPassThroughMutant -Op $op -Uri 'file:///C:/x.ps1' -Line 7 -Col 3
            $mutant.params.position.line | Should -Not -Be $shipped.params.position.line -Because ('op ' + $op)
        }
    }
}

Describe 'the client entry point is a parameter surface, not a frozen-surface change' {
    It 'lsp-query.ps1 exists and parses' {
        Test-Path -LiteralPath $script:QueryPath | Should -BeTrue
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:QueryPath, [ref]$null, [ref]$errs) | Out-Null
        @($errs).Count | Should -Be 0
    }

    It 'adds no userConfig knob and no CONTRACT.md line' {
        # CONTRACT.md freezes exactly two enumerable surfaces. Confirmed against the manifest and
        # the contract itself rather than assumed, which is what the docket asked P1-3 to do too.
        $manifest = (Get-Content -LiteralPath (Join-Path $script:PluginRoot '.claude-plugin/plugin.json') -Raw) | ConvertFrom-Json
        @($manifest.userConfig.PSObject.Properties.Name) | Should -Not -Contain 'query'
        @($manifest.userConfig.PSObject.Properties.Name) | Should -Not -Contain 'queryOps'
        $contract = [System.IO.File]::ReadAllText((Join-Path $script:PluginRoot 'CONTRACT.md'))
        $contract | Should -Not -Match 'lsp-query'
    }

    It 'validates its op set against the same vocabulary the daemon serves' {
        # The ValidateSet on the client and Get-QueryOps in the daemon are two statements of one
        # fact and must not drift. The client is the copy, so it is the one checked against source.
        $src = [System.IO.File]::ReadAllText($script:QueryPath)
        foreach ($op in @(Get-QueryOps)) {
            $src.Contains("'" + $op + "'") | Should -BeTrue -Because ('the client must accept ' + $op)
        }
    }

    It 'sends the position it was given, performing no conversion of its own' {
        # Two conversions is one too many, and the second one is invisible. The client must hand
        # the daemon the numbers the caller typed.
        $src = [System.IO.File]::ReadAllText($script:QueryPath)
        $src | Should -Match 'line = \$Line; col = \$Col'
        $src | Should -Not -Match '\$Line - 1'
        $src | Should -Not -Match '\$Col - 1'
    }
}
