function Read-ConfigFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $content = $null
    try {
        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    }
    catch [System.IO.FileNotFoundException] {
        Write-Warning "Config file not found: $Path"
    }
    catch {
        Write-Warning "Failed to read config: $($_.Exception.Message)"
    }
    finally {
        Write-Verbose "Read attempt complete for $Path"
    }
    return $content
}
