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

    # Every function on the planning path, extracted from the SHIPPED daemon text. Get-QueryOps
    # and the planner both read Get-QueryOpSpec now, so loading the pair alone would leave the
    # vocabulary undefined and the file would fail loudly rather than test a stale copy.
    $script:SpecText = Get-DaemonFunctionText -Name 'Get-QueryOpSpec'
    $script:OpsText = Get-DaemonFunctionText -Name 'Get-QueryOps'
    $script:ResolveText = Get-DaemonFunctionText -Name 'Resolve-QueryOp'
    $script:UnknownText = Get-DaemonFunctionText -Name 'Get-UnknownQueryOpError'
    $script:PlanText = Get-DaemonFunctionText -Name 'Get-QueryRequestPlan'
    foreach ($t in @($script:SpecText, $script:OpsText, $script:ResolveText,
            $script:UnknownText, $script:PlanText)) {
        . ([scriptblock]::Create($t))
    }

    # What each KIND needs from a caller, so a test can ask for a plan for ANY op without a
    # hard-coded list of which op wants what. Derived from the spec: a sixth op added to the
    # daemon with a new kind lands here as an unsupplied kind and fails loudly.
    function Get-PlanForOp {
        param([string] $Op, [int] $Line = 4, [int] $Col = 9, [string] $Uri = 'file:///C:/x.ps1',
            [string] $Query = 'Get-Thing')
        return (Get-QueryRequestPlan -Op $Op -Uri $Uri -Line $Line -Col $Col -Query $Query)
    }

    function Get-OpsOfKind {
        param([string] $Kind)
        $spec = Get-QueryOpSpec
        $out = @()
        foreach ($k in $spec.Keys) { if ([string]$spec[$k].kind -eq $Kind) { $out += [string]$k } }
        # Leading-comma return would nest under @() at the call site (Hub Rule 37); an explicit
        # array variable returns the same set without that trap.
        return $out
    }

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

    # THE SECOND RED CONTROL, for the two arms the pass-through mutant cannot reach. Before the
    # symbol ops existed this planner had exactly ONE arm: every op was a position query. That is
    # the PRIOR IMPLEMENTATION, and forcing documentSymbol and workspaceSymbol down it is the
    # named defect -- "do not invent a fake position for an op that has none". The mutant pins
    # the kind to 'position' for every op, which is that prior shape exactly.
    $script:UniformAnchor = '$kind = [string]$spec[$opNorm].kind'
    $script:UniformReplacement = "`$kind = 'position'"
    $script:UniformAnchorCount = ([regex]::Matches(
            $script:PlanText, [regex]::Escape($script:UniformAnchor))).Count
    $script:UniformText = $script:PlanText.
        Replace($script:UniformAnchor, $script:UniformReplacement).
        Replace('function Get-QueryRequestPlan', 'function Get-QueryRequestPlanUniformPositionMutant')
    . ([scriptblock]::Create($script:UniformText))
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
    It 'the uniform-position mutant substitution had exactly one anchor to bite on' {
        $script:UniformAnchorCount | Should -Be 1
        $script:UniformText | Should -Not -Be $script:PlanText
    }
    It 'pulled a non-empty body for every function on the planning path' {
        foreach ($t in @($script:SpecText, $script:OpsText, $script:ResolveText,
                $script:UnknownText, $script:PlanText)) {
            $t | Should -Not -BeNullOrEmpty
        }
        $src = [System.IO.File]::ReadAllText($script:DaemonPath)
        foreach ($t in @($script:SpecText, $script:ResolveText, $script:UnknownText)) {
            $src.Contains($t) | Should -BeTrue
        }
    }
}

