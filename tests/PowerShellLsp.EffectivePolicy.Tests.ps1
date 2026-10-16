#Requires -Version 5.1

# Effective-policy resolver, application evidence and the managed scan (Pester 5) -- dispatch 000305,
# B1 (enterprise review F3; owner ruling O03: managed mode; refuse in managed only; full main pass).
#
# FIVE LAYERS:
#   1. The resolver (no daemon): Import-OrgPolicy's fixed reason codes, the caller-independent parse
#      failure, the canonical identity (equal effective policies -> equal identity; every member moves
#      it; injective and host-independent -- a rule code that is not a rule name is refused, and only
#      ASCII A-Z is folded), obligations (not-required is never failed), and the client's no-second-read
#      resolution.
#   2. Application evidence (no daemon): the RequiredRules version guard's verdict, the content-
#      addressed and verified merged-settings write, and the evidence records.
#   3. The managed verdict (no daemon): Test-ScanPolicyCertification's table -- every refusal code,
#      and the fully evidenced control that certifies -- the mode (an explicit -PolicyMode, else open:
#      POWERSHELL_LSP_POLICY_MODE never selects a managed scan since dispatch 000306, owner ruling Q03),
#      the ambient-option refusal, and the child carrier.
#   4. The shipped CLI over PRODUCTION-BUILT evidence (fake hooks, no daemon): lsp-scan.ps1 relocated
#      beside tests/fixtures/scan-verdict/pv-policy-variant.ps1 certifies the agreeing control and
#      refuses activation-unsupported, merge-write-failed, a changed settings file, either party's
#      disagreement, missing evidence, an unknown engine and a narrowed configuration.
#   5. The real daemon, every ambient CLAUDE_PLUGIN_OPTION_* and POWERSHELL_LSP_* cleared and ONLY
#      -OrgPolicyPath supplied: the four members drive the MAIN pass (required rule, override,
#      exclusion, prohibited suppression -- each against a no-policy baseline); managed mode certifies
#      the control and refuses a missing, a corrupt and an undeclared policy, a failed merged-settings
#      write (a squatted target, computed with the production functions), ambient configuration and a
#      forged rule code; the unmanaged scan keeps its fail-open behavior; doctor reports the running
#      daemon's own record -- not yet applied (pending) before its first analyzed file.
#
# ASCII-only (PS 5.1 em-dash trap); StrictMode-safe.

$script:EpOnWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
$script:EpOnLinux = (Test-Path 'Variable:\IsLinux') -and [bool]$IsLinux
$script:EpOnMacOS = (Test-Path 'Variable:\IsMacOS') -and [bool]$IsMacOS
$script:EpUnsupported = -not ($script:EpOnWindows -or $script:EpOnLinux -or $script:EpOnMacOS)
$script:EpNoTestJson = ($PSVersionTable.PSVersion.Major -lt 6)

BeforeAll {
    $script:EpRepo = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:EpRepo 'scripts/lib/lsp-common.ps1')
    . (Join-Path $script:EpRepo 'scripts/lib/lsp-scan-common.ps1')
    . (Join-Path $script:EpRepo 'scripts/lib/lsp-scan-receipt.ps1')
    . (Join-Path $script:EpRepo 'scripts/lib/lsp-policy.ps1')

    function New-EpPolicy {
        # A policy file under $TestDrive with $Text, returned as its absolute path. -Bom writes the UTF-8
        # BOM a non-ASCII policy needs for Windows PowerShell 5.1 to read it as UTF-8 at all.
        param([string]$Text, [string]$Name = 'org.psd1', [switch]$Bom)
        $d = Join-Path $TestDrive ('ep-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $p = Join-Path $d $Name
        [System.IO.File]::WriteAllText($p, $Text + "`n", (New-Object System.Text.UTF8Encoding([bool]$Bom)))
        return $p
    }
}

