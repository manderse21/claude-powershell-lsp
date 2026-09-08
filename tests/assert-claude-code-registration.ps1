#Requires -Version 5.1

# assert-claude-code-registration.ps1 -- P1-3's registration half (dispatch 000287,
# ENTERPRISE-PROGRAM-DOCKET P1-3, review item 4; ruling R-G = Advisory).
#
# WHAT IT ASSERTS. Given the text a real Claude Code client printed for `claude plugin details
# powershell-lsp`, this asserts that THAT CLIENT actually registered this plugin's components:
# the three hooks, the LSP server, and every command the repository ships. The point is that the
# CLIENT is the one enumerating them -- reading our own manifest back to ourselves would prove
# only that the file we wrote is the file we wrote.
#
# WHY THE COMMAND SET IS DERIVED, NOT LISTED. A hard-coded list of expected components is a
# sample wearing a census's clothes: add a command and the list keeps passing while the claim in
# its own name goes false. Dispatch 000287 found exactly that shape in this repository's protocol
# handshake census on the same day, so the expected set here is read from `commands/*.md` on
# disk. Add a command and this asserts the client registered it, with no edit here.
#
# WHAT IT DELIBERATELY DOES NOT DO: write a `claudeCodeCompatibility` block into the manifest.
# The docket is explicit that "the declaration is the output ... written from what the matrix
# proved, never ahead of it", and docs/SUPPORT-POLICY.md refuses to declare an untested floor in
# so many words. This leg proves REGISTRATION. It does not prove that a diagnostic surfaces --
# that needs a live agent turn and therefore a credential -- so the declaration is not yet
# earned and is not written. See the outbox for the measured decomposition.
#
# Exit 0 = the client registered everything this repository ships. Exit 1 = it did not, named.
# Exit 3 = usage: the details output is missing or too short to be a real inventory.
#
# ASCII-only (PS 5.1 em-dash trap); StrictMode-safe.
#
# Author: Mike Andersen / powershell-lsp plugin.

[CmdletBinding()]
param(
    # The captured stdout of `claude plugin details powershell-lsp`.
    [Parameter(Mandatory = $true)]
    [string] $DetailsOutput,

    # The plugin root, used to derive the expected command set from disk.
    [string] $PluginRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $DetailsOutput -PathType Leaf)) {
    [Console]::Error.WriteLine("usage: -DetailsOutput '$DetailsOutput' does not exist")
    exit 3
}
$text = [System.IO.File]::ReadAllText($DetailsOutput)

# VACUITY GUARD, first and unconditional. Every assertion below is a substring test, and every
# substring test passes trivially against a plausible-looking short string -- an error banner, an
# empty capture, a usage message. If the client printed no inventory this must fail LOUDLY rather
# than report that nothing was missing from nothing.
if ($text.Length -lt 200 -or $text.IndexOf('Component inventory') -lt 0) {
    [Console]::Error.WriteLine('usage: the captured output carries no "Component inventory" section, so there is nothing to assert over.')
    [Console]::Error.WriteLine('--- captured output begins ---')
    [Console]::Error.WriteLine($text)
    [Console]::Error.WriteLine('--- captured output ends ---')
    exit 3
}

$failures = @()
$lines = @($text -split "`n")

function Get-InventoryLine {
    # THE SCOPE, and it is load-bearing. Every assertion below must be made against the inventory
    # line for its own component kind, NEVER against the whole document.
    #
    # This was found by its own RED control rather than reasoned out: with the `Skills (4)` line
    # deleted from a real capture, a whole-document substring search still found every command
    # name -- because the "Per-component" token-cost table further down the same output lists them
    # again. The assertion passed over an inventory that no longer enumerated a single command.
    # A check that locates by heading has to be anchored to that heading.
    param([string]$Prefix)
    foreach ($ln in $lines) {
        $t = $ln.Trim()
        if ($t.StartsWith($Prefix)) { return $t }
    }
    return ''
}

function Assert-InLine {
    param([string]$What, [string]$Line, [string]$Needle)
    # .Contains, never -like or -match: a needle carrying '[' opens a wildcard CHARACTER CLASS
    # under -like and a character class under -match, and the assertion then passes over nothing.
    # This repository has shipped that bug and caught it only by running a mutant.
    if ($Line.Contains($Needle)) {
        Write-Host ("OK      : {0} -- the client enumerated '{1}'" -f $What, $Needle)
        return
    }
    $script:failures += ("MISSING : {0} -- the client did not enumerate '{1}'" -f $What, $Needle)
}

# --- the hooks. The PostToolUse hook is the product; the other two are its lifecycle. ---------
$hookLine = Get-InventoryLine -Prefix 'Hooks ('
if ([string]::IsNullOrWhiteSpace($hookLine)) {
    $failures += 'MISSING : the inventory carries no "Hooks (" line at all.'
} else {
    foreach ($h in @('SessionStart', 'PostToolUse', 'SessionEnd')) {
        Assert-InLine -What 'hook' -Line $hookLine -Needle $h
    }
}

# --- the LSP server -----------------------------------------------------------------------
$lspLine = Get-InventoryLine -Prefix 'LSP servers ('
if ($lspLine -notmatch '^LSP servers \(([1-9][0-9]*)\)') {
    $failures += 'MISSING : the inventory does not report at least one LSP server.'
} else {
    Write-Host ("OK      : LSP server -- the client enumerated '{0}'" -f $lspLine)
}

# --- the commands, DERIVED from disk rather than listed here ------------------------------
$commandsDir = Join-Path $PluginRoot 'commands'
$expected = @()
if (Test-Path -LiteralPath $commandsDir) {
    $expected = @(Get-ChildItem -LiteralPath $commandsDir -Filter '*.md' -File |
            ForEach-Object { $_.BaseName } | Sort-Object)
}
if (@($expected).Count -eq 0) {
    $failures += 'DERIVATION: commands/ yielded no *.md, so the expected command set is empty and this check would pass over nothing.'
} else {
    Write-Host ("derived {0} expected command(s) from commands/: {1}" -f @($expected).Count, ($expected -join ', '))
    $skillLine = Get-InventoryLine -Prefix 'Skills ('
    if ([string]::IsNullOrWhiteSpace($skillLine)) {
        $failures += 'MISSING : the inventory carries no "Skills (" line at all.'
    } else {
        foreach ($c in $expected) {
            Assert-InLine -What 'command' -Line $skillLine -Needle $c
        }
        # The COUNT the client reports must equal the number this repository ships. Naming every
        # expected command proves none is missing; the count is what proves none is extra -- a
        # client registering a component we do not ship is drift in the other direction.
        if ($skillLine -match '^Skills \(([0-9]+)\)') {
            $reported = [int]$Matches[1]
            if ($reported -ne @($expected).Count) {
                $failures += ("COUNT   : the client reported {0} skill(s); commands/ ships {1}." -f $reported, @($expected).Count)
            } else {
                Write-Host ("OK      : count -- the client reported {0} skill(s), matching commands/" -f $reported)
            }
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    foreach ($f in $failures) { Write-Host $f }
    Write-Host ("claude-code registration FAILED: {0} problem(s)." -f $failures.Count)
    exit 1
}

Write-Host ''
Write-Host 'claude-code registration PASSED: the client enumerated every hook, the LSP server, and every shipped command.'
exit 0