Describe 'Get-QueryOps is the one op vocabulary' {
    It 'names the five operations the docket prices, and nothing it cannot serve' {
        @(Get-QueryOps) | Should -Be @('definition', 'references', 'hover',
            'documentSymbol', 'workspaceSymbol')
    }
    It 'derives its list from the spec rather than restating it' {
        # Two statements of one vocabulary is how an advertisement and a behaviour drift
        # (Hub Rule 18). This asserts they are the same statement, by value and by order.
        (@(Get-QueryOps) -join ',') | Should -BeExactly (@((Get-QueryOpSpec).Keys) -join ',')
    }
    It 'every op it names produces a plan when given what its kind requires' {
        foreach ($op in @(Get-QueryOps)) {
            (Get-PlanForOp -Op $op).ok |
                Should -BeTrue -Because ($op + ' is advertised, so it must plan')
        }
    }
}

Describe 'the op kinds PARTITION the vocabulary -- derived, never a hard-coded list' {
    # 000287 shipped a census that was a hard-coded list of three over a tree holding six sites.
    # These assertions derive the sets from the spec and then assert the partition, so an op
    # added without a kind, or with a kind nothing handles, fails here rather than shipping.
    It 'every advertised op carries exactly one kind and one method, both non-empty' {
        $spec = Get-QueryOpSpec
        @($spec.Keys).Count | Should -Be @(Get-QueryOps).Count
        foreach ($k in $spec.Keys) {
            [string]$spec[$k].kind | Should -Not -BeNullOrEmpty -Because ($k + ' needs a kind')
            [string]$spec[$k].method | Should -Not -BeNullOrEmpty -Because ($k + ' needs a method')
        }
    }
    It 'the kinds present are exactly the three the planner has arms for' {
        $spec = Get-QueryOpSpec
        $kinds = @()
        foreach ($k in $spec.Keys) { $kinds += [string]$spec[$k].kind }
        (@($kinds | Sort-Object -Unique) -join ',') | Should -BeExactly 'document,position,query'
    }
    It 'the three kinds partition the vocabulary -- every op in exactly one, none left over' {
        $all = @(Get-QueryOps)
        $pos = @(Get-OpsOfKind -Kind 'position')
        $doc = @(Get-OpsOfKind -Kind 'document')
        $qry = @(Get-OpsOfKind -Kind 'query')
        ($pos.Count + $doc.Count + $qry.Count) | Should -Be $all.Count
        # And the partition is non-degenerate: an empty arm would make every assertion that
        # loops over it vacuous (Hub Rule 37).
        $pos.Count | Should -BeGreaterThan 0
        $doc.Count | Should -BeGreaterThan 0
        $qry.Count | Should -BeGreaterThan 0
    }
    It 'the position-carrying ops are the three that shipped in 000287' {
        (@(Get-OpsOfKind -Kind 'position') -join ',') | Should -BeExactly 'definition,references,hover'
    }
    It 'every method is distinct -- two ops sharing one request would make one of them a lie' {
        $spec = Get-QueryOpSpec
        $methods = @()
        foreach ($k in $spec.Keys) { $methods += [string]$spec[$k].method }
        @($methods | Sort-Object -Unique).Count | Should -Be @($methods).Count
    }
}

Describe 'Get-QueryRequestPlan -- the method mapping' {
    It 'maps <Op> to <Method>' -TestCases @(
        @{ Op = 'definition'; Method = 'textDocument/definition' }
        @{ Op = 'references'; Method = 'textDocument/references' }
        @{ Op = 'hover'; Method = 'textDocument/hover' }
        @{ Op = 'documentSymbol'; Method = 'textDocument/documentSymbol' }
        @{ Op = 'workspaceSymbol'; Method = 'workspace/symbol' }
    ) {
        param($Op, $Method)
        $plan = Get-PlanForOp -Op $Op
        $plan.ok | Should -BeTrue
        $plan.method | Should -BeExactly $Method
    }

    It 'the mapping table covers every advertised op -- no op planned by accident' {
        # The TestCases above are a literal list, so this asserts the list is COMPLETE against
        # the derived vocabulary rather than leaving a new op silently untested.
        $mapped = @('definition', 'references', 'hover', 'documentSymbol', 'workspaceSymbol')
        (@(Get-QueryOps) -join ',') | Should -BeExactly ($mapped -join ',')
    }

    It 'accepts an op in any case or padding, because a CLI argument arrives as typed' {
        (Get-QueryRequestPlan -Op '  Definition ' -Uri 'file:///C:/x.ps1' -Line 1 -Col 1).method |
            Should -BeExactly 'textDocument/definition'
    }

    It 'canonicalises a camelCase op instead of lowercasing it away' {
        # The three original ops were all lowercase, so ToLowerInvariant was free. It is not
        # free any more: lowercasing 'DocumentSymbol' yields an op the spec does not hold.
        (Get-PlanForOp -Op 'DOCUMENTSYMBOL').op | Should -BeExactly 'documentSymbol'
        (Get-PlanForOp -Op '  workspacesymbol ').op | Should -BeExactly 'workspaceSymbol'
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
        foreach ($op in @(Get-QueryOps)) {
            if ($op -eq 'references') { continue }
            (Get-PlanForOp -Op $op).params.ContainsKey('context') |
                Should -BeFalse -Because ($op + ' asked for no declaration context')
        }
    }
}