Describe 'The effective-policy resolver: one reader, fixed reasons, a canonical identity (dispatch 000305 B1)' {

    It 'Import-OrgPolicy names each degrade with a fixed code beside its prose: <Name> -> <Code>' -TestCases @(
        @{ Name = 'a relative path'; Code = 'policy-path-relative'; Make = { 'relative/org.psd1' } }
        @{ Name = 'a missing file'; Code = 'policy-file-missing'; Make = { Join-Path $TestDrive ('gone-' + [guid]::NewGuid().ToString('N') + '.psd1') } }
        @{ Name = 'an unparseable file'; Code = 'policy-unreadable'; Make = { New-EpPolicy '@{ ExcludeRules = @( this is not' } }
        @{ Name = 'a file that tries to run a command'; Code = 'policy-unreadable'; Make = { New-EpPolicy '@{ ExcludeRules = @(Get-Process) }' } }
        @{ Name = 'a sidecar that does not match'; Code = 'policy-integrity-mismatch'; Make = { $p = New-EpPolicy "@{ ExcludeRules = @('A') }"; Set-Content -LiteralPath ($p + '.sha256') -Value ('f' * 64) -Encoding ascii; $p } }
        @{ Name = 'a sidecar with no digest'; Code = 'policy-integrity-malformed'; Make = { $p = New-EpPolicy "@{ ExcludeRules = @('A') }"; Set-Content -LiteralPath ($p + '.sha256') -Value 'no digest here' -Encoding ascii; $p } }
    ) {
        param($Name, $Code, $Make)
        $path = & $Make
        $w = ''; $r = ''
        $pol = Import-OrgPolicy -Path $path -WarningOut ([ref]$w) -ReasonOut ([ref]$r)
        $w | Should -Not -BeNullOrEmpty -Because ($Name + ' is a degrade and must say so')
        $r | Should -BeExactly $Code
        @($pol.ExcludeRules).Count | Should -Be 0 -Because 'a degraded policy applies nothing (fail-open, unchanged)'
        (Get-PolicyReasonTable).Contains($r) | Should -BeTrue -Because 'every code Import-OrgPolicy sets is declared in the reason table'
    }

    It 'a usable policy, and an unconfigured one, set NO reason code and no warning' {
        $w = ''; $r = 'untouched'
        [void](Import-OrgPolicy -Path (New-EpPolicy "@{ ExcludeRules = @('A') }") -WarningOut ([ref]$w) -ReasonOut ([ref]$r))
        $w | Should -BeExactly ''
        $r | Should -BeExactly 'untouched' -Because 'ReasonOut is written only on a degrade'
        $w2 = ''; $r2 = 'untouched'
        [void](Import-OrgPolicy -Path '' -WarningOut ([ref]$w2) -ReasonOut ([ref]$r2))
        $w2 | Should -BeExactly ''; $r2 | Should -BeExactly 'untouched'
    }

    It 'every policy-* code the readers in lsp-common.ps1 can set is a declared reason (the vocabulary cannot drift)' {
        $src = [System.IO.File]::ReadAllText((Join-Path $script:EpRepo 'scripts/lib/lsp-common.ps1'))
        $codes = @([regex]::Matches($src, "'(policy-[a-z-]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $codes.Count | Should -BeGreaterOrEqual 6 -Because 'a floor, so this census cannot pass by finding nothing'
        $table = Get-PolicyReasonTable
        foreach ($c in $codes) { $table.Contains($c) | Should -BeTrue -Because ($c + ' is set by a reader and must be declared') }
    }

    It 'THE PARSE FAILURE NO LONGER DEPENDS ON THE CALLER: under ErrorActionPreference Continue a corrupt policy still warns' {
        # Measured on pwsh 7.6.6 and Windows PowerShell 5.1.26100 before the fix: Import-PowerShellDataFile
        # reports an unparseable file as a NON-terminating error, so under Continue $data came back $null
        # and Import-OrgPolicy returned a valid-looking EMPTY policy with NO warning. The control half
        # re-measures that platform behavior here, so the fix stays justified by an observation.
        # Both halves run in a FRESH child of this same edition with default preferences -- the caller
        # the fix is for -- because Pester's own scope changes how the cmdlet's error propagates in-process.
        $bad = New-EpPolicy '@{ ExcludeRules = @( this is not'
        $lib = Join-Path $script:EpRepo 'scripts/lib/lsp-common.ps1'
        $exe = (Get-Process -Id $PID).Path
        $cmd = "`$ErrorActionPreference = 'Continue'; `$d = Import-PowerShellDataFile -LiteralPath '" + $bad + "' 2>`$null; " +
            "'CONTROL=' + [string](`$null -eq `$d); . '" + $lib + "'; `$w = ''; [void](Import-OrgPolicy -Path '" + $bad + "' -WarningOut ([ref]`$w)); 'WARN=' + `$w"
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $out = (@(& $exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>$null) -join "`n") } finally { $ErrorActionPreference = $prev }
        $out | Should -Match 'CONTROL=True' -Because 'CONTROL: under Continue the cmdlet reports the corrupt file without throwing, and returns nothing'
        $out | Should -Match 'WARN=orgPolicy could not be read' -Because 'a corrupt policy is a degrade under every caller preference'
    }

    It 'Resolve-EffectivePolicy keeps requested, effective and identity apart -- and a usable policy has an identity' {
        $p = New-EpPolicy "@{ ExcludeRules = @('PSUseApprovedVerbs'); RequiredRules = @('PSAvoidGlobalVars') }"
        $r = Resolve-EffectivePolicy -Path $p -Source 'cli'
        $r.requested.source | Should -BeExactly 'cli'
        $r.requested.path | Should -BeExactly $p
        $r.requested.configured | Should -BeTrue
        $r.requested.fileSha256 | Should -BeExactly ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant())
        $r.requested.sidecar | Should -BeExactly 'not-present'
        $r.usable | Should -BeTrue
        $r.reason | Should -BeExactly ''
        $r.identity.schema | Should -BeExactly 'powershell-lsp/effective-policy'
        $r.identity.version | Should -Be 1
        $r.identity.sha256 | Should -Match '^[0-9a-f]{64}$'
        @($r.effective.ExcludeRules) | Should -Be @('PSUseApprovedVerbs')
        @($r.effective.RequiredRules) | Should -Be @('PSAvoidGlobalVars')
    }

    It 'a configured but unusable policy has NO identity (a managed gate can never certify the empty policy in its place)' {
        $r = Resolve-EffectivePolicy -Path (Join-Path $TestDrive 'nope.psd1') -Source 'cli'
        $r.requested.configured | Should -BeTrue
        $r.usable | Should -BeFalse
        $r.reason | Should -BeExactly 'policy-file-missing'
        $r.identity.sha256 | Should -BeExactly ''
        $r.obligations.mergedSettings | Should -BeExactly 'not-required'
    }

    It 'an unconfigured policy is not configured, not usable, and carries no reason -- "not declared" is the managed verdict''s word' {
        $r = Resolve-EffectivePolicy -Path '' -Source 'cli'
        $r.requested.configured | Should -BeFalse
        $r.usable | Should -BeFalse
        $r.reason | Should -BeExactly ''
        $r.identity.sha256 | Should -BeExactly ''
    }

    It 'EQUAL EFFECTIVE POLICIES PRODUCE ONE IDENTITY: reordered, re-cased, commented, duplicated and moot entries' {
        $a = New-EpPolicy "@{ ExcludeRules = @('PSUseApprovedVerbs', 'PSAvoidX'); RequiredRules = @('PSAvoidGlobalVars', 'PSAvoidX'); SeverityOverrides = @{ PSAvoidUsingCmdletAliases = 'error'; PSAvoidX = 'Warning' }; ProhibitedSuppressions = @('PSAvoidUsingPlainTextForPassword') }"
        $b = New-EpPolicy "# a comment the identity must not see`n@{`n  ProhibitedSuppressions = @('psavoidusingplaintextforpassword')`n  SeverityOverrides = @{ 'psavoidusingcmdletaliases' = 'Error' }`n  RequiredRules = @('psavoidglobalvars')`n  ExcludeRules = @('psavoidx', 'PSUseApprovedVerbs', 'PSUseApprovedVerbs')`n  IncludeRules = @('advisory, never enforced')`n}"
        $ra = Resolve-EffectivePolicy -Path $a
        $rb = Resolve-EffectivePolicy -Path $b
        $ra.requested.fileSha256 | Should -Not -BeExactly $rb.requested.fileSha256 -Because 'CONTROL: the two FILES differ'
        $rb.identity.sha256 | Should -BeExactly $ra.identity.sha256
    }

    It 'every member moves the identity: <Name>' -TestCases @(
        @{ Name = 'one more exclusion'; Text = "@{ ExcludeRules = @('A', 'B') }" }
        @{ Name = 'one more required rule'; Text = "@{ ExcludeRules = @('A'); RequiredRules = @('R') }" }
        @{ Name = 'one more override'; Text = "@{ ExcludeRules = @('A'); SeverityOverrides = @{ R = 'Error' } }" }
        @{ Name = 'one more prohibited suppression'; Text = "@{ ExcludeRules = @('A'); ProhibitedSuppressions = @('R') }" }
    ) {
        param($Name, $Text)
        $base = (Resolve-EffectivePolicy -Path (New-EpPolicy "@{ ExcludeRules = @('A') }")).identity.sha256
        (Resolve-EffectivePolicy -Path (New-EpPolicy $Text)).identity.sha256 | Should -Not -BeExactly $base
    }

    It 'an override''s SEVERITY moves the identity too (the value is part of the policy)' {
        $e = (Resolve-EffectivePolicy -Path (New-EpPolicy "@{ SeverityOverrides = @{ R = 'Error' } }")).identity.sha256
        $w = (Resolve-EffectivePolicy -Path (New-EpPolicy "@{ SeverityOverrides = @{ R = 'Warning' } }")).identity.sha256
        $w | Should -Not -BeExactly $e
    }

    It 'THE CANONICAL HASHING RULES, as a known answer: the exact text, and its SHA-256 computed independently' {
        $r = Resolve-EffectivePolicy -Path (New-EpPolicy "@{ RequiredRules = @('PSAvoidGlobalVars'); ExcludeRules = @('PSUseApprovedVerbs'); SeverityOverrides = @{ PSAvoidUsingCmdletAliases = 'error' }; ProhibitedSuppressions = @('PSAvoidUsingPlainTextForPassword') }")
        $tab = [string][char]9
        $expected = 'powershell-lsp/effective-policy 1' + "`n" +
            'exclude' + $tab + 'psuseapprovedverbs' + "`n" +
            'override' + $tab + 'psavoidusingcmdletaliases' + $tab + 'Error' + "`n" +
            'prohibit' + $tab + 'psavoidusingplaintextforpassword' + "`n" +
            'require' + $tab + 'psavoidglobalvars' + "`n"
        $text = ConvertTo-EffectivePolicyText -Effective $r.effective
        $text | Should -BeExactly $expected
        $file = Join-Path $TestDrive ('canon-' + [guid]::NewGuid().ToString('N') + '.txt')
        [System.IO.File]::WriteAllBytes($file, (New-Object System.Text.UTF8Encoding($false)).GetBytes($expected))
        $r.identity.sha256 | Should -BeExactly ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant())
    }

    It 'A RULE CODE MUST BE A RULE NAME: <Name> refuses the whole policy as unreadable (review finding B1-R01)' -TestCases @(
        @{ Name = 'an LF and a TAB inside an ExcludeRules code'; Bom = $false; Text = ("@{ ExcludeRules = @('PSUseApprovedVerbs" + "`n" + 'require' + "`t" + "PSAvoidGlobalVars') }") }
        @{ Name = 'a TAB inside a RequiredRules code'; Bom = $false; Text = ("@{ RequiredRules = @('PSAvoid" + "`t" + "GlobalVars') }") }
        @{ Name = 'a CR inside a ProhibitedSuppressions code'; Bom = $false; Text = ("@{ ProhibitedSuppressions = @('PSAvoidUsing" + "`r" + "PlainTextForPassword') }") }
        @{ Name = 'an LF inside a SeverityOverrides key'; Bom = $false; Text = ("@{ SeverityOverrides = @{ 'PSAvoidX" + "`n" + "override' = 'Error' } }") }
        @{ Name = 'a space inside a code'; Bom = $false; Text = "@{ ExcludeRules = @('PSUse ApprovedVerbs') }" }
        @{ Name = 'a wildcard, which no enforcement point matches as a name'; Bom = $false; Text = "@{ RequiredRules = @('PSAvoid*') }" }
        @{ Name = 'U+212A KELVIN SIGN inside a code'; Bom = $true; Text = ("@{ ExcludeRules = @('PSMisleadingBac" + [string][char]0x212A + "tick') }") }
        @{ Name = 'a non-ASCII space around a rule name'; Bom = $true; Text = ("@{ ExcludeRules = @('" + [string][char]0x00A0 + "PSUseApprovedVerbs') }") }
    ) {
        param($Name, $Bom, $Text)
        $p = New-EpPolicy $Text -Bom:$Bom
        $w = ''; $r = ''
        $pol = Import-OrgPolicy -Path $p -WarningOut ([ref]$w) -ReasonOut ([ref]$r)
        $w | Should -Match 'not a rule name' -Because ($Name + ' is malformed policy, refused with one warning')
        $w | Should -MatchExactly '\A[\x20-\x7E]+\z' -Because 'the warning shows the entry as one line of printable ASCII (case-sensitive: -Match would let U+212A pass as k)'
        $r | Should -BeExactly 'policy-unreadable' -Because 'the existing corrupt-policy refusal, not a new code'
        foreach ($m in @('ExcludeRules', 'RequiredRules', 'ProhibitedSuppressions')) { @($pol[$m]).Count | Should -Be 0 -Because ($m + ': an unreadable policy applies nothing') }
        $pol.SeverityOverrides.Count | Should -Be 0
        $res = Resolve-EffectivePolicy -Path $p -Source 'cli'
        $res.usable | Should -BeFalse
        $res.reason | Should -BeExactly 'policy-unreadable'
        $res.identity.sha256 | Should -BeExactly '' -Because 'a policy that is not usable has no identity to present'
    }

    It 'SEPARATOR INJECTION: one forged rule code can no longer present another policy''s identity (review finding B1-R01)' {
        $org = New-EpPolicy "@{ ExcludeRules = @('PSUseApprovedVerbs'); RequiredRules = @('PSAvoidGlobalVars') }"
        $forged = New-EpPolicy ("@{ ExcludeRules = @('PSUseApprovedVerbs" + "`n" + 'require' + "`t" + "PSAvoidGlobalVars') }")
        $ro = Resolve-EffectivePolicy -Path $org -Source 'cli'
        # CONTROL: the forged file holds ONE string, and the pre-correction encoding (verb, TAB, the code
        # through ToLowerInvariant, LF -- nothing refused or escaped) renders it as the org policy's exact
        # canonical text, so it would have presented the org policy's identity (measured by the review:
        # both managed scans CERTIFIED as 937b69ab...646d).
        $raw = @((Import-PowerShellDataFile -LiteralPath $forged).ExcludeRules)
        $raw.Count | Should -Be 1
        $tab = [string][char]9
        $naive = 'powershell-lsp/effective-policy 1' + "`n" + 'exclude' + $tab + ([string]$raw[0]).Trim().ToLowerInvariant() + "`n"
        $naive | Should -BeExactly (ConvertTo-EffectivePolicyText -Effective $ro.effective) -Because 'CONTROL: the collision is real'
        (Get-Sha256HexFromBytes -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes($naive))) | Should -BeExactly $ro.identity.sha256
        # THE CORRECTION: the forged policy is unreadable, has no identity, and a managed scan refuses it.
        $ro.usable | Should -BeTrue
        $ro.identity.sha256 | Should -BeExactly '937b69abf90e7c72590ce2f8550f0328f688826cff796ffbcb2d163ee636646d' -Because 'an ordinary policy keeps the identity the review measured'
        $rf = Resolve-EffectivePolicy -Path $forged -Source 'cli'
        $rf.usable | Should -BeFalse
        $rf.reason | Should -BeExactly 'policy-unreadable'
        $rf.identity.sha256 | Should -BeExactly ''
        $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $rf
        $c.Certified | Should -BeFalse
        @($c.Reasons) | Should -Contain 'policy-unreadable'
    }

    It 'HOST-INDEPENDENT FOLDING: U+212A KELVIN SIGN is refused on every host, and only ASCII A-Z is folded (review finding B1-R01)' {
        $k = [string][char]0x212A
        $kelvin = New-EpPolicy ("@{ ExcludeRules = @('PSMisleadingBac" + $k + "tick') }") -Bom
        # CONTROL: the policy as parsed on THIS host really carries U+212A, and OrdinalIgnoreCase -- the
        # match every enforcement point uses -- does not take it for the real rule. ToLowerInvariant folded
        # it to 'k' on PowerShell 7 and not on Windows PowerShell 5.1 (measured by the review), so before
        # this correction it shared PSMisleadingBacktick's identity on one host and had its own on the other.
        $parsed = [string]@((Import-PowerShellDataFile -LiteralPath $kelvin).ExcludeRules)[0]
        $parsed.Contains($k) | Should -BeTrue -Because 'CONTROL: the BOM made both hosts read U+212A'
        [string]::Equals($parsed, 'PSMisleadingBacktick', [System.StringComparison]::OrdinalIgnoreCase) | Should -BeFalse
        # THE CORRECTION, the same on every host: the Kelvin policy is refused and has no identity, and the
        # real rule's policy has the known-answer identity.
        $rk = Resolve-EffectivePolicy -Path $kelvin
        $rk.usable | Should -BeFalse
        $rk.reason | Should -BeExactly 'policy-unreadable'
        $rk.identity.sha256 | Should -BeExactly ''
        $real = Resolve-EffectivePolicy -Path (New-EpPolicy "@{ ExcludeRules = @('PSMisleadingBacktick') }")
        $expected = 'powershell-lsp/effective-policy 1' + "`n" + 'exclude' + [string][char]9 + 'psmisleadingbacktick' + "`n"
        ConvertTo-EffectivePolicyText -Effective $real.effective | Should -BeExactly $expected
        $file = Join-Path $TestDrive ('kelvin-' + [guid]::NewGuid().ToString('N') + '.txt')
        [System.IO.File]::WriteAllBytes($file, (New-Object System.Text.UTF8Encoding($false)).GetBytes($expected))
        $real.identity.sha256 | Should -BeExactly ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant())
        # The fold itself: A-Z only. U+212A and every other non-ASCII character are left exactly as they are.
        ConvertTo-AsciiLowerCase ('PSMisleadingBac' + $k + 'tick') | Should -BeExactly ('psmisleadingbac' + $k + 'tick')
        $eAcute = [string][char]0x00C9
        ConvertTo-AsciiLowerCase ('AZaz09_-.\' + $eAcute) | Should -BeExactly ('azaz09_-.\' + $eAcute)
        # And the canonical text never folds through a culture's or Unicode's case map again.
        $src = [System.IO.File]::ReadAllText((Join-Path $script:EpRepo 'scripts/lib/lsp-policy.ps1'))
        $body = $src.Substring($src.IndexOf('function ConvertTo-EffectivePolicyText'))
        $body = $body.Substring(0, $body.IndexOf('function Get-EffectivePolicyDigest'))
        $body | Should -Match 'ConvertTo-AsciiLowerCase' -Because 'a floor, so this census cannot pass on the wrong slice'
        $body | Should -Not -Match '\.To(Lower|Upper)(Invariant)?\('
    }

    It 'ORDINARY RULE NAMES KEEP THEIR IDENTITIES: every default, plugin and custom-rule name is accepted and folded exactly as before' {
        # The custom-rule shape is the one PSScriptAnalyzer 1.25.0 reports (measured on both hosts):
        # '<module>\<function>'. For an ASCII name the new fold equals the old ToLowerInvariant, so every
        # ordinary policy's canonical text -- and so its identity -- is unchanged.
        $names = @(Get-PssaDefaultRuleNames) + @('PSAvoidGlobalVars', 'ProhibitedSuppression', 'ManifestConsistency', 'NonAsciiChar',
            'PS7OnlySyntax', 'ModuleNotInstalled', 'CommandLinePlaceholder', 'BashIsm', 'My.Rules\Measure-NoFoo', 'PSB1_Under_Score9')
        $names.Count | Should -BeGreaterOrEqual 20 -Because 'a floor, so this census cannot pass by finding nothing'
        foreach ($n in $names) {
            Test-OrgPolicyRuleCode $n | Should -BeTrue -Because ($n + ' is a rule name')
            Test-OrgPolicyRuleCode ('  ' + $n + "`t") | Should -BeTrue -Because 'ASCII whitespace padding is trimmed, as always'
            ConvertTo-AsciiLowerCase $n | Should -BeExactly $n.ToLowerInvariant() -Because ($n + ' keeps its folded form')
        }
        Test-OrgPolicyRuleCode '' | Should -BeTrue -Because 'a blank entry is no rule, skipped as before'
        Test-OrgPolicyRuleCode '   ' | Should -BeTrue
        Test-OrgPolicyRuleCode 42 | Should -BeFalse -Because 'not a string (Import-OrgPolicy skips it before asking)'
        $r = Resolve-EffectivePolicy -Path (New-EpPolicy "@{ ExcludeRules = @('  My.Rules\Measure-NoFoo  ', '', 'PSUseApprovedVerbs'); SeverityOverrides = @{ 'My.Rules\Measure-NoFoo' = 'error' } }")
        $r.usable | Should -BeTrue
        $tab = [string][char]9
        ConvertTo-EffectivePolicyText -Effective $r.effective | Should -BeExactly ('powershell-lsp/effective-policy 1' + "`n" +
            'exclude' + $tab + 'my.rules\measure-nofoo' + "`n" + 'exclude' + $tab + 'psuseapprovedverbs' + "`n")
    }

    It 'obligations distinguish NOT REQUIRED from required, member by member' {
        $none = Resolve-EffectivePolicy -Path (New-EpPolicy '@{ }')
        $none.usable | Should -BeTrue -Because 'a valid no-op policy is usable'
        $none.obligations.mergedSettings | Should -BeExactly 'not-required'
        $none.obligations.clientAdjudication | Should -BeExactly 'not-required'
        $none.obligations.suppressionPass | Should -BeExactly 'not-required'
        $req = Resolve-EffectivePolicy -Path (New-EpPolicy "@{ RequiredRules = @('R') }")
        $req.obligations.mergedSettings | Should -BeExactly 'required'
        $req.obligations.clientAdjudication | Should -BeExactly 'not-required'
        $exc = Resolve-EffectivePolicy -Path (New-EpPolicy "@{ ExcludeRules = @('R') }")
        $exc.obligations.mergedSettings | Should -BeExactly 'not-required'
        $exc.obligations.clientAdjudication | Should -BeExactly 'required'
        $pro = Resolve-EffectivePolicy -Path (New-EpPolicy "@{ ProhibitedSuppressions = @('R') }")
        $pro.obligations.suppressionPass | Should -BeExactly 'required'
        $moot = Resolve-EffectivePolicy -Path (New-EpPolicy "@{ RequiredRules = @('R'); ExcludeRules = @('R') }")
        $moot.obligations.mergedSettings | Should -BeExactly 'not-required' -Because 'a required rule the policy also excludes is not required (exclusion wins)'
    }

    It 'the client''s resolution of the object it ALREADY read equals a fresh resolution of the same file (no second read needed)' {
        $p = New-EpPolicy "@{ ExcludeRules = @('PSUseApprovedVerbs'); SeverityOverrides = @{ PSAvoidUsingCmdletAliases = 'Error' } }"
        $w = ''; $c = ''
        $pol = Import-OrgPolicy -Path $p -WarningOut ([ref]$w) -ReasonOut ([ref]$c)
        $client = New-PolicyResolution -Policy $pol -Path $p -Source 'knob' -Warning $w -Reason $c
        $client.identity.sha256 | Should -BeExactly (Resolve-EffectivePolicy -Path $p).identity.sha256
        $bad = New-PolicyResolution -Policy (New-EmptyOrgPolicy) -Path $p -Source 'knob' -Warning 'some degrade' -Reason 'policy-integrity-mismatch'
        $bad.usable | Should -BeFalse
        $bad.reason | Should -BeExactly 'policy-integrity-mismatch'
        $bad.identity.sha256 | Should -BeExactly ''
    }

    It 'the existing readers are unchanged: Import-OrgPolicyExcludes and the four Import-OrgPolicy members' {
        $p = New-EpPolicy "@{ ExcludeRules = @('  B  ', 'A', 'B'); SeverityOverrides = @{ X = 'error' }; RequiredRules = @('R'); ProhibitedSuppressions = @('S') }"
        @(Import-OrgPolicyExcludes -Path $p) | Should -Be @('B', 'A') -Because 'first-seen order, trimmed, de-duplicated -- exactly as before'
        $pol = Import-OrgPolicy -Path $p
        $pol.SeverityOverrides['X'] | Should -BeExactly 'Error'
        @($pol.RequiredRules) | Should -Be @('R')
        @($pol.ProhibitedSuppressions) | Should -Be @('S')
    }
}

