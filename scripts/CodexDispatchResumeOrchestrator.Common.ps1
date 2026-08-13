Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexDispatchOrchestrator.Common.ps1')
$script:ResumeErrorPrefix = 'Codex Dispatch Resume Orchestrator error: '

function New-ResumeError { param([string]$Message) throw [System.InvalidOperationException]::new($script:ResumeErrorPrefix + $Message) }
function Test-ResumeGuid { param($Value) $g=[guid]::Empty; return ($Value -is [string] -and [guid]::TryParseExact([string]$Value,'D',[ref]$g) -and [string]$Value -ceq $g.ToString('D').ToLowerInvariant()) }
function Assert-ResumeInput { param([string]$DispatchId,[string]$Answer,[Int64]$IssueNumber)
 if(-not(Test-ResumeGuid $DispatchId)){New-ResumeError 'DispatchId must be a lowercase canonical UUID D.'}
 if($Answer.Length -lt 1 -or $Answer.Length -gt 16384){New-ResumeError 'Answer length must be 1..16384 .NET string characters.'}
 if([string]::IsNullOrWhiteSpace($Answer)){New-ResumeError 'Answer must not be whitespace-only.'}
 if($IssueNumber -lt 1){New-ResumeError 'IssueNumber must be >= 1.'}
}
function New-CodexDispatchResumeOrchestratorDependencies {
 $paths=[ordered]@{GetState='Get-CodexDispatchState.ps1';UpdateState='Update-CodexDispatchState.ps1';ResumeWorker='Invoke-CodexWorkerResume.ps1';Publisher='Publish-CodexDispatchIssue.ps1'}
 $blocks=[ordered]@{}
 foreach($name in $paths.Keys){$path=Join-Path $PSScriptRoot $paths[$name];if(-not(Test-Path -LiteralPath $path -PathType Leaf)){New-ResumeError 'A Resume Orchestrator dependency is missing.'};$blocks[$name]=({param($Request)& $path @Request}.GetNewClosure())}
 return [pscustomobject]$blocks
}
function Assert-ResumeDependencies { param($Dependencies)
 Assert-CodexDispatchOrchestratorExactProperties -Value $Dependencies -Names @('GetState','UpdateState','ResumeWorker','Publisher') -Context 'Resume dependencies'
 foreach($name in $Dependencies.PSObject.Properties.Name){if($Dependencies.$name -isnot [scriptblock]){New-ResumeError 'Resume dependency contract is invalid.'}}
}
function Assert-ResumeState { param($State)
 if([string]$State.phase -cne 'worker' -or [string]$State.status -cne 'needs_input'){New-ResumeError 'State is not resumable worker/needs_input.'}
 if(-not(Test-CodexDispatchOrchestratorRepository $State.projectRepository) -or -not(Test-ResumeGuid $State.threadId)){New-ResumeError 'Resumable State identity contract is invalid.'}
}
function Assert-ResumeRunningReadback { param($State,[string]$Repository,[string]$ThreadId,[Int64]$Revision)
 if([int64]$State.revision -ne $Revision -or [string]$State.phase -cne 'worker' -or [string]$State.status -cne 'running' -or [string]$State.projectRepository -cne $Repository -or [string]$State.threadId -cne $ThreadId -or [string]$State.report -cne '' -or [string]$State.question -cne '' -or [string]$State.context -cne '' -or @($State.options).Count -ne 0 -or [string]$State.diagnostic -cne ''){New-ResumeError 'worker/running State readback contract is invalid.'}
}
function Assert-ResumeWorkerResult { param($Result,[string]$ThreadId)
 Assert-CodexDispatchOrchestratorWorkerResult -Result $Result
 if($Result.threadId -isnot [string] -or [string]$Result.threadId -cne $ThreadId){New-ResumeError 'Resume Worker threadId must exactly equal State threadId.'}
}
function ConvertTo-ResumeSafeDiagnostic {
 param($Value,[object[]]$CredentialSnapshot,[string]$Answer,[string]$ThreadId,[string]$ConfigPath,[string]$IndexPath,[string]$Fallback)
 $text=ConvertTo-CodexDispatchOrchestratorSafeDiagnostic -Value $Value -CredentialSnapshot $CredentialSnapshot -Fallback $Fallback
 foreach($value in @($Answer,$ThreadId,$ConfigPath,$IndexPath)) { if($value -is [string] -and $value.Length -gt 0){$text=$text.Replace($value,'[REDACTED]')} }
 $text=[regex]::Replace($text,'(?i)(?:[a-z]:\\|\\\\)[^\s''""<>|]*','[REDACTED_PATH]')
 $text=[regex]::Replace($text,'(?i)\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b','[REDACTED_UUID]')
 # Exception text is untrusted at this public boundary. Retain only a bounded,
 # fixed category after applying defense-in-depth redaction above.
 return $Fallback
}
function Publish-ResumeState { param($State,[Int64]$IssueNumber,$Dependencies,[string]$ConfigPath,[object[]]$CredentialSnapshot)
 $metadata=[pscustomobject][ordered]@{issuePublication='failed';issueNumber=$null;issueUrl=$null;projectionDiagnostic=''}
 $record=Get-CodexDispatchOrchestratorCredentialRecord -Snapshot $CredentialSnapshot -Name 'CODEX_DISPATCH_GITHUB_TOKEN'
 try { try { Restore-CodexDispatchOrchestratorCredential -Record $record;
   $result=& $Dependencies.Publisher ([ordered]@{DispatchId=[string]$State.dispatchId;IssueNumber=$IssueNumber;ConfigPath=$ConfigPath})
   Assert-CodexDispatchOrchestratorExactProperties -Value $result -Names @('version','action','dispatchId','revision','repository','issueNumber','issueUrl') -Context 'Resume Publisher result'
   if(-not(Test-CodexDispatchOrchestratorInteger $result.version) -or [int64]$result.version -ne 1 -or $result.action -isnot [string] -or [string]$result.action -cnotin @('updated','noop') -or [string]$result.dispatchId -cne [string]$State.dispatchId -or -not(Test-CodexDispatchOrchestratorInteger $result.revision) -or [int64]$result.revision -ne [int64]$State.revision -or -not(Test-CodexDispatchOrchestratorInteger $result.issueNumber) -or [int64]$result.issueNumber -ne $IssueNumber -or $result.issueUrl -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$result.issueUrl)){New-ResumeError 'Resume Publisher result contract is invalid.'}
   $metadata.issuePublication=[string]$result.action;$metadata.issueNumber=[int64]$result.issueNumber;$metadata.issueUrl=[string]$result.issueUrl
  } catch {$metadata.projectionDiagnostic=ConvertTo-ResumeSafeDiagnostic -Value $_.Exception.Message -CredentialSnapshot $CredentialSnapshot -Answer '' -ThreadId ([string]$State.threadId) -ConfigPath $ConfigPath -IndexPath '' -Fallback 'Issue publication failed.'}
 } finally {[Environment]::SetEnvironmentVariable('CODEX_DISPATCH_GITHUB_TOKEN',$null,[EnvironmentVariableTarget]::Process)}
 return $metadata
}
function Invoke-CodexDispatchResumeOrchestratorInternal {
 [CmdletBinding()]param([string]$DispatchId,[string]$Answer,[Int64]$IssueNumber,[AllowEmptyString()][string]$ConfigPath,$Dependencies)
 $snapshot=Get-CodexDispatchOrchestratorCredentialSnapshot
 try {
  Remove-CodexDispatchOrchestratorCredentials;Assert-ResumeInput $DispatchId $Answer $IssueNumber;Assert-ResumeDependencies $Dependencies
  $indexPath=Get-CodexDispatchOrchestratorIndexPath
  $state=Get-CodexDispatchOrchestratorDurableState -Dependencies $Dependencies -DispatchId $DispatchId -ConfigPath $ConfigPath;Assert-ResumeState $state
  $repo=[string]$state.projectRepository;$thread=[string]$state.threadId;$r=[int64]$state.revision
  [void](Update-CodexDispatchOrchestratorState -Action $Dependencies.UpdateState -Parameters ([ordered]@{DispatchId=[string]$state.dispatchId;ExpectedRevision=$r;Phase='worker';Status='running';ProjectRepository=$repo;ThreadId=$thread;Report='';Question='';Context='';Options=[string[]]@();Diagnostic='';ConfigPath=$ConfigPath}))
  $state=Get-CodexDispatchOrchestratorDurableState -Dependencies $Dependencies -DispatchId ([string]$state.dispatchId) -ConfigPath $ConfigPath;Assert-ResumeRunningReadback $state $repo $thread ($r+1)
  $result=$null;$failure=$null;try{$result=& $Dependencies.ResumeWorker ([ordered]@{Answer=$Answer;ProjectRepository=$repo;ThreadId=$thread;ConfigPath=$ConfigPath;IndexPath=$indexPath})}catch{$failure=$_.Exception.Message}
  if($null -eq $failure){try{Assert-ResumeWorkerResult $result $thread}catch{$failure=$_.Exception.Message}}
  if($null -ne $failure){$final=[ordered]@{DispatchId=[string]$state.dispatchId;ExpectedRevision=[int64]$state.revision;Phase='worker';Status='failed';ProjectRepository=$repo;ThreadId=$thread;Diagnostic=(ConvertTo-ResumeSafeDiagnostic -Value $failure -CredentialSnapshot $snapshot -Answer $Answer -ThreadId $thread -ConfigPath $ConfigPath -IndexPath $indexPath -Fallback 'Resume Worker invocation failed.');ConfigPath=$ConfigPath}}
  elseif([string]$result.status -ceq 'completed'){$final=[ordered]@{DispatchId=[string]$state.dispatchId;ExpectedRevision=[int64]$state.revision;Phase='worker';Status='completed';ProjectRepository=$repo;ThreadId=$thread;Report=[string]$result.report;ConfigPath=$ConfigPath}}
  elseif([string]$result.status -ceq 'needs_input'){$final=[ordered]@{DispatchId=[string]$state.dispatchId;ExpectedRevision=[int64]$state.revision;Phase='worker';Status='needs_input';ProjectRepository=$repo;ThreadId=$thread;Report=[string]$result.report;Question=[string]$result.question;Context=[string]$result.context;Options=[string[]]$result.options;ConfigPath=$ConfigPath}}
  else {$final=[ordered]@{DispatchId=[string]$state.dispatchId;ExpectedRevision=[int64]$state.revision;Phase='worker';Status='failed';ProjectRepository=$repo;ThreadId=$thread;Diagnostic=(ConvertTo-ResumeSafeDiagnostic -Value $result.diagnostic -CredentialSnapshot $snapshot -Answer $Answer -ThreadId $thread -ConfigPath $ConfigPath -IndexPath $indexPath -Fallback 'Resume Worker returned failed.');ConfigPath=$ConfigPath}}
  [void](Update-CodexDispatchOrchestratorState -Action $Dependencies.UpdateState -Parameters $final)
  $durable=Get-CodexDispatchOrchestratorDurableState -Dependencies $Dependencies -DispatchId ([string]$state.dispatchId) -ConfigPath $ConfigPath
  $projection=Publish-ResumeState -State $durable -IssueNumber $IssueNumber -Dependencies $Dependencies -ConfigPath $ConfigPath -CredentialSnapshot $snapshot
  return New-CodexDispatchOrchestratorOutput -State $durable -ProjectionMetadata $projection
 } finally {Restore-CodexDispatchOrchestratorCredentials -Snapshot $snapshot}
}
function ConvertTo-CodexDispatchResumePublicError { param([object[]]$CredentialSnapshot) return $script:ResumeErrorPrefix+'execution failed; inspect local Runtime State, configuration, and components.' }
