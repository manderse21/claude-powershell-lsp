#Requires -Version 5.1

# pre-push-guard.ps1 -- the powershell-lsp repo's pre-push policy guard (dispatch 000080).
#
# WHAT IT DOES
#   Refuses a `git push` whose refspec would UPDATE refs/heads/main on ORIGIN, with a
#   message that names the PR-and-HOLD rule and how to override. Every other push --
#   a feature branch, a tag, a branch delete, a fork remote -- passes through untouched.
#
# WHY
#   main lands via a reviewed, merged PR (the PR-and-HOLD discipline), never a local push.
#   dispatch 000079 pushed straight to origin/main from a worktree and it became permanent.
#   This turns "do not push to main" from a discipline into a refusal on the dev's machine,
#   caught before the push leaves -- with a clear message and an audited escape hatch.
#
# OVERRIDE (audited, explicit, never silent)
#   Set POWERSHELL_LSP_ALLOW_PUSH_TO_MAIN to a NON-EMPTY reason. The push is then allowed
#   AND an audit line (UTC timestamp, reason, sha, target ref) is appended to the bypass
#   log. Unset / empty / whitespace-only does NOT override.
#
# BYPASS LOG
#   Default: <git-common-dir>/powershell-lsp-push-to-main-bypass.log -- inside .git, so it
#   is never committed and is shared across every linked worktree of the clone. Relocate
#   via POWERSHELL_LSP_PUSH_AUDIT_LOG=<absolute path> (the suite test points it at a temp
#   file).
#
# HOW IT IS WIRED
#   The tracked git hook hooks/pre-push (a POSIX sh shim) forwards the push refspec (stdin)
#   and the remote name/url (argv) here. Install with scripts/install-git-hooks.ps1, which
#   sets core.hooksPath to the tracked hooks/ dir so the guard also fires from a linked
#   worktree, not only the primary checkout. See CONTRIBUTING.md.
#
# This script is DOT-SOURCE SAFE (the doctor.ps1 pattern): dot-sourcing defines the pure
# decision functions without reading stdin or touching git, so the unit suite exercises
# the logic with no I/O beyond a TestDrive file.

[CmdletBinding()]
param(
    # The remote NAME git passes as argv[1] to a pre-push hook (e.g. 'origin').
    [string] $RemoteName = '',
    # The remote URL git passes as argv[2] to a pre-push hook.
    [string] $RemoteUrl = ''
)

function Test-IsOriginRemote {
    # origin == matched by NAME ('origin') OR by URL equal to origin's configured URL. A
    # fork (a different name AND a different url) is NOT origin. Keeps the refusal narrow.
    param(
        [string] $RemoteName,
        [string] $RemoteUrl,
        [string] $OriginUrl
    )
    if ($RemoteName -eq 'origin') { return $true }
    if (-not [string]::IsNullOrWhiteSpace($OriginUrl) -and -not [string]::IsNullOrWhiteSpace($RemoteUrl)) {
        if ($RemoteUrl.Trim() -eq $OriginUrl.Trim()) { return $true }
    }
    return $false
}

function Resolve-PushToMainGuard {
    # PURE decision over already-resolved inputs. No git, no stdin, no env, no file I/O --
    # so the suite test can drive every branch directly. Returns a decision object the hook
    # entry point (and the test) act on.
    param(
        [string]   $RemoteName,
        [string]   $RemoteUrl,
        [string]   $OriginUrl,
        # Raw pre-push stdin lines: "<localref> <localsha> <remoteref> <remotesha>".
        [string[]] $PushSpecLines,
        # The value of POWERSHELL_LSP_ALLOW_PUSH_TO_MAIN; non-empty (trimmed) => override.
        [string]   $OverrideReason = ''
    )

    $isOrigin = Test-IsOriginRemote -RemoteName $RemoteName -RemoteUrl $RemoteUrl -OriginUrl $OriginUrl

    # Does any refspec UPDATE refs/heads/main (i.e. NOT a delete)? A delete carries an
    # all-zero local sha (SHA-1 or SHA-256) -- leave deletes untouched.
    $targetsMain  = $false
    $mainLocalSha = ''
    foreach ($line in @($PushSpecLines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = -split $line.Trim()
        if ($parts.Count -lt 4) { continue }
        $localSha  = $parts[1]
        $remoteRef = $parts[2]
        if ($remoteRef -eq 'refs/heads/main') {
            if ($localSha -notmatch '^0+$') {
                $targetsMain  = $true
                $mainLocalSha = $localSha
            }
        }
    }

    $blocks     = ($isOrigin -and $targetsMain)
    $overridden = (-not [string]::IsNullOrWhiteSpace($OverrideReason))

    $decision = 'allow'
    if ($blocks -and -not $overridden) { $decision = 'refuse' }

    $targetRef = ''
    if ($targetsMain) { $targetRef = 'refs/heads/main' }

    return [pscustomobject]@{
        Decision    = $decision        # 'refuse' | 'allow'
        IsOrigin    = $isOrigin
        TargetsMain = $targetsMain     # updates (not deletes) origin's main head
        Blocks      = $blocks          # would refuse absent an override
        Overridden  = $overridden
        Sha         = $mainLocalSha    # the sha that would land on main (for the audit line)
        TargetRef   = $targetRef
    }
}

function Get-PushAuditLogPath {
    # Default bypass-log path: inside the git common dir (never committed; shared across
    # every linked worktree). POWERSHELL_LSP_PUSH_AUDIT_LOG overrides (absolute path).
    param(
        [string] $GitCommonDir,
        [string] $OverridePath = ''
    )
    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) { return $OverridePath }
    if ([string]::IsNullOrWhiteSpace($GitCommonDir)) { return '' }
    return (Join-Path $GitCommonDir 'powershell-lsp-push-to-main-bypass.log')
}