Describe 'RequiredRules application evidence: the version guard and the merged-settings write (dispatch 000305 B1)' {

    It 'Merge-RequiredRulesSettings reports the guard''s verdict: <Name> -> <Guard>' -TestCases @(
        @{ Name = 'the verified tag, no repo IncludeRules'; Tag = 'v4.6.0'; Repo = ''; Guard = 'pass'; Merged = $true }
        @{ Name = 'another PSES version, no repo IncludeRules'; Tag = 'v9.9.9'; Repo = ''; Guard = 'refused'; Merged = $false }
        @{ Name = 'an unknown PSES version'; Tag = 'unknown'; Repo = ''; Guard = 'refused'; Merged = $false }
        @{ Name = 'another PSES version, a repo IncludeRules to merge onto'; Tag = 'v9.9.9'; Repo = "@{ IncludeRules = @('PSUseApprovedVerbs') }"; Guard = 'not-needed'; Merged = $true }
    ) {
        param($Name, $Tag, $Repo, $Guard, $Merged)
        $settings = ''
        if ($Repo -ne '') { $settings = New-EpPolicy $Repo -Name 'PSScriptAnalyzerSettings.psd1' }
        $g = ''
        $m = Merge-RequiredRulesSettings -ResolvedSettingsPath $settings -RequiredRules @('PSAvoidGlobalVars') -CurrentPsesTag $Tag -GuardOut ([ref]$g)
        $g | Should -BeExactly $Guard
        ($null -ne $m) | Should -Be $Merged
    }

    It 'nothing required: no merge, and the guard is not needed' {
        $g = 'untouched'
        Merge-RequiredRulesSettings -RequiredRules @() -GuardOut ([ref]$g) | Should -Be $null
        $g | Should -BeExactly 'not-needed'
    }

    It 'the merged settings text is deterministic -- fixed key order, LF line ends, nested tables in sorted key order' {
        # Rules, not RuleArguments, since dispatch 000306: the renderer writes only keys PSScriptAnalyzer accepts.
        $s = @{ IncludeRules = @('B', 'A'); Rules = @{ Zeta = @{ z = 1; a = 2 }; Alpha = @{ k = 'v' } } }
        $t1 = ConvertTo-MergedPssaSettingsText -Settings $s
        $t2 = ConvertTo-MergedPssaSettingsText -Settings $s
        $t2 | Should -BeExactly $t1
        $t1 | Should -Not -Match "`r"
        $t1.IndexOf('Alpha') | Should -BeLessThan $t1.IndexOf('Zeta')
    }

    It 'the merged file is CONTENT-ADDRESSED and VERIFIED: one name per text, a second write reuses it, another text gets another file' {
        $data = Join-Path $TestDrive ('mw-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $p1 = Write-MergedPssaSettingsFile -Settings @{ IncludeRules = @('A') } -DataRoot $data
        $p2 = Write-MergedPssaSettingsFile -Settings @{ IncludeRules = @('A') } -DataRoot $data
        $p3 = Write-MergedPssaSettingsFile -Settings @{ IncludeRules = @('B') } -DataRoot $data
        $p1 | Should -Not -BeNullOrEmpty
        $p2 | Should -BeExactly $p1
        $p3 | Should -Not -BeExactly $p1
        [System.IO.Path]::GetDirectoryName($p1) | Should -BeExactly (Get-MergedPssaSettingsDir -DataRoot $data)
        $sha = Get-Sha256HexFromBytes -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-MergedPssaSettingsText -Settings @{ IncludeRules = @('A') })))
        [System.IO.Path]::GetFileName($p1) | Should -BeExactly ('merged-settings-' + $sha.Substring(0, 16) + '.psd1')
        (Get-PolicyFileSha256 -Path $p1) | Should -BeExactly $sha -Because 'the bytes on disk are the bytes that were meant'
        (Import-PowerShellDataFile -LiteralPath $p1).IncludeRules | Should -Be @('A')
    }

    It 'a squatted target or a squatted settings directory makes the write FAIL (never a path to bytes that were not written)' {
        $data = Join-Path $TestDrive ('mws-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $settings = @{ IncludeRules = @('Squat') }
        $sha = Get-Sha256HexFromBytes -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-MergedPssaSettingsText -Settings $settings)))
        $target = Join-Path (Get-MergedPssaSettingsDir -DataRoot $data) ('merged-settings-' + $sha.Substring(0, 16) + '.psd1')
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Write-MergedPssaSettingsFile -Settings $settings -DataRoot $data | Should -BeExactly ''
        $data2 = Join-Path $TestDrive ('mwd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $data2 | Out-Null
        [System.IO.File]::WriteAllText((Get-MergedPssaSettingsDir -DataRoot $data2), 'a file where the directory must be')
        Write-MergedPssaSettingsFile -Settings $settings -DataRoot $data2 | Should -BeExactly ''
    }

    It 'a LOST RENAME is not a failed write: a concurrent writer''s identical file is accepted, a different one is not' {
        # The race, made deterministic: the first look reports no file (the other daemon has not renamed
        # yet), then this call's rename meets the file the other daemon put in place. Only that look is
        # mocked; the rename, the read-back and the temp cleanup are real.
        $settings = @{ IncludeRules = @('Race') }
        $sha = Get-Sha256HexFromBytes -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-MergedPssaSettingsText -Settings $settings)))
        $name = 'merged-settings-' + $sha.Substring(0, 16) + '.psd1'
        $data = Join-Path $TestDrive ('mwr-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $target = Join-Path (Get-MergedPssaSettingsDir -DataRoot $data) $name
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        [System.IO.File]::WriteAllText($target, (ConvertTo-MergedPssaSettingsText -Settings $settings), (New-Object System.Text.UTF8Encoding($false)))
        Mock Test-Path { $false } -ParameterFilter { $PathType -eq 'Leaf' -and [string]$LiteralPath -like ('*' + $name) }
        Write-MergedPssaSettingsFile -Settings $settings -DataRoot $data | Should -BeExactly $target
        Should -Invoke Test-Path -Times 1 -Exactly -ParameterFilter { $PathType -eq 'Leaf' -and [string]$LiteralPath -like ('*' + $name) } -Because 'the race must really have been staged'
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $target) -Filter '*.tmp').Count | Should -Be 0 -Because 'the losing writer''s temp file is removed'
        # The control: the same race against a file that does NOT hash to the intended text is refused.
        $data2 = Join-Path $TestDrive ('mwr-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $target2 = Join-Path (Get-MergedPssaSettingsDir -DataRoot $data2) $name
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target2) | Out-Null
        [System.IO.File]::WriteAllText($target2, '@{ IncludeRules = @(''NotTheIntendedText'') }')
        Write-MergedPssaSettingsFile -Settings $settings -DataRoot $data2 | Should -BeExactly '' -Because 'a path is returned only for the bytes this call meant to write'
    }

    It 'the daemon''s application record carries every observation it is given, and an unknown state reads pending' {
        $res = Resolve-EffectivePolicy -Path (New-EpPolicy "@{ RequiredRules = @('R') }")
        $ev = New-PolicyApplicationEvidence -Resolution $res -RequiredState 'activated' -RequiredCount 1 -GuardVerifiedFor 'v4.6.0' `
            -GuardObserved 'v4.6.0' -GuardResult 'pass' -MergedPath 'm' -MergedSha256 ('c' * 64) -SettingsPath 'm' -SettingsSource 'merged' `
            -SettingsSha256 ('c' * 64) -Delivered $true
        $ev.resolution.usable | Should -BeTrue
        $ev.resolution.effectiveSha256 | Should -BeExactly $res.identity.sha256
        $ev.requiredRules.state | Should -BeExactly 'activated'
        $ev.requiredRules.guard.observed | Should -BeExactly 'v4.6.0'
        $ev.settings.delivered | Should -BeTrue
        (New-PolicyApplicationEvidence -RequiredState 'made-up').requiredRules.state | Should -BeExactly 'pending'
        $copy = Copy-PolicyApplicationEvidence -Evidence $ev -SettingsSha256 ('d' * 64)
        $copy.settings.sha256 | Should -BeExactly ('d' * 64) -Because 'a scan-mode answer re-hashes the settings file at that analysis'
        $copy.requiredRules.mergedSettingsSha256 | Should -BeExactly ('c' * 64)
    }

    It 'the client''s adjudication record counts what the policy did to the findings it saw' {
        $recs = @(
            [pscustomobject]@{ code = 'PSAvoidUsingCmdletAliases'; severity = 'Warning' }
            [pscustomobject]@{ code = 'psavoidusingcmdletaliases'; severity = 'Warning' }
            [pscustomobject]@{ code = 'PSUseApprovedVerbs'; severity = 'Warning' }
        )
        Measure-PolicyOverrideHits -Records $recs -OrgSeverity @{ PSAvoidUsingCmdletAliases = 'Error' } | Should -Be 2
        Measure-PolicyOverrideHits -Records $recs -OrgSeverity @{} | Should -Be 0
        Measure-PolicyOverrideHits -Records $recs -OrgSeverity @{ PSAvoidUsingCmdletAliases = 'NotASeverity' } | Should -Be 0
        $ev = New-PolicyAdjudicationEvidence -Mode 'closed' -FailClosed $true -Dropped 3 -Restamped 2 -ProhibitedFlagged 1
        $ev.mode | Should -BeExactly 'closed'
        $ev.failClosed | Should -BeTrue
        $ev.dropped | Should -Be 3
        $ev.resolution.configured | Should -BeFalse
    }
}

