Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:CodexDispatchOrchestratorCredentialNames = [string[]]@(
    'CODEX_DISPATCH_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN'
)
$script:CodexDispatchOrchestratorErrorPrefix = 'Codex Dispatch Orchestrator 错误：'

function New-CodexDispatchOrchestratorError {
    param([Parameter(Mandatory = $true)][string]$Message)

    throw [System.InvalidOperationException]::new(
        $script:CodexDispatchOrchestratorErrorPrefix + $Message
    )
}

function Test-CodexDispatchOrchestratorObject {
    param([Parameter()][AllowNull()][object]$Value)

    return (
        $null -ne $Value -and $Value -isnot [string] -and
        $Value -isnot [System.Array] -and $Value -isnot [System.ValueType]
    )
}

function Test-CodexDispatchOrchestratorInteger {
    param([Parameter()][AllowNull()][object]$Value)

    return (
        $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
    )
}

function Assert-CodexDispatchOrchestratorExactProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (-not (Test-CodexDispatchOrchestratorObject -Value $Value)) {
        New-CodexDispatchOrchestratorError "$Context 必须是 object。"
    }
    $actual = [string[]]@($Value.PSObject.Properties.Name)
    if (($actual -join ',') -cne ($Names -join ',')) {
        New-CodexDispatchOrchestratorError (
            "$Context 字段 contract 无效。expected=" + ($Names -join ',') +
            '; actual=' + ($actual -join ',')
        )
    }
}

function Test-CodexDispatchOrchestratorRepository {
    param([Parameter()][AllowNull()][object]$Value)

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $false
    }
    $identity = [string]$Value
    $match = [regex]::Match(
        $identity,
        '^(?<owner>[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/(?<repo>[A-Za-z0-9._-]{1,100})$'
    )
    return (
        $match.Success -and $identity -ceq $identity.Trim() -and
        -not $match.Groups['owner'].Value.Contains('--') -and
        $match.Groups['repo'].Value -notin @('.', '..')
    )
}

function Get-CodexDispatchOrchestratorCredentialSnapshot {
    $environment = [Environment]::GetEnvironmentVariables(
        [EnvironmentVariableTarget]::Process
    )
    $records = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $script:CodexDispatchOrchestratorCredentialNames) {
        $exists = $environment.Contains($name)
        [void]$records.Add([pscustomobject][ordered]@{
            name = $name
            exists = [bool]$exists
            value = if ($exists) { [string]$environment[$name] } else { $null }
        })
    }
    return [object[]]$records.ToArray()
}

function Remove-CodexDispatchOrchestratorCredentials {
    foreach ($name in $script:CodexDispatchOrchestratorCredentialNames) {
        [Environment]::SetEnvironmentVariable(
            $name, $null, [EnvironmentVariableTarget]::Process
        )
    }
}

