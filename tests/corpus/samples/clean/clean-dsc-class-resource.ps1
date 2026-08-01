#Requires -Version 5.1

<#
.SYNOPSIS
    KNOWN-GOOD corpus sample: a class-based DSC resource (dispatch 000171 leg 3).
.DESCRIPTION
    One of the three round-3 shapes that are reachable with ZERO third-party source
    vendored. A class-based [DscResource()] is ordinary PowerShell class syntax plus
    two attributes, so it parses on BOTH analysis hosts without any module present.

    IT DELIBERATELY CARRIES NO 'Import-DscResource -ModuleName PSDesiredStateConfiguration'.
    Dispatch 000170 measured that line as a HARD PARSE ERROR under pwsh 7 ("Could not
    find the module"), and pwsh is the analysis host on every CI leg -- so a fixture
    carrying it would be a parser sample wearing a clean sample's name.

    Being in samples/clean, this file's contribution is to the measured FALSE-POSITIVE
    rate: the tool must stay SILENT on it. That is the point -- DSC resource syntax is a
    shape the analyzer had never been exercised against.
#>

enum CleanDscEnsure {
    Absent
    Present
}

[DscResource()]
class CleanDscTextFileResource {

    [DscProperty(Key)]
    [string] $Path

    [DscProperty(Mandatory)]
    [CleanDscEnsure] $Ensure

    [DscProperty()]
    [string] $Contents

    [CleanDscTextFileResource] Get() {
        $current = [CleanDscTextFileResource]::new()
        $current.Path = $this.Path
        if (Test-Path -LiteralPath $this.Path) {
            $current.Ensure = [CleanDscEnsure]::Present
            $current.Contents = Get-Content -LiteralPath $this.Path -Raw
        } else {
            $current.Ensure = [CleanDscEnsure]::Absent
            $current.Contents = ''
        }
        return $current
    }

    [bool] Test() {
        $current = $this.Get()
        if ($current.Ensure -ne $this.Ensure) {
            return $false
        }
        if ($this.Ensure -eq [CleanDscEnsure]::Absent) {
            return $true
        }
        return ($current.Contents -eq $this.Contents)
    }

    [void] Set() {
        if ($this.Ensure -eq [CleanDscEnsure]::Present) {
            Set-Content -LiteralPath $this.Path -Value $this.Contents -Encoding ascii
            return
        }
        if (Test-Path -LiteralPath $this.Path) {
            Remove-Item -LiteralPath $this.Path
        }
    }
}
