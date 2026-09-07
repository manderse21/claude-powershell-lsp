#Requires -Version 5.1

# audit-repo-target.ps1 -- resolve, and PIN, the repository that audit-release-bodies.ps1
# sweeps (dispatch 000286, phase 3(a)).
#
# THE DEFECT THIS CLOSES, and why the obvious fix would have been vacuous.
#
# Dispatch 000285 added a repo-identity assertion so that -Repo could not point the sweep at
# a foreign repository while it compared the bodies it found there against THIS checkout's
# CHANGELOG. That assertion fires only on an EXPLICIT -Repo. With -Repo omitted the script
# passed NO --repo to gh at all and let gh resolve the repository itself, and 000285 recorded
# in its own words that this was safe because "when -Repo is omitted, gh resolves the same
# remote". MEASURED AT gh 2.95.0, THAT IS FALSE. GH_REPO takes precedence over the git remote
# for the two commands this sweep actually issues:
#
#   inside the claude-powershell-lsp checkout, with GH_REPO=cli/cli --
#     gh release list  --limit 2 --json tagName    -> [{"tagName":"v2.100.0"}, ...]  cli/cli
#     gh release view  --json tagName -q .tagName  -> v2.100.0                       cli/cli
#     gh repo view     --json nameWithOwner        -> manderse21/claude-powershell-lsp  LOCAL
#
# So the unguarded door was real: export GH_REPO, run the sweep with no -Repo, and it reads a
# stranger's published bodies against this repository's CHANGELOG and reports the result in the
# vocabulary of a currency finding -- precisely the defect the -Repo assertion exists to prevent.
#
# AND THE FIX 000285 IMAGINED WOULD NOT HAVE CLOSED IT. Its note proposed "asking gh what it
# resolved and comparing", one more subprocess per run. The third line above is why that fails:
# gh repo view reports the GIT REMOTE and ignores GH_REPO, while the release commands follow
# GH_REPO. A guard built on it would have compared the remote against the remote, agreed with
# itself, and passed while the sweep read cli/cli. That is a guard measuring a proxy the guarded
# party controls -- the shape Hub Rule 35 was promoted for -- and it would have been WORSE than
# the open gap, because it would have looked closed.
#
# THE FIX IS STRUCTURAL, NOT A GUARD, AND IT COSTS NOTHING. The --repo FLAG beats GH_REPO
# (measured: with GH_REPO=cli/cli, "gh release list --repo manderse21/claude-powershell-lsp"
# returned v1.34.0). So instead of policing the ambient resolution, this ELIMINATES it: the
# target is decided here, once, and passed explicitly to every gh call. gh is left with nothing
# to resolve, which closes GH_REPO and the "gh repo set-default" gh-resolved git-config door
# together, and adds ZERO subprocesses -- against the ~500-720 ms per gh invocation measured on
# this machine, the declined option's real price.
#
# The expected slug is always DERIVED from the checkout's own origin remote, never hard-coded,
# so a fork or a rename is not a false refusal.
#
# ASCII-only (PS 5.1 em-dash trap). Pure: no gh, no git, no network, no environment reads --
# every input is a parameter, which is what lets the GH_REPO case be exercised from a machine
# where GH_REPO is not set.