function Set-CodexDispatchOrchestratorEmptyEnvironmentVariable {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not ('CodexDispatchOrchestrator.NativeEnvironment' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace CodexDispatchOrchestrator {
    public static class NativeEnvironment {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool SetEnvironmentVariable(string name, string value);
        public static void SetEmpty(string name) {
            if (!SetEnvironmentVariable(name, String.Empty)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }
}
'@
    }
    [CodexDispatchOrchestrator.NativeEnvironment]::SetEmpty($Name)
}

function Restore-CodexDispatchOrchestratorCredential {
    param([Parameter(Mandatory = $true)][object]$Record)

    if (-not [bool]$Record.exists) {
        [Environment]::SetEnvironmentVariable(
            [string]$Record.name, $null, [EnvironmentVariableTarget]::Process
        )
        return
    }
    if ([string]$Record.value -ceq '') {
        Set-CodexDispatchOrchestratorEmptyEnvironmentVariable `
            -Name ([string]$Record.name)
        return
    }
    [Environment]::SetEnvironmentVariable(
        [string]$Record.name,
        [string]$Record.value,
        [EnvironmentVariableTarget]::Process
    )
}

function Restore-CodexDispatchOrchestratorCredentials {
    param([Parameter(Mandatory = $true)][object[]]$Snapshot)

    foreach ($record in $Snapshot) {
        Restore-CodexDispatchOrchestratorCredential -Record $record
    }
}

function Get-CodexDispatchOrchestratorCredentialRecord {
    param(
        [Parameter(Mandatory = $true)][object[]]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $matches = @($Snapshot | Where-Object { [string]$_.name -ceq $Name })
    if ($matches.Count -ne 1) {
        New-CodexDispatchOrchestratorError "Credential snapshot 缺少 $Name。"
    }
    return $matches[0]
}

function ConvertTo-CodexDispatchOrchestratorSafeDiagnostic {
    param(
        [Parameter()][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][object[]]$CredentialSnapshot,
        [Parameter(Mandatory = $true)][string]$Fallback,
        [Parameter()][int]$MaximumLength = 2048
    )

    $text = if ($null -eq $Value) { '' } else { ([string]$Value).Trim() }
    if ([string]::IsNullOrWhiteSpace($text)) { $text = $Fallback }
    foreach ($record in $CredentialSnapshot) {
        if (
            [bool]$record.exists -and
            -not [string]::IsNullOrEmpty([string]$record.value)
        ) {
            $text = $text.Replace([string]$record.value, '[REDACTED]')
        }
    }
    $text = $text.Replace("`r", ' ').Replace("`n", ' ')
    if ($text.Length -gt $MaximumLength) {
        $text = $text.Substring(0, $MaximumLength - 3) + '...'
    }
    return $text
}

function Get-CodexDispatchOrchestratorIndexPath {
    $candidate = Join-Path -Path (Get-Location).Path -ChildPath 'project-index.json'
    try { $fullPath = [System.IO.Path]::GetFullPath($candidate) }
    catch { New-CodexDispatchOrchestratorError 'project-index.json path 无效。' }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        New-CodexDispatchOrchestratorError "找不到 Project Index：$fullPath。"
    }
    $item = Get-Item -Force -LiteralPath $fullPath
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        New-CodexDispatchOrchestratorError 'Project Index 不能是 reparse point。'
    }
    return $item.FullName
}

function New-CodexDispatchOrchestratorDependencies {
    $newStatePath = Join-Path $PSScriptRoot 'New-CodexDispatchState.ps1'
    $getStatePath = Join-Path $PSScriptRoot 'Get-CodexDispatchState.ps1'
    $updateStatePath = Join-Path $PSScriptRoot 'Update-CodexDispatchState.ps1'
    $fastRouterPath = Join-Path $PSScriptRoot 'Fast-Route-CodexTask.ps1'
    $slowRouterPath = Join-Path $PSScriptRoot 'Slow-Route-CodexTask.ps1'
    $workerPath = Join-Path $PSScriptRoot 'Invoke-CodexWorker.ps1'
    $publisherPath = Join-Path $PSScriptRoot 'Publish-CodexDispatchIssue.ps1'
    foreach ($path in @(
        $newStatePath, $getStatePath, $updateStatePath, $fastRouterPath,
        $slowRouterPath, $workerPath, $publisherPath
    )) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            New-CodexDispatchOrchestratorError "找不到 dependency：$path。"
        }
    }

    $newState = { param($Request) & $newStatePath @Request }.GetNewClosure()
    $getState = { param($Request) & $getStatePath @Request }.GetNewClosure()
    $updateState = { param($Request) & $updateStatePath @Request }.GetNewClosure()
    $fastRouter = { param($Request) & $fastRouterPath @Request }.GetNewClosure()
    $slowRouter = { param($Request) & $slowRouterPath @Request }.GetNewClosure()
    $worker = { param($Request) & $workerPath @Request }.GetNewClosure()
    $publisher = { param($Request) & $publisherPath @Request }.GetNewClosure()

    return [pscustomobject][ordered]@{
        NewState = $newState
        GetState = $getState
        UpdateState = $updateState
        FastRouter = $fastRouter
        SlowRouter = $slowRouter
        Worker = $worker
        Publisher = $publisher
    }
}

function Assert-CodexDispatchOrchestratorDependencies {
    param([Parameter(Mandatory = $true)][object]$Dependencies)

    Assert-CodexDispatchOrchestratorExactProperties `
        -Value $Dependencies `
        -Names @(
            'NewState', 'GetState', 'UpdateState', 'FastRouter',
            'SlowRouter', 'Worker', 'Publisher'
        ) `
        -Context 'Orchestrator dependencies'
    foreach ($name in $Dependencies.PSObject.Properties.Name) {
        if ($Dependencies.$name -isnot [scriptblock]) {
            New-CodexDispatchOrchestratorError "Dependency $name 必须是 scriptblock。"
        }
    }
}

function Assert-CodexDispatchOrchestratorFastResult {
    param([Parameter(Mandatory = $true)][object]$Result)

    Assert-CodexDispatchOrchestratorExactProperties `
        -Value $Result `
        -Names @('version','status','topScore','lead','selectedProject','candidates') `
        -Context 'Fast Router result'
    if (-not (Test-CodexDispatchOrchestratorInteger $Result.version) -or [int64]$Result.version -ne 1) {
        New-CodexDispatchOrchestratorError 'Fast Router result version 必须是 1。'
    }
    if ($Result.status -isnot [string] -or [string]$Result.status -cnotin @(
        'strong','ambiguous','no_match','disabled'
    )) {
        New-CodexDispatchOrchestratorError 'Fast Router result status contract 无效。'
    }
    if (
        -not (Test-CodexDispatchOrchestratorInteger $Result.topScore) -or
        -not (Test-CodexDispatchOrchestratorInteger $Result.lead) -or
        $Result.candidates -isnot [System.Array]
    ) {
        New-CodexDispatchOrchestratorError 'Fast Router result score/candidates contract 无效。'
    }
    if ([string]$Result.status -ceq 'strong') {
        Assert-CodexDispatchOrchestratorExactProperties `
            -Value $Result.selectedProject `
            -Names @('name','localPath','githubRepository','score','matchedSignals') `
            -Context 'Fast Router selectedProject'
        $repository = $Result.selectedProject.githubRepository
        if ($null -ne $repository -and -not (
            Test-CodexDispatchOrchestratorRepository -Value $repository
        )) {
            New-CodexDispatchOrchestratorError `
                'Fast Router strong repository 必须是合法 identity 或 null。'
        }
    }
    elseif ($null -ne $Result.selectedProject) {
        New-CodexDispatchOrchestratorError `
            'Fast Router non-strong selectedProject 必须是 null。'
    }
}

function Assert-CodexDispatchOrchestratorSlowResult {
    param([Parameter(Mandatory = $true)][object]$Result)

    Assert-CodexDispatchOrchestratorExactProperties `
        -Value $Result `
        -Names @('version','status','selectedProject','confidence','reason','question','options') `
        -Context 'Slow Router result'
    if (-not (Test-CodexDispatchOrchestratorInteger $Result.version) -or [int64]$Result.version -ne 1) {
        New-CodexDispatchOrchestratorError 'Slow Router result version 必须是 1。'
    }
    if ($Result.status -isnot [string] -or [string]$Result.status -cnotin @(
        'routed','needs_input','no_match','disabled'
    )) {
        New-CodexDispatchOrchestratorError 'Slow Router result status contract 无效。'
    }
    if ($Result.options -isnot [System.Array]) {
        New-CodexDispatchOrchestratorError 'Slow Router result options 必须是 array。'
    }
    if ([string]$Result.status -ceq 'routed') {
        Assert-CodexDispatchOrchestratorExactProperties `
            -Value $Result.selectedProject `
            -Names @('name','localPath','githubRepository') `
            -Context 'Slow Router selectedProject'
        if (-not (Test-CodexDispatchOrchestratorRepository `
            -Value $Result.selectedProject.githubRepository
        )) {
            New-CodexDispatchOrchestratorError `
                'Slow Router routed repository identity 无效。'
        }
    }
    elseif ($null -ne $Result.selectedProject) {
        New-CodexDispatchOrchestratorError `
            'Slow Router non-routed selectedProject 必须是 null。'
    }
    if ([string]$Result.status -ceq 'needs_input') {
        if (
            $Result.question -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$Result.question)
        ) {
            New-CodexDispatchOrchestratorError `
                'Slow Router needs_input question 无效。'
        }
        $distinct = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )
        foreach ($option in $Result.options) {
            if ($option -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$option)) {
                New-CodexDispatchOrchestratorError `
                    'Slow Router needs_input option 无效。'
            }
            [void]$distinct.Add([string]$option)
        }
        if ($distinct.Count -lt 2) {
            New-CodexDispatchOrchestratorError `
                'Slow Router needs_input 至少需要两个 distinct options。'
        }
    }
    if (
        [string]$Result.status -ceq 'no_match' -and
        ($Result.reason -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$Result.reason))
    ) {
        New-CodexDispatchOrchestratorError 'Slow Router no_match reason 无效。'
    }
}

