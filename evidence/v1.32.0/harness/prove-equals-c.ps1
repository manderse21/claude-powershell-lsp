#Requires -Version 5.1
# prove-equals-c.ps1 -- prove the staged plugin SCRIPT tree under CLAUDE_PLUGIN_ROOT
# is byte-identical to release-identity commit C.
#
# Dispatch 000267 (freeze 1B). ASCII only.
#
# METHOD. `git archive C` emits each blob's literal bytes. So "staged tree ==
# git archive of C" is proven here by computing, from the bytes on disk, each
# file's git object id with `git hash-object --no-filters` (no EOL / smudge
# filtering: the literal bytes are hashed) and requiring it to equal the blob id
# recorded in C's own tree. This is stronger than diffing against a second
# extraction of the same tar, because it never compares the staging to itself --
# the reference is git's content-addressed tree of C.
#
# SCOPE, and the two things deliberately outside it:
#
#   1. CLAUDE_PLUGIN_DATA is EXCLUDED. It is a sibling of CLAUDE_PLUGIN_ROOT,
#      never a descendant, which is ASSERTED below rather than assumed.
#
#   2. A file that is UNTRACKED AT C AND IGNORED BY C's OWN .gitignore is a
#      measurement byproduct, not a script-tree change. At C the shipped default
#      for the dogfood capture log is <plugin-root>/dogfood/diagnostics.jsonl
#      (lsp-common.ps1 Get-DogfoodLogPath, precedence item 2), which .gitignore
#      at C covers with `/dogfood/`. So measurement DOES write inside the plugin
#      root, and the honest claim is about the tracked script tree.
#      The ignore rules are evaluated by git itself, and the repo working tree's
#      .gitignore is first proven byte-identical to C's, so the rules applied are
#      C's rules. Any extra path that is NOT ignored FAILS the proof.