function Get-AuditRepoSlug {
    # OWNER/NAME from a git remote URL, in either transport form. Returns '' if unrecognised.
    param([string] $Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    $u = $Url.Trim()
    if ($u.EndsWith('.git')) { $u = $u.Substring(0, $u.Length - 4) }
    $m = [regex]::Match($u, '(?:[:/])([^/:]+)/([^/]+)$')
    if (-not $m.Success) { return '' }
    return ('{0}/{1}' -f $m.Groups[1].Value, $m.Groups[2].Value)
}

function Resolve-AuditRepoTarget {
    # Decide WHICH repository the sweep reads, and say so out loud. Returns an object:
    #   Slug    the OWNER/NAME to pass to gh as --repo. '' when Error is set.
    #   Error   '' when the sweep may proceed; otherwise the operator-facing refusal.
    #   Banner  '' or the loud line naming a deliberate cross-repo sweep.
    #   Source  which input decided it: 'repo-param' | 'origin' | 'gh-repo-env'
    #
    # FAIL CLOSED IS THE POINT. Every path that cannot PIN a target returns an Error rather
    # than falling through to gh's own resolution, because falling through is the defect.
    param(
        [string] $RepoParam,
        [string] $OriginSlug,
        [string] $GhRepoEnv,
        [bool]   $AllowForeignRepo = $false
    )

    $repoParamSet = -not [string]::IsNullOrWhiteSpace($RepoParam)
    $ghRepoSet    = -not [string]::IsNullOrWhiteSpace($GhRepoEnv)
    $originKnown  = -not [string]::IsNullOrWhiteSpace($OriginSlug)

    if ($repoParamSet) {
        # EXPLICIT -Repo. The 000285 assertion, unchanged in meaning. It is checked FIRST and
        # GH_REPO is not consulted at all, because --repo beats GH_REPO at gh: an operator who
        # named a repository on the command line gets that repository, and an ambient variable
        # must not be able to silently redirect an explicit instruction.
        if (-not $originKnown) {
            return [pscustomobject]@{
                Slug = ''; Source = 'repo-param'; Banner = ''
                Error = ("-Repo '{0}' was given but this checkout's origin remote could not be resolved, so the repository identity cannot be checked. Re-run without -Repo, or pass -AllowForeignRepo if you mean to audit a different repository." -f $RepoParam)
            }
        }
        if ($RepoParam -ne $OriginSlug) {
            if (-not $AllowForeignRepo) {
                return [pscustomobject]@{
                    Slug = ''; Source = 'repo-param'; Banner = ''
                    Error = ("REPO IDENTITY: -Repo '{0}' is not this checkout's repository ('{1}'). This sweep compares PUBLISHED RELEASE BODIES against THIS checkout's CHANGELOG.md, so auditing a different repository compares two unrelated things and reports the result as if it were a currency finding. Pass -AllowForeignRepo if that is genuinely what you want." -f $RepoParam, $OriginSlug)
                }
            }
            return [pscustomobject]@{
                Slug = $RepoParam; Source = 'repo-param'; Error = ''
                Banner = ("FOREIGN REPO: sweeping '{0}' against the CHANGELOG of '{1}' -- results are NOT a currency finding for either repository." -f $RepoParam, $OriginSlug)
            }
        }
        return [pscustomobject]@{ Slug = $RepoParam; Source = 'repo-param'; Error = ''; Banner = '' }
    }

    # NO -Repo. This is the arm 000285 left open.
    if (-not $originKnown) {
        # Previously this fell through to gh, which would have guessed from GH_REPO or from a
        # remote this code could not read -- an unpinned sweep whose target never appears in
        # the output. There is no safe guess, so there is no guess.
        return [pscustomobject]@{
            Slug = ''; Source = 'origin'; Banner = ''
            Error = "This checkout's origin remote could not be resolved and -Repo was not given, so the repository to audit cannot be PINNED. Earlier versions let gh resolve it silently, which is exactly how a foreign repository's release bodies could be compared against this CHANGELOG. Pass -Repo OWNER/NAME."
        }
    }

    if ($ghRepoSet -and $GhRepoEnv -ne $OriginSlug) {
        # GH_REPO disagrees with the checkout. It is NOT silently ignored even though --repo
        # would now beat it: the operator's environment and this script's premise disagree, and
        # saying so is the whole lesson of the -Repo assertion. Refuse, and name both values.
        if (-not $AllowForeignRepo) {
            return [pscustomobject]@{
                Slug = ''; Source = 'gh-repo-env'; Banner = ''
                Error = ("REPO IDENTITY: GH_REPO is set to '{0}', which is not this checkout's repository ('{1}'). gh honours GH_REPO for 'gh release list' and 'gh release view', so without this refusal the sweep would read that repository's published bodies and compare them against THIS checkout's CHANGELOG.md. Unset GH_REPO, or pass -Repo OWNER/NAME explicitly, or pass -AllowForeignRepo if a cross-repo sweep is genuinely what you want." -f $GhRepoEnv, $OriginSlug)
            }
        }
        return [pscustomobject]@{
            Slug = $GhRepoEnv; Source = 'gh-repo-env'; Error = ''
            Banner = ("FOREIGN REPO: GH_REPO selects '{0}'; sweeping it against the CHANGELOG of '{1}' -- results are NOT a currency finding for either repository." -f $GhRepoEnv, $OriginSlug)
        }
    }

    return [pscustomobject]@{ Slug = $OriginSlug; Source = 'origin'; Error = ''; Banner = '' }
}
