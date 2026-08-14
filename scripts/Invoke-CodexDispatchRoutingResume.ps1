[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$DispatchId,
    [Parameter(Mandatory = $true, Position = 1)][AllowEmptyString()][string]$Answer,
    [Parameter(Mandatory = $true, Position = 2)][Int64]$IssueNumber,
    [Parameter()][AllowEmptyString()][string]$ConfigPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$publicFailure = 'Codex Dispatch Routing Resume Orchestrator error: execution failed.'
try {
    $commonPath = Join-Path $PSScriptRoot 'CodexDispatchRoutingResumeOrchestrator.Common.ps1'
    if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
        throw [System.InvalidOperationException]::new('Routing resume common is missing.')
    }
    . $commonPath
    $dependencies = New-CodexDispatchRoutingResumeOrchestratorDependencies
    Invoke-CodexDispatchRoutingResumeOrchestratorInternal -DispatchId $DispatchId -Answer $Answer -IssueNumber $IssueNumber -ConfigPath $ConfigPath -Dependencies $dependencies
}
catch {
    throw [System.InvalidOperationException]::new($publicFailure)
}
