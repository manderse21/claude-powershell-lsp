#Requires -Version 5.1

# install-git-hooks.ps1 -- wire this repo's tracked git hooks (dispatch 000080).
#
# The repo ships its git hooks tracked under hooks/ (today: a pre-push guard that refuses a
# direct push to origin/main -- see scripts/pre-push-guard.ps1). git does not run tracked
# hooks until you point it at them; this one-time, idempotent installer does that by setting
#
#     core.hooksPath = <primary-working-tree>/hooks
#
# in the clone's shared config. Because the path is absolute and the config is shared, the
# hooks ALSO fire from every linked worktree (`git worktree add ...`), not only the primary
# checkout -- which is the exact dispatch 000079 case (a worktree pushed straight to main).
# It resolves the PRIMARY working tree (not the current, possibly-linked, worktree) so the
# setting stays valid after any linked worktree is pruned.
#
# Re-run any time; it is safe and idempotent. Uninstall with: git config --unset core.hooksPath
#
# Usage:  pwsh -File scripts/install-git-hooks.ps1
#         pwsh -File scripts/install-git-hooks.ps1 -Quiet

[CmdletBinding()]
param(
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Note {
    param([string] $Message)
    if (-not $Quiet) { Write-Host $Message }
}

# Must be inside a work tree.
$inWorkTree = (& git rev-parse --is-inside-work-tree 2>$null | Select-Object -First 1)
if ($inWorkTree -ne 'true') {
    Write-Error 'install-git-hooks.ps1 must be run inside the git working tree.'
    exit 1
}

# Resolve the PRIMARY working tree as the parent of the git COMMON dir. From the primary
# checkout `git rev-parse --git-common-dir` returns '.git' (relative); from a linked worktree
# it returns the absolute primary .git -- resolving to absolute handles both.
$commonDir = (& git rev-parse --git-common-dir 2>$null | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($commonDir)) {
    Write-Error 'install-git-hooks.ps1: could not resolve the git common dir.'
    exit 1
}
$commonDir   = (Resolve-Path -LiteralPath $commonDir -ErrorAction Stop).Path
$primaryRoot = Split-Path -Parent $commonDir
$hooksDir    = Join-Path $primaryRoot 'hooks'
$hookFile    = Join-Path $hooksDir 'pre-push'

if (-not (Test-Path -LiteralPath $hookFile)) {
    Write-Error ("install-git-hooks.ps1: tracked hook not found at $hookFile -- run this from a checkout that has the hooks/ directory (it ships on main).")
    exit 1
}

# git accepts forward slashes on every platform; avoids backslash-escaping surprises.
$hooksDirForGit = ($hooksDir -replace '\\', '/')
& git config core.hooksPath $hooksDirForGit

# Belt-and-suspenders on POSIX: the tracked hook ships mode 100755, but make the current
# checkout's copy executable in case it was materialized without the bit. No-op on Windows.
$onWindows = if (Test-Path 'Variable:\IsWindows') { [bool]$IsWindows } else { $true }
if (-not $onWindows) {
    try { & chmod +x -- $hookFile 2>$null } catch { }
}

$confirm = (& git config --get core.hooksPath | Select-Object -First 1)
Write-Note ''
Write-Note 'powershell-lsp: git hooks installed.'
Write-Note ("  core.hooksPath -> " + $confirm)
Write-Note ("  pre-push guard  -> " + $hookFile)
Write-Note ''
Write-Note '  A direct push to origin/main is now refused on this machine (it also fires from'
Write-Note '  linked worktrees). Deliberate one-off override (audited):'
Write-Note '    POWERSHELL_LSP_ALLOW_PUSH_TO_MAIN="why this push is intentional" git push ...'
Write-Note ''
exit 0