Describe 'the document arm -- documentSymbol names a FILE and no position' {
    It 'plans a textDocument and nothing else' {
        $plan = Get-QueryRequestPlan -Op 'documentSymbol' -Uri 'file:///C:/x.ps1' -Line 4 -Col 9
        $plan.ok | Should -BeTrue
        $plan.kind | Should -BeExactly 'document'
        $plan.params.textDocument.uri | Should -BeExactly 'file:///C:/x.ps1'
        # THE POINT OF THE WHOLE ARM: no fabricated position reaches PSES, even when the caller
        # supplied line and col positionally out of habit.
        $plan.params.ContainsKey('position') | Should -BeFalse
        @($plan.params.Keys) -join ',' | Should -BeExactly 'textDocument'
    }
    It 'still requires the document it is named after' {
        $plan = Get-QueryRequestPlan -Op 'documentSymbol' -Uri '' -Line 1 -Col 1
        $plan.ok | Should -BeFalse
        $plan.error | Should -Match 'document uri'
    }
    It 'does NOT refuse a position below 1, because it reads no position at all' {
        # The position rule is the position arm's. Applying it here would refuse a legitimate
        # documentSymbol for breaking a rule that does not govern it.
        (Get-QueryRequestPlan -Op 'documentSymbol' -Uri 'file:///C:/x.ps1' -Line 0 -Col 0).ok |
            Should -BeTrue
    }
}

