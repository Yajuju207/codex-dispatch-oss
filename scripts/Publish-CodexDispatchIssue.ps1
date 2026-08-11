[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$DispatchId,

    [Parameter()]
    [AllowNull()]
    [object]$IssueNumber,

    [Parameter()]
    [AllowEmptyString()]
    [string]$ConfigPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexDispatchGitHubIssue.Common.ps1')

$token = [Environment]::GetEnvironmentVariable(
    'CODEX_DISPATCH_GITHUB_TOKEN',
    [EnvironmentVariableTarget]::Process
)
try {
    if ([string]::IsNullOrWhiteSpace($token)) {
        New-CodexDispatchGitHubIssueError `
            -Message '缺少 CODEX_DISPATCH_GITHUB_TOKEN。'
    }
    return Invoke-CodexDispatchGitHubIssuePublishInternal `
        -DispatchId $DispatchId `
        -IssueNumber $IssueNumber `
        -ConfigPath $ConfigPath `
        -Token $token `
        -Transport (Get-CodexDispatchGitHubDefaultTransport)
}
catch {
    ConvertTo-CodexDispatchGitHubIssueError `
        -ErrorRecord $_ `
        -Context '无法发布 Issue' `
        -Token $token
}
