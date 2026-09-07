#Requires -Version 5.1

# Which repository does audit-release-bodies.ps1 actually sweep? (dispatch 000286, phase 3(a))
#
# Dispatch 000285 guarded an EXPLICIT -Repo against the checkout's own origin remote, and named
# the arm it left open: with -Repo omitted, gh resolved the repository itself and nothing checked
# it. That arm was not theoretical. Measured at gh 2.95.0, inside the claude-powershell-lsp
# checkout, with GH_REPO=cli/cli exported:
#
#   gh release list --limit 2 --json tagName   -> [{"tagName":"v2.100.0"}, ...]      cli/cli
#   gh release view --json tagName -q .tagName -> v2.100.0                           cli/cli
#   gh repo view    --json nameWithOwner       -> manderse21/claude-powershell-lsp   LOCAL
#
# The sweep followed GH_REPO; the "which repo am I on" command did not. So the fix 000285
# sketched -- ask gh what it resolved and compare -- would have been VACUOUS, agreeing with
# itself while the sweep read a stranger's releases. The shipped fix instead PINS the target and
# passes --repo on every call (the flag beats GH_REPO, measured), leaving gh nothing to resolve.
#
# These tests are pure: no gh, no git, no network. Resolve-AuditRepoTarget takes GH_REPO as a
# PARAMETER, which is exactly what lets the GH_REPO case be exercised on a machine where GH_REPO
# is not set -- the same technique 000285 used to exercise the Linux doctor probe from Windows.

BeforeAll {
    $script:PluginRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:PluginRoot 'scripts'
    $script:AuditScript = Join-Path $script:ScriptsDir 'audit-release-bodies.ps1'
    . (Join-Path $script:ScriptsDir 'lib/audit-repo-target.ps1')

    $script:Origin = 'manderse21/claude-powershell-lsp'
    $script:Foreign = 'cli/cli'
}