function Assert-CodexDispatchOrchestratorWorkerResult {
    param([Parameter(Mandatory = $true)][object]$Result)

    Assert-CodexDispatchOrchestratorExactProperties `
        -Value $Result `
        -Names @(
            'version','status','project','threadId','report','question','context',
            'options','exitCode','diagnostic'
        ) `
        -Context 'Worker result'
    if (-not (Test-CodexDispatchOrchestratorInteger $Result.version) -or [int64]$Result.version -ne 1) {
        New-CodexDispatchOrchestratorError 'Worker result version 必须是 1。'
    }
    if ($Result.status -isnot [string] -or [string]$Result.status -cnotin @(
        'completed','needs_input','failed'
    )) {
        New-CodexDispatchOrchestratorError 'Worker result status contract 无效。'
    }
    if ($Result.options -isnot [System.Array]) {
        New-CodexDispatchOrchestratorError 'Worker result options 必须是 array。'
    }
    if ([string]$Result.status -cin @('completed','needs_input')) {
        $threadGuid = [guid]::Empty
        if (
            $Result.threadId -isnot [string] -or
            -not [guid]::TryParseExact([string]$Result.threadId, 'D', [ref]$threadGuid) -or
            [string]$Result.threadId -cne $threadGuid.ToString('D').ToLowerInvariant()
        ) {
            New-CodexDispatchOrchestratorError `
                'Worker completed/needs_input threadId contract 无效。'
        }
    }
    elseif ($null -ne $Result.threadId) {
        $threadGuid = [guid]::Empty
        if (
            $Result.threadId -isnot [string] -or
            -not [guid]::TryParseExact([string]$Result.threadId, 'D', [ref]$threadGuid) -or
            [string]$Result.threadId -cne $threadGuid.ToString('D').ToLowerInvariant()
        ) {
            New-CodexDispatchOrchestratorError `
                'Worker failed threadId 必须是 canonical UUID D 或 null。'
        }
    }
    if (
        [string]$Result.status -ceq 'completed' -and
        ($Result.report -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$Result.report))
    ) {
        New-CodexDispatchOrchestratorError 'Worker completed report 无效。'
    }
    if ([string]$Result.status -ceq 'needs_input') {
        foreach ($field in @('report','question','context')) {
            if (
                $Result.$field -isnot [string] -or
                [string]::IsNullOrWhiteSpace([string]$Result.$field)
            ) {
                New-CodexDispatchOrchestratorError `
                    "Worker needs_input $field 无效。"
            }
        }
        $distinct = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )
        foreach ($option in $Result.options) {
            if ($option -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$option)) {
                New-CodexDispatchOrchestratorError `
                    'Worker needs_input option 无效。'
            }
            [void]$distinct.Add([string]$option)
        }
        if ($distinct.Count -lt 2) {
            New-CodexDispatchOrchestratorError `
                'Worker needs_input 至少需要两个 distinct options。'
        }
    }
    if (
        [string]$Result.status -ceq 'failed' -and
        ($Result.diagnostic -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$Result.diagnostic))
    ) {
        New-CodexDispatchOrchestratorError 'Worker failed diagnostic 无效。'
    }
}

