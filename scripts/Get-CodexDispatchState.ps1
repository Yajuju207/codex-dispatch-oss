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
. (Join-Path $PSScriptRoot 'CodexDispatchState.Common.ps1')

try {
    $canonicalDispatchId = ConvertTo-CodexDispatchCanonicalGuid `
        -Value $DispatchId `
        -Context 'dispatchId'
    $config = Get-CodexDispatchRuntimeConfiguration -ConfigPath $ConfigPath
    $dispatchesDirectory = Get-CodexDispatchesDirectory `
        -StateDirectory ([string]$config.runtime.stateDirectory)
    if ([string]::IsNullOrWhiteSpace($dispatchesDirectory)) {
        New-CodexDispatchRuntimeStateError "找不到 dispatch state：$canonicalDispatchId。"
    }
    $statePath = Get-CodexDispatchStateFilePath `
        -DispatchesDirectory $dispatchesDirectory `
        -CanonicalDispatchId $canonicalDispatchId
    return Read-CodexDispatchStateFile `
        -StateFilePath $statePath `
        -ExpectedDispatchId $canonicalDispatchId
}
catch {
    ConvertTo-CodexDispatchRuntimeStateError `
        -ErrorRecord $_ `
        -Context '无法读取 dispatch state'
}