function Add-PushToMainAuditLine {
    # Append ONE ASCII audit line for an override: UTC time, reason, sha, target ref.
    # Returns the line written. The reason is flattened to a single physical line so a
    # newline in it cannot forge extra audit records.
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Reason,
        [string] $Sha = '',
        [string] $TargetRef = '',
        [string] $RemoteName = ''
    )
    $utc        = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $flatReason = ($Reason -replace '[\r\n]+', ' ').Trim()
    $target     = $TargetRef
    if (-not [string]::IsNullOrWhiteSpace($RemoteName)) { $target = "$RemoteName $TargetRef" }
    $line = '{0} | OVERRIDE | reason="{1}" | sha={2} | ref={3}' -f $utc, $flatReason, $Sha, $target

    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Add-Content -LiteralPath $Path -Value $line -Encoding ASCII
    return $line
}

# ===========================================================================
# Entry point -- runs ONLY on direct invocation (pwsh -File ...), not when the script is
# dot-sourced (so the unit tests load the functions without reading stdin or touching git).
# ===========================================================================
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Read the push refspec from stdin (git pipes it). Guard against a TTY so a manual run
    # does not hang waiting for EOF.
    $specLines = @()
    if ([Console]::IsInputRedirected) {
        $raw = [Console]::In.ReadToEnd()
        if ($null -ne $raw -and $raw.Length -gt 0) {
            $specLines = @($raw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }

    # origin's configured URL (best-effort; name-match alone catches `git push origin ...`).
    $originUrl = ''
    try { $originUrl = (& git remote get-url origin 2>$null | Select-Object -First 1) } catch { $originUrl = '' }
    if ($null -eq $originUrl) { $originUrl = '' }

    # The git common dir (absolute) -> the default audit log path; shown in the message too.
    $commonDir = ''
    try { $commonDir = (& git rev-parse --git-common-dir 2>$null | Select-Object -First 1) } catch { $commonDir = '' }
    if ($null -eq $commonDir) { $commonDir = '' }
    if ($commonDir.Length -gt 0) {
        try { $commonDir = (Resolve-Path -LiteralPath $commonDir -ErrorAction Stop).Path } catch { }
    }
    $auditOverride = $env:POWERSHELL_LSP_PUSH_AUDIT_LOG
    if ($null -eq $auditOverride) { $auditOverride = '' }
    $auditPath = Get-PushAuditLogPath -GitCommonDir $commonDir -OverridePath $auditOverride

    $overrideReason = $env:POWERSHELL_LSP_ALLOW_PUSH_TO_MAIN
    if ($null -eq $overrideReason) { $overrideReason = '' }

    $result = Resolve-PushToMainGuard -RemoteName $RemoteName -RemoteUrl $RemoteUrl `
        -OriginUrl $originUrl -PushSpecLines $specLines -OverrideReason $overrideReason

    if ($result.Decision -eq 'refuse') {
        $auditLine = if ([string]::IsNullOrWhiteSpace($auditPath)) { '<git-common-dir>/powershell-lsp-push-to-main-bypass.log' } else { $auditPath }
        $msg = @(
            '',
            'powershell-lsp: refusing to push to origin/main.',
            '',
            '  main lands via a reviewed, merged PR -- never a direct local push (PR-and-HOLD).',
            '  This guard caught the push on your machine before it left (dispatch 000080).',
            '',
            '  Open a PR instead:',
            '    git push origin HEAD:refs/heads/<your-branch>    # then open a PR and HOLD',
            '',
            '  Deliberate one-off override (explicit + audited):',
            '    POWERSHELL_LSP_ALLOW_PUSH_TO_MAIN="why this push is intentional" git push ...',
            '    -> the push is allowed AND an audit line is appended to:',
            ('       ' + $auditLine),
            ''
        ) -join [Environment]::NewLine
        [Console]::Error.WriteLine($msg)
        exit 1
    }

    if ($result.Blocks -and $result.Overridden) {
        # Audited allow: append the bypass line BEFORE letting the push proceed.
        if (-not [string]::IsNullOrWhiteSpace($auditPath)) {
            $line = Add-PushToMainAuditLine -Path $auditPath -Reason $overrideReason `
                -Sha $result.Sha -TargetRef $result.TargetRef -RemoteName $RemoteName
            [Console]::Error.WriteLine("powershell-lsp: ALLOWING override push to origin/main; audited -> $auditPath")
            [Console]::Error.WriteLine("  $line")
        } else {
            [Console]::Error.WriteLine('powershell-lsp: WARNING override push to origin/main allowed but the audit log path could not be resolved; not logged.')
        }
    }

    exit 0
}