function Get-CodexDispatchOrchestratorRoutingIntervention {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('technical','no_match','disabled')]
        [string]$Kind,
        [Parameter()][AllowNull()][object]$Reason,
        [Parameter(Mandatory = $true)][object[]]$CredentialSnapshot
    )

    if ($Kind -ceq 'technical') {
        return [pscustomobject][ordered]@{
            report = 'Routing requires operator intervention.'
            question = 'Retry routing or stop this dispatch?'
            context = ConvertTo-CodexDispatchOrchestratorSafeDiagnostic `
                -Value $Reason -CredentialSnapshot $CredentialSnapshot `
                -Fallback 'A Router component failed or returned an invalid contract.'
            options = [string[]]@('Retry routing','Stop dispatch')
        }
    }
    if ($Kind -ceq 'no_match') {
        return [pscustomobject][ordered]@{
            report = 'Routing could not select a project.'
            question = 'Retry routing with more project detail or stop this dispatch?'
            context = ConvertTo-CodexDispatchOrchestratorSafeDiagnostic `
                -Value $Reason -CredentialSnapshot $CredentialSnapshot `
                -Fallback 'Slow Router found no matching project.'
            options = [string[]]@('Retry routing','Stop dispatch')
        }
    }
    return [pscustomobject][ordered]@{
        report = 'Routing requires operator intervention.'
        question = 'Enable Slow Router and retry, or stop this dispatch?'
        context = 'Fast Router did not select a project and Slow Router is disabled.'
        options = [string[]]@('Retry routing','Stop dispatch')
    }
}

