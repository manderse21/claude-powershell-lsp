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
# ASCII-only.

@{
    Files    = @(
        'PowerShellLsp.ScanVerdict.Tests.ps1'
        'PowerShellLsp.ScanReadOnly.Tests.ps1'
    )

    Tags     = @{
        'ScanRed-A2' = 'A2 -- typed scan completion receipt (a scan reports a file analyzed only on positive evidence of completion, both child streams drained, a timed-out child terminated) and narrow formatter-off containment (formatting off in every scan child)'
        'ScanRed-A3' = 'A3 -- declared read-only scan configuration (ambient ruleInclude / ruleExclude / profile / ps_host values never reach a scan child)'
    }

    Expected = @(
        # ---- F1, helper boundary (fake children through the production Invoke-ScanFileDiagnostics)
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'S1 verdict -- a child that ends silently is NOT reported analyzed'
            Path = 'Scan verdict census at the helper boundary (dispatch 000302 A1).S1 silent exit 0.S1 verdict -- a child that ends silently is NOT reported analyzed'
            Message = 'because S1 verdict: a silent exit 0 is not evidence that analysis completed, but got \$true' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'S2 verdict -- a child that exits nonzero is NOT reported analyzed'
            Path = 'Scan verdict census at the helper boundary (dispatch 000302 A1).S2 nonzero exit.S2 verdict -- a child that exits nonzero is NOT reported analyzed'
            Message = 'because S2 verdict: a nonzero exit means the analysis host failed, but got \$true' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'S3 verdict -- a child that reports a failure only on stderr is NOT reported analyzed'
            Path = 'Scan verdict census at the helper boundary (dispatch 000302 A1).S3 stderr-only error.S3 verdict -- a child that reports a failure only on stderr is NOT reported analyzed'
            Message = 'because S3 verdict: the failure the child reported on stderr was discarded, but got \$true' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'S3b verdict -- a child that floods stderr and exits is not held to the cap by an undrained pipe'
            Path = 'Scan verdict census at the helper boundary (dispatch 000302 A1).S3b stderr flood.S3b verdict -- a child that floods stderr and exits is not held to the cap by an undrained pipe'
            Message = 'to be less than 6000, because S3b verdict: stderr must be drained concurrently so a finished child can exit, but got \d+' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'S4 verdict -- a child whose response cannot be parsed is NOT reported analyzed'
            Path = 'Scan verdict census at the helper boundary (dispatch 000302 A1).S4 malformed response.S4 verdict -- a child whose response cannot be parsed is NOT reported analyzed'
            Message = 'because S4 verdict: an unparseable response is not a verdict, but got \$true' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'S5 verdict -- a truncated record stream is NOT reported analyzed'
            Path = 'Scan verdict census at the helper boundary (dispatch 000302 A1).S5 truncated completion.S5 verdict -- a truncated record stream is NOT reported analyzed'
            Message = 'because S5 verdict: a partial finding set must not read as a complete one, but got \$true' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'S5m verdict -- findings announced but never recorded are NOT reported analyzed'
            Path = 'Scan verdict census at the helper boundary (dispatch 000302 A1).S5m missing completion records.S5m verdict -- findings announced but never recorded are NOT reported analyzed'
            Message = 'because S5m verdict: a missing record stream must not read as zero findings, but got \$true' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'S6 verdict -- a daemon ok=false answer is NOT reported analyzed'
            Path = 'Scan verdict census at the helper boundary (dispatch 000302 A1).S6 daemon ok=false.S6 verdict -- a daemon ok=false answer is NOT reported analyzed'
            Message = 'because S6 verdict: the daemon refused the analysis, but got \$true' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'; Hosts = @('Desktop')
            Name = 'S7b on a Windows PowerShell 5.1 parent -- the cap kill terminates the timed-out child'
            Path = 'Scan verdict census at the helper boundary (dispatch 000302 A1).S7 deadline kill.S7b on a Windows PowerShell 5.1 parent -- the cap kill terminates the timed-out child'
            Message = 'because S7b verdict: a timed-out child must not outlive the cap kill, but got \$true' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'S8 verdict -- a source that disappeared before analysis is NOT reported analyzed'
            Path = 'Scan verdict census at the helper boundary (dispatch 000302 A1).S8 source disappearance.S8 verdict -- a source that disappeared before analysis is NOT reported analyzed'
            Message = 'because S8 verdict: a file that was never read was never analyzed, but got \$true' }

        # ---- F1, the real client reaches the same situations
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'R8 verdict -- the real client on a vanished source is NOT reported analyzed'
            Path = 'Scan verdict reachability through the real client (dispatch 000302 A1).R8 the real client meets a vanished source file.R8 verdict -- the real client on a vanished source is NOT reported analyzed'
            Message = 'because R8 verdict: the real client analysed nothing and said so only in its own log, but got \$true' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'R2 verdict -- a client the host could not even load is NOT reported analyzed'
            Path = 'Scan verdict reachability through the real client (dispatch 000302 A1).R2 the analysis host cannot run the client script.R2 verdict -- a client the host could not even load is NOT reported analyzed'
            Message = 'because R2 verdict: the analysis host failed before the client ran, but got \$true' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'R6 verdict -- the real client on a daemon ok=false answer is NOT reported analyzed'
            Path = 'Scan verdict reachability through the real client (dispatch 000302 A1).R6 the real client gets a daemon ok=false answer.R6 verdict -- the real client on a daemon ok=false answer is NOT reported analyzed'
            Message = 'because R6 verdict: the daemon refused the analysis, but got \$true' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'R4 verdict -- the real client on a malformed daemon answer is NOT reported analyzed'
            Path = 'Scan verdict reachability through the real client (dispatch 000302 A1).R4 the real client gets a wrong-typed daemon answer.R4 verdict -- the real client on a malformed daemon answer is NOT reported analyzed'
            Message = 'because R4 verdict: the client crashed before rendering any verdict, but got \$true' }

        # ---- F1, the shipped CLI (relocated byte-for-byte beside fake hooks)
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'C-S1 verdict -- a silent child makes the CLI exit 4 with executionSuccessful=false'
            Path = 'Scan verdict at the CLI boundary with the shipped lsp-scan relocated beside fake hooks (dispatch 000302 A1).C-S1 verdict -- a silent child makes the CLI exit 4 with executionSuccessful=false'
            Message = 'because C-S1 verdict: an unanalyzed file must make the scan INCOMPLETE, but they were different\..*But was:\s+''exit=0 executionSuccessful=True''' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'C-S2 verdict -- a nonzero child makes the CLI exit 4 with executionSuccessful=false'
            Path = 'Scan verdict at the CLI boundary with the shipped lsp-scan relocated beside fake hooks (dispatch 000302 A1).C-S2 verdict -- a nonzero child makes the CLI exit 4 with executionSuccessful=false'
            Message = 'because C-S2 verdict: an unanalyzed file must make the scan INCOMPLETE, but they were different\..*But was:\s+''exit=0 executionSuccessful=True''' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'C-S3 verdict -- a stderr-only child makes the CLI exit 4 with executionSuccessful=false'
            Path = 'Scan verdict at the CLI boundary with the shipped lsp-scan relocated beside fake hooks (dispatch 000302 A1).C-S3 verdict -- a stderr-only child makes the CLI exit 4 with executionSuccessful=false'
            Message = 'because C-S3 verdict: an unanalyzed file must make the scan INCOMPLETE, but they were different\..*But was:\s+''exit=0 executionSuccessful=True''' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'C-S4 verdict -- a malformed child response makes the CLI exit 4 with executionSuccessful=false'
            Path = 'Scan verdict at the CLI boundary with the shipped lsp-scan relocated beside fake hooks (dispatch 000302 A1).C-S4 verdict -- a malformed child response makes the CLI exit 4 with executionSuccessful=false'
            Message = 'because C-S4 verdict: an unanalyzed file must make the scan INCOMPLETE, but they were different\..*But was:\s+''exit=0 executionSuccessful=True''' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'C-S5 verdict -- a truncated record stream makes the CLI exit 4 with executionSuccessful=false'
            Path = 'Scan verdict at the CLI boundary with the shipped lsp-scan relocated beside fake hooks (dispatch 000302 A1).C-S5 verdict -- a truncated record stream makes the CLI exit 4 with executionSuccessful=false'
            Message = 'because C-S5 verdict: an unanalyzed file must make the scan INCOMPLETE, but they were different\..*But was:\s+''exit=0 executionSuccessful=True''' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'C-S5m verdict -- missing records make the CLI exit 4 with executionSuccessful=false'
            Path = 'Scan verdict at the CLI boundary with the shipped lsp-scan relocated beside fake hooks (dispatch 000302 A1).C-S5m verdict -- missing records make the CLI exit 4 with executionSuccessful=false'
            Message = 'because C-S5m verdict: an unanalyzed file must make the scan INCOMPLETE, but they were different\..*But was:\s+''exit=0 executionSuccessful=True''' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'C-S6 verdict -- a daemon ok=false child makes the CLI exit 4 with executionSuccessful=false'
            Path = 'Scan verdict at the CLI boundary with the shipped lsp-scan relocated beside fake hooks (dispatch 000302 A1).C-S6 verdict -- a daemon ok=false child makes the CLI exit 4 with executionSuccessful=false'
            Message = 'because C-S6 verdict: an unanalyzed file must make the scan INCOMPLETE, but they were different\..*But was:\s+''exit=0 executionSuccessful=True''' }
        @{ File = 'PowerShellLsp.ScanVerdict.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'C-S8 verdict -- a vanished source makes the CLI exit 4 with executionSuccessful=false'
            Path = 'Scan verdict at the CLI boundary with the shipped lsp-scan relocated beside fake hooks (dispatch 000302 A1).C-S8 verdict -- a vanished source makes the CLI exit 4 with executionSuccessful=false'
            Message = 'because C-S8 verdict: an unanalyzed file must make the scan INCOMPLETE, but they were different\..*But was:\s+''exit=0 executionSuccessful=True''' }

        # ---- F2, transport census (recording fakes): formatting must be off in every scan child (A2)
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan client resolves formatting off'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).formatOnEdit and profile reach the scan client.formatOnEdit=suggest under profile safe -- the scan client resolves formatting off'
            Message = 'because F2 format safe/suggest: a scan child must never format, but they were different\..*But was:\s+''suggest''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan client resolves formatting off'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).formatOnEdit and profile reach the scan client.formatOnEdit=apply under profile safe -- the scan client resolves formatting off'
            Message = 'because F2 format safe/apply: a scan child must never format, but they were different\..*But was:\s+''apply''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan client resolves formatting off'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).formatOnEdit and profile reach the scan client.formatOnEdit=unset under profile recommended -- the scan client resolves formatting off'
            Message = 'because F2 format recommended/unset: a scan child must never format, but they were different\..*But was:\s+''suggest''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan client resolves formatting off'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).formatOnEdit and profile reach the scan client.formatOnEdit=suggest under profile recommended -- the scan client resolves formatting off'
            Message = 'because F2 format recommended/suggest: a scan child must never format, but they were different\..*But was:\s+''suggest''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan client resolves formatting off'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).formatOnEdit and profile reach the scan client.formatOnEdit=apply under profile recommended -- the scan client resolves formatting off'
            Message = 'because F2 format recommended/apply: a scan child must never format, but they were different\..*But was:\s+''apply''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan client resolves formatting off'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).formatOnEdit and profile reach the scan client.formatOnEdit=unset under profile strict -- the scan client resolves formatting off'
            Message = 'because F2 format strict/unset: a scan child must never format, but they were different\..*But was:\s+''suggest''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan client resolves formatting off'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).formatOnEdit and profile reach the scan client.formatOnEdit=suggest under profile strict -- the scan client resolves formatting off'
            Message = 'because F2 format strict/suggest: a scan child must never format, but they were different\..*But was:\s+''suggest''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan client resolves formatting off'
            Path = 'Scan read-only census of the configuration a scan child receives (dispatch 000302 A1).formatOnEdit and profile reach the scan client.formatOnEdit=apply under profile strict -- the scan client resolves formatting off'
            Message = 'because F2 format strict/apply: a scan child must never format, but they were different\..*But was:\s+''apply''' }

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

        # ---- F2, real daemon + formatter: an apply-mode scan rewrites the source and loses its findings (A2)
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan leaves the source bytes unchanged'
            Path = 'Scan read-only integration with the real daemon and formatter (dispatch 000302 A1).formatOnEdit=apply under profile safe -- the scan leaves the source bytes unchanged'
            Message = 'because F2 bytes safe/apply: a scan must never write a source file, but they were different\.' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan leaves the source bytes unchanged'
            Path = 'Scan read-only integration with the real daemon and formatter (dispatch 000302 A1).formatOnEdit=apply under profile recommended -- the scan leaves the source bytes unchanged'
            Message = 'because F2 bytes recommended/apply: a scan must never write a source file, but they were different\.' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan leaves the source bytes unchanged'
            Path = 'Scan read-only integration with the real daemon and formatter (dispatch 000302 A1).formatOnEdit=apply under profile strict -- the scan leaves the source bytes unchanged'
            Message = 'because F2 bytes strict/apply: a scan must never write a source file, but they were different\.' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan reports the clean-environment finding set'
            Path = 'Scan read-only integration with the real daemon and formatter (dispatch 000302 A1).formatOnEdit=apply under profile safe -- the scan reports the clean-environment finding set'
            Message = 'because F2 findings safe/apply: equivalent declared inputs must give the same findings, but they were different\..*But was:\s+''''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan reports the clean-environment finding set'
            Path = 'Scan read-only integration with the real daemon and formatter (dispatch 000302 A1).formatOnEdit=apply under profile recommended -- the scan reports the clean-environment finding set'
            Message = 'because F2 findings recommended/apply: equivalent declared inputs must give the same findings, but they were different\..*But was:\s+''''' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'formatOnEdit=<Mode> under profile <ProfileName> -- the scan reports the clean-environment finding set'
            Path = 'Scan read-only integration with the real daemon and formatter (dispatch 000302 A1).formatOnEdit=apply under profile strict -- the scan reports the clean-environment finding set'
            Message = 'because F2 findings strict/apply: equivalent declared inputs must give the same findings, but they were different\..*But was:\s+''''' }

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

        # ---- F2, the shipped CLI end to end with formatOnEdit=apply in its environment (A2)
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'the CLI scan leaves the source bytes unchanged with formatOnEdit=apply in its environment'
            Path = 'Scan read-only integration with the real daemon and formatter (dispatch 000302 A1).the shipped CLI end to end with formatOnEdit=apply left in its environment.the CLI scan leaves the source bytes unchanged with formatOnEdit=apply in its environment'
            Message = 'because F2 CLI bytes: a scan must never write a source file \(the CLI reported exit=0 executionSuccessful=True\), but they were different\.' }
        @{ File = 'PowerShellLsp.ScanReadOnly.Tests.ps1'; Tag = 'ScanRed-A2'
            Name = 'the CLI scan reports the clean-environment finding set with formatOnEdit=apply in its environment'
            Path = 'Scan read-only integration with the real daemon and formatter (dispatch 000302 A1).the shipped CLI end to end with formatOnEdit=apply left in its environment.the CLI scan reports the clean-environment finding set with formatOnEdit=apply in its environment'
            Message = 'because F2 CLI findings: an ambient formatOnEdit must not change what a scan reports \(the CLI reported exit=0 executionSuccessful=True\), but they were different\..*But was:\s+''''' }
    )
}
