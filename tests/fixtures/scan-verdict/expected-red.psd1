# expected-red.psd1 -- THE list of tests excluded from the normal runner because they were
# measured RED and are owned by the leg that fixes them. Data only.
#
#   tests/run-tests.ps1           excludes these Tags by default (-ExcludeTag);
#   tests/assert-expected-red.ps1 runs these Files in full in a fresh process and ACCEPTS only when
#                                 every Expected test fails with its declared assertion (Message, a
#                                 regex over the first error), no other test carries one of these
#                                 Tags, every untagged test in the Files passes, and nothing crashed.
#                                 A manifest that declares nothing -- no File, no Tag, no entry -- is
#                                 accepted as it is: nothing is expected RED, and no test is run;
#   PowerShellLsp.ScanVerdict.Tests.ps1 'Temporary RED exclusions are exactly the manifest' fails
#                                 if a RED tag -- one these entries name, or any ScanRed-* tag -- sits
#                                 anywhere these entries do not name.
#
# Each entry: File (the test file), Tag (the owner), Name (the It title as written, templates
# included), Path (Pester's ExpandedPath), Message (the declared failure), and optionally Hosts
# ('Core' / 'Desktop') for a test that is RED on one host only and SKIPPED on the other.
#
# REMOVING AN ENTRY is the owner's job and happens in the same change that turns the test green:
# remove the It's tag, remove the entry here, and -- once a tag has no entries left -- remove it
# from Tags and from run-tests.ps1's default, and a File no entry names from Files. Never add an
# entry for a test that was not measured RED; never widen a Message to make a different failure fit.
#
# CENSUS. Dispatch 000302 (A1) measured 54 tests RED and listed them here: 39 ScanRed-A2 and 15
# ScanRed-A3. Dispatch 000304 (A2) turned the 39 ScanRed-A2 tests green -- the completion receipt and
# formatter-off containment -- and retired that tag. Dispatch 000314 (ER2) turned the 15 ScanRed-A3
# tests green -- a scan declares its children's configuration: every spelling of perFileCap,
# severityThreshold, scopeToEdit, timeoutMs, profile, ps_host, ruleInclude and ruleExclude is removed
# from every scan child and the scan's own values are set (Set-ScanChildDeclaredOptions,
# scripts/lib/lsp-scan-common.ps1) -- and retired that tag, its entries and its file in the same change.
# Nothing is expected RED now, and the normal runner excludes no test.
#
# ASCII-only.

@{
    Files    = @()

    Tags     = @{}

    Expected = @()
}