function Update-CodexDispatchOrchestratorState {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Parameters
    )

    return & $Action $Parameters
}

function Get-CodexDispatchOrchestratorDurableState {
    param(
        [Parameter(Mandatory = $true)][object]$Dependencies,
        [Parameter(Mandatory = $true)][string]$DispatchId,
        [Parameter()][AllowEmptyString()][string]$ConfigPath
    )

    return & $Dependencies.GetState ([ordered]@{
        DispatchId = $DispatchId
        ConfigPath = $ConfigPath
    })
}

function Publish-CodexDispatchOrchestratorState {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Dependencies,
        [Parameter()][AllowEmptyString()][string]$ConfigPath,
        [Parameter(Mandatory = $true)][object[]]$CredentialSnapshot
    )

    $publication = 'failed'
    $issueNumber = $null
    $issueUrl = $null
    $projectionDiagnostic = ''
    $githubRecord = Get-CodexDispatchOrchestratorCredentialRecord `
        -Snapshot $CredentialSnapshot -Name 'CODEX_DISPATCH_GITHUB_TOKEN'
    try {
        Restore-CodexDispatchOrchestratorCredential -Record $githubRecord
        try {
            $result = & $Dependencies.Publisher ([ordered]@{
                DispatchId = [string]$State.dispatchId
                ConfigPath = $ConfigPath
            })
            Assert-CodexDispatchOrchestratorExactProperties `
                -Value $result `
                -Names @(
                    'version','action','dispatchId','revision','repository',
                    'issueNumber','issueUrl'
                ) `
                -Context 'Issue Publisher result'
            if (
                -not (Test-CodexDispatchOrchestratorInteger $result.version) -or
                [int64]$result.version -ne 1 -or
                $result.action -isnot [string] -or [string]$result.action -cne 'created' -or
                [string]$result.dispatchId -cne [string]$State.dispatchId -or
                -not (Test-CodexDispatchOrchestratorInteger $result.revision) -or
                [int64]$result.revision -ne [int64]$State.revision -or
                -not (Test-CodexDispatchOrchestratorInteger $result.issueNumber) -or
                [int64]$result.issueNumber -lt 1 -or
                $result.issueUrl -isnot [string] -or
                [string]::IsNullOrWhiteSpace([string]$result.issueUrl)
            ) {
                New-CodexDispatchOrchestratorError `
                    'Initial Issue Publisher result contract 无效；expected action=created。'
            }
            $publication = 'created'
            $issueNumber = [int64]$result.issueNumber
            $issueUrl = [string]$result.issueUrl
        }
        catch {
            $projectionDiagnostic = ConvertTo-CodexDispatchOrchestratorSafeDiagnostic `
                -Value $_.Exception.Message `
                -CredentialSnapshot $CredentialSnapshot `
                -Fallback 'Issue publication failed.'
        }
    }
    finally {
        [Environment]::SetEnvironmentVariable(
            'CODEX_DISPATCH_GITHUB_TOKEN', $null,
            [EnvironmentVariableTarget]::Process
        )
    }
    return [pscustomobject][ordered]@{
        issuePublication = $publication
        issueNumber = $issueNumber
        issueUrl = $issueUrl
        projectionDiagnostic = $projectionDiagnostic
    }
}

