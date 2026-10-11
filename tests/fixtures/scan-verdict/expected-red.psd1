# expected-red.psd1 -- THE list of tests excluded from the normal runner because they were
# measured RED at the dispatch 000302 (A1) head. Data only.
#
#   tests/run-tests.ps1           excludes these Tags by default (-ExcludeTag);
#   tests/assert-expected-red.ps1 runs these Files in full in a fresh process and ACCEPTS only when
#                                 every Expected test fails with its declared assertion (Message, a
#                                 regex over the first error), no other test carries one of these
#                                 Tags, every untagged test in the Files passes, and nothing crashed;
#   PowerShellLsp.ScanVerdict.Tests.ps1 'Temporary RED exclusions are exactly the manifest' fails
#                                 if a RED tag sits anywhere these entries do not name.
#
# Each entry: File (the test file), Tag (the owner), Name (the It title as written, templates
# included), Path (Pester's ExpandedPath), Message (the declared failure), and optionally Hosts
# ('Core' / 'Desktop') for a test that is RED on one host only and SKIPPED on the other.
#
# REMOVING AN ENTRY is the owner's job and happens in the same change that turns the test green:
# remove the It's tag, remove the entry here, and -- once a tag has no entries left -- remove it
# from Tags and from run-tests.ps1's default. Never add an entry for a test that was not measured
# RED; never widen a Message to make a different failure fit.
#
# THE SPELLING CHANNEL (review RC01, correction round 2). The option resolver accepts any
# CLAUDE_PLUGIN_OPTION_* spelling that normalizes to a knob and takes the first non-blank one it
# enumerates; the scan's per-child overrides replace only the spelling they name. The entries under
# that heading below stage a hostile value under another such spelling and fail on the
# deterministic half -- the value reached the scan child -- so a containment that overrides or
# clears only the scan's own spelling cannot turn them green. Same-spelling cases are controls.
#
# CENSUS. At the A1 head after correction round 2: 54 entries -- 39 ScanRed-A2, 15 ScanRed-A3.
# Dispatch 000304 (A2) turned all 39 ScanRed-A2 tests green -- the completion receipt (F1) and
# formatter-off containment in every scan child, under every spelling of formatOnEdit (F2) -- and
# removed their tags, their entries and the ScanRed-A2 tag itself, in the same change. What remains
# is A3's: 15 entries, all in PowerShellLsp.ScanReadOnly.Tests.ps1, which is therefore the only
# file the oracle needs to run (PowerShellLsp.ScanVerdict.Tests.ps1 holds no RED test any more and
# runs in the normal suite).
#
# ASCII-only.