Describe 'audit-release-bodies -- the repository it sweeps is PINNED, not resolved by gh (dispatch 000286)' {

    Context 'RED CONTROL -- the PRIOR implementation leaves the door open' {
        It 'the prior construction emits NO --repo when -Repo is omitted, so gh resolves it' {
            # Not an arbitrary mutant: these are the exact two lines audit-release-bodies.ps1
            # carried before this dispatch. If this ever stops holding, the defect was not real.
            $priorImplementation = {
                param($Repo)
                $ghArgsRepo = @()
                if (-not [string]::IsNullOrWhiteSpace($Repo)) { $ghArgsRepo = @('--repo', $Repo) }
                return , $ghArgsRepo
            }

            # ASSIGNED, never re-wrapped in @(). The scriptblock returns with a leading comma so
            # an EMPTY array survives the pipeline; wrapping that result in @() would nest it and
            # .Count would read 1 over an empty instrument -- Hub Rule 37, which this control
            # tripped on its first run and which is precisely the failure mode it exists to avoid.
            $priorArgs = & $priorImplementation ''
            $priorArgs.Count | Should -Be 0 -Because 'with no -Repo the prior code passed gh nothing, so GH_REPO decided the target'

            # And the same input under the FIX pins the target explicitly. Both directions in
            # one place, so a reader can see the change rather than infer it.
            $fixed = Resolve-AuditRepoTarget -RepoParam '' -OriginSlug $script:Origin -GhRepoEnv '' -AllowForeignRepo $false
            $fixed.Error | Should -BeNullOrEmpty
            $fixed.Slug | Should -Be $script:Origin
        }

        It 'the prior construction DID pass --repo when -Repo was explicit (so only the omitted arm was open)' {
            $priorImplementation = {
                param($Repo)
                $ghArgsRepo = @()
                if (-not [string]::IsNullOrWhiteSpace($Repo)) { $ghArgsRepo = @('--repo', $Repo) }
                return , $ghArgsRepo
            }
            $priorArgs = & $priorImplementation $script:Foreign
            $priorArgs.Count | Should -Be 2
            $priorArgs[0] | Should -Be '--repo'
            $priorArgs[1] | Should -Be $script:Foreign
        }
    }

    Context 'the arm 000285 left open -- GH_REPO with no -Repo' {
        It 'REFUSES when GH_REPO names a repository that is not this checkout' {
            $r = Resolve-AuditRepoTarget -RepoParam '' -OriginSlug $script:Origin `
                -GhRepoEnv $script:Foreign -AllowForeignRepo $false
            $r.Error | Should -Not -BeNullOrEmpty
            $r.Slug | Should -BeNullOrEmpty
            # The refusal must NAME BOTH values, or the operator cannot act on it.
            $r.Error | Should -BeLike "*$($script:Foreign)*"
            $r.Error | Should -BeLike "*$($script:Origin)*"
        }

        It 'ALLOWS it, loudly, when -AllowForeignRepo is passed -- the escape hatch survives' {
            $r = Resolve-AuditRepoTarget -RepoParam '' -OriginSlug $script:Origin `
                -GhRepoEnv $script:Foreign -AllowForeignRepo $true
            $r.Error | Should -BeNullOrEmpty
            $r.Slug | Should -Be $script:Foreign
            $r.Source | Should -Be 'gh-repo-env'
            $r.Banner | Should -Not -BeNullOrEmpty
        }

        It 'OVER-CORRECTION GUARD: a GH_REPO that AGREES with the checkout is not a fault' {
            # A fix that refused on the mere PRESENCE of GH_REPO would break every operator who
            # sets it to this same repository, and would be a different defect, not a fix.
            $r = Resolve-AuditRepoTarget -RepoParam '' -OriginSlug $script:Origin `
                -GhRepoEnv $script:Origin -AllowForeignRepo $false
            $r.Error | Should -BeNullOrEmpty
            $r.Slug | Should -Be $script:Origin
            $r.Source | Should -Be 'origin'
            $r.Banner | Should -BeNullOrEmpty
        }
    }

    Context 'FAIL CLOSED -- an unpinnable target is refused, never guessed' {
        It 'refuses when origin cannot be resolved and no -Repo was given' {
            # Previously this fell through to gh's own resolution, which is the defect in its
            # purest form: a sweep whose target nothing in the process could name.
            $r = Resolve-AuditRepoTarget -RepoParam '' -OriginSlug '' -GhRepoEnv '' -AllowForeignRepo $false
            $r.Error | Should -Not -BeNullOrEmpty
            $r.Slug | Should -BeNullOrEmpty
        }

        It 'refuses an explicit -Repo when origin cannot be resolved (000285 behaviour, unchanged)' {
            $r = Resolve-AuditRepoTarget -RepoParam $script:Foreign -OriginSlug '' -GhRepoEnv '' -AllowForeignRepo $false
            $r.Error | Should -Not -BeNullOrEmpty
        }
    }

    Context 'the 000285 assertion still holds exactly as it did -- explicit -Repo' {
        It 'REFUSES a foreign -Repo without the override' {
            $r = Resolve-AuditRepoTarget -RepoParam $script:Foreign -OriginSlug $script:Origin `
                -GhRepoEnv '' -AllowForeignRepo $false
            $r.Error | Should -Not -BeNullOrEmpty
            $r.Error | Should -BeLike 'REPO IDENTITY:*'
        }

        It 'ALLOWS a foreign -Repo with the override, and banners it' {
            $r = Resolve-AuditRepoTarget -RepoParam $script:Foreign -OriginSlug $script:Origin `
                -GhRepoEnv '' -AllowForeignRepo $true
            $r.Error | Should -BeNullOrEmpty
            $r.Slug | Should -Be $script:Foreign
            $r.Banner | Should -BeLike 'FOREIGN REPO:*'
        }

        It 'ACCEPTS a -Repo that matches the checkout' {
            $r = Resolve-AuditRepoTarget -RepoParam $script:Origin -OriginSlug $script:Origin `
                -GhRepoEnv '' -AllowForeignRepo $false
            $r.Error | Should -BeNullOrEmpty
            $r.Slug | Should -Be $script:Origin
            $r.Banner | Should -BeNullOrEmpty
        }

        It 'an EXPLICIT -Repo is not overridden by a foreign GH_REPO -- the flag beats the env' {
            # Measured at gh 2.95.0: `gh release list --repo <slug>` returned <slug>'s releases
            # while GH_REPO=cli/cli was exported. The resolver must agree with gh's precedence,
            # or the refusal would fire on a command line that was already unambiguous.
            $r = Resolve-AuditRepoTarget -RepoParam $script:Origin -OriginSlug $script:Origin `
                -GhRepoEnv $script:Foreign -AllowForeignRepo $false
            $r.Error | Should -BeNullOrEmpty
            $r.Slug | Should -Be $script:Origin
            $r.Source | Should -Be 'repo-param'
        }
    }

    Context 'Get-AuditRepoSlug -- derivation from the remote, in either transport' {
        It 'reads an HTTPS remote' {
            Get-AuditRepoSlug -Url 'https://github.com/manderse21/claude-powershell-lsp.git' |
                Should -Be $script:Origin
        }
        It 'reads an SSH remote' {
            Get-AuditRepoSlug -Url 'git@github.com:manderse21/claude-powershell-lsp.git' |
                Should -Be $script:Origin
        }
        It 'returns empty for something it does not recognise, rather than a wrong slug' {
            Get-AuditRepoSlug -Url '' | Should -Be ''
            Get-AuditRepoSlug -Url 'not-a-remote' | Should -Be ''
        }
    }

    Context 'PAYLOAD FLOOR -- the shipped script actually USES the resolver' {
        # The resolver could be perfect while nothing called it. 000285 named this hazard in its
        # own doctor work and paid a CI cycle for it; these two assertions are the cheap version.
        BeforeAll {
            $script:AuditSrc = (Get-Content -LiteralPath $script:AuditScript -Raw) -replace '\s+', ' '
        }

        # EVERY needle below goes through .Contains(), never -BeLike, and that is not a style
        # preference. -BeLike is WILDCARD matching, so a '[' opens a CHARACTER CLASS: the pattern
        # '*[string]::IsNullOrWhiteSpace*' does not match the literal text '[string]::...' at all,
        # it matches one character from {s,t,r,i,n,g}. The absence assertion below was written
        # with -BeLike first and PASSED under a mutant that restored the very line it forbids --
        # a vacuous guard, caught only because the mutant was actually run. Demonstrated:
        #   $s = 'if (-not [string]::IsNullOrWhiteSpace($Repo)) { x }'
        #   $s.Contains('[string]')                         -> True
        #   $s -like '*[string]::IsNullOrWhiteSpace*'       -> False
        It 'dot-sources the resolver and passes --repo UNCONDITIONALLY' {
            $script:AuditSrc.Contains('lib/audit-repo-target.ps1') |
                Should -BeTrue -Because 'the resolver must actually be loaded'
            $script:AuditSrc.Contains("`$ghArgsRepo = @('--repo', `$auditTarget.Slug)") |
                Should -BeTrue -Because 'every gh call must carry an explicit, pinned --repo'
        }

        It 'no longer carries the PRIOR conditional construction that left gh to resolve' {
            # Whitespace-normalised so a re-wrap cannot fake this either way.
            $script:AuditSrc.Contains("if (-not [string]::IsNullOrWhiteSpace(`$Repo)) { `$ghArgsRepo = @('--repo', `$Repo) }") |
                Should -BeFalse -Because 'the prior construction is the defect; its return must be detectable'
        }

        It 'reads GH_REPO and feeds it to the resolver, so the env arm is actually wired' {
            $script:AuditSrc.Contains('-GhRepoEnv $env:GH_REPO') |
                Should -BeTrue -Because 'the GH_REPO arm is inert unless the real env value reaches it'
        }
    }
}