Describe 'Receipt schema version 2 carries policy evidence -- and a receipt still certifies nothing (dispatch 000305 B1)' {

    BeforeAll {
        $script:RvSchemaText = [System.IO.File]::ReadAllText((Join-Path $script:EpRepo 'docs/scan-receipt.schema.json'))
        function New-RvReceipt {
            # A real file, its snapshot, the daemon binding and the client's receipt -- every record
            # built by the production builders. -WithEvidence carries both parties' policy records.
            param([switch]$WithEvidence)
            $file = Join-Path $TestDrive ('rv-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
            [System.IO.File]::WriteAllText($file, "function Get-RvThing {`n    param([string]`$Name)`n    Write-Output `$Name`n}`n")
            $full = [System.IO.Path]::GetFullPath($file)
            $snap = Read-ScanSourceSnapshot -Path $full
            $rid = New-ScanRequestId
            $res = Resolve-EffectivePolicy -Path (New-EpPolicy "@{ RequiredRules = @('PSAvoidGlobalVars') }")
            $daemon = New-PolicyApplicationEvidence -Resolution $res -RequiredState 'activated' -RequiredCount 1 -GuardVerifiedFor 'v4.6.0' `
                -GuardObserved 'v4.6.0' -GuardResult 'pass' -MergedPath 'C:\m.psd1' -MergedSha256 ('c' * 64) -SettingsPath 'C:\m.psd1' `
                -SettingsSource 'merged' -SettingsSha256 ('c' * 64) -Delivered $true
            $engine = [ordered]@{ pses = '4.6.0'; pssa = '1.25.0'; source = 'module-manifest'; daemonPlugin = '1.0.0'; daemonHost = 'Core 7'; psesHost = 'pwsh' }
            $binding = New-ScanAnalysisBinding -RequestId $rid -AnalyzedPath $full -Snapshot $snap -Settled $true -PssaAvailable $true `
                -Engine $engine -Policy $(if ($WithEvidence) { $daemon } else { $null })
            $client = New-PolicyAdjudicationEvidence -Resolution $res -Path 'p' -Mode 'closed'
            $receipt = New-ScanReceipt -RequestId $rid -File $full -Pass 'pssa' -Status 'ok' -Binding $binding -Records @() -FormatMode 'off' `
                -PolicyEvidence $(if ($WithEvidence) { $client } else { $null })
            return @{ Receipt = $receipt; Rid = $rid; Path = $full; Snap = $snap }
        }
        function Test-RvReceipt {
            param($Case)
            $rp = Join-Path $TestDrive ($Case.Rid + '.json')
            [System.IO.File]::WriteAllText($rp, ($Case.Receipt | ConvertTo-Json -Depth 10 -Compress))
            $child = [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; Killed = $false; Exited = $true }
            return (Test-ScanReceipt -Path $rp -RequestId $Case.Rid -FilePath $Case.Path -PreSnapshot $Case.Snap -PostSnapshot $Case.Snap -Child $child -Records @())
        }
    }

    It 'the schema version is 2, and a version-2 receipt WITHOUT evidence still reads policy unbound' {
        [int](Get-ScanReceiptSchema).Version | Should -Be 2
        $c = New-RvReceipt
        $c.Receipt.policy.state | Should -BeExactly 'unbound'
        $v = Test-RvReceipt -Case $c
        [string]$v.Completeness | Should -BeExactly 'complete'
        [string]$v.Certification.Policy | Should -BeExactly 'unbound'
    }

    It 'WITH evidence: policy is observed, both records ride verbatim, and completeness is untouched -- evidence is not a verdict' {
        $c = New-RvReceipt -WithEvidence
        $c.Receipt.policy.state | Should -BeExactly 'observed'
        $c.Receipt.policy.daemon.requiredRules.state | Should -BeExactly 'activated'
        $c.Receipt.policy.client.mode | Should -BeExactly 'closed'
        $v = Test-RvReceipt -Case $c
        [string]$v.Completeness | Should -BeExactly 'complete'
        [string]$v.Certification.Policy | Should -BeExactly 'observed'
        @($v.Problems).Count | Should -Be 0
    }

    It 'a receipt that claims its policy <State> is malformed, with evidence or without' -TestCases @(
        @{ State = 'verified' }
        @{ State = 'certified' }
    ) {
        param($State)
        $c = New-RvReceipt -WithEvidence
        $c.Receipt['policy']['state'] = $State
        $v = Test-RvReceipt -Case $c
        @($v.Reasons) | Should -Contain 'receipt-malformed'
    }

    It 'an evidence record of the wrong shape is malformed: <Name>' -TestCases @(
        @{ Name = 'usable as a string'; Mutate = { param($r) $r['policy']['client']['resolution']['usable'] = 'yes' } }
        @{ Name = 'a short identity'; Mutate = { param($r) $r['policy']['daemon']['resolution']['effectiveSha256'] = 'abc' } }
        @{ Name = 'a negative count'; Mutate = { param($r) $r['policy']['client']['dropped'] = -1 } }
        @{ Name = 'no settings record'; Mutate = { param($r) $r['policy']['daemon'].Remove('settings') } }
    ) {
        param($Name, $Mutate)
        $c = New-RvReceipt -WithEvidence
        & $Mutate $c.Receipt
        $v = Test-RvReceipt -Case $c
        @($v.Reasons) | Should -Contain 'receipt-malformed' -Because $Name
    }

    It 'with and without evidence, the producer''s receipt validates against docs/scan-receipt.schema.json' -Skip:$script:EpNoTestJson {
        foreach ($with in @($false, $true)) {
            $c = New-RvReceipt -WithEvidence:$with
            $json = $c.Receipt | ConvertTo-Json -Depth 10 -Compress
            (Test-Json -Json $json -Schema $script:RvSchemaText -ErrorAction SilentlyContinue) | Should -BeTrue -Because ('evidence=' + $with)
        }
    }
}

Describe 'The managed verdict, the mode precedence and the ambient refusal (dispatch 000305 B1)' {

    BeforeAll {
        $script:VdReq = Resolve-EffectivePolicy -Path (New-EpPolicy "@{ RequiredRules = @('PSAvoidGlobalVars'); ExcludeRules = @('PSUseApprovedVerbs') }") -Source 'cli'
        $script:VdExc = Resolve-EffectivePolicy -Path (New-EpPolicy "@{ ExcludeRules = @('PSUseApprovedVerbs') }") -Source 'cli'

        function New-VdReceipt {
            # A receipt as the scan reads it back (a JSON round trip), built by the production
            # builders, with exactly one fact changed per $Fault.
            param($Declared, [string]$Fault = '')
            $sha = [string]$Declared.identity.sha256
            $needs = ([string]$Declared.obligations.mergedSettings -eq 'required')
            $merged = ('c' * 64)
            $state = $(if ($needs) { 'activated' } else { 'not-required' })
            $source = $(if ($needs) { 'merged' } else { 'none' })
            $settingsSha = $(if ($needs) { $merged } else { '' })
            switch ($Fault) {
                'activation-unsupported' { $state = 'activation-unsupported' }
                'merge-write-failed' { $state = 'merge-write-failed' }
                'not-delivered' { $state = 'not-delivered' }
                'settings-changed' { $settingsSha = ('d' * 64) }
                'pending' { $state = 'pending' }
                'daemon-activated-unrequired' { $state = 'activated' }
            }
            # The settings verdict the daemon records since dispatch 000306: valid when it handed PSES a merged
            # file, none when it handed none (the B1b verdict cases are in PowerShellLsp.PolicySettings.Tests.ps1).
            $daemon = New-PolicyApplicationEvidence -RequiredState $state -RequiredCount 1 -GuardVerifiedFor 'v4.6.0' -GuardObserved 'v4.6.0' `
                -GuardResult 'pass' -MergedPath 'm' -MergedSha256 $(if ($needs) { $merged } else { '' }) -SettingsPath 'm' -SettingsSource $source `
                -SettingsSha256 $settingsSha -Delivered $needs -SettingsValidation $(if ($needs) { 'valid' } else { 'none' })
            $daemon.resolution = [ordered]@{ path = 'p'; configured = $true; usable = $true; reason = ''; effectiveSha256 = $(if ($Fault -eq 'daemon-disagreement') { 'e' * 64 } else { $sha }) }
            $client = New-PolicyAdjudicationEvidence -Mode 'closed'
            $client.resolution = [ordered]@{ path = 'p'; configured = $true; usable = ($Fault -ne 'client-unusable'); reason = ''; effectiveSha256 = $(if ($Fault -eq 'client-disagreement') { 'f' * 64 } else { $sha }) }
            $receipt = [ordered]@{
                engine = [ordered]@{ pses = $(if ($Fault -eq 'engine-unknown') { 'unknown' } else { '4.6.0' }); pssa = '1.25.0' }
                config = [ordered]@{ state = 'unbound'; observed = [ordered]@{ severityThreshold = $(if ($Fault -eq 'threshold-raised') { 'Warning' } else { 'Hint' }); ruleInclude = ''; ruleExclude = $(if ($Fault -eq 'config-narrowed') { 'X' } else { '' }); perFileCap = 0 } }
                policy = $(if ($Fault -eq 'no-evidence') { [ordered]@{ state = 'unbound' } } else { [ordered]@{ state = 'observed'; client = $client; daemon = $(if ($Fault -eq 'no-daemon-record') { $null } else { $daemon }) } })
            }
            return (($receipt | ConvertTo-Json -Depth 8) | ConvertFrom-Json)
        }
        function New-VdFile {
            param($Declared, [string]$Fault = '', [string]$Completeness = 'complete', [string]$Pass = 'pssa')
            return [pscustomobject]@{ File = 'C:\x.ps1'; Completeness = $Completeness; Pass = $Pass; Receipt = (New-VdReceipt -Declared $Declared -Fault $Fault) }
        }
    }

    It 'UNMANAGED (open): nothing is certified or refused -- the 1.x contract' {
        $c = Test-ScanPolicyCertification -Mode 'open' -Declared $null -Files @((New-VdFile -Declared $script:VdReq -Fault 'merge-write-failed'))
        $c.Managed | Should -BeFalse
        $c.Certified | Should -BeNullOrEmpty
        @($c.AllReasons).Count | Should -Be 0
    }

    It 'THE CONTROL: a usable declared policy with agreeing evidence from both parties certifies (<Name>)' -TestCases @(
        @{ Name = 'RequiredRules activated'; Key = 'VdReq' }
        @{ Name = 'no RequiredRules -- not-required is not failed'; Key = 'VdExc' }
    ) {
        param($Name, $Key)
        $decl = Get-Variable -Name $Key -Scope Script -ValueOnly
        $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $decl -Files @((New-VdFile -Declared $decl))
        $c.Managed | Should -BeTrue
        @($c.AllReasons) -join ',' | Should -BeExactly ''
        $c.Certified | Should -BeTrue
    }

    It 'RUN-LEVEL REFUSAL <Name> -> <Code>' -TestCases @(
        @{ Name = 'no declared policy (O03: refuse in managed only)'; Code = 'policy-not-declared'; Declared = 'none'; Ambient = @(); Suppression = 'not-required' }
        @{ Name = 'a missing declared policy'; Code = 'policy-file-missing'; Declared = 'missing'; Ambient = @(); Suppression = 'not-required' }
        @{ Name = 'a corrupt declared policy'; Code = 'policy-unreadable'; Declared = 'corrupt'; Ambient = @(); Suppression = 'not-required' }
        @{ Name = 'an ambient option reached the scan'; Code = 'config-ambient'; Declared = 'ok'; Ambient = @('CLAUDE_PLUGIN_OPTION_ruleExclude'); Suppression = 'not-required' }
        @{ Name = 'the suppression pass could not run'; Code = 'policy-suppression-pass-failed'; Declared = 'ok'; Ambient = @(); Suppression = 'failed' }
    ) {
        param($Name, $Code, $Declared, $Ambient, $Suppression)
        $decl = switch ($Declared) {
            'none' { $null }
            'missing' { Resolve-EffectivePolicy -Path (Join-Path $TestDrive 'nope.psd1') -Source 'cli' }
            'corrupt' { Resolve-EffectivePolicy -Path (New-EpPolicy '@{ ExcludeRules = @( no') -Source 'cli' }
            default { $script:VdExc }
        }
        $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $decl -Ambient $Ambient -SuppressionPass $Suppression `
            -Files @((New-VdFile -Declared $script:VdExc))
        $c.Certified | Should -BeFalse
        @($c.Reasons) | Should -Contain $Code
    }

    It 'PER-FILE REFUSAL <Fault> -> <Code>' -TestCases @(
        @{ Fault = 'activation-unsupported'; Code = 'policy-activation-unsupported'; Key = 'VdReq' }
        @{ Fault = 'merge-write-failed'; Code = 'policy-merge-write-failed'; Key = 'VdReq' }
        @{ Fault = 'not-delivered'; Code = 'policy-activation-not-delivered'; Key = 'VdReq' }
        @{ Fault = 'settings-changed'; Code = 'policy-activation-not-delivered'; Key = 'VdReq' }
        @{ Fault = 'pending'; Code = 'policy-evidence-missing'; Key = 'VdReq' }
        @{ Fault = 'daemon-disagreement'; Code = 'policy-disagreement'; Key = 'VdReq' }
        @{ Fault = 'client-disagreement'; Code = 'policy-disagreement'; Key = 'VdExc' }
        @{ Fault = 'client-unusable'; Code = 'policy-disagreement'; Key = 'VdExc' }
        @{ Fault = 'daemon-activated-unrequired'; Code = 'policy-disagreement'; Key = 'VdExc' }
        @{ Fault = 'no-evidence'; Code = 'policy-evidence-missing'; Key = 'VdExc' }
        @{ Fault = 'no-daemon-record'; Code = 'policy-evidence-missing'; Key = 'VdExc' }
        @{ Fault = 'engine-unknown'; Code = 'engine-unknown'; Key = 'VdExc' }
        @{ Fault = 'config-narrowed'; Code = 'config-observed-mismatch'; Key = 'VdExc' }
        # The severity-threshold boundary (a raised local threshold can hide a finding the policy wants)
        # is retained for UNMANAGED developer assistance only; a managed scan refuses it.
        @{ Fault = 'threshold-raised'; Code = 'config-observed-mismatch'; Key = 'VdReq' }
    ) {
        param($Fault, $Code, $Key)
        $decl = Get-Variable -Name $Key -Scope Script -ValueOnly
        $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $decl -Files @((New-VdFile -Declared $decl -Fault $Fault))
        $c.Certified | Should -BeFalse
        @($c.Files).Count | Should -Be 1
        @($c.Files[0].Reasons) | Should -Contain $Code
    }

    It 'a file whose analysis is not complete is never certified, whatever its evidence says' {
        $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $script:VdExc -Files @((New-VdFile -Declared $script:VdExc -Completeness 'partial' -Pass 'parser'))
        $c.Certified | Should -BeFalse
        @($c.AllReasons) | Should -Contain 'analysis-incomplete'
    }

    It 'NO FILE, NO PROOF: a managed verdict over zero files is analysis-empty, never certified; unmanaged is untouched' {
        foreach ($decl in @($script:VdReq, $script:VdExc)) {
            $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $decl
            $c.Certified | Should -BeFalse -Because 'O03 certifies only when proof the policy was applied is present'
            @($c.Reasons) -join ',' | Should -BeExactly 'analysis-empty' -Because 'a usable declared policy and no ambient option leave only the missing proof'
            $c2 = Test-ScanPolicyCertification -Mode 'closed' -Declared $decl -Files @($null)
            @($c2.Reasons) | Should -Contain 'analysis-empty' -Because 'a null entry is not an analyzed file'
        }
        (Test-ScanPolicyCertification -Mode 'closed' -Declared $null).Reasons -join ',' | Should -BeExactly 'analysis-empty,policy-not-declared'
        $open = Test-ScanPolicyCertification -Mode 'open' -Declared $script:VdReq
        $open.Managed | Should -BeFalse
        @($open.AllReasons).Count | Should -Be 0 -Because 'an unmanaged empty scan refuses nothing (exit 0, as always)'
    }

    It 'THE DAEMON''S PENDING RECORD is missing evidence, not a disagreement: <Key>' -TestCases @(
        @{ Key = 'VdReq' }
        @{ Key = 'VdExc' }
    ) {
        # The record the daemon starts with, exactly as it builds it (pses-daemon.ps1): it stays 'pending'
        # when Initialize-PssaSettings returns before resolving anything, and it carries no resolution.
        param($Key)
        $decl = Get-Variable -Name $Key -Scope Script -ValueOnly
        $pending = New-PolicyApplicationEvidence -Path 'C:\org.psd1' -RequiredState 'pending' -GuardVerifiedFor 'v4.6.0'
        $f = New-VdFile -Declared $decl
        $f.Receipt.policy.daemon = (($pending | ConvertTo-Json -Depth 8) | ConvertFrom-Json)
        $c = Test-ScanPolicyCertification -Mode 'closed' -Declared $decl -Files @($f)
        $c.Certified | Should -BeFalse
        @($c.Files[0].Reasons) -join ',' | Should -BeExactly 'policy-evidence-missing'
        # The control: the same record AFTER it resolved -- not-configured, i.e. a daemon launched with no
        # policy at all -- is a real disagreement with the declared one.
        $none = New-PolicyApplicationEvidence -Path '' -RequiredState 'not-configured' -GuardVerifiedFor 'v4.6.0'
        $f2 = New-VdFile -Declared $decl
        $f2.Receipt.policy.daemon = (($none | ConvertTo-Json -Depth 8) | ConvertFrom-Json)
        @((Test-ScanPolicyCertification -Mode 'closed' -Declared $decl -Files @($f2)).Files[0].Reasons) | Should -Contain 'policy-disagreement'
    }

    It 'every code the verdict can return is declared in the reason table' {
        $table = Get-PolicyReasonTable
        $src = [System.IO.File]::ReadAllText((Join-Path $script:EpRepo 'scripts/lib/lsp-policy.ps1'))
        $body = $src.Substring($src.IndexOf('function Test-ScanPolicyCertification'))
        $body = $body.Substring(0, $body.IndexOf('function New-ScanPolicyReport'))
        $codes = @([regex]::Matches($body, "Add\('([a-z-]+)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $codes.Count | Should -BeGreaterOrEqual 10 -Because 'a floor, so this census cannot pass by finding nothing'
        foreach ($c in $codes) { $table.Contains($c) | Should -BeTrue -Because ($c + ' is returned and must be declared') }
    }

    It 'MODE: managed ONLY on an explicit -PolicyMode closed -- POWERSHELL_LSP_POLICY_MODE never selects a managed scan (owner ruling Q03, dispatch 000306)' {
        $prev = $env:POWERSHELL_LSP_POLICY_MODE
        try {
            Remove-Item Env:\POWERSHELL_LSP_POLICY_MODE -ErrorAction SilentlyContinue
            (Resolve-ScanPolicyMode -Explicit '').resolved | Should -BeExactly 'open'
            (Resolve-ScanPolicyMode -Explicit '').source | Should -BeExactly 'default'
            $env:POWERSHELL_LSP_POLICY_MODE = 'closed'
            (Get-PolicyModeInfo).resolved | Should -BeExactly 'closed' -Because 'CONTROL: the variable is set and recognized -- it keeps its interactive fail-closed meaning'
            (Resolve-ScanPolicyMode -Explicit '').resolved | Should -BeExactly 'open' -Because 'B1 took the mode from the variable here, so every scan on such a host was managed'
            (Resolve-ScanPolicyMode -Explicit '').source | Should -BeExactly 'default'
            (Resolve-ScanPolicyMode -Explicit '').raw | Should -BeExactly 'closed' -Because 'the raw value is still reported, for the record'
            (Resolve-ScanPolicyMode -Explicit 'closed').resolved | Should -BeExactly 'closed'
            (Resolve-ScanPolicyMode -Explicit 'closed').source | Should -BeExactly 'cli'
            (Resolve-ScanPolicyMode -Explicit 'open').resolved | Should -BeExactly 'open'
            (Resolve-ScanPolicyMode -Explicit 'open').source | Should -BeExactly 'cli'
            Remove-Item Env:\POWERSHELL_LSP_POLICY_MODE -ErrorAction SilentlyContinue
            (Resolve-ScanPolicyMode -Explicit 'closed').resolved | Should -BeExactly 'closed'
        } finally {
            if ($null -eq $prev) { Remove-Item Env:\POWERSHELL_LSP_POLICY_MODE -ErrorAction SilentlyContinue } else { $env:POWERSHELL_LSP_POLICY_MODE = $prev }
        }
    }

    It 'AMBIENT OPTIONS: every spelling of an analysis knob is reported by NAME; contained or declared values are not' {
        $envd = @{
            'CLAUDE_PLUGIN_OPTION_RULE_EXCLUDE'      = 'PSUseApprovedVerbs'
            'CLAUDE_PLUGIN_OPTION_ruleInclude'       = 'X'
            'CLAUDE_PLUGIN_OPTION_PRO_FILE'          = 'strict'
            'CLAUDE_PLUGIN_OPTION_psHost'            = 'powershell'
            'CLAUDE_PLUGIN_OPTION_severityThreshold' = 'Hint'
            'CLAUDE_PLUGIN_OPTION_PER_FILE_CAP'      = '0'
            'CLAUDE_PLUGIN_OPTION_formatOnEdit'      = 'apply'
            'CLAUDE_PLUGIN_OPTION_enableStats'       = 'true'
            'CLAUDE_PLUGIN_OPTION_ORGPOLICY'         = 'C:\ambient.psd1'
            'POWERSHELL_LSP_CAPTURE_MODE'            = 'off'
            'PATH'                                   = 'x'
        }
        $declared = @(Get-ScanAmbientAnalysisOptions -Environment $envd -PolicyDeclared $true)
        ($declared -join ',') | Should -BeExactly 'CLAUDE_PLUGIN_OPTION_PRO_FILE,CLAUDE_PLUGIN_OPTION_RULE_EXCLUDE,CLAUDE_PLUGIN_OPTION_psHost,CLAUDE_PLUGIN_OPTION_ruleInclude'
        $undeclared = @(Get-ScanAmbientAnalysisOptions -Environment $envd -PolicyDeclared $false)
        $undeclared | Should -Contain 'CLAUDE_PLUGIN_OPTION_ORGPOLICY' -Because 'with no declared policy an ambient orgPolicy is not replaced, so it is ambient'
        @(Get-ScanAmbientAnalysisOptions -Environment @{ PATH = 'x' }).Count | Should -Be 0
    }

    It 'THE CARRIER: Set-ScanChildPolicy removes every orgPolicy spelling, sets the declared one, and sets the mode only when given' {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.EnvironmentVariables['CLAUDE_PLUGIN_OPTION_ORG_POLICY'] = 'C:\ambient-a.psd1'
        $psi.EnvironmentVariables['CLAUDE_PLUGIN_OPTION_orgpolicy'] = 'C:\ambient-b.psd1'
        $psi.EnvironmentVariables['CLAUDE_PLUGIN_OPTION_ruleExclude'] = 'kept'
        Set-ScanChildPolicy -StartInfo $psi -OrgPolicyPath 'C:\declared.psd1' -PolicyMode 'closed'
        $spellings = @(@($psi.EnvironmentVariables.Keys) | Where-Object { (([string]$_) -replace '_', '').ToLowerInvariant() -eq 'claudepluginoptionorgpolicy' })
        $spellings.Count | Should -Be 1 -Because 'exactly one spelling survives, so no enumeration order can pick an ambient one'
        $psi.EnvironmentVariables[[string]$spellings[0]] | Should -BeExactly 'C:\declared.psd1'
        $psi.EnvironmentVariables['POWERSHELL_LSP_POLICY_MODE'] | Should -BeExactly 'closed'
        $psi.EnvironmentVariables['CLAUDE_PLUGIN_OPTION_ruleExclude'] | Should -BeExactly 'kept' -Because 'B1 replaces only the policy; the declared child configuration is A3''s'
        $plain = New-Object System.Diagnostics.ProcessStartInfo
        $plain.EnvironmentVariables['CLAUDE_PLUGIN_OPTION_orgPolicy'] = 'C:\ambient.psd1'
        Set-ScanChildPolicy -StartInfo $plain -OrgPolicyPath '' -PolicyMode ''
        $plain.EnvironmentVariables['CLAUDE_PLUGIN_OPTION_orgPolicy'] | Should -BeExactly 'C:\ambient.psd1' -Because 'no declared policy: the unmanaged child is exactly what it was'
        $plain.EnvironmentVariables.ContainsKey('POWERSHELL_LSP_POLICY_MODE') | Should -BeFalse
    }
}

Describe 'The shipped CLI certifies only on agreeing evidence -- production-built policy evidence variants (dispatch 000305 B1)' -Skip:$script:EpUnsupported {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:PvHost = Resolve-PsHost 'pwsh'
        if ($null -eq $script:PvHost) { throw 'no PowerShell host (pwsh / powershell) to run the relocated CLI' }
        $script:PvRoots = New-Object System.Collections.ArrayList

        function Invoke-PvCase {
            # One end-to-end run of the RELOCATED shipped CLI, managed, over one target, with the
            # policy-evidence fake as its client. Hermetic: no CLAUDE_PLUGIN_OPTION_* / POWERSHELL_LSP_*
            # inherited, its own data root, the variant in a data file.
            # -EmptyTarget: the target holds no PowerShell file (one .txt), so the scan takes its
            # no-files branch and no client or daemon ever runs.
            param([string]$Variant, [string]$PolicyText, [string]$Mode = 'closed', [switch]$EmptyTarget)
            $root = New-SvTempRoot -Tag ('pv' + [guid]::NewGuid().ToString('N').Substring(0, 4)) -MintingFile 'tests/PowerShellLsp.EffectivePolicy.Tests.ps1'
            [void]$script:PvRoots.Add($root)
            $tree = New-SvCliTree -Root $root -ClientFixture 'pv-policy-variant.ps1'
            $src = Join-Path $root 'src'
            New-Item -ItemType Directory -Force -Path $src | Out-Null
            if ($EmptyTarget) {
                [System.IO.File]::WriteAllText((Join-Path $src 'notes.txt'), "not PowerShell`n")
            } else {
                [System.IO.File]::WriteAllText((Join-Path $src 'target.ps1'), "function Get-PvTarget {`n    param([string]`$Name)`n    Write-Output `$Name`n}`n", (New-Object System.Text.UTF8Encoding($false)))
            }
            $data = Join-Path $root 'data'
            New-Item -ItemType Directory -Force -Path $data | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $data 'pv-variant.txt'), $Variant)
            $policy = Join-Path $root 'policy.psd1'
            [System.IO.File]::WriteAllText($policy, $PolicyText + "`n")
            $sarifPath = Join-Path $root 'out.sarif'
            $run = Invoke-SvChildProcess -HostExe $script:PvHost -CapMs 180000 `
                -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tree.ScanScript, $src,
                    '-Format', 'sarif', '-OutputPath', $sarifPath, '-PsHost', $script:PvHost,
                    '-OrgPolicyPath', $policy, '-PolicyMode', $Mode) `
                -ExtraEnv @{ CLAUDE_PLUGIN_DATA = $data } -RemoveEnvPrefix @('CLAUDE_PLUGIN_OPTION_', 'POWERSHELL_LSP_')
            $text = Read-SvTextFile -Path $sarifPath
            $sarif = $null
            if (-not [string]::IsNullOrWhiteSpace($text)) { $sarif = $text | ConvertFrom-Json }
            $pol = $null
            if ($null -ne $sarif) {
                $inv = $sarif.runs[0].invocations[0]
                if ($null -ne $inv.PSObject.Properties['properties']) { $pol = $inv.properties.policy }
            }
            return @{ Run = $run; Sarif = $sarif; Policy = $pol; Marker = (Read-SvTextFile -Path (Join-Path $data 'fake-ran.txt')) }
        }
        $script:PvRequired = "@{ RequiredRules = @('PSAvoidGlobalVars'); ExcludeRules = @('PSUseApprovedVerbs') }"
        $script:PvExclude = "@{ ExcludeRules = @('PSUseApprovedVerbs') }"
    }

    AfterAll {
        foreach ($r in @($script:PvRoots)) { Remove-SvTempRoot -Path $r }
    }

    It 'THE CONTROL: agreeing evidence for a RequiredRules policy is CERTIFIED -- exit 0, executionSuccessful=true' {
        $c = Invoke-PvCase -Variant 'applied' -PolicyText $script:PvRequired
        $c.Marker | Should -BeExactly 'PV:applied' -Because 'the fake client must really have run'
        $c.Run.ExitCode | Should -Be 0 -Because ('stderr: ' + $c.Run.Err)
        [bool]$c.Sarif.runs[0].invocations[0].executionSuccessful | Should -BeTrue
        $c.Policy.certification | Should -BeExactly 'certified'
        $c.Policy.mode | Should -BeExactly 'closed'
        $c.Policy.modeSource | Should -BeExactly 'cli'
        $c.Run.Err | Should -Match 'CERTIFIED'
    }

    It 'the same control in OPEN mode reports the policy and certifies nothing (unmanaged)' {
        $c = Invoke-PvCase -Variant 'applied' -PolicyText $script:PvRequired -Mode 'open'
        $c.Run.ExitCode | Should -Be 0
        $c.Policy.certification | Should -BeExactly 'not-requested'
    }

    It 'VARIANT <Variant> is NOT CERTIFIED with <Code> -- exit 4, executionSuccessful=false' -TestCases @(
        @{ Variant = 'activation-unsupported'; Code = 'policy-activation-unsupported'; Policy = 'required' }
        @{ Variant = 'merge-write-failed'; Code = 'policy-merge-write-failed'; Policy = 'required' }
        @{ Variant = 'settings-changed'; Code = 'policy-activation-not-delivered'; Policy = 'required' }
        @{ Variant = 'daemon-disagreement'; Code = 'policy-disagreement'; Policy = 'exclude' }
        @{ Variant = 'client-disagreement'; Code = 'policy-disagreement'; Policy = 'exclude' }
        @{ Variant = 'no-evidence'; Code = 'policy-evidence-missing'; Policy = 'exclude' }
        @{ Variant = 'engine-unknown'; Code = 'engine-unknown'; Policy = 'exclude' }
        @{ Variant = 'config-narrowed'; Code = 'config-observed-mismatch'; Policy = 'exclude' }
        # dispatch 000306 (B1b): the daemon's settings verdict, and the terminal record of a throwing resolution.
        @{ Variant = 'settings-rejected'; Code = 'policy-settings-rejected'; Policy = 'exclude' }
        @{ Variant = 'settings-rejected'; Code = 'policy-settings-rejected'; Policy = 'required' }
        @{ Variant = 'settings-unresolved'; Code = 'policy-evidence-missing'; Policy = 'required' }
    ) {
        param($Variant, $Code, $Policy)
        $text = $(if ($Policy -eq 'required') { $script:PvRequired } else { $script:PvExclude })
        $c = Invoke-PvCase -Variant $Variant -PolicyText $text
        $c.Marker | Should -BeExactly ('PV:' + $Variant)
        $c.Run.ExitCode | Should -Be 4 -Because ('stderr: ' + $c.Run.Err)
        [bool]$c.Sarif.runs[0].invocations[0].executionSuccessful | Should -BeFalse
        $c.Policy.certification | Should -BeExactly 'not-certified'
        @($c.Policy.reasons) | Should -Contain $Code
        $c.Run.Err | Should -Match ([regex]::Escape($Code))
        $notes = @($c.Sarif.runs[0].invocations[0].toolExecutionNotifications | Where-Object { [string]$_.message.text -match 'NOT CERTIFIED' })
        @($notes | ForEach-Object { [string]$_.properties.reason }) | Should -Contain $Code
    }

    It 'a required ProhibitedSuppressions pass that cannot run (no vendored analyzer here) is a refused obligation' {
        $c = Invoke-PvCase -Variant 'applied' -PolicyText "@{ ProhibitedSuppressions = @('PSAvoidUsingPlainTextForPassword') }"
        $c.Run.ExitCode | Should -Be 4 -Because ('stderr: ' + $c.Run.Err)
        @($c.Policy.reasons) | Should -Contain 'policy-suppression-pass-failed'
        $c.Policy.suppressionPass | Should -BeExactly 'failed'
    }

    It 'AN EMPTY TARGET is NOT CERTIFIED in managed mode (analysis-empty, exit 4) and stays exit 0 unmanaged' {
        $m = Invoke-PvCase -Variant 'applied' -PolicyText $script:PvExclude -EmptyTarget
        $m.Marker | Should -BeNullOrEmpty -Because 'no client may have run: the target holds no PowerShell file'
        $m.Run.ExitCode | Should -Be 4 -Because ('stderr: ' + $m.Run.Err)
        [bool]$m.Sarif.runs[0].invocations[0].executionSuccessful | Should -BeFalse
        $m.Policy.certification | Should -BeExactly 'not-certified'
        @($m.Policy.reasons) -join ',' | Should -BeExactly 'analysis-empty'
        $m.Run.Err | Should -Match 'analysis-empty'
        $m.Run.Err | Should -Not -Match 'CERTIFIED --' -Because 'the certified line must never be printed for zero files'
        $o = Invoke-PvCase -Variant 'applied' -PolicyText $script:PvExclude -EmptyTarget -Mode 'open'
        $o.Run.ExitCode | Should -Be 0 -Because ('nothing to analyze is not a fault in an unmanaged scan; stderr: ' + $o.Run.Err)
        [bool]$o.Sarif.runs[0].invocations[0].executionSuccessful | Should -BeTrue
        $o.Policy.certification | Should -BeExactly 'not-requested'
    }
}

