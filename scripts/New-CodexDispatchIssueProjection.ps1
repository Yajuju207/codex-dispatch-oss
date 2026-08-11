[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$DispatchId,

    [Parameter()]
    [AllowEmptyString()]
    [string]$ConfigPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexDispatchGitHubIssue.Common.ps1')

try {
    $context = Get-CodexDispatchGitHubProjectionContext `
        -DispatchId $DispatchId `
        -ConfigPath $ConfigPath
    return $context.projection
}
catch {
    ConvertTo-CodexDispatchGitHubIssueError `
        -ErrorRecord $_ `
        -Context '无法生成 Issue projection'
}
