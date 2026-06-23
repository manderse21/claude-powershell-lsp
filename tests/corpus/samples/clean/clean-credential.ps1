function Get-AccountName {
    param([System.Management.Automation.PSCredential]$Credential)
    Write-Output $Credential.UserName
}
