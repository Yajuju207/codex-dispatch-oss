Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexDispatchOrchestrator.Common.ps1')
$script:RoutingResumeErrorPrefix = 'Codex Dispatch Routing Resume Orchestrator error: '

function New-RoutingResumeError { param([string]$Message) throw [System.InvalidOperationException]::new($script:RoutingResumeErrorPrefix + $Message) }
function Test-RoutingResumeGuid { param($Value) $guid=[guid]::Empty; return ($Value -is [string] -and [guid]::TryParseExact([string]$Value, 'D', [ref]$guid) -and [string]$Value -ceq $guid.ToString('D').ToLowerInvariant()) }
function Assert-RoutingResumeInput {
    param([string]$DispatchId,[string]$Answer,[Int64]$IssueNumber)
    if (-not (Test-RoutingResumeGuid $DispatchId)) { New-RoutingResumeError 'DispatchId must be a lowercase canonical UUID D.' }
    if ($Answer.Length -lt 1 -or $Answer.Length -gt 16384) { New-RoutingResumeError 'Answer length must be 1..16384 .NET string characters.' }
    if ([string]::IsNullOrWhiteSpace($Answer)) { New-RoutingResumeError 'Answer must not be whitespace-only.' }
    if ($IssueNumber -lt 1) { New-RoutingResumeError 'IssueNumber must be >= 1.' }
}
function New-CodexDispatchRoutingResumeOrchestratorDependencies {
    $paths=[ordered]@{GetState='Get-CodexDispatchState.ps1';UpdateState='Update-CodexDispatchState.ps1';FastRouter='Fast-Route-CodexTask.ps1';SlowRouter='Slow-Route-CodexTask.ps1';Worker='Invoke-CodexWorker.ps1';Publisher='Publish-CodexDispatchIssue.ps1'}
    $blocks=[ordered]@{}
    foreach($name in $paths.Keys) { $path=Join-Path $PSScriptRoot $paths[$name]; if(-not(Test-Path -LiteralPath $path -PathType Leaf)){New-RoutingResumeError 'A Routing Resume dependency is missing.'}; $blocks[$name]=({param($Request)& $path @Request}.GetNewClosure()) }
    return [pscustomobject]$blocks
}
function Assert-RoutingResumeDependencies {
    param($Dependencies)
    Assert-CodexDispatchOrchestratorExactProperties -Value $Dependencies -Names @('GetState','UpdateState','FastRouter','SlowRouter','Worker','Publisher') -Context 'Routing Resume dependencies'
    foreach($name in $Dependencies.PSObject.Properties.Name) { if($Dependencies.$name -isnot [scriptblock]) { New-RoutingResumeError "Routing Resume dependency $name contract is invalid." } }
}
function Assert-RoutingResumeState {
    param($State)
    if([string]$State.phase -cne 'routing' -or [string]$State.status -cne 'needs_input') { New-RoutingResumeError 'State is not resumable routing/needs_input.' }
    if($null -ne $State.projectRepository -or $null -ne $State.threadId) { New-RoutingResumeError 'Routing State identity contract is invalid.' }
}
function Assert-RoutingResumeRoutingRunningReadback {
    param($State,[string]$Task,[Int64]$Revision)
    if([int64]$State.revision -ne $Revision -or [string]$State.phase -cne 'routing' -or [string]$State.status -cne 'running' -or [string]$State.task -cne $Task -or $null -ne $State.projectRepository -or $null -ne $State.threadId -or [string]$State.report -cne '' -or [string]$State.question -cne '' -or [string]$State.context -cne '' -or @($State.options).Count -ne 0 -or [string]$State.diagnostic -cne '') { New-RoutingResumeError 'routing/running State readback contract is invalid.' }
}
function Assert-RoutingResumeWorkerRunningReadback {
    param($State,[string]$Task,[string]$Repository,[Int64]$Revision)
    if([int64]$State.revision -ne $Revision -or [string]$State.phase -cne 'worker' -or [string]$State.status -cne 'running' -or [string]$State.task -cne $Task -or [string]$State.projectRepository -cne $Repository -or $null -ne $State.threadId -or [string]$State.report -cne '' -or [string]$State.question -cne '' -or [string]$State.context -cne '' -or @($State.options).Count -ne 0 -or [string]$State.diagnostic -cne '') { New-RoutingResumeError 'worker/running State readback contract is invalid.' }
}
function New-RoutingResumeEnvelope {
    param($State,[string]$Answer)
    $envelope=[pscustomobject][ordered]@{
        originalTask=[string]$State.task
        routingClarification=[pscustomobject][ordered]@{
            question=[string]$State.question
            context=[string]$State.context
            options=[string[]]@($State.options)
            answer=$Answer
        }
    }
    return ConvertTo-Json -InputObject $envelope -Depth 4 -Compress
}
function New-RoutingResumeIntervention {
    param([ValidateSet('technical','no_match','disabled')][string]$Kind)
    switch($Kind) {
        'no_match' { return [pscustomobject][ordered]@{report='Routing could not select a project.';question='Retry routing with more project detail or stop this dispatch?';context='No current project matched the supplied clarification.';options=[string[]]@('Retry routing','Stop dispatch')} }
        'disabled' { return [pscustomobject][ordered]@{report='Routing requires operator intervention.';question='Enable Slow Router and retry, or stop this dispatch?';context='Fast Router did not select a project and Slow Router is disabled.';options=[string[]]@('Retry routing','Stop dispatch')} }
        default { return [pscustomobject][ordered]@{report='Routing requires operator intervention.';question='Retry routing or stop this dispatch?';context='A Router component failed or returned an invalid contract.';options=[string[]]@('Retry routing','Stop dispatch')} }
    }
}
function Update-RoutingResumeState { param([scriptblock]$Action,[System.Collections.IDictionary]$Parameters) return & $Action $Parameters }
function Get-RoutingResumeState { param($Dependencies,[string]$DispatchId,[string]$ConfigPath) return & ($Dependencies.GetState) ([ordered]@{DispatchId=$DispatchId;ConfigPath=$ConfigPath}) }
function Publish-RoutingResumeState {
    param($State,[Int64]$IssueNumber,$Dependencies,[string]$ConfigPath,[object[]]$CredentialSnapshot)
    $metadata=[pscustomobject][ordered]@{issuePublication='failed';issueNumber=$null;issueUrl=$null;projectionDiagnostic=''}
    $record=Get-CodexDispatchOrchestratorCredentialRecord -Snapshot $CredentialSnapshot -Name 'CODEX_DISPATCH_GITHUB_TOKEN'
    try { try {
        Restore-CodexDispatchOrchestratorCredential -Record $record
        $result=& ($Dependencies.Publisher) ([ordered]@{DispatchId=[string]$State.dispatchId;IssueNumber=$IssueNumber;ConfigPath=$ConfigPath})
        Assert-CodexDispatchOrchestratorExactProperties -Value $result -Names @('version','action','dispatchId','revision','repository','issueNumber','issueUrl') -Context 'Routing Resume Publisher result'
        if(-not(Test-CodexDispatchOrchestratorInteger $result.version) -or [int64]$result.version -ne 1 -or $result.action -isnot [string] -or [string]$result.action -cnotin @('updated','noop') -or [string]$result.dispatchId -cne [string]$State.dispatchId -or -not(Test-CodexDispatchOrchestratorInteger $result.revision) -or [int64]$result.revision -ne [int64]$State.revision -or -not(Test-CodexDispatchOrchestratorInteger $result.issueNumber) -or [int64]$result.issueNumber -ne $IssueNumber -or $result.issueUrl -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$result.issueUrl)) { New-RoutingResumeError 'Routing Resume Publisher result contract is invalid.' }
        $metadata.issuePublication=[string]$result.action;$metadata.issueNumber=[int64]$result.issueNumber;$metadata.issueUrl=[string]$result.issueUrl
    } catch { $metadata.projectionDiagnostic='Issue publication failed.' } }
    finally { [Environment]::SetEnvironmentVariable('CODEX_DISPATCH_GITHUB_TOKEN',$null,[EnvironmentVariableTarget]::Process) }
    return $metadata
}
function Complete-RoutingResumeVisibleState {
    param($CurrentState,[System.Collections.IDictionary]$Parameters,$Dependencies,[string]$ConfigPath,[Int64]$IssueNumber,[object[]]$CredentialSnapshot)
    [void](Update-RoutingResumeState -Action $Dependencies.UpdateState -Parameters $Parameters)
    $durable=Get-RoutingResumeState -Dependencies $Dependencies -DispatchId ([string]$CurrentState.dispatchId) -ConfigPath $ConfigPath
    $projection=Publish-RoutingResumeState -State $durable -IssueNumber $IssueNumber -Dependencies $Dependencies -ConfigPath $ConfigPath -CredentialSnapshot $CredentialSnapshot
    return New-CodexDispatchOrchestratorOutput -State $durable -ProjectionMetadata $projection
}
function Complete-RoutingResumeNeedsInput {
    param($State,$Intervention,$Dependencies,[string]$ConfigPath,[Int64]$IssueNumber,[object[]]$CredentialSnapshot)
    return Complete-RoutingResumeVisibleState -CurrentState $State -Dependencies $Dependencies -ConfigPath $ConfigPath -IssueNumber $IssueNumber -CredentialSnapshot $CredentialSnapshot -Parameters ([ordered]@{DispatchId=[string]$State.dispatchId;ExpectedRevision=[int64]$State.revision;Phase='routing';Status='needs_input';ProjectRepository=$null;ThreadId=$null;Report=[string]$Intervention.report;Question=[string]$Intervention.question;Context=[string]$Intervention.context;Options=[string[]]$Intervention.options;Diagnostic='';ConfigPath=$ConfigPath})
}
function Invoke-CodexDispatchRoutingResumeOrchestratorInternal {
    [CmdletBinding()]param([string]$DispatchId,[string]$Answer,[Int64]$IssueNumber,[AllowEmptyString()][string]$ConfigPath,$Dependencies)
    $snapshot=Get-CodexDispatchOrchestratorCredentialSnapshot
    try {
        Remove-CodexDispatchOrchestratorCredentials;Assert-RoutingResumeInput $DispatchId $Answer $IssueNumber;Assert-RoutingResumeDependencies $Dependencies
        $indexPath=Get-CodexDispatchOrchestratorIndexPath
        $state=Get-RoutingResumeState -Dependencies $Dependencies -DispatchId $DispatchId -ConfigPath $ConfigPath;Assert-RoutingResumeState $state
        $task=[string]$state.task;$envelope=New-RoutingResumeEnvelope -State $state -Answer $Answer;$revision=[int64]$state.revision
        [void](Update-RoutingResumeState -Action $Dependencies.UpdateState -Parameters ([ordered]@{DispatchId=[string]$state.dispatchId;ExpectedRevision=$revision;Phase='routing';Status='running';ProjectRepository=$null;ThreadId=$null;Report='';Question='';Context='';Options=[string[]]@();Diagnostic='';ConfigPath=$ConfigPath}))
        $state=Get-RoutingResumeState -Dependencies $Dependencies -DispatchId ([string]$state.dispatchId) -ConfigPath $ConfigPath;Assert-RoutingResumeRoutingRunningReadback $state $task ($revision+1)
        $fast=$null;try { $fast=& ($Dependencies.FastRouter) ([ordered]@{Task=$Answer;ConfigPath=$ConfigPath;IndexPath=$indexPath});Assert-CodexDispatchOrchestratorFastResult -Result $fast } catch { return Complete-RoutingResumeNeedsInput -State $state -Intervention (New-RoutingResumeIntervention -Kind technical) -Dependencies $Dependencies -ConfigPath $ConfigPath -IssueNumber $IssueNumber -CredentialSnapshot $snapshot }
        $repository=$null;$useSlow=$true
        if([string]$fast.status -ceq 'strong' -and $null -ne $fast.selectedProject.githubRepository) { $repository=[string]$fast.selectedProject.githubRepository;$useSlow=$false }
        if($useSlow) {
            $slow=$null;try { $slow=& ($Dependencies.SlowRouter) ([ordered]@{Task=$envelope;ConfigPath=$ConfigPath;IndexPath=$indexPath});Assert-CodexDispatchOrchestratorSlowResult -Result $slow } catch { return Complete-RoutingResumeNeedsInput -State $state -Intervention (New-RoutingResumeIntervention -Kind technical) -Dependencies $Dependencies -ConfigPath $ConfigPath -IssueNumber $IssueNumber -CredentialSnapshot $snapshot }
            if([string]$slow.status -ceq 'routed') { $repository=[string]$slow.selectedProject.githubRepository }
            else {
                if([string]$slow.status -ceq 'needs_input') { $intervention=[pscustomobject][ordered]@{report='Routing still needs a project selection.';question='Which project did you mean?';context='Slow Router still found multiple plausible projects.';options=[string[]]$slow.options} }
                elseif([string]$slow.status -ceq 'no_match') { $intervention=New-RoutingResumeIntervention -Kind no_match }
                else { $intervention=New-RoutingResumeIntervention -Kind disabled }
                return Complete-RoutingResumeNeedsInput -State $state -Intervention $intervention -Dependencies $Dependencies -ConfigPath $ConfigPath -IssueNumber $IssueNumber -CredentialSnapshot $snapshot
            }
        }
        $workerRunningRevision = [int64]$state.revision
        [void](Update-RoutingResumeState -Action $Dependencies.UpdateState -Parameters ([ordered]@{DispatchId=[string]$state.dispatchId;ExpectedRevision=$workerRunningRevision;Phase='worker';Status='running';ProjectRepository=$repository;ThreadId=$null;Report='';Question='';Context='';Options=[string[]]@();Diagnostic='';ConfigPath=$ConfigPath}))
        $state=Get-RoutingResumeState -Dependencies $Dependencies -DispatchId ([string]$state.dispatchId) -ConfigPath $ConfigPath;Assert-RoutingResumeWorkerRunningReadback $state $task $repository ($workerRunningRevision + 1)
        $worker=$null;$failure=$null;try { $worker=& ($Dependencies.Worker) ([ordered]@{Task=$task;ProjectRepository=$repository;ConfigPath=$ConfigPath;IndexPath=$indexPath}) } catch { $failure=$_.Exception.Message }
        if($null -eq $failure) { try { Assert-CodexDispatchOrchestratorWorkerResult -Result $worker } catch { $failure=$_.Exception.Message } }
        if($null -ne $failure) { $final=[ordered]@{DispatchId=[string]$state.dispatchId;ExpectedRevision=[int64]$state.revision;Phase='worker';Status='failed';ProjectRepository=$repository;ThreadId=$null;Diagnostic='Worker invocation failed.';ConfigPath=$ConfigPath} }
        elseif([string]$worker.status -ceq 'completed') { $final=[ordered]@{DispatchId=[string]$state.dispatchId;ExpectedRevision=[int64]$state.revision;Phase='worker';Status='completed';ProjectRepository=$repository;ThreadId=[string]$worker.threadId;Report=[string]$worker.report;ConfigPath=$ConfigPath} }
        elseif([string]$worker.status -ceq 'needs_input') { $final=[ordered]@{DispatchId=[string]$state.dispatchId;ExpectedRevision=[int64]$state.revision;Phase='worker';Status='needs_input';ProjectRepository=$repository;ThreadId=[string]$worker.threadId;Report=[string]$worker.report;Question=[string]$worker.question;Context=[string]$worker.context;Options=[string[]]$worker.options;ConfigPath=$ConfigPath} }
        else { $final=[ordered]@{DispatchId=[string]$state.dispatchId;ExpectedRevision=[int64]$state.revision;Phase='worker';Status='failed';ProjectRepository=$repository;Diagnostic='Worker returned failed.';ConfigPath=$ConfigPath};if($worker.threadId -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$worker.threadId)){$final['ThreadId']=[string]$worker.threadId} }
        return Complete-RoutingResumeVisibleState -CurrentState $state -Parameters $final -Dependencies $Dependencies -ConfigPath $ConfigPath -IssueNumber $IssueNumber -CredentialSnapshot $snapshot
    } finally { Restore-CodexDispatchOrchestratorCredentials -Snapshot $snapshot }
}