function New-CodexDispatchOrchestratorOutput {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$ProjectionMetadata
    )

    if (
        [string]$State.phase -cnotin @('routing','worker') -or
        [string]$State.status -cnotin @('needs_input','completed','failed')
    ) {
        New-CodexDispatchOrchestratorError `
            'Public output 只能返回 needs_input、completed 或 failed durable state。'
    }
    return [pscustomobject][ordered]@{
        version = 1
        dispatchId = [string]$State.dispatchId
        revision = [int64]$State.revision
        phase = [string]$State.phase
        status = [string]$State.status
        projectRepository = $State.projectRepository
        report = [string]$State.report
        question = [string]$State.question
        context = [string]$State.context
        options = [string[]]$State.options
        diagnostic = [string]$State.diagnostic
        issuePublication = [string]$ProjectionMetadata.issuePublication
        issueNumber = $ProjectionMetadata.issueNumber
        issueUrl = $ProjectionMetadata.issueUrl
        projectionDiagnostic = [string]$ProjectionMetadata.projectionDiagnostic
    }
}

function Complete-CodexDispatchOrchestratorVisibleState {
    param(
        [Parameter(Mandatory = $true)][object]$CurrentState,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$UpdateParameters,
        [Parameter(Mandatory = $true)][object]$Dependencies,
        [Parameter()][AllowEmptyString()][string]$ConfigPath,
        [Parameter(Mandatory = $true)][object[]]$CredentialSnapshot
    )

    [void](Update-CodexDispatchOrchestratorState `
        -Action $Dependencies.UpdateState -Parameters $UpdateParameters)
    $durable = Get-CodexDispatchOrchestratorDurableState `
        -Dependencies $Dependencies `
        -DispatchId ([string]$CurrentState.dispatchId) `
        -ConfigPath $ConfigPath
    $projection = Publish-CodexDispatchOrchestratorState `
        -State $durable -Dependencies $Dependencies -ConfigPath $ConfigPath `
        -CredentialSnapshot $CredentialSnapshot
    return New-CodexDispatchOrchestratorOutput `
        -State $durable -ProjectionMetadata $projection
}

function Invoke-CodexDispatchOrchestratorInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Task,
        [Parameter()][AllowEmptyString()][string]$ConfigPath,
        [Parameter(Mandatory = $true)][object]$Dependencies
    )

    $credentialSnapshot = Get-CodexDispatchOrchestratorCredentialSnapshot
    try {
        Remove-CodexDispatchOrchestratorCredentials
        if ([string]::IsNullOrWhiteSpace($Task)) {
            New-CodexDispatchOrchestratorError 'Task 必须是非空字符串。'
        }
        Assert-CodexDispatchOrchestratorDependencies -Dependencies $Dependencies
        $indexPath = Get-CodexDispatchOrchestratorIndexPath

        $state = & $Dependencies.NewState ([ordered]@{
            Task = $Task
            ConfigPath = $ConfigPath
        })
        [void](Update-CodexDispatchOrchestratorState `
            -Action $Dependencies.UpdateState `
            -Parameters ([ordered]@{
                DispatchId = [string]$state.dispatchId
                ExpectedRevision = [int64]$state.revision
                Phase = 'routing'
                Status = 'running'
                ConfigPath = $ConfigPath
            }))
        $state = Get-CodexDispatchOrchestratorDurableState `
            -Dependencies $Dependencies -DispatchId ([string]$state.dispatchId) `
            -ConfigPath $ConfigPath

        $fastResult = $null
        try {
            $fastResult = & $Dependencies.FastRouter ([ordered]@{
                Task = $Task
                ConfigPath = $ConfigPath
                IndexPath = $indexPath
            })
            Assert-CodexDispatchOrchestratorFastResult -Result $fastResult
        }
        catch {
            $intervention = Get-CodexDispatchOrchestratorRoutingIntervention `
                -Kind technical -Reason $_.Exception.Message `
                -CredentialSnapshot $credentialSnapshot
            return Complete-CodexDispatchOrchestratorVisibleState `
                -CurrentState $state -Dependencies $Dependencies `
                -ConfigPath $ConfigPath -CredentialSnapshot $credentialSnapshot `
                -UpdateParameters ([ordered]@{
                    DispatchId = [string]$state.dispatchId
                    ExpectedRevision = [int64]$state.revision
                    Phase = 'routing'; Status = 'needs_input'
                    Report = $intervention.report; Question = $intervention.question
                    Context = $intervention.context; Options = $intervention.options
                    ConfigPath = $ConfigPath
                })
        }

        $projectRepository = $null
        $useSlowRouter = $true
        if ([string]$fastResult.status -ceq 'strong') {
            if ($null -eq $fastResult.selectedProject.githubRepository) {
                $useSlowRouter = $true
            }
            else {
                $projectRepository = [string]$fastResult.selectedProject.githubRepository
                $useSlowRouter = $false
            }
        }

        if ($useSlowRouter) {
            $slowResult = $null
            try {
                $slowResult = & $Dependencies.SlowRouter ([ordered]@{
                    Task = $Task
                    ConfigPath = $ConfigPath
                    IndexPath = $indexPath
                })
                Assert-CodexDispatchOrchestratorSlowResult -Result $slowResult
            }
            catch {
                $intervention = Get-CodexDispatchOrchestratorRoutingIntervention `
                    -Kind technical -Reason $_.Exception.Message `
                    -CredentialSnapshot $credentialSnapshot
                return Complete-CodexDispatchOrchestratorVisibleState `
                    -CurrentState $state -Dependencies $Dependencies `
                    -ConfigPath $ConfigPath -CredentialSnapshot $credentialSnapshot `
                    -UpdateParameters ([ordered]@{
                        DispatchId = [string]$state.dispatchId
                        ExpectedRevision = [int64]$state.revision
                        Phase = 'routing'; Status = 'needs_input'
                        Report = $intervention.report; Question = $intervention.question
                        Context = $intervention.context; Options = $intervention.options
                        ConfigPath = $ConfigPath
                    })
            }
            if ([string]$slowResult.status -ceq 'routed') {
                $projectRepository = [string]$slowResult.selectedProject.githubRepository
            }
            else {
                if ([string]$slowResult.status -ceq 'needs_input') {
                    $intervention = [pscustomobject][ordered]@{
                        report = 'Routing needs a project selection.'
                        question = [string]$slowResult.question
                        context = 'Slow Router found multiple plausible projects.'
                        options = [string[]]$slowResult.options
                    }
                }
                elseif ([string]$slowResult.status -ceq 'no_match') {
                    $intervention = Get-CodexDispatchOrchestratorRoutingIntervention `
                        -Kind no_match -Reason $slowResult.reason `
                        -CredentialSnapshot $credentialSnapshot
                }
                else {
                    $intervention = Get-CodexDispatchOrchestratorRoutingIntervention `
                        -Kind disabled -Reason $null `
                        -CredentialSnapshot $credentialSnapshot
                }
                return Complete-CodexDispatchOrchestratorVisibleState `
                    -CurrentState $state -Dependencies $Dependencies `
                    -ConfigPath $ConfigPath -CredentialSnapshot $credentialSnapshot `
                    -UpdateParameters ([ordered]@{
                        DispatchId = [string]$state.dispatchId
                        ExpectedRevision = [int64]$state.revision
                        Phase = 'routing'; Status = 'needs_input'
                        Report = $intervention.report; Question = $intervention.question
                        Context = $intervention.context; Options = $intervention.options
                        ConfigPath = $ConfigPath
                    })
            }
        }

        [void](Update-CodexDispatchOrchestratorState `
            -Action $Dependencies.UpdateState `
            -Parameters ([ordered]@{
                DispatchId = [string]$state.dispatchId
                ExpectedRevision = [int64]$state.revision
                Phase = 'worker'; Status = 'running'
                ProjectRepository = $projectRepository
                ConfigPath = $ConfigPath
            }))
        $state = Get-CodexDispatchOrchestratorDurableState `
            -Dependencies $Dependencies -DispatchId ([string]$state.dispatchId) `
            -ConfigPath $ConfigPath

        $workerResult = $null
        $workerFailure = $null
        try {
            $workerResult = & $Dependencies.Worker ([ordered]@{
                Task = $Task
                ProjectRepository = $projectRepository
                ConfigPath = $ConfigPath
                IndexPath = $indexPath
            })
        }
        catch {
            $workerFailure = $_.Exception.Message
        }
        if ($null -eq $workerFailure) {
            try { Assert-CodexDispatchOrchestratorWorkerResult -Result $workerResult }
            catch { $workerFailure = $_.Exception.Message }
        }

        if ($null -ne $workerFailure) {
            $diagnostic = ConvertTo-CodexDispatchOrchestratorSafeDiagnostic `
                -Value $workerFailure -CredentialSnapshot $credentialSnapshot `
                -Fallback 'Worker invocation failed.'
            return Complete-CodexDispatchOrchestratorVisibleState `
                -CurrentState $state -Dependencies $Dependencies `
                -ConfigPath $ConfigPath -CredentialSnapshot $credentialSnapshot `
                -UpdateParameters ([ordered]@{
                    DispatchId = [string]$state.dispatchId
                    ExpectedRevision = [int64]$state.revision
                    Phase = 'worker'; Status = 'failed'
                    Diagnostic = $diagnostic
                    ConfigPath = $ConfigPath
                })
        }

        if ([string]$workerResult.status -ceq 'completed') {
            $finalParameters = [ordered]@{
                DispatchId = [string]$state.dispatchId
                ExpectedRevision = [int64]$state.revision
                Phase = 'worker'; Status = 'completed'
                ThreadId = [string]$workerResult.threadId
                Report = [string]$workerResult.report
                ConfigPath = $ConfigPath
            }
        }
        elseif ([string]$workerResult.status -ceq 'needs_input') {
            $finalParameters = [ordered]@{
                DispatchId = [string]$state.dispatchId
                ExpectedRevision = [int64]$state.revision
                Phase = 'worker'; Status = 'needs_input'
                ThreadId = [string]$workerResult.threadId
                Report = [string]$workerResult.report
                Question = [string]$workerResult.question
                Context = [string]$workerResult.context
                Options = [string[]]$workerResult.options
                ConfigPath = $ConfigPath
            }
        }
        else {
            $finalParameters = [ordered]@{
                DispatchId = [string]$state.dispatchId
                ExpectedRevision = [int64]$state.revision
                Phase = 'worker'; Status = 'failed'
                Diagnostic = ConvertTo-CodexDispatchOrchestratorSafeDiagnostic `
                    -Value $workerResult.diagnostic `
                    -CredentialSnapshot $credentialSnapshot `
                    -Fallback 'Worker returned failed.'
                ConfigPath = $ConfigPath
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$workerResult.threadId)) {
                $finalParameters['ThreadId'] = [string]$workerResult.threadId
            }
        }
        return Complete-CodexDispatchOrchestratorVisibleState `
            -CurrentState $state -Dependencies $Dependencies `
            -ConfigPath $ConfigPath -CredentialSnapshot $credentialSnapshot `
            -UpdateParameters $finalParameters
    }
    finally {
        Restore-CodexDispatchOrchestratorCredentials `
            -Snapshot $credentialSnapshot
    }
}
