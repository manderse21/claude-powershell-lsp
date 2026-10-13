# PV -- POLICY EVIDENCE VARIANTS (dispatch 000305, B1): the controls for the MANAGED scan.
#
# A FAKE scripts/lsp-client.ps1, run by the shipped lsp-scan.ps1 relocated beside it (New-SvCliTree).
# It stands for the client AND its daemon, and every record it writes is built by the PRODUCTION
# builders from the libraries copied beside it -- Resolve-EffectivePolicy, New-PolicyApplicationEvidence,
# New-PolicyAdjudicationEvidence, New-ScanAnalysisBinding, New-ScanReceipt, Write-ScanReceipt -- never
# spelled by hand. It reads the policy the scan handed it exactly as the real client does
# (Get-PluginOption 'orgPolicy', which Set-ScanChildPolicy set), so the 'applied' control agrees with
# the scan's own resolution only if the declared path really reached the child. Each fault variant then
# changes exactly ONE fact the managed verdict depends on:
#
#   applied                 the control: both parties applied the declared policy; a required rule was
#                           merged, verified and delivered (else not-required)
#   activation-unsupported  the daemon's RequiredRules version guard refused (observed v9.9.9)
#   merge-write-failed      the daemon could not write and verify the merged settings file
#   settings-changed        activated, but the settings file PSES reads no longer hashes to what was written
#   daemon-disagreement     the daemon applied a DIFFERENT policy (another file's identity)
#   client-disagreement     the client applied a DIFFERENT policy
#   no-evidence             no policy evidence at all (the receipt's policy block stays unbound)
#   engine-unknown          the engine versions could not be observed
#   config-narrowed         the daemon reports an ambient ruleExclude it was launched with
#
# The variant name is read from <CLAUDE_PLUGIN_DATA>/pv-variant.txt, which the test writes before the
# run -- no environment variable is involved, so no ambient value can select a variant.
#
# ASCII-only (PS 5.1 reads a UTF-8-without-BOM file through Windows-1252).

. (Join-Path $PSScriptRoot 'lib/lsp-common.ps1')
. (Join-Path $PSScriptRoot 'lib/lsp-scan-receipt.ps1')
. (Join-Path $PSScriptRoot 'lib/lsp-policy.ps1')
$raw = Get-StdinText   # BOM-tolerant, as the real hooks read it (a 5.1 parent prepends a BOM)
$data = $env:CLAUDE_PLUGIN_DATA
$variant = ([System.IO.File]::ReadAllText((Join-Path $data 'pv-variant.txt'))).Trim()
[System.IO.File]::WriteAllText((Join-Path $data 'fake-ran.txt'), 'PV:' + $variant)
$payload = $raw | ConvertFrom-Json
$path = [System.IO.Path]::GetFullPath([string](($payload.tool_input).file_path))
$ctx = Get-ScanRequestContext -Payload $payload
if ($null -eq $ctx) { exit 2 }

$knob = [string](Get-PluginOption 'orgPolicy' '')
$clientRes = Resolve-EffectivePolicy -Path $knob -Source 'knob'
$daemonRes = $clientRes
if ($variant -eq 'daemon-disagreement' -or $variant -eq 'client-disagreement') {
    $other = Join-Path $data 'pv-other-policy.psd1'
    [System.IO.File]::WriteAllText($other, "@{ ExcludeRules = @('PSB1SomeOtherRule') }`n")
    if ($variant -eq 'daemon-disagreement') { $daemonRes = Resolve-EffectivePolicy -Path $other -Source 'daemon' }
    else { $clientRes = Resolve-EffectivePolicy -Path $other -Source 'knob' }
}

$required = Get-PolicyStringList -Object $daemonRes.effective -Name 'RequiredRules'
$state = $(if (-not [bool]$daemonRes.usable) { 'policy-unusable' } elseif ($required.Count -gt 0) { 'activated' } else { 'not-required' })
$guardObserved = 'v4.6.0'
$guardResult = $(if ($required.Count -gt 0) { 'pass' } else { '' })
$mergedPath = ''
$mergedSha = ''
$settingsSource = 'none'
$settingsPath = ''
if ($state -eq 'activated') {
    $merged = Merge-RequiredRulesSettings -ResolvedSettingsPath '' -RequiredRules $required -CurrentPsesTag 'v4.6.0'
    $mergedPath = Write-MergedPssaSettingsFile -Settings $merged -DataRoot $data
    $mergedSha = Get-PolicyFileSha256 -Path $mergedPath
    $settingsSource = 'merged'
    $settingsPath = $mergedPath
}
switch ($variant) {
    'activation-unsupported' { $state = 'activation-unsupported'; $guardObserved = 'v9.9.9'; $guardResult = 'refused'; $mergedPath = ''; $mergedSha = ''; $settingsSource = 'none'; $settingsPath = '' }
    'merge-write-failed' { $state = 'merge-write-failed'; $mergedPath = ''; $mergedSha = ''; $settingsSource = 'none'; $settingsPath = '' }
}
$settingsSha = $(if ($settingsPath -ne '') { Get-PolicyFileSha256 -Path $settingsPath } else { '' })
if ($variant -eq 'settings-changed') { $settingsSha = ('0' * 64) }
$daemonEvidence = New-PolicyApplicationEvidence -Resolution $daemonRes -Path $knob -RequiredState $state `
    -RequiredCount $required.Count -GuardVerifiedFor 'v4.6.0' -GuardObserved $guardObserved -GuardResult $guardResult `
    -MergedPath $mergedPath -MergedSha256 $mergedSha -SettingsPath $settingsPath -SettingsSource $settingsSource `
    -SettingsSha256 $settingsSha -Delivered ($settingsSource -eq 'merged')
$clientEvidence = New-PolicyAdjudicationEvidence -Resolution $clientRes -Path $knob -Mode ([string](Get-PolicyModeInfo).resolved)

$snap = Read-ScanSourceSnapshot -Path $path
$engine = Get-ScanEngineIdentity -PsesHost 'pv-policy-variant'
if ($variant -ne 'engine-unknown') {
    # A fake has no PSES bundle beside it; stand in observed versions so 'unknown' is this one variant's.
    $engine['pses'] = '4.6.0'; $engine['pssa'] = '1.25.0'
}
$config = [ordered]@{
    settingsPath = $settingsPath; ruleset = 'pses-default'; severityThreshold = 'Hint'; ruleInclude = ''
    ruleExclude = $(if ($variant -eq 'config-narrowed') { 'PSUseApprovedVerbs' } else { '' })
    perFileCap = 0; moduleAwareness = 'off'; referenceSurfacing = 'off'; orgPolicy = $knob
}
$bindingPolicy = $(if ($variant -eq 'no-evidence') { $null } else { $daemonEvidence })
$binding = New-ScanAnalysisBinding -RequestId $ctx.RequestId -AnalyzedPath $path -Snapshot $snap -Settled $true `
    -PssaAvailable $true -Engine $engine -Config $config -Policy $bindingPolicy
$receipt = New-ScanReceipt -RequestId $ctx.RequestId -File $path -Pass 'pssa' -Status 'ok' -Binding $binding `
    -Records @() -FormatMode 'off' -PolicyEvidence $(if ($variant -eq 'no-evidence') { $null } else { $clientEvidence })
[void](Write-ScanReceipt -Path $ctx.ReceiptPath -Receipt $receipt)
exit 0