param(
    [string] $Commit = 'af6996f971c8e8629a7d005e83f72865f2a66112',
    [string] $Repo   = 'C:\Users\mande\projects\work\nortam\claude-powershell-lsp',
    [string] $Root   = 'C:\Users\mande\AppData\Local\Temp\psl-267\root',
    [string] $Data   = 'C:\Users\mande\AppData\Local\Temp\psl-267\data',
    [string] $Label  = 'unlabelled',
    [string] $JsonOut = '',
    [switch] $RedControl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MinFiles = 400   # payload floor: C carries 423 tracked paths

function Test-IgnoredAtC([string[]] $relPaths) {
    # Evaluate C's ignore rules with git itself. Guard first: the working tree's
    # .gitignore must be byte-identical to C's, or these are not C's rules.
    if ($relPaths.Count -eq 0) { return @{} }
    $wt = Join-Path $Repo '.gitignore'
    if (-not (Test-Path -LiteralPath $wt)) { throw 'cannot evaluate C ignore rules: no .gitignore in the repo working tree' }
    $wtOid = (& git -C $Repo hash-object --no-filters $wt).Trim()
    $cOid  = $null
    foreach ($l in @(& git -C $Repo ls-tree $Commit -- .gitignore)) {
        $tab = $l.IndexOf("`t"); if ($tab -lt 0) { continue }
        $cOid = ($l.Substring(0, $tab) -split '\s+')[2]
    }
    if (-not $cOid) { throw 'C has no .gitignore -- no extra path can be classified as an ignored byproduct' }
    if ($wtOid -cne $cOid) {
        throw ('the working tree .gitignore (' + $wtOid + ') differs from C (' + $cOid +
               '); ignore classification would not be using C rules')
    }
    $res = @{}
    foreach ($p in $relPaths) {
        & git -C $Repo check-ignore -q -- $p 2>&1 | Out-Null
        $res[$p] = ($LASTEXITCODE -eq 0)
    }
    return $res
}

function Invoke-Proof {
    param([string] $rootPath)

    # --- reference: C's own tree ---------------------------------------------
    $expect = @{}
    $lines = @(& git -C $Repo ls-tree -r $Commit)
    if ($LASTEXITCODE -ne 0) { throw ('git ls-tree failed: exit ' + $LASTEXITCODE) }
    foreach ($l in $lines) {
        $tab = $l.IndexOf("`t")
        if ($tab -lt 0) { continue }
        $meta = $l.Substring(0, $tab) -split '\s+'
        if ($meta[1] -ne 'blob') { continue }
        $expect[$l.Substring($tab + 1)] = $meta[2]
    }

    # --- observed: the staged tree on disk ------------------------------------
    $rootFull = (Resolve-Path -LiteralPath $rootPath).ProviderPath.TrimEnd('\')
    $dataFull = $null
    if (Test-Path -LiteralPath $Data) {
        $dataFull = (Resolve-Path -LiteralPath $Data).ProviderPath.TrimEnd('\')
    }
    $dataInsideRoot = $false
    if ($dataFull) { $dataInsideRoot = $dataFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase) }

    $files = @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force)
    $excludedForData = 0
    $paths = New-Object System.Collections.Generic.List[string]
    $rels  = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) {
        if ($dataFull -and $f.FullName.StartsWith($dataFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $excludedForData++
            continue
        }
        $paths.Add($f.FullName)
        $rels.Add($f.FullName.Substring($rootFull.Length + 1).Replace('\', '/'))
    }

    # One git process for the whole tree, not one per file.
    $tmp = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($tmp, (($paths -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    $oids = @(& cmd.exe /c ('type "' + $tmp + '" | git -C "' + $Repo + '" hash-object --no-filters --stdin-paths'))
    Remove-Item -LiteralPath $tmp -Force
    if ($oids.Count -ne $paths.Count) {
        throw ('hash-object returned ' + $oids.Count + ' ids for ' + $paths.Count + ' files')
    }

    $observed = @{}
    for ($i = 0; $i -lt $rels.Count; $i++) { $observed[$rels[$i]] = $oids[$i].Trim() }

    # --- compare --------------------------------------------------------------
    $missing = @($expect.Keys   | Where-Object { -not $observed.ContainsKey($_) } | Sort-Object)
    $differ  = @($expect.Keys   | Where-Object { $observed.ContainsKey($_) -and $observed[$_] -cne $expect[$_] } | Sort-Object)
    $extraAll = @($observed.Keys | Where-Object { -not $expect.ContainsKey($_) } | Sort-Object)

    $ignoreMap = Test-IgnoredAtC $extraAll
    $byproducts = @($extraAll | Where-Object { $ignoreMap[$_] })
    $extraBad   = @($extraAll | Where-Object { -not $ignoreMap[$_] })

    # The digest is taken over the TRACKED path set only, so it is a stable
    # identity for the script tree and does not move when a byproduct appears.
    $tracked = @($observed.Keys | Where-Object { $expect.ContainsKey($_) } | Sort-Object)
    $manifest = (($tracked | ForEach-Object { $_ + ' ' + $observed[$_] }) -join "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    $digest = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($manifest)))).Replace('-', '').ToLower()
    $sha.Dispose()

    return [pscustomobject]@{
        label             = $Label
        commit            = $Commit
        expected_files    = $expect.Count
        tracked_observed  = $tracked.Count
        missing           = $missing
        differing         = $differ
        extra_ignored_byproducts = $byproducts
        extra_unexplained = $extraBad
        manifest_sha256   = $digest
        data_inside_root  = $dataInsideRoot
        excluded_for_data = $excludedForData
        equal             = ($missing.Count -eq 0 -and $differ.Count -eq 0 -and $extraBad.Count -eq 0)
    }
}

$r = Invoke-Proof -rootPath $Root

# --- vacuity guards ----------------------------------------------------------
if ($r.expected_files -lt $MinFiles) {
    throw ('payload floor: C names only ' + $r.expected_files + ' blobs, expected at least ' + $MinFiles)
}
if ($r.tracked_observed -lt $MinFiles) {
    throw ('payload floor: only ' + $r.tracked_observed + ' tracked files hashed under root, expected at least ' + $MinFiles)
}
if ($r.data_inside_root) {
    throw 'CLAUDE_PLUGIN_DATA resolves INSIDE CLAUDE_PLUGIN_ROOT -- the exclusion would be silently hashing mutated state'
}

Write-Output ('[' + $r.label + '] tracked_at_C=' + $r.expected_files + ' tracked_observed=' + $r.tracked_observed +
              ' missing=' + $r.missing.Count + ' differing=' + $r.differing.Count +
              ' ignored_byproducts=' + $r.extra_ignored_byproducts.Count +
              ' unexplained_extra=' + $r.extra_unexplained.Count +
              ' data_inside_root=' + $r.data_inside_root + ' manifest_sha256=' + $r.manifest_sha256 +
              ' EQUAL=' + $r.equal)
if ($r.missing.Count -gt 0)   { Write-Output ('  missing: '   + (($r.missing   | Select-Object -First 10) -join ', ')) }
if ($r.differing.Count -gt 0) { Write-Output ('  differing: ' + (($r.differing | Select-Object -First 10) -join ', ')) }
if ($r.extra_ignored_byproducts.Count -gt 0) { Write-Output ('  ignored byproducts: ' + ($r.extra_ignored_byproducts -join ', ')) }
if ($r.extra_unexplained.Count -gt 0)        { Write-Output ('  UNEXPLAINED extra: ' + ($r.extra_unexplained -join ', ')) }

if ($JsonOut) { $r | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $JsonOut -Encoding UTF8 }

# --- RED controls ------------------------------------------------------------
# Falsify the check on BOTH arms it can fail on: a modified tracked file, and an
# extra path that is NOT ignored. Without these, "EQUAL" could be a check that
# cannot fail.
if ($RedControl) {
    # Arm 1 -- a real byte change to a tracked file.
    $victim = Join-Path $Root 'scripts/lsp-client.ps1'
    $orig = [IO.File]::ReadAllBytes($victim)
    try {
        $mut = [byte[]]::new($orig.Length + 1)
        [Array]::Copy($orig, $mut, $orig.Length)
        $mut[$orig.Length] = 0x0A
        [IO.File]::WriteAllBytes($victim, $mut)
        $red = Invoke-Proof -rootPath $Root
        Write-Output ('[RED 1: mutated tracked file] differing=' + $red.differing.Count + ' EQUAL=' + $red.equal)
        if ($red.equal) { throw 'RED 1 FAILED: still EQUAL after a real mutation -- the proof is vacuous' }
        if ($red.differing -notcontains 'scripts/lsp-client.ps1') { throw 'RED 1 FAILED: the mutated file was not the one reported' }
    } finally {
        [IO.File]::WriteAllBytes($victim, $orig)
    }

    # Arm 2 -- an untracked, NON-ignored extra path must not be waved through.
    $intruder = Join-Path $Root 'scripts/NOT-IN-C.ps1'
    try {
        [IO.File]::WriteAllText($intruder, "# planted by the RED control`n")
        $red2 = Invoke-Proof -rootPath $Root
        Write-Output ('[RED 2: unexplained extra file] unexplained=' + $red2.extra_unexplained.Count + ' EQUAL=' + $red2.equal)
        if ($red2.equal) { throw 'RED 2 FAILED: an untracked non-ignored file did not fail the proof' }
        if ($red2.extra_unexplained -notcontains 'scripts/NOT-IN-C.ps1') { throw 'RED 2 FAILED: the planted file was not the one reported' }
    } finally {
        Remove-Item -LiteralPath $intruder -Force -ErrorAction SilentlyContinue
    }

    $back = Invoke-Proof -rootPath $Root
    Write-Output ('[RED controls restored] EQUAL=' + $back.equal)
    if (-not $back.equal) { throw 'RED CONTROL FAILED: the tree did not restore to C after the controls' }
}

if (-not $r.equal) { throw ('EQUALITY PROOF FAILED for ' + $r.label) }
Write-Output ('PASS: staged CLAUDE_PLUGIN_ROOT tracked tree is byte-identical to ' + $Commit)
