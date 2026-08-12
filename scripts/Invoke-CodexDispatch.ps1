[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [AllowEmptyString()]
    [string]$Task,

    [Parameter()]
    [AllowEmptyString()]
    [string]$ConfigPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexDispatchOrchestrator.Common.ps1')

$dependencies = New-CodexDispatchOrchestratorDependencies
Invoke-CodexDispatchOrchestratorInternal `
    -Task $Task -ConfigPath $ConfigPath -Dependencies $dependencies
