[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Task,

    [Parameter()]
    [AllowEmptyString()]
    [string]$ConfigPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexDispatchState.Common.ps1')

try {
    if ([string]::IsNullOrWhiteSpace($Task)) {
        New-CodexDispatchRuntimeStateError 'Task 必须是 non-empty string。'
    }
    $config = Get-CodexDispatchRuntimeConfiguration -ConfigPath $ConfigPath
    $dispatchId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
    $now = [datetime]::UtcNow.ToString(
        'o',
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $state = [pscustomobject][ordered]@{
        version = 1
        dispatchId = $dispatchId
        revision = [int64]1
        createdAtUtc = $now
        updatedAtUtc = $now
        phase = 'routing'
        status = 'pending'
        task = $Task
        projectRepository = $null
        threadId = $null
        report = ''
        question = ''
        context = ''
        options = [string[]]@()
        diagnostic = ''
    }
    return Write-CodexDispatchStateCreate `
        -StateDirectory ([string]$config.runtime.stateDirectory) `
        -State $state
}
catch {
    ConvertTo-CodexDispatchRuntimeStateError `
        -ErrorRecord $_ `
        -Context '无法创建 dispatch state'
}