Describe 'Explicit -OrgPolicyPath drives the MAIN pass, with every ambient plugin variable cleared (dispatch 000305 B1)' -Skip:$script:EpUnsupported {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'Integration.Common.ps1')
        . (Join-Path $PSScriptRoot 'ScanHarness.Common.ps1')
        $script:MpScripts = Join-Path $script:EpRepo 'scripts'
        $script:MpScan = Join-Path $script:MpScripts 'lsp-scan.ps1'
        $script:MpHost = Resolve-PsHost 'pwsh'
        $script:MpData = if (-not [string]::IsNullOrWhiteSpace($env:PSLS_TEST_DATA_DIR)) { $env:PSLS_TEST_DATA_DIR } else { Join-Path ([System.IO.Path]::GetTempPath()) 'psls-sarifscan-test-data' }
        New-Item -ItemType Directory -Force -Path $script:MpData | Out-Null
        $prevData = $env:CLAUDE_PLUGIN_DATA
        $env:CLAUDE_PLUGIN_DATA = $script:MpData
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $script:MpHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:MpScripts 'ensure-pses.ps1') 2>&1 | Out-Null
            & $script:MpHost -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:MpScripts 'ensure-pssa.ps1') 2>&1 | Out-Null
        } finally { $ErrorActionPreference = $prevEap; $env:CLAUDE_PLUGIN_DATA = $prevData }

        # Fixtures under the shared data root (one directory per run), policies OUTSIDE the scanned trees.
        $script:MpWork = Join-Path $script:MpData ('b1-policy-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        function New-MpDir([string]$Name, [hashtable]$Files) {
            $d = Join-Path $script:MpWork $Name
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            foreach ($k in @($Files.Keys)) { [System.IO.File]::WriteAllText((Join-Path $d $k), [string]$Files[$k], (New-Object System.Text.UTF8Encoding($false))) }
            return $d
        }
        function New-MpPolicy([string]$Name, [string]$Text) {
            $p = Join-Path $script:MpWork ($Name + '.psd1')
            [System.IO.File]::WriteAllText($p, $Text + "`n", (New-Object System.Text.UTF8Encoding($false)))
            return $p
        }
        $aliasFile = "function Get-MpThing {`n    gci`n}`n"
        $script:MpReqDir = New-MpDir 'src-req' @{ 'thing.ps1' = "function Set-MpGlobal {`n    gci`n    `$global:MpThing = 1`n}`n" }
        $script:MpOvrDir = New-MpDir 'src-ovr' @{ 'thing.ps1' = $aliasFile }
        $script:MpExcDir = New-MpDir 'src-exc' @{ 'thing.ps1' = $aliasFile }
        $script:MpSupDir = New-MpDir 'src-sup' @{ 'suppressed.ps1' = "function Test-MpSuppressed {`n    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]`n    param(`$Password)`n    Write-Output `$Password`n}`n" }
        # The merge-write fixture carries its own repo-local settings with a rule name unique to this run
        # in IncludeRules (PSScriptAnalyzer matches an unknown name to nothing, measured), so its merged
        # settings text -- and so its content-addressed file name -- is this run's alone, and the squat
        # below cannot touch any other scan's merged file. Its IncludeRules is also what the unmanaged
        # fallback runs when the merge fails: the alias rule, never PSAvoidGlobalVars.
        $unique = 'PSB1Unique' + [guid]::NewGuid().ToString('N')
        $script:MpMwDir = New-MpDir 'src-mw' @{
            'thing.ps1'                     = "function Set-MpGlobal {`n    gci`n    `$global:MpThing = 1`n}`n"
            'PSScriptAnalyzerSettings.psd1' = "@{ IncludeRules = @('PSAvoidUsingCmdletAliases', '" + $unique + "') }`n"
        }
        $script:MpReqPolicy = New-MpPolicy 'required' "@{ RequiredRules = @('PSAvoidGlobalVars') }"
        $script:MpOvrPolicy = New-MpPolicy 'override' "@{ SeverityOverrides = @{ PSAvoidUsingCmdletAliases = 'Error' } }"
        $script:MpExcPolicy = New-MpPolicy 'exclude' "@{ ExcludeRules = @('PSAvoidUsingCmdletAliases') }"
        $script:MpSupPolicy = New-MpPolicy 'suppress' "@{ ProhibitedSuppressions = @('PSAvoidUsingPlainTextForPassword') }"
        $script:MpCorrupt = New-MpPolicy 'corrupt' '@{ ExcludeRules = @( this is not data'
        $script:MpMissing = Join-Path $script:MpWork 'missing.psd1'
        # The review's forged policy (finding B1-R01): ONE exclusion whose text carries an LF and a TAB, which
        # the pre-correction canonical text rendered as excluding PSUseApprovedVerbs AND requiring
        # PSAvoidGlobalVars -- a managed scan of it was CERTIFIED with that policy's identity.
        $script:MpForged = New-MpPolicy 'forged' ("@{ ExcludeRules = @('PSUseApprovedVerbs" + "`n" + 'require' + "`t" + "PSAvoidGlobalVars') }")

        # The squat: the EXACT content-addressed path the daemon will write for src-mw under the required
        # policy, computed with the production functions over the same inputs the daemon uses.
        $mwSettings = Resolve-PssaSettingsPath -EditedFilePath (Join-Path $script:MpMwDir 'thing.ps1') -ProjectRoot $script:MpMwDir
        $mwMerged = Merge-RequiredRulesSettings -ResolvedSettingsPath $mwSettings -RequiredRules @('PSAvoidGlobalVars') -CurrentPsesTag (Get-PssaDefaultRulesVerifiedForPsesTag)
        $mwSha = Get-Sha256HexFromBytes -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-MergedPssaSettingsText -Settings $mwMerged)))
        $script:MpSquat = Join-Path (Get-MergedPssaSettingsDir -DataRoot $script:MpData) ('merged-settings-' + $mwSha.Substring(0, 16) + '.psd1')
        New-Item -ItemType Directory -Force -Path $script:MpSquat | Out-Null

        function Invoke-MpScan {
            # The SHIPPED scan, in a child whose environment has every CLAUDE_PLUGIN_OPTION_* and
            # POWERSHELL_LSP_* removed; $Extra adds back exactly what a case stages.
            param([string]$Target, [string]$Policy = '', [string]$Mode = '', [hashtable]$Extra = @{})
            $out = Join-Path $script:MpWork ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.sarif')
            $args2 = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:MpScan, $Target, '-Format', 'sarif', '-OutputPath', $out)
            if ($Policy -ne '') { $args2 += @('-OrgPolicyPath', $Policy) }
            if ($Mode -ne '') { $args2 += @('-PolicyMode', $Mode) }
            $envx = @{ CLAUDE_PLUGIN_DATA = $script:MpData }
            foreach ($k in @($Extra.Keys)) { $envx[$k] = [string]$Extra[$k] }
            $run = Invoke-SvChildProcess -HostExe $script:MpHost -CapMs 300000 -ArgumentList $args2 -ExtraEnv $envx `
                -RemoveEnvPrefix @('CLAUDE_PLUGIN_OPTION_', 'POWERSHELL_LSP_')
            $text = Read-SvTextFile -Path $out
            $sarif = $null
            if (-not [string]::IsNullOrWhiteSpace($text)) { $sarif = $text | ConvertFrom-Json }
            $results = @()
            $pol = $null
            $inv = $null
            if ($null -ne $sarif) {
                $results = @(@($sarif.runs[0].results) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.ruleId + ':' + [string]$_.level })
                $inv = $sarif.runs[0].invocations[0]
                if ($null -ne $inv.PSObject.Properties['properties']) { $pol = $inv.properties.policy }
            }
            return @{ Exit = [int]$run.ExitCode; Err = [string]$run.Err; Sarif = $sarif; Text = $text; Results = $results; Policy = $pol; Invocation = $inv; TimedOut = [bool]$run.TimedOut }
        }

        # Every scan runs here, once, so each It reads a measured result.
        $script:Mp = @{}
        $script:Mp.BaseReq = Invoke-MpScan -Target $script:MpReqDir
        $script:Mp.BaseOvr = Invoke-MpScan -Target $script:MpOvrDir
        $script:Mp.BaseSup = Invoke-MpScan -Target $script:MpSupDir
        $script:Mp.Req = Invoke-MpScan -Target $script:MpReqDir -Policy $script:MpReqPolicy
        $script:Mp.Ovr = Invoke-MpScan -Target $script:MpOvrDir -Policy $script:MpOvrPolicy
        $script:Mp.Exc = Invoke-MpScan -Target $script:MpExcDir -Policy $script:MpExcPolicy
        $script:Mp.Sup = Invoke-MpScan -Target $script:MpSupDir -Policy $script:MpSupPolicy
        $script:Mp.ReqManaged = Invoke-MpScan -Target $script:MpReqDir -Policy $script:MpReqPolicy -Mode 'closed'
        $script:Mp.NotDeclared = Invoke-MpScan -Target $script:MpOvrDir -Mode 'closed'
        $script:Mp.Missing = Invoke-MpScan -Target $script:MpOvrDir -Policy $script:MpMissing -Mode 'closed'
        $script:Mp.MissingOpen = Invoke-MpScan -Target $script:MpOvrDir -Policy $script:MpMissing
        $script:Mp.Corrupt = Invoke-MpScan -Target $script:MpOvrDir -Policy $script:MpCorrupt -Mode 'closed'
        $script:Mp.MergeFail = Invoke-MpScan -Target $script:MpMwDir -Policy $script:MpReqPolicy -Mode 'closed'
        $script:Mp.MergeFailOpen = Invoke-MpScan -Target $script:MpMwDir -Policy $script:MpReqPolicy
        $script:Mp.Ambient = Invoke-MpScan -Target $script:MpExcDir -Policy $script:MpExcPolicy -Mode 'closed' -Extra @{ CLAUDE_PLUGIN_OPTION_ruleExclude = 'PSAvoidUsingWriteHost' }
        # POWERSHELL_LSP_POLICY_MODE=closed and no -PolicyMode (owner ruling Q03, dispatch 000306): unmanaged now,
        # with no declared policy and with one.
        $script:Mp.EnvClosed = Invoke-MpScan -Target $script:MpOvrDir -Extra @{ POWERSHELL_LSP_POLICY_MODE = 'closed' }
        $script:Mp.EnvClosedDeclared = Invoke-MpScan -Target $script:MpExcDir -Policy $script:MpExcPolicy -Extra @{ POWERSHELL_LSP_POLICY_MODE = 'closed' }
        $script:Mp.Forged = Invoke-MpScan -Target $script:MpReqDir -Policy $script:MpForged -Mode 'closed'

        # Doctor reads a RUNNING daemon's own record: a scan daemon under the required policy, one
        # scan-mode analysis (which resolves the session's settings), then the production observation.
        $script:MpDocSid = 'b1doc-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $env:CLAUDE_PLUGIN_DATA = $script:MpData
        $script:MpDocDaemon = $null
        $script:MpDocInfo = $null
        $script:MpDocRecord = $null
        $script:MpDocPendingInfo = $null
        try {
            $saved = Save-SvAmbientEnv
            try {
                $script:MpDocDaemon = Start-ScanDaemon -ScriptsDir $script:MpScripts -DataRoot $script:MpData -SessionId $script:MpDocSid `
                    -HostExe $script:MpHost -OrgPolicyPath $script:MpReqPolicy
                if ($null -ne $script:MpDocDaemon) {
                    . (Join-Path $script:MpScripts 'doctor.ps1')
                    # BEFORE the first analyzed file (review finding B1-I02): the daemon is ready and its record is
                    # still the 'pending' one it starts with -- its warm-start never resolves the session's
                    # settings -- so doctor must read it as not yet applied, never as a mismatch.
                    $env:CLAUDE_PLUGIN_OPTION_orgPolicy = $script:MpReqPolicy
                    $script:MpDocPendingInfo = Get-OrgPolicyEnforcementReportInfo -DaemonObservation (Get-DoctorDaemonObservation -SessionId $script:MpDocSid)
                    Remove-Item Env:\CLAUDE_PLUGIN_OPTION_orgPolicy -ErrorAction SilentlyContinue
                    [void](Invoke-ScanFileDiagnostics -ScriptsDir $script:MpScripts -DataRoot $script:MpData -SessionId $script:MpDocSid `
                        -HostExe $script:MpHost -FilePath (Join-Path $script:MpReqDir 'thing.ps1') -Cwd $script:MpReqDir -OrgPolicyPath $script:MpReqPolicy)
                    $sf = Join-Path $script:MpData ('session/' + $script:MpDocSid + '.json')
                    # The daemon rewrites its record on a 10 s heartbeat; 45 s spans several of them.
                    for ($i = 0; $i -lt 90; $i++) {
                        $rec = $null
                        try { $rec = (Get-Content -LiteralPath $sf -Raw) | ConvertFrom-Json } catch { $rec = $null }
                        if ($null -ne $rec -and $null -ne $rec.PSObject.Properties['policy'] -and [string]$rec.policy.requiredRules.state -ne 'pending') { $script:MpDocRecord = $rec; break }
                        Start-Sleep -Milliseconds 500
                    }
                    $obs = Get-DoctorDaemonObservation -SessionId $script:MpDocSid
                    $env:CLAUDE_PLUGIN_OPTION_orgPolicy = $script:MpReqPolicy
                    $script:MpDocInfo = Get-OrgPolicyEnforcementReportInfo -DaemonObservation $obs
                }
            } finally {
                Restore-SvAmbientEnv -Saved $saved
            }
        } finally {
            $env:CLAUDE_PLUGIN_DATA = $prevData
        }
    }

    AfterAll {
        if ($script:MpDocSid) {
            Stop-ScanDaemon -ScriptsDir $script:MpScripts -DataRoot $script:MpData -SessionId $script:MpDocSid -HostExe $script:MpHost -DaemonInfo $script:MpDocDaemon
        }
        if ($script:MpSquat -and (Test-Path -LiteralPath $script:MpSquat)) { Remove-Item -LiteralPath $script:MpSquat -Recurse -Force -ErrorAction SilentlyContinue }
        if ($script:MpWork -and (Test-Path -LiteralPath $script:MpWork)) { Remove-Item -LiteralPath $script:MpWork -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'every scan ran to its report (this Describe cannot pass vacuously)' {
        foreach ($k in @($script:Mp.Keys)) {
            $script:Mp[$k].TimedOut | Should -BeFalse -Because ($k + ' must finish')
            $script:Mp[$k].Sarif | Should -Not -BeNullOrEmpty -Because ($k + ' must write its SARIF; stderr: ' + $script:Mp[$k].Err)
        }
        $script:Mp.BaseReq.Results | Should -Contain 'PSAvoidUsingCmdletAliases:warning' -Because 'the warm analyzer really ran (the baseline finding)'
    }

    It 'REQUIRED RULE: PSAvoidGlobalVars is absent without the policy and reported with ONLY -OrgPolicyPath' {
        $script:Mp.BaseReq.Results | Should -Not -Contain 'PSAvoidGlobalVars:warning' -Because 'CONTROL: outside PSES''s default rule set'
        $script:Mp.Req.Exit | Should -Be 0
        $script:Mp.Req.Results | Should -Contain 'PSAvoidGlobalVars:warning'
        $script:Mp.Req.Results | Should -Contain 'PSAvoidUsingCmdletAliases:warning' -Because 'the merge keeps PSES''s own default rules'
    }

    It 'OVERRIDE: the alias finding is a warning without the policy and an error with ONLY -OrgPolicyPath' {
        $script:Mp.BaseOvr.Results | Should -Contain 'PSAvoidUsingCmdletAliases:warning'
        $script:Mp.Ovr.Exit | Should -Be 0
        $script:Mp.Ovr.Results | Should -Contain 'PSAvoidUsingCmdletAliases:error'
        $script:Mp.Ovr.Results | Should -Not -Contain 'PSAvoidUsingCmdletAliases:warning'
    }

    It 'EXCLUSION: the alias finding is reported without the policy and dropped with ONLY -OrgPolicyPath' {
        $script:Mp.Exc.Exit | Should -Be 0
        $script:Mp.Exc.Results | Should -Not -Contain 'PSAvoidUsingCmdletAliases:warning'
        @($script:Mp.Exc.Results).Count | Should -Be 0
    }

    It 'PROHIBITED SUPPRESSION: the edit-path finding AND the re-surfaced finding, with ONLY -OrgPolicyPath' {
        @($script:Mp.BaseSup.Results).Count | Should -Be 0 -Because 'CONTROL: the finding is suppressed in source'
        $script:Mp.Sup.Exit | Should -Be 0
        $script:Mp.Sup.Results | Should -Contain 'ProhibitedSuppression:warning' -Because 'the hook adjudication now runs in the scan (full main pass)'
        $script:Mp.Sup.Results | Should -Contain 'PSAvoidUsingPlainTextForPassword:warning' -Because 'the scan''s own re-surfacing pass, unchanged'
    }

    It 'the four unmanaged scans report the declared policy''s identity and certify nothing' {
        foreach ($k in @('Req', 'Ovr', 'Exc', 'Sup')) {
            $p = $script:Mp[$k].Policy
            $p | Should -Not -BeNullOrEmpty
            $p.certification | Should -BeExactly 'not-requested'
            [string]$p.effective.sha256 | Should -Match '^[0-9a-f]{64}$'
            [bool]$script:Mp[$k].Invocation.executionSuccessful | Should -BeTrue
        }
        $script:Mp.Req.Policy.effective.sha256 | Should -BeExactly ([string](Resolve-EffectivePolicy -Path $script:MpReqPolicy).identity.sha256)
    }

    It 'a scan with no policy and no managed mode carries no policy property at all (the unmanaged default is unchanged)' {
        $script:Mp.BaseReq.Policy | Should -BeNullOrEmpty
        $script:Mp.BaseReq.Invocation.PSObject.Properties['properties'] | Should -BeNullOrEmpty
    }

    It 'MANAGED CONTROL: the required-rule policy is CERTIFIED -- exit 0, every party''s evidence agreeing' {
        $m = $script:Mp.ReqManaged
        $m.Exit | Should -Be 0 -Because ('stderr: ' + $m.Err)
        [bool]$m.Invocation.executionSuccessful | Should -BeTrue
        $m.Policy.certification | Should -BeExactly 'certified'
        $m.Policy.obligations.mergedSettings | Should -BeExactly 'required'
        $m.Results | Should -Contain 'PSAvoidGlobalVars:warning'
        $m.Err | Should -Match 'CERTIFIED'
    }

    It 'MANAGED REFUSAL <Key> -> <Code>: exit 4, executionSuccessful=false, the reason named' -TestCases @(
        @{ Key = 'NotDeclared'; Code = 'policy-not-declared' }
        @{ Key = 'Missing'; Code = 'policy-file-missing' }
        @{ Key = 'Corrupt'; Code = 'policy-unreadable' }
        @{ Key = 'MergeFail'; Code = 'policy-merge-write-failed' }
        @{ Key = 'Ambient'; Code = 'config-ambient' }
    ) {
        param($Key, $Code)
        $m = $script:Mp[$Key]
        $m.Exit | Should -Be 4 -Because ('stderr: ' + $m.Err)
        [bool]$m.Invocation.executionSuccessful | Should -BeFalse
        $m.Policy.certification | Should -BeExactly 'not-certified'
        @($m.Policy.reasons) | Should -Contain $Code
        $m.Err | Should -Match 'NOT CERTIFIED'
    }

    It 'a failed merged-settings write is fail-OPEN in the unmanaged scan: exit 0, the required rule simply not active' {
        $script:Mp.MergeFailOpen.Exit | Should -Be 0 -Because ('stderr: ' + $script:Mp.MergeFailOpen.Err)
        $script:Mp.MergeFailOpen.Results | Should -Not -Contain 'PSAvoidGlobalVars:warning' -Because 'the squat made the write fail, so RequiredRules was not activated'
        $script:Mp.MergeFailOpen.Results | Should -Contain 'PSAvoidUsingCmdletAliases:warning'
        Test-Path -LiteralPath $script:MpSquat -PathType Container | Should -BeTrue -Because 'the squat was still in place, so the failure was the injected one'
    }

    It 'a missing policy in the unmanaged scan keeps today''s behavior: a warning, the findings, exit 0' {
        $script:Mp.MissingOpen.Exit | Should -Be 0
        $script:Mp.MissingOpen.Err | Should -Match 'orgPolicy file not found'
        $script:Mp.MissingOpen.Results | Should -Contain 'PSAvoidUsingCmdletAliases:warning'
    }

    It 'the policy-bearing SARIF -- certified, refused, unmanaged -- validates against the vendored SARIF 2.1.0 schema' -Skip:$script:EpNoTestJson {
        $schema = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'sarif/sarif-2.1.0.json'))
        foreach ($k in @('ReqManaged', 'Missing', 'MergeFail', 'Req', 'Sup')) {
            (Test-Json -Json $script:Mp[$k].Text -Schema $schema -ErrorAction SilentlyContinue) | Should -BeTrue -Because ($k + ': properties.policy and the NOT CERTIFIED notifications keep the SARIF ingestible')
        }
    }

    It 'POWERSHELL_LSP_POLICY_MODE=closed does NOT make a scan managed (owner ruling Q03, dispatch 000306): no policy, exit 0, the unmanaged SARIF' {
        # B1 read the variable as the scan's mode, so this scan was NOT CERTIFIED (policy-not-declared, exit 4) --
        # the shape /powershell-lsp:scan took on every host that set the variable for interactive fail-closed.
        $e = $script:Mp.EnvClosed
        $e.Exit | Should -Be 0 -Because ('stderr: ' + $e.Err)
        [bool]$e.Invocation.executionSuccessful | Should -BeTrue
        $e.Policy | Should -BeNullOrEmpty -Because 'an unmanaged scan without -OrgPolicyPath emits exactly what it always did'
        $e.Err | Should -Not -Match 'CERTIFIED'
        $e.Results | Should -Contain 'PSAvoidUsingCmdletAliases:warning'
    }

    It 'POWERSHELL_LSP_POLICY_MODE=closed with a declared policy and no -PolicyMode: unmanaged -- the policy applies, nothing is certified or refused' {
        $e = $script:Mp.EnvClosedDeclared
        $e.Exit | Should -Be 0 -Because ('stderr: ' + $e.Err)
        $e.Policy.mode | Should -BeExactly 'open'
        $e.Policy.modeSource | Should -BeExactly 'default'
        $e.Policy.certification | Should -BeExactly 'not-requested'
        @($e.Results).Count | Should -Be 0 -Because 'the declared exclusion still drives the main pass'
    }

    It 'FORGED RULE CODE end to end: the separator-injection policy is NOT CERTIFIED and presents no identity (review finding B1-R01)' {
        $m = $script:Mp.Forged
        $m.Exit | Should -Be 4 -Because ('stderr: ' + $m.Err)
        [bool]$m.Invocation.executionSuccessful | Should -BeFalse
        $m.Policy.certification | Should -BeExactly 'not-certified'
        @($m.Policy.reasons) | Should -Contain 'policy-unreadable'
        [string]$m.Policy.effective.sha256 | Should -BeExactly '' -Because 'the review measured this policy CERTIFIED as 937b69ab...646d'
        $m.Err | Should -Match 'not a rule name'
    }

    It 'DOCTOR before the first analyzed file: the daemon''s startup record reads not yet applied (pending), never a mismatch (review finding B1-I02)' {
        $script:MpDocDaemon | Should -Not -BeNullOrEmpty -Because 'the scan daemon must have come up'
        $script:MpDocPendingInfo | Should -Not -BeNullOrEmpty -Because 'doctor must have observed the daemon before its first analysis'
        $script:MpDocPendingInfo.applied | Should -BeTrue -Because 'the policy parses'
        $script:MpDocPendingInfo.effectiveSha256 | Should -Match '^[0-9a-f]{64}$'
        $script:MpDocPendingInfo.enforcement.state | Should -BeExactly 'not-observed'
        $script:MpDocPendingInfo.enforcement.reason | Should -BeExactly 'pending'
        $script:MpDocPendingInfo.enforcement.matchesParsed | Should -BeNullOrEmpty
        $script:MpDocPendingInfo.enforcement.daemonEffectiveSha256 | Should -BeExactly ''
    }

    It 'DOCTOR reads the running daemon''s own record: RequiredRules activated, the merged file it wrote, matching the parsed policy' {
        $script:MpDocDaemon | Should -Not -BeNullOrEmpty -Because 'the scan daemon must have come up'
        $script:MpDocRecord | Should -Not -BeNullOrEmpty -Because 'the session record must carry the policy record once settings resolved'
        [string]$script:MpDocRecord.policy.requiredRules.state | Should -BeExactly 'activated'
        [string]$script:MpDocRecord.policy.requiredRules.guard.result | Should -BeExactly 'pass'
        [string]$script:MpDocRecord.policy.requiredRules.guard.observed | Should -BeExactly (Get-PssaDefaultRulesVerifiedForPsesTag) -Because 'the guard compares the PSES version read from the manifest the daemon launches'
        $merged = [string]$script:MpDocRecord.policy.requiredRules.mergedSettingsPath
        (Get-PolicyFileSha256 -Path $merged) | Should -BeExactly ([string]$script:MpDocRecord.policy.requiredRules.mergedSettingsSha256)
        $script:MpDocInfo.applied | Should -BeTrue
        $script:MpDocInfo.enforcement.state | Should -BeExactly 'observed'
        $script:MpDocInfo.enforcement.matchesParsed | Should -BeTrue
        $script:MpDocInfo.enforcement.requiredRules | Should -BeExactly 'activated'
    }
}