@{
    Files    = @(
        'PowerShellLsp.ScanReadOnly.Tests.ps1'
    )

    Tags     = @{
        'ScanRed-A3' = 'A3 -- declared read-only scan configuration (ambient ruleInclude / ruleExclude / profile / ps_host values never reach a scan child, and no ambient value reaches one under another spelling the option resolver accepts, whether or not the scan declares that knob -- perFileCap / severityThreshold / scopeToEdit / timeoutMs it does)'
    }

    Expected = @(
        # ---- F2, transport census: ambient analysis knobs and the ambient analysis host must not reach a scan child (A3)
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A3'
            Name = 'an ambient ruleInclude does not reach the scan session-start'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).daemon-side knobs reach the scan session-start.an ambient ruleInclude does not reach the scan session-start'
            Message = 'because F2 ruleInclude: an ambient include list must not narrow a scan, but they were different\..*But was:\s+''PSAvoidUsingCmdletAliases''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A3'
            Name = 'an ambient ruleExclude does not reach the scan session-start'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).daemon-side knobs reach the scan session-start.an ambient ruleExclude does not reach the scan session-start'
            Message = 'because F2 ruleExclude: an ambient exclude list must not narrow a scan, but they were different\..*But was:\s+''PSUseApprovedVerbs''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A3'
            Name = 'an ambient profile does not change the analysis defaults the scan session-start resolves'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).daemon-side knobs reach the scan session-start.an ambient profile does not change the analysis defaults the scan session-start resolves'
            Message = 'because F2 profile: an ambient profile must not change what a scan analyses, but they were different\..*But was:\s+''ruleset=base moduleAwareness=suggest referenceSurfacing=counts''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A3'
            Name = 'an ambient ps_host does not override the analysis host the scan declares'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).daemon-side knobs reach the scan session-start.an ambient ps_host does not override the analysis host the scan declares'
            Message = 'because F2 ps_host: an ambient ps_host must not move a scan onto another analysis host, but they were different\..*But was:\s+''powershell''' }

        # ---- F2, the spelling channel: a hostile value under another spelling the resolver accepts reaches the scan child (A3)
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A3'
            Name = 'an ambient CLAUDE_PLUGIN_OPTION_PER_FILE_CAP does not reach the scan session-start beside the declared cap of 0'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).other spellings of a knob reach the scan child.an ambient CLAUDE_PLUGIN_OPTION_PER_FILE_CAP does not reach the scan session-start beside the declared cap of 0'
            Message = 'because F2 perFileCap alias: an ambient cap must not reach a scan child under any spelling, but they were different\..*But was:\s+''CLAUDE_PLUGIN_OPTION_PER_FILE_CAP=1''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A3'
            Name = 'an ambient CLAUDE_PLUGIN_OPTION_SEVERITY_THRESHOLD does not reach the scan session-start beside the declared Hint'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).other spellings of a knob reach the scan child.an ambient CLAUDE_PLUGIN_OPTION_SEVERITY_THRESHOLD does not reach the scan session-start beside the declared Hint'
            Message = 'because F2 severityThreshold alias: an ambient threshold must not reach a scan child under any spelling, but they were different\..*But was:\s+''CLAUDE_PLUGIN_OPTION_SEVERITY_THRESHOLD=Error''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A3'
            Name = 'an ambient CLAUDE_PLUGIN_OPTION_RULE_INCLUDE does not reach the scan session-start'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).other spellings of a knob reach the scan child.an ambient CLAUDE_PLUGIN_OPTION_RULE_INCLUDE does not reach the scan session-start'
            Message = 'because F2 ruleInclude alias: an ambient include list must not reach a scan child under any spelling, but they were different\..*But was:\s+''CLAUDE_PLUGIN_OPTION_RULE_INCLUDE=PSAvoidUsingCmdletAliases''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A3'
            Name = 'an ambient CLAUDE_PLUGIN_OPTION_RULE_EXCLUDE does not reach the scan session-start'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).other spellings of a knob reach the scan child.an ambient CLAUDE_PLUGIN_OPTION_RULE_EXCLUDE does not reach the scan session-start'
            Message = 'because F2 ruleExclude alias: an ambient exclude list must not reach a scan child under any spelling, but they were different\..*But was:\s+''CLAUDE_PLUGIN_OPTION_RULE_EXCLUDE=PSUseApprovedVerbs''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A3'
            Name = 'an ambient CLAUDE_PLUGIN_OPTION_PRO_FILE does not reach the scan session-start'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).other spellings of a knob reach the scan child.an ambient CLAUDE_PLUGIN_OPTION_PRO_FILE does not reach the scan session-start'
            Message = 'because F2 profile alias: an ambient profile must not reach a scan child under any spelling, but they were different\..*But was:\s+''CLAUDE_PLUGIN_OPTION_PRO_FILE=strict''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A3'
            Name = 'an ambient CLAUDE_PLUGIN_OPTION_psHost does not reach the scan session-start'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).other spellings of a knob reach the scan child.an ambient CLAUDE_PLUGIN_OPTION_psHost does not reach the scan session-start'
            Message = 'because F2 ps_host alias: an ambient analysis host must not reach a scan child under any spelling, but they were different\..*But was:\s+''CLAUDE_PLUGIN_OPTION_psHost=powershell''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A3'
            Name = 'an ambient CLAUDE_PLUGIN_OPTION_SCOPE_TO_EDIT does not reach the scan client beside the declared false'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).other spellings of a knob reach the scan child.an ambient CLAUDE_PLUGIN_OPTION_SCOPE_TO_EDIT does not reach the scan client beside the declared false'
            Message = 'because F2 scopeToEdit alias: an ambient scoping value must not reach a scan child under any spelling, but they were different\..*But was:\s+''CLAUDE_PLUGIN_OPTION_SCOPE_TO_EDIT=true''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A3'
            Name = 'an ambient CLAUDE_PLUGIN_OPTION_TIMEOUT_MS does not reach the scan client beside the declared 18000'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).other spellings of a knob reach the scan child.an ambient CLAUDE_PLUGIN_OPTION_TIMEOUT_MS does not reach the scan client beside the declared 18000'
            Message = 'because F2 timeoutMs alias: an ambient client timeout must not reach a scan child under any spelling, but they were different\..*But was:\s+''CLAUDE_PLUGIN_OPTION_TIMEOUT_MS=1''' }
        # ---- F2, real daemon: hostile daemon-side configuration (A3)
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A3'
            Name = 'an ambient ruleExclude does not change the scan finding set'
            Path = 'Scan read-only integration with the real daemon and formatter (dispatch 000302 A1).hostile daemon-side configuration, each under its own real daemon.an ambient ruleExclude does not change the scan finding set'
            Message = 'because F2 hostile ruleExclude: an ambient exclude list must not narrow a scan, but they were different\..*But was:\s+''''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A3'
            Name = 'an ambient ruleInclude does not change the scan finding set'
            Path = 'Scan read-only integration with the real daemon and formatter (dispatch 000302 A1).hostile daemon-side configuration, each under its own real daemon.an ambient ruleInclude does not change the scan finding set'
            Message = 'because F2 hostile ruleInclude: an ambient include list must not narrow a scan, but they were different\..*But was:\s+''''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A3'
            Name = 'an ambient profile does not change the scan finding set'
            Path = 'Scan read-only integration with the real daemon and formatter (dispatch 000302 A1).hostile daemon-side configuration, each under its own real daemon.an ambient profile does not change the scan finding set'
            Message = 'because F2 hostile profile: an ambient profile must not change what a scan reports, but they were different\..*But was:\s+''PSAvoidUsingWriteHost@' }
    )
}
