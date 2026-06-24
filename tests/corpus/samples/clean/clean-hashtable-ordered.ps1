function New-ServerConfig {
    [CmdletBinding()]
    param (
        [string]$ServerName = 'localhost',
        [int]$Port = 8080
    )
    $config = [ordered]@{
        ServerName = $ServerName
        Port       = $Port
        Endpoint   = "http://${ServerName}:$Port"
    }
    return $config
}
