[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$DispatchId,

    [Parameter(Mandatory = $true)]
    [object]$ExpectedRevision,

    [Parameter(Mandatory = $true)]
    [object]$Phase,

    [Parameter(Mandatory = $true)]
    [object]$Status,

    [Parameter()]
    [AllowNull()]
    [object]$ProjectRepository,

    [Parameter()]
    [AllowNull()]
    [object]$ThreadId,

    [Parameter()]
    [AllowNull()]
    [object]$Report,

    [Parameter()]
    [AllowNull()]
    [object]$Question,

    [Parameter()]
    [AllowNull()]
    [object]$Context,

    [Parameter()]
    [AllowNull()]
    [object]$Options,

    [Parameter()]
    [AllowNull()]
    [object]$Diagnostic,

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
    if (-not (Test-CodexDispatchStateInteger -Value $ExpectedRevision)) {
        New-CodexDispatchRuntimeStateError 'ExpectedRevision 必须是 integer >= 1。'
    }
    try {
        $expectedRevisionValue = [int64]$ExpectedRevision
    }
    catch {
        New-CodexDispatchRuntimeStateError 'ExpectedRevision 超出支持范围。'
    }
    if ($expectedRevisionValue -lt 1) {
        New-CodexDispatchRuntimeStateError 'ExpectedRevision 必须是 integer >= 1。'
    }
    if ($Phase -isnot [string] -or [string]$Phase -cnotin @('routing', 'worker')) {
        New-CodexDispatchRuntimeStateError "Phase 无效：$Phase。"
    }
    if ($Status -isnot [string] -or [string]$Status -cnotin @(
        'pending', 'running', 'needs_input', 'completed', 'failed'
    )) {
        New-CodexDispatchRuntimeStateError "Status 无效：$Status。"
    }

    $changes = [ordered]@{}
    if ($PSBoundParameters.ContainsKey('ProjectRepository')) {
        $changes['projectRepository'] = ConvertTo-CodexDispatchRepositoryIdentity `
            -Value $ProjectRepository `
            -Context 'ProjectRepository' `
            -AllowNull
    }
    if ($PSBoundParameters.ContainsKey('ThreadId')) {
        $changes['threadId'] = ConvertTo-CodexDispatchCanonicalThreadId `
            -Value $ThreadId `
            -Context 'ThreadId' `
            -AllowNull
    }
    foreach ($fieldName in @('Report', 'Question', 'Context', 'Diagnostic')) {
        if ($PSBoundParameters.ContainsKey($fieldName)) {
            $fieldValue = $PSBoundParameters[$fieldName]
            if ($fieldValue -isnot [string]) {
                New-CodexDispatchRuntimeStateError "$fieldName 必须是 string。"
            }
            $changes[$fieldName.Substring(0, 1).ToLowerInvariant() + $fieldName.Substring(1)] = [string]$fieldValue
        }
    }
    if ($PSBoundParameters.ContainsKey('Options')) {
        $changes['options'] = ConvertTo-CodexDispatchOptionsArray `
            -Value $Options `
            -Context 'Options'
    }

    $config = Get-CodexDispatchRuntimeConfiguration -ConfigPath $ConfigPath
    return Update-CodexDispatchStateTransaction `
        -StateDirectory ([string]$config.runtime.stateDirectory) `
        -CanonicalDispatchId $canonicalDispatchId `
        -ExpectedRevision $expectedRevisionValue `
        -Phase ([string]$Phase) `
        -Status ([string]$Status) `
        -Changes $changes
}
catch {
    ConvertTo-CodexDispatchRuntimeStateError `
        -ErrorRecord $_ `
        -Context '无法更新 dispatch state'
}