Describe 'the query arm -- workspaceSymbol names a STRING and no file' {
    It 'plans a bare query and no document at all' {
        $plan = Get-QueryRequestPlan -Op 'workspaceSymbol' -Uri '' -Line 0 -Col 0 -Query 'Get-Thing'
        $plan.ok | Should -BeTrue
        $plan.kind | Should -BeExactly 'query'
        $plan.method | Should -BeExactly 'workspace/symbol'
        $plan.params.query | Should -BeExactly 'Get-Thing'
        $plan.params.ContainsKey('textDocument') | Should -BeFalse
        $plan.params.ContainsKey('position') | Should -BeFalse
        @($plan.params.Keys) -join ',' | Should -BeExactly 'query'
    }
    It 'needs no uri -- requiring one would refuse a legitimate workspace question' {
        (Get-QueryRequestPlan -Op 'workspaceSymbol' -Uri '' -Line 1 -Col 1 -Query 'X').ok |
            Should -BeTrue
    }
    It 'refuses an empty query by name rather than searching for nothing' {
        # An empty query is not "match everything" here; it is a caller who forgot the argument.
        foreach ($q in @('', '   ')) {
            $plan = Get-QueryRequestPlan -Op 'workspaceSymbol' -Uri '' -Line 1 -Col 1 -Query $q
            $plan.ok | Should -BeFalse
            $plan.error | Should -Match 'requires a query string'
        }
    }
    It 'carries the query through verbatim, including wildcards and spaces' {
        (Get-QueryRequestPlan -Op 'workspaceSymbol' -Uri '' -Line 1 -Col 1 -Query 'Get-* thing').params.query |
            Should -BeExactly 'Get-* thing'
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

    It 'the mutant is wrong on EVERY POSITION op, not just the one it was demonstrated on' {
        # A control that only bites one arm leaves the others unguarded (banked: a red control must
        # mutate every arm of the check it controls). The set is DERIVED, not listed: this mutant
        # controls the position conversion, so it is run over exactly the ops that carry a
        # position -- and the partition test above proves that set is neither empty nor stale.
        $posOps = @(Get-OpsOfKind -Kind 'position')
        $posOps.Count | Should -BeGreaterThan 0
        foreach ($op in $posOps) {
            $shipped = Get-QueryRequestPlan -Op $op -Uri 'file:///C:/x.ps1' -Line 7 -Col 3
            $mutant = Get-QueryRequestPlanPassThroughMutant -Op $op -Uri 'file:///C:/x.ps1' -Line 7 -Col 3
            $mutant.params.position.line | Should -Not -Be $shipped.params.position.line -Because ('op ' + $op)
        }
    }

    It 'the pass-through mutant leaves the two non-position arms untouched, which is WHY there is a second control' {
        # Stated so the next reader does not mistake this control for covering the symbol ops.
        # It cannot: the arms it mutates are never reached by an op that carries no position.
        foreach ($op in @(Get-OpsOfKind -Kind 'document') + @(Get-OpsOfKind -Kind 'query')) {
            $shipped = Get-PlanForOp -Op $op
            $mutant = Get-QueryRequestPlanPassThroughMutant -Op $op -Uri 'file:///C:/x.ps1' -Line 7 -Col 3 -Query 'Get-Thing'
            $mutant.ok | Should -BeTrue
            (@($mutant.params.Keys) -join ',') | Should -BeExactly (@($shipped.params.Keys) -join ',')
        }
    }
}

Describe 'SECOND RED CONTROL -- the uniform-position mutant is the shape this replaced' {
    # Before the symbol ops existed the planner had one arm and every op was a position query.
    # Forcing documentSymbol and workspaceSymbol down it is the defect the charter names by
    # name: do not invent a fake position for an op that has none.
    It 'the mutant really does force every op down the position arm (the mutant LANDED)' {
        # Assert the mutation APPLIED before concluding anything from what it does. A control
        # that silently did not land reports the same green as a correct implementation.
        $m = Get-QueryRequestPlanUniformPositionMutant -Op 'documentSymbol' -Uri 'file:///C:/x.ps1' -Line 4 -Col 9
        $m.ok | Should -BeTrue
        $m.kind | Should -BeExactly 'position'
        $m.params.ContainsKey('position') | Should -BeTrue
        $m.params.position.line | Should -Be 3
        $m.params.position.character | Should -Be 8
    }

    It 'the shipped planner sends NO position for documentSymbol where the mutant sends one' {
        $shipped = Get-QueryRequestPlan -Op 'documentSymbol' -Uri 'file:///C:/x.ps1' -Line 4 -Col 9
        $mutant = Get-QueryRequestPlanUniformPositionMutant -Op 'documentSymbol' -Uri 'file:///C:/x.ps1' -Line 4 -Col 9
        $shipped.params.ContainsKey('position') | Should -BeFalse
        $mutant.params.ContainsKey('position') | Should -BeTrue
        (@($shipped.params.Keys) -join ',') | Should -Not -Be (@($mutant.params.Keys) -join ',')
    }

    It 'the mutant REFUSES a workspaceSymbol the shipped planner serves' {
        # Down the position arm, workspace/symbol needs a uri it never had and a position it was
        # never given -- so the mutant refuses the query outright. The shipped planner answers it.
        $shipped = Get-QueryRequestPlan -Op 'workspaceSymbol' -Uri '' -Line 0 -Col 0 -Query 'Get-Thing'
        $mutant = Get-QueryRequestPlanUniformPositionMutant -Op 'workspaceSymbol' -Uri '' -Line 0 -Col 0 -Query 'Get-Thing'
        $shipped.ok | Should -BeTrue
        $mutant.ok | Should -BeFalse
    }

    It 'the mutant is wrong on EVERY non-position op, not just the one it was demonstrated on' {
        $others = @(Get-OpsOfKind -Kind 'document') + @(Get-OpsOfKind -Kind 'query')
        @($others).Count | Should -BeGreaterThan 0
        foreach ($op in $others) {
            $shipped = Get-PlanForOp -Op $op
            $mutant = Get-QueryRequestPlanUniformPositionMutant -Op $op -Uri 'file:///C:/x.ps1' -Line 4 -Col 9 -Query 'Get-Thing'
            $differs = ($mutant.ok -ne $shipped.ok) -or
                ((@($mutant.params.Keys) -join ',') -ne (@($shipped.params.Keys) -join ','))
            $differs | Should -BeTrue -Because ($op + ' must be planned differently than a position query')
        }
    }

    It 'the mutant leaves the three POSITION ops alone, so it controls what it claims to' {
        # A mutant that changed everything would prove nothing about the symbol arms specifically.
        foreach ($op in @(Get-OpsOfKind -Kind 'position')) {
            $shipped = Get-QueryRequestPlan -Op $op -Uri 'file:///C:/x.ps1' -Line 4 -Col 9
            $mutant = Get-QueryRequestPlanUniformPositionMutant -Op $op -Uri 'file:///C:/x.ps1' -Line 4 -Col 9
            $mutant.method | Should -BeExactly $shipped.method
            $mutant.params.position.line | Should -Be $shipped.params.position.line
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

    It 'sends the query string the symbol search needs' {
        $src = [System.IO.File]::ReadAllText($script:QueryPath)
        $src | Should -Match 'query = \$Query'
    }

    It 'does not require a file or a position of the ops that have none' {
        # documentSymbol names no position and workspaceSymbol names no file. A Mandatory
        # parameter on either would refuse a legitimate call before the daemon ever saw it.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:QueryPath, [ref]$null, [ref]$null)
        $params = $ast.ParamBlock.Parameters
        foreach ($name in @('File', 'Line', 'Col', 'Query')) {
            $prm = $params | Where-Object { $_.Name.VariablePath.UserPath -eq $name }
            @($prm).Count | Should -Be 1 -Because ('-' + $name + ' must exist exactly once')
            $mandatory = $false
            foreach ($att in $prm.Attributes) {
                foreach ($na in @($att.NamedArguments)) {
                    if ($na.ArgumentName -eq 'Mandatory') { $mandatory = $true }
                }
            }
            $mandatory | Should -BeFalse -Because ('-' + $name + ' does not apply to every op')
        }
        # -Op stays mandatory: there is no default question.
        $opPrm = $params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Op' }
        $opMandatory = $false
        foreach ($att in $opPrm.Attributes) {
            foreach ($na in @($att.NamedArguments)) { if ($na.ArgumentName -eq 'Mandatory') { $opMandatory = $true } }
        }
        $opMandatory | Should -BeTrue
    }

    It 'guards its up-front position check on what the caller actually supplied' {
        # An unconditional check would refuse documentSymbol for leaving -Line at its default.
        $src = [System.IO.File]::ReadAllText($script:QueryPath)
        $src.Contains("PSBoundParameters.ContainsKey('Line')") | Should -BeTrue
        $src.Contains("PSBoundParameters.ContainsKey('Col')") | Should -BeTrue
    }

    It 'renders a subject line for every kind the daemon can report' {
        # The -Text rendering switches on the daemon's echoed kind. A kind with no arm would
        # fall to the default and render the op alone -- correct, but silently less useful --
        # so the arms are asserted to COVER the spec rather than to merely exist.
        $src = [System.IO.File]::ReadAllText($script:QueryPath)
        $spec = Get-QueryOpSpec
        $kinds = @()
        foreach ($k in $spec.Keys) { $kinds += [string]$spec[$k].kind }
        foreach ($kind in @($kinds | Sort-Object -Unique)) {
            $src.Contains("'" + $kind + "' {") | Should -BeTrue -Because ('kind ' + $kind + ' needs a rendering')
        }
    }
}
