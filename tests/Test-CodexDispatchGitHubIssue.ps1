[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptsRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts'))
$newState = Join-Path $scriptsRoot 'New-CodexDispatchState.ps1'
$updateState = Join-Path $scriptsRoot 'Update-CodexDispatchState.ps1'
$projectionScript = Join-Path $scriptsRoot 'New-CodexDispatchIssueProjection.ps1'
$publishScript = Join-Path $scriptsRoot 'Publish-CodexDispatchIssue.ps1'
$common = Join-Path $scriptsRoot 'CodexDispatchGitHubIssue.Common.ps1'
foreach ($requiredFile in @(
    $newState, $updateState, $projectionScript, $publishScript, $common
)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "找不到 GitHub Issue Adapter 文件：$requiredFile"
    }
}
. $common

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    if (-not $Condition) { throw "断言失败：$Message" }
}

function Assert-Equal {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Actual,

        [Parameter()]
        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    if (-not [object]::Equals($Actual, $Expected)) {
        throw "断言失败：$Message。Expected=$Expected Actual=$Actual"
    }
}

function Get-ThrownMessage {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)
    try { & $Action | Out-Null } catch { return [string]$_.Exception.Message }
    return $null
}

function Assert-AdapterError {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Contains
    )
    $message = Get-ThrownMessage -Action $Action
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($message)) `
        -Message "预期异常包含 $Contains，但调用成功"
    Assert-True -Condition $message.StartsWith(
        'Codex Dispatch GitHub Issue 错误：',
        [System.StringComparison]::Ordinal
    ) -Message "错误前缀不统一：$message"
    Assert-True -Condition $message.Contains($Contains) `
        -Message "异常未包含 $Contains。实际：$message"
    return $message
}

function Write-TestConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
        [Parameter(Mandatory = $true)][string]$StateDirectory,
        [Parameter()][string]$Repository = 'example-owner/private-control',
        [Parameter()][object]$Provider = 'github',
        [Parameter()][bool]$IncludeAssignee = $true,
        [Parameter()][object]$Assignee = 'example-user',
        [Parameter()][object]$ExposePaths = $false,
        [Parameter()][object]$ExposeThreads = $false,
        [Parameter()][object]$IncludeTask = $false
    )
    $controlPlane = [ordered]@{
        provider = $Provider
        repository = $Repository
        defaultBranch = 'main'
    }
    if ($IncludeAssignee) { $controlPlane['issueAssignee'] = $Assignee }
    $document = [ordered]@{
        version = 1
        workspace = [ordered]@{
            root = $WorkspaceRoot
            scanDepth = 1
            allowReparsePoints = $false
        }
        runtime = [ordered]@{ stateDirectory = $StateDirectory }
        controlPlane = $controlPlane
        routing = [ordered]@{
            fast = [ordered]@{ enabled = $true }
            slow = [ordered]@{ enabled = $true }
        }
        codex = [ordered]@{
            command = 'codex'
            workerSandbox = 'workspace-write'
            routerSandbox = 'read-only'
            approvalPolicy = 'never'
        }
        privacy = [ordered]@{
            exposeLocalPathsInIssues = $ExposePaths
            exposeThreadIdsInIssues = $ExposeThreads
            includeOriginalTaskInIssues = $IncludeTask
        }
        safety = [ordered]@{
            restrictToWorkspaceRoot = $true
            requireExplicitAuthorizationFor = @('push', 'deploy')
        }
    }
    [System.IO.File]::WriteAllText(
        $ConfigPath,
        (ConvertTo-Json -InputObject $document -Depth 8) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function New-TestCase {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter()][string]$Repository = 'example-owner/private-control',
        [Parameter()][bool]$IncludeAssignee = $true,
        [Parameter()][object]$Assignee = 'example-user',
        [Parameter()][object]$ExposePaths = $false,
        [Parameter()][object]$ExposeThreads = $false,
        [Parameter()][object]$IncludeTask = $false
    )
    $root = Join-Path $Parent $Name
    $workspace = Join-Path $root 'workspace'
    $stateDirectory = Join-Path $root 'state'
    [void](New-Item -ItemType Directory -Path $workspace -Force)
    [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
    $config = Join-Path $root 'config.local.json'
    Write-TestConfiguration -ConfigPath $config -WorkspaceRoot '.\workspace' `
        -StateDirectory '.\state' -Repository $Repository `
        -IncludeAssignee $IncludeAssignee -Assignee $Assignee `
        -ExposePaths $ExposePaths -ExposeThreads $ExposeThreads `
        -IncludeTask $IncludeTask
    return [pscustomobject]@{
        Root = $root
        Workspace = $workspace
        StateDirectory = $stateDirectory
        Config = $config
    }
}

function New-RoutingPendingFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter()][string]$Task = 'ordinary task',
        [Parameter()][string]$Repository = 'example-owner/private-control',
        [Parameter()][bool]$IncludeAssignee = $true,
        [Parameter()][object]$ExposePaths = $false,
        [Parameter()][object]$ExposeThreads = $false,
        [Parameter()][object]$IncludeTask = $false
    )
    $case = New-TestCase -Parent $Parent -Name $Name `
        -Repository $Repository -IncludeAssignee $IncludeAssignee `
        -ExposePaths $ExposePaths -ExposeThreads $ExposeThreads `
        -IncludeTask $IncludeTask
    $state = & $newState -Task $Task -ConfigPath $case.Config
    return [pscustomobject]@{ Case = $case; State = $state }
}

function Move-ToRoutingRunning {
    param([Parameter(Mandatory = $true)][object]$Fixture)
    $state = & $updateState -DispatchId $Fixture.State.dispatchId `
        -ExpectedRevision $Fixture.State.revision -Phase routing -Status running `
        -ConfigPath $Fixture.Case.Config
    return [pscustomobject]@{ Case = $Fixture.Case; State = $state }
}

function Move-ToWorkerRunning {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [Parameter()][string]$ProjectRepository = 'project-owner/project-name'
    )
    $routing = Move-ToRoutingRunning -Fixture $Fixture
    $state = & $updateState -DispatchId $routing.State.dispatchId `
        -ExpectedRevision $routing.State.revision -Phase worker -Status running `
        -ProjectRepository $ProjectRepository -ConfigPath $routing.Case.Config
    return [pscustomobject]@{ Case = $routing.Case; State = $state }
}

function Get-Projection {
    param([Parameter(Mandatory = $true)][object]$Fixture)
    return & $projectionScript -DispatchId $Fixture.State.dispatchId `
        -ConfigPath $Fixture.Case.Config
}

function New-IssueResponse {
    param(
        [Parameter()][int64]$Number = 17,
        [Parameter()][string]$Repository = 'example-owner/private-control'
    )
    return [pscustomobject][ordered]@{
        number = $Number
        html_url = "https://github.com/$Repository/issues/$Number"
        repository_url = "https://api.github.com/repos/$Repository"
    }
}

function New-RepositoryMetadataResponse {
    param(
        [Parameter()][string]$FullName = 'example-owner/private-control',
        [Parameter()][object]$Private = $true,
        [Parameter()][switch]$OmitFullName,
        [Parameter()][switch]$OmitPrivate
    )
    $metadata = [ordered]@{}
    if (-not $OmitFullName) { $metadata['full_name'] = $FullName }
    if (-not $OmitPrivate) { $metadata['private'] = $Private }
    return [pscustomobject]$metadata
}

function New-RemoteIssue {
    param(
        [Parameter(Mandatory = $true)][object]$Projection,
        [Parameter()][int64]$Number = 17,
        [Parameter()][string]$Repository = 'example-owner/private-control',
        [Parameter()][string]$Title,
        [Parameter()][string]$Body,
        [Parameter()][string]$State,
        [Parameter()][switch]$PullRequest
    )
    if (-not $PSBoundParameters.ContainsKey('Title')) { $Title = $Projection.title }
    if (-not $PSBoundParameters.ContainsKey('Body')) { $Body = $Projection.body }
    if (-not $PSBoundParameters.ContainsKey('State')) { $State = $Projection.desiredState }
    $issue = [ordered]@{
        number = $Number
        html_url = "https://github.com/$Repository/issues/$Number"
        repository_url = "https://api.github.com/repos/$Repository"
        title = $Title
        body = $Body
        state = $State
    }
    if ($PullRequest) { $issue['pull_request'] = [pscustomobject]@{ url = 'opaque' } }
    return [pscustomobject]$issue
}

function New-FakeTransport {
    param(
        [Parameter()][object[]]$Responses = @(),
        [Parameter()][AllowNull()][object]$RepositoryResponse
    )
    if (-not $PSBoundParameters.ContainsKey('RepositoryResponse')) {
        $RepositoryResponse = New-RepositoryMetadataResponse
    }
    $allRequests = [System.Collections.Generic.List[object]]::new()
    $issueRequests = [System.Collections.Generic.List[object]]::new()
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($response in $Responses) { $queue.Enqueue($response) }
    $preflight = [pscustomobject]@{ Pending = $true; Response = $RepositoryResponse }
    $transport = {
        param($Request)
        $allRequests.Add($Request)
        if ($preflight.Pending) {
            $preflight.Pending = $false
            if ($preflight.Response -is [System.Exception]) {
                throw $preflight.Response
            }
            return $preflight.Response
        }
        $issueRequests.Add($Request)
        if ($queue.Count -eq 0) { throw 'unexpected fake request' }
        $response = $queue.Dequeue()
        if ($response -is [System.Exception]) { throw $response }
        return $response
    }.GetNewClosure()
    return [pscustomobject]@{
        Requests = $issueRequests
        AllRequests = $allRequests
        Transport = $transport
    }
}

function Invoke-FakePublish {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [Parameter(Mandatory = $true)][object]$Fake,
        [Parameter()][AllowNull()][object]$IssueNumber,
        [Parameter()][string]$Token = 'fake-adapter-token-9f88'
    )
    return Invoke-CodexDispatchGitHubIssuePublishInternal `
        -DispatchId $Fixture.State.dispatchId -IssueNumber $IssueNumber `
        -ConfigPath $Fixture.Case.Config -Token $Token `
        -Transport $Fake.Transport
}

function New-HttpException {
    param(
        [Parameter(Mandatory = $true)][int]$Status,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $exception = [System.Exception]::new('transport failure')
    $exception.Data['StatusCode'] = $Status
    $exception.Data['GitHubMessage'] = $Message
    return $exception
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ('codex-dispatch-github-issue-tests-' + [guid]::NewGuid().ToString('N'))
$passed = 0
$testCount = 71
try {
    [void](New-Item -ItemType Directory -Path $testRoot)

    $pending = New-RoutingPendingFixture -Parent $testRoot -Name 'pending'
    $pendingProjection = Get-Projection -Fixture $pending
    Assert-Equal ($pendingProjection.PSObject.Properties.Name -join ',') `
        'version,dispatchId,revision,title,body,desiredState' 'projection exact fields'
    Assert-Equal $pendingProjection.version 1 'projection version'
    $passed++; Write-Host "PASS $passed/$testCount：projection exact contract"

    Assert-Equal $pendingProjection.title '[CodexDispatch][PENDING][ROUTING]' `
        'routing pending title'
    Assert-Equal $pendingProjection.desiredState 'open' 'routing pending open'
    $passed++; Write-Host "PASS $passed/$testCount：AA routing pending projection"

    $routingRunning = Move-ToRoutingRunning -Fixture (
        New-RoutingPendingFixture -Parent $testRoot -Name 'routing-running'
    )
    $routingRunningProjection = Get-Projection -Fixture $routingRunning
    Assert-Equal $routingRunningProjection.title '[CodexDispatch][RUNNING][ROUTING]' `
        'routing running title'
    $passed++; Write-Host "PASS $passed/$testCount：routing running projection"

    $routingNeedsBase = Move-ToRoutingRunning -Fixture (
        New-RoutingPendingFixture -Parent $testRoot -Name 'routing-needs'
    )
    $routingNeedsState = & $updateState `
        -DispatchId $routingNeedsBase.State.dispatchId `
        -ExpectedRevision $routingNeedsBase.State.revision `
        -Phase routing -Status needs_input -Report 'routing report' `
        -Question 'choose?' -Context 'routing context' `
        -Options @('first', 'second') -ConfigPath $routingNeedsBase.Case.Config
    $routingNeeds = [pscustomobject]@{
        Case = $routingNeedsBase.Case; State = $routingNeedsState
    }
    $routingNeedsProjection = Get-Projection -Fixture $routingNeeds
    Assert-Equal $routingNeedsProjection.desiredState 'open' 'routing needs_input open'
    Assert-True $routingNeedsProjection.body.Contains('<pre>choose?</pre>') `
        'routing question displayed'
    $passed++; Write-Host "PASS $passed/$testCount：AB routing needs_input projection"

    $worker = Move-ToWorkerRunning -Fixture (
        New-RoutingPendingFixture -Parent $testRoot -Name 'worker-running'
    )
    $workerProjection = Get-Projection -Fixture $worker
    Assert-Equal $workerProjection.title '[CodexDispatch][RUNNING][project-name]' `
        'worker target extraction'
    Assert-Equal $workerProjection.desiredState 'open' 'worker running open'
    $passed++; Write-Host "PASS $passed/$testCount：AC/AG worker running target"

    $threadId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
    $workerNeedsState = & $updateState -DispatchId $worker.State.dispatchId `
        -ExpectedRevision $worker.State.revision -Phase worker -Status needs_input `
        -ThreadId $threadId -Report 'worker report' -Question 'next?' `
        -Context 'worker context' -Options @('alpha', 'beta') `
        -ConfigPath $worker.Case.Config
    $workerNeeds = [pscustomobject]@{ Case = $worker.Case; State = $workerNeedsState }
    $workerNeedsProjection = Get-Projection -Fixture $workerNeeds
    Assert-Equal $workerNeedsProjection.desiredState 'open' 'worker needs_input open'
    $passed++; Write-Host "PASS $passed/$testCount：AD/U worker needs_input projection"

    $completedWorker = Move-ToWorkerRunning -Fixture (
        New-RoutingPendingFixture -Parent $testRoot -Name 'completed'
    )
    $completedState = & $updateState -DispatchId $completedWorker.State.dispatchId `
        -ExpectedRevision $completedWorker.State.revision -Phase worker -Status completed `
        -ThreadId ([guid]::NewGuid().ToString('D')) -Report 'done safely' `
        -ConfigPath $completedWorker.Case.Config
    $completed = [pscustomobject]@{ Case = $completedWorker.Case; State = $completedState }
    $completedProjection = Get-Projection -Fixture $completed
    Assert-Equal $completedProjection.desiredState 'closed' 'completed closed'
    $passed++; Write-Host "PASS $passed/$testCount：AE/S worker completed closes"

    $failedWorker = Move-ToWorkerRunning -Fixture (
        New-RoutingPendingFixture -Parent $testRoot -Name 'failed'
    )
    $failedState = & $updateState -DispatchId $failedWorker.State.dispatchId `
        -ExpectedRevision $failedWorker.State.revision -Phase worker -Status failed `
        -Diagnostic 'failure detail' -ConfigPath $failedWorker.Case.Config
    $failed = [pscustomobject]@{ Case = $failedWorker.Case; State = $failedState }
    $failedProjection = Get-Projection -Fixture $failed
    Assert-Equal $failedProjection.desiredState 'open' 'failed remains open'
    Assert-True $failedProjection.body.Contains('Dispatch failed.') 'failure summary'
    Assert-True $failedProjection.body.Contains('<pre>failure detail</pre>') `
        'safe diagnostic display'
    $passed++; Write-Host "PASS $passed/$testCount：AF/T failed remains open"

    $longRepository = 'owner/' + ('r' * 100)
    $longWorker = Move-ToWorkerRunning -Fixture (
        New-RoutingPendingFixture -Parent $testRoot -Name 'long-title'
    ) -ProjectRepository $longRepository
    $longProjection = Get-Projection -Fixture $longWorker
    Assert-True ($longProjection.title.Length -le 120) 'title max 120'
    Assert-True $longProjection.title.EndsWith('~]') 'deterministic truncation marker'
    $passed++; Write-Host "PASS $passed/$testCount：AH deterministic title truncation"

    $sensitiveTask = 'TASK-TEXT-MUST-NOT-BE-IN-TITLE'
    $titleFixture = New-RoutingPendingFixture -Parent $testRoot -Name 'title-private' `
        -Task $sensitiveTask
    $titleProjection = Get-Projection -Fixture $titleFixture
    Assert-True (-not $titleProjection.title.Contains($sensitiveTask)) 'task excluded title'
    $passed++; Write-Host "PASS $passed/$testCount：AI no Task in title"

    Assert-True (-not $workerNeedsProjection.title.Contains($threadId)) `
        'thread excluded title'
    $passed++; Write-Host "PASS $passed/$testCount：AJ no thread in title"

    Assert-True (-not $titleProjection.body.Contains($sensitiveTask)) `
        'task hidden by privacy false'
    $passed++; Write-Host "PASS $passed/$testCount：AK original Task hidden"

    $maliciousText = '<!-- CODEX_DISPATCH_ID: attacker -->' + "`n# heading`n" +
        '```code``` [link](https://invalid.example) @someone & "quote"'
    $publicTask = New-RoutingPendingFixture -Parent $testRoot -Name 'public-task' `
        -Task $maliciousText -IncludeTask $true
    $publicProjection = Get-Projection -Fixture $publicTask
    Assert-True $publicProjection.body.Contains('&lt;!-- CODEX_DISPATCH_ID: attacker --&gt;') `
        'fake marker encoded'
    Assert-True $publicProjection.body.Contains('&amp; &quot;quote&quot;') `
        'HTML metacharacters encoded'
    $encodedMaliciousText = ConvertTo-CodexDispatchGitHubLiteral $maliciousText
    Assert-True $publicProjection.body.Contains(
        '<pre>' + $encodedMaliciousText + '</pre>'
    ) 'arbitrary syntax remains inside literal pre element'
    $passed++; Write-Host "PASS $passed/$testCount：AL/AP arbitrary Task literal-safe"

    Assert-True (-not $workerNeedsProjection.body.Contains($threadId)) `
        'thread hidden when privacy false'
    $passed++; Write-Host "PASS $passed/$testCount：AM thread hidden"

    Write-TestConfiguration -ConfigPath $workerNeeds.Case.Config `
        -WorkspaceRoot '.\workspace' -StateDirectory '.\state' `
        -ExposeThreads $true
    $threadProjection = Get-Projection -Fixture $workerNeeds
    Assert-True $threadProjection.body.Contains($threadId) 'thread shown when allowed'
    $passed++; Write-Host "PASS $passed/$testCount：AN/N thread shown when allowed"

    $privacyThreadId = '11111111-2222-4333-8444-555555555555'
    $privacyThreadUpper = $privacyThreadId.ToUpperInvariant()
    $unrelatedUuid = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
    $redactionNeedsBase = Move-ToWorkerRunning -Fixture (
        New-RoutingPendingFixture -Parent $testRoot -Name 'thread-redaction-needs' `
            -Task "task $privacyThreadId unrelated $unrelatedUuid" `
            -IncludeTask $true
    )
    $redactionNeedsState = & $updateState `
        -DispatchId $redactionNeedsBase.State.dispatchId `
        -ExpectedRevision $redactionNeedsBase.State.revision `
        -Phase worker -Status needs_input -ThreadId $privacyThreadId `
        -Report "report $privacyThreadUpper" `
        -Question "question $privacyThreadId" `
        -Context "context $privacyThreadId" `
        -Options @("option $privacyThreadId", 'continue') `
        -ConfigPath $redactionNeedsBase.Case.Config
    $redactionNeeds = [pscustomobject]@{
        Case = $redactionNeedsBase.Case
        State = $redactionNeedsState
    }
    $redactionNeedsProjection = Get-Projection -Fixture $redactionNeeds

    $redactionFailedBase = Move-ToWorkerRunning -Fixture (
        New-RoutingPendingFixture -Parent $testRoot -Name 'thread-redaction-failed' `
            -Task "failed task $privacyThreadId" -IncludeTask $true
    )
    $redactionFailedState = & $updateState `
        -DispatchId $redactionFailedBase.State.dispatchId `
        -ExpectedRevision $redactionFailedBase.State.revision `
        -Phase worker -Status failed -ThreadId $privacyThreadId `
        -Diagnostic "diagnostic $privacyThreadId" `
        -ConfigPath $redactionFailedBase.Case.Config
    $redactionFailed = [pscustomobject]@{
        Case = $redactionFailedBase.Case
        State = $redactionFailedState
    }
    $redactionFailedProjection = Get-Projection -Fixture $redactionFailed
    foreach ($redactedBody in @(
        $redactionNeedsProjection.body,
        $redactionFailedProjection.body
    )) {
        Assert-True ($redactedBody.IndexOf(
            $privacyThreadId,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -lt 0) 'hidden thread absent from all arbitrary projected text'
        Assert-True $redactedBody.Contains('[REDACTED_THREAD_ID]') `
            'hidden thread replaced deterministically'
    }
    $passed++; Write-Host "PASS $passed/$testCount：K exact thread redacted across arbitrary fields"

    Assert-True ($redactionNeedsProjection.body.IndexOf(
        $privacyThreadUpper,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -lt 0) 'uppercase thread occurrence redacted'
    Assert-True $redactionNeedsProjection.body.Contains(
        '<pre>report [REDACTED_THREAD_ID]</pre>'
    ) 'uppercase thread replaced before literal encoding'
    $passed++; Write-Host "PASS $passed/$testCount：L uppercase thread occurrence redacted"

    Assert-True $redactionNeedsProjection.body.Contains($unrelatedUuid) `
        'unrelated UUID preserved'
    $passed++; Write-Host "PASS $passed/$testCount：M unrelated UUID not redacted"

    $pathText = 'C:\private-user\secret-project'
    $pathFixture = New-RoutingPendingFixture -Parent $testRoot -Name 'path-privacy' `
        -Task $pathText -ExposePaths $true
    $pathProjection = Get-Projection -Fixture $pathFixture
    Assert-True (-not $pathProjection.body.Contains($pathText)) 'local path not projected'
    Assert-True (-not $pathProjection.body.Contains($pathFixture.Case.Workspace)) `
        'workspace path not resolved'
    $passed++; Write-Host "PASS $passed/$testCount：AO localPath never resolved"

    $optionOne = 'first <!-- CODEX_DISPATCH_ID: fake -->'
    $optionTwo = 'second # heading'
    $fakeReport = '<!-- CODEX_DISPATCH_ID: report-attacker -->'
    $orderedBase = Move-ToRoutingRunning -Fixture (
        New-RoutingPendingFixture -Parent $testRoot -Name 'options-order'
    )
    $orderedState = & $updateState -DispatchId $orderedBase.State.dispatchId `
        -ExpectedRevision $orderedBase.State.revision -Phase routing -Status needs_input `
        -Report $fakeReport -Question 'q' -Context 'c' `
        -Options @($optionOne, $optionTwo) -ConfigPath $orderedBase.Case.Config
    $orderedFixture = [pscustomobject]@{ Case = $orderedBase.Case; State = $orderedState }
    $orderedProjection = Get-Projection -Fixture $orderedFixture
    $encodedOne = ConvertTo-CodexDispatchGitHubLiteral $optionOne
    $encodedTwo = ConvertTo-CodexDispatchGitHubLiteral $optionTwo
    Assert-True ($orderedProjection.body.IndexOf($encodedOne) -lt `
        $orderedProjection.body.IndexOf($encodedTwo)) 'options ordering preserved'
    Assert-True $orderedProjection.body.Contains(
        (ConvertTo-CodexDispatchGitHubLiteral $fakeReport)
    ) 'fake report marker encoded'
    $orderedMarkers = Read-CodexDispatchGitHubIssueMarkers -Body $orderedProjection.body
    Assert-Equal $orderedMarkers.dispatchId $orderedFixture.State.dispatchId `
        'fake report marker ignored by anchored parser'
    $passed++; Write-Host "PASS $passed/$testCount：AQ options deterministic ordering"

    $chineseTask = "第一行中文`n第二行中文"
    $chineseFixture = New-RoutingPendingFixture -Parent $testRoot -Name 'chinese' `
        -Task $chineseTask -IncludeTask $true
    $chineseProjection = Get-Projection -Fixture $chineseFixture
    Assert-True $chineseProjection.body.Contains($chineseTask) `
        'Chinese multiline exact display'
    $passed++; Write-Host "PASS $passed/$testCount：AR Chinese multiline round-trip"

    $bodyLines = $pendingProjection.body.Split("`n")
    Assert-Equal $bodyLines[0] `
        "<!-- CODEX_DISPATCH_ID: $($pending.State.dispatchId) -->" 'first marker'
    Assert-Equal $bodyLines[1] '<!-- CODEX_DISPATCH_REVISION: 1 -->' 'second marker'
    Assert-Equal $bodyLines[2] '' 'blank after markers'
    $passed++; Write-Host "PASS $passed/$testCount：AS exact marker prefix"

    Assert-Equal $workerNeedsProjection.revision ([int64]$workerNeeds.State.revision) `
        'runtime revision exact'
    $passed++; Write-Host "PASS $passed/$testCount：AT revision from local state"

    $invalidFixture = New-RoutingPendingFixture -Parent $testRoot -Name 'invalid-state'
    $invalidPath = Join-Path (Join-Path $invalidFixture.Case.StateDirectory 'dispatches') `
        ($invalidFixture.State.dispatchId + '.json')
    $invalidDocument = Get-Content -Raw -LiteralPath $invalidPath | ConvertFrom-Json
    $invalidDocument.status = 'impossible'
    [System.IO.File]::WriteAllText(
        $invalidPath,
        (ConvertTo-Json $invalidDocument -Depth 8) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-AdapterError -Action {
        & $projectionScript -DispatchId $invalidFixture.State.dispatchId `
            -ConfigPath $invalidFixture.Case.Config
    } -Contains 'Runtime State' | Out-Null
    $passed++; Write-Host "PASS $passed/$testCount：AU impossible state rejected by State API"

    $markers = Read-CodexDispatchGitHubIssueMarkers -Body $publicProjection.body
    Assert-Equal $markers.dispatchId $publicTask.State.dispatchId `
        'real prefix marker wins'
    $passed++; Write-Host "PASS $passed/$testCount：N fake marker in Task ignored"

    $createFake = New-FakeTransport -Responses @(
        (New-IssueResponse -Number 21)
    )
    $created = Invoke-FakePublish -Fixture $pending -Fake $createFake
    Assert-Equal ($createFake.AllRequests.method -join ',') 'GET,POST' `
        'private repository preflight before create'
    Assert-Equal $createFake.AllRequests[0].uri `
        'https://api.github.com/repos/example-owner/private-control' `
        'exact repository metadata endpoint'
    Assert-Equal $createFake.Requests.Count 1 'one create request'
    Assert-Equal $createFake.Requests[0].method 'POST' 'create method'
    Assert-Equal $createFake.Requests[0].uri `
        'https://api.github.com/repos/example-owner/private-control/issues' `
        'exact create endpoint'
    $passed++; Write-Host "PASS $passed/$testCount：A create exact repository endpoint"

    Assert-Equal $createFake.Requests[0].headers.Authorization `
        'Bearer fake-adapter-token-9f88' 'dedicated bearer auth'
    Assert-Equal $createFake.AllRequests[0].headers.Authorization `
        'Bearer fake-adapter-token-9f88' 'repository preflight bearer auth'
    Assert-Equal $createFake.Requests[0].headers.Accept `
        'application/vnd.github+json' 'accept header'
    Assert-Equal $createFake.Requests[0].headers.'X-GitHub-Api-Version' `
        '2022-11-28' 'API version header'
    Assert-Equal $createFake.Requests[0].contentType 'application/json; charset=utf-8' `
        'content type'
    $passed++; Write-Host "PASS $passed/$testCount：B GitHub headers contract"

    $createdJson = ConvertTo-Json $created -Compress
    Assert-True (-not $createdJson.Contains('fake-adapter-token-9f88')) `
        'token absent output'
    $passed++; Write-Host "PASS $passed/$testCount：C token absent output"

    Assert-Equal ($created.PSObject.Properties.Name -join ',') `
        'version,action,dispatchId,revision,repository,issueNumber,issueUrl' `
        'publish exact fields'
    Assert-Equal $created.action 'created' 'create action'
    Assert-Equal $created.issueNumber ([int64]21) 'created number'
    $passed++; Write-Host "PASS $passed/$testCount：F create success contract"

    $createPayload = $createFake.Requests[0].body | ConvertFrom-Json
    Assert-Equal ($createPayload.PSObject.Properties.Name -join ',') `
        'title,body,assignees' 'create payload fields with assignee'
    Assert-Equal $createPayload.assignees[0] 'example-user' 'configured assignee'
    $passed++; Write-Host "PASS $passed/$testCount：G optional assignee included"

    $noAssignee = New-RoutingPendingFixture -Parent $testRoot -Name 'no-assignee' `
        -IncludeAssignee $false
    $noAssigneeFake = New-FakeTransport -Responses @(
        (New-IssueResponse -Number 22)
    )
    Invoke-FakePublish -Fixture $noAssignee -Fake $noAssigneeFake | Out-Null
    $noAssigneePayload = $noAssigneeFake.Requests[0].body | ConvertFrom-Json
    Assert-True ($null -eq $noAssigneePayload.PSObject.Properties['assignees']) `
        'assignees omitted'
    $passed++; Write-Host "PASS $passed/$testCount：H absent assignee omitted"

    $priorToken = [Environment]::GetEnvironmentVariable(
        'CODEX_DISPATCH_GITHUB_TOKEN', [EnvironmentVariableTarget]::Process
    )
    try {
        [Environment]::SetEnvironmentVariable(
            'CODEX_DISPATCH_GITHUB_TOKEN', $null, [EnvironmentVariableTarget]::Process
        )
        Assert-AdapterError -Action {
            & $publishScript -DispatchId $pending.State.dispatchId `
                -ConfigPath $pending.Case.Config
        } -Contains '缺少 CODEX_DISPATCH_GITHUB_TOKEN。' | Out-Null
    }
    finally {
        [Environment]::SetEnvironmentVariable(
            'CODEX_DISPATCH_GITHUB_TOKEN', $priorToken,
            [EnvironmentVariableTarget]::Process
        )
    }
    $passed++; Write-Host "PASS $passed/$testCount：E missing token fails before network"

    $noTokenFake = New-FakeTransport -Responses @((New-IssueResponse))
    Assert-AdapterError -Action {
        Invoke-FakePublish -Fixture $pending -Fake $noTokenFake -Token ''
    } -Contains '缺少 CODEX_DISPATCH_GITHUB_TOKEN。' | Out-Null
    Assert-Equal $noTokenFake.Requests.Count 0 'no network without token'
    Assert-Equal $noTokenFake.AllRequests.Count 0 'no repository preflight without token'
    $passed++; Write-Host "PASS $passed/$testCount：missing token internal preflight"

    $publicCreateFake = New-FakeTransport -RepositoryResponse (
        New-RepositoryMetadataResponse -Private $false
    )
    Assert-AdapterError -Action {
        Invoke-FakePublish -Fixture $pending -Fake $publicCreateFake
    } -Contains 'control-plane repository 必须是 private repository' | Out-Null
    Assert-Equal $publicCreateFake.AllRequests.Count 1 `
        'public repository create only metadata GET'
    Assert-Equal $publicCreateFake.Requests.Count 0 `
        'public repository rejected before issue POST'
    $passed++; Write-Host "PASS $passed/$testCount：repository private=false blocks create"

    $publicUpdateFake = New-FakeTransport -RepositoryResponse (
        New-RepositoryMetadataResponse -Private $false
    )
    Assert-AdapterError -Action {
        Invoke-FakePublish -Fixture $pending -Fake $publicUpdateFake -IssueNumber 17
    } -Contains 'control-plane repository 必须是 private repository' | Out-Null
    Assert-Equal $publicUpdateFake.AllRequests.Count 1 `
        'public repository update only metadata GET'
    Assert-Equal $publicUpdateFake.Requests.Count 0 `
        'public repository rejected before issue GET/PATCH'
    $passed++; Write-Host "PASS $passed/$testCount：repository private=false blocks update"

    $identityMismatchFake = New-FakeTransport -RepositoryResponse (
        New-RepositoryMetadataResponse -FullName 'other-owner/other-repository'
    )
    Assert-AdapterError -Action {
        Invoke-FakePublish -Fixture $pending -Fake $identityMismatchFake
    } -Contains 'control-plane repository identity 与配置不匹配' | Out-Null
    Assert-Equal $identityMismatchFake.Requests.Count 0 `
        'identity mismatch rejected before issue API'
    $passed++; Write-Host "PASS $passed/$testCount：repository identity mismatch fails closed"

    $caseRepository = New-RoutingPendingFixture -Parent $testRoot `
        -Name 'repository-case-identity' -Repository 'Owner/Repo'
    $caseIdentityFake = New-FakeTransport `
        -RepositoryResponse (
            New-RepositoryMetadataResponse -FullName 'owner/repo'
        ) `
        -Responses @((New-IssueResponse -Repository 'owner/repo'))
    $caseIdentityResult = Invoke-FakePublish `
        -Fixture $caseRepository -Fake $caseIdentityFake
    Assert-Equal $caseIdentityResult.action 'created' `
        'case-only repository identity allowed'
    Assert-Equal ($caseIdentityFake.AllRequests.method -join ',') 'GET,POST' `
        'case-only identity performs metadata GET then Issue POST'
    Assert-Equal $caseIdentityFake.Requests.Count 1 `
        'case-only identity performs exactly one Issue API request'
    $passed++; Write-Host "PASS $passed/$testCount：repository identity case-insensitive exact"

    $missingPrivateFake = New-FakeTransport -RepositoryResponse (
        New-RepositoryMetadataResponse -OmitPrivate
    )
    Assert-AdapterError -Action {
        Invoke-FakePublish -Fixture $pending -Fake $missingPrivateFake
    } -Contains 'control-plane repository 必须是 private repository' | Out-Null
    Assert-Equal $missingPrivateFake.Requests.Count 0 `
        'missing private rejected before issue API'
    $passed++; Write-Host "PASS $passed/$testCount：missing private field fails closed"

    $typedPrivateFake = New-FakeTransport -RepositoryResponse (
        New-RepositoryMetadataResponse -Private 'true'
    )
    Assert-AdapterError -Action {
        Invoke-FakePublish -Fixture $pending -Fake $typedPrivateFake
    } -Contains 'control-plane repository 必须是 private repository' | Out-Null
    Assert-Equal $typedPrivateFake.Requests.Count 0 `
        'non-bool private rejected before issue API'
    $passed++; Write-Host "PASS $passed/$testCount：non-bool private field fails closed"

    $missingFullNameFake = New-FakeTransport -RepositoryResponse (
        New-RepositoryMetadataResponse -OmitFullName
    )
    Assert-AdapterError -Action {
        Invoke-FakePublish -Fixture $pending -Fake $missingFullNameFake
    } -Contains 'control-plane repository identity 与配置不匹配' | Out-Null
    $typedFullNameFake = New-FakeTransport -RepositoryResponse (
        [pscustomobject]@{ full_name = 42; private = $true }
    )
    Assert-AdapterError -Action {
        Invoke-FakePublish -Fixture $pending -Fake $typedFullNameFake
    } -Contains 'control-plane repository identity 与配置不匹配' | Out-Null
    Assert-Equal ($missingFullNameFake.Requests.Count + $typedFullNameFake.Requests.Count) `
        0 'invalid full_name rejected before issue API'
    $passed++; Write-Host "PASS $passed/$testCount：missing/non-string full_name fails closed"

    foreach ($repositoryStatusCode in @(401, 403, 404)) {
        $repositoryHttpFake = New-FakeTransport -RepositoryResponse (
            New-HttpException -Status $repositoryStatusCode `
                -Message 'repository metadata denied'
        )
        $repositoryHttpMessage = Assert-AdapterError -Action {
            Invoke-FakePublish -Fixture $pending -Fake $repositoryHttpFake
        } -Contains "GitHub HTTP $repositoryStatusCode"
        Assert-True $repositoryHttpMessage.Contains(
            'endpoint /repos/example-owner/private-control'
        ) 'repository HTTP error includes bounded endpoint path'
        Assert-Equal $repositoryHttpFake.Requests.Count 0 `
            'repository HTTP error before issue API'
        $passed++; Write-Host (
            "PASS $passed/$testCount：repository metadata HTTP " +
                "$repositoryStatusCode bounded error"
        )
    }

    $repositorySecretToken = 'repository-secret-token-7421'
    $repositoryLeakFake = New-FakeTransport -RepositoryResponse (
        New-HttpException -Status 403 `
            -Message ("denied $repositorySecretToken")
    )
    $repositoryLeakMessage = Get-ThrownMessage -Action {
        Invoke-FakePublish -Fixture $pending -Fake $repositoryLeakFake `
            -Token $repositorySecretToken
    }
    Assert-True (-not $repositoryLeakMessage.Contains($repositorySecretToken)) `
        'configured token absent from repository preflight error'
    Assert-Equal $repositoryLeakFake.Requests.Count 0 `
        'repository token error before issue API'
    $passed++; Write-Host "PASS $passed/$testCount：repository preflight token-safe error"

    $updateProjection = Get-Projection -Fixture $workerNeeds
    $oldBody = $updateProjection.body.Replace(
        "CODEX_DISPATCH_REVISION: $($updateProjection.revision)",
        'CODEX_DISPATCH_REVISION: 1'
    )
    $updateFake = New-FakeTransport -Responses @(
        (New-RemoteIssue -Projection $updateProjection -Body $oldBody),
        (New-IssueResponse)
    )
    $updated = Invoke-FakePublish -Fixture $workerNeeds -Fake $updateFake -IssueNumber 17
    Assert-Equal ($updateFake.AllRequests.method -join ',') 'GET,GET,PATCH' `
        'private repository preflight before update'
    Assert-Equal ($updateFake.Requests.method -join ',') 'GET,PATCH' 'update sequence'
    Assert-Equal $updated.action 'updated' 'update action'
    $passed++; Write-Host "PASS $passed/$testCount：I/O update GET then PATCH lower revision"

    $patchPayload = $updateFake.Requests[1].body | ConvertFrom-Json
    Assert-Equal ($patchPayload.PSObject.Properties.Name -join ',') `
        'title,body,state' 'PATCH exact fields'
    Assert-Equal $patchPayload.body $updateProjection.body 'canonical body patch'
    $passed++; Write-Host "PASS $passed/$testCount：update canonical payload"

    $prFake = New-FakeTransport -Responses @(
        (New-RemoteIssue -Projection $pendingProjection -PullRequest)
    )
    Assert-AdapterError -Action {
        Invoke-FakePublish -Fixture $pending -Fake $prFake -IssueNumber 17
    } -Contains 'pull_request' | Out-Null
    Assert-Equal $prFake.Requests.Count 1 'PR rejected before PATCH'
    $passed++; Write-Host "PASS $passed/$testCount：J PR-shaped Issue rejected"

    $otherId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
    $wrongBody = $pendingProjection.body.Replace(
        $pending.State.dispatchId, $otherId
    )
    $wrongFake = New-FakeTransport -Responses @(
        (New-RemoteIssue -Projection $pendingProjection -Body $wrongBody)
    )
    Assert-AdapterError -Action {
        Invoke-FakePublish -Fixture $pending -Fake $wrongFake -IssueNumber 17
    } -Contains 'dispatchId 与 caller' | Out-Null
    $passed++; Write-Host "PASS $passed/$testCount：K wrong dispatch marker rejected"

    $malformedFake = New-FakeTransport -Responses @(
        (New-RemoteIssue -Projection $pendingProjection -Body '<!-- broken -->')
    )
    Assert-AdapterError -Action {
        Invoke-FakePublish -Fixture $pending -Fake $malformedFake -IssueNumber 17
    } -Contains 'marker prefix malformed' | Out-Null
    $passed++; Write-Host "PASS $passed/$testCount：L malformed marker rejected"

    $prefixedFake = New-FakeTransport -Responses @(
        (New-RemoteIssue -Projection $pendingProjection `
            -Body ("user text`n" + $pendingProjection.body))
    )
    Assert-AdapterError -Action {
        Invoke-FakePublish -Fixture $pending -Fake $prefixedFake -IssueNumber 17
    } -Contains 'marker prefix malformed' | Out-Null
    $passed++; Write-Host "PASS $passed/$testCount：M marker recognized only at prefix"

    $noopFake = New-FakeTransport -Responses @(
        (New-RemoteIssue -Projection $pendingProjection)
    )
    $noop = Invoke-FakePublish -Fixture $pending -Fake $noopFake -IssueNumber 17
    Assert-Equal $noop.action 'noop' 'equal canonical projection noop'
    Assert-Equal $noopFake.Requests.Count 1 'no PATCH for noop'
    $passed++; Write-Host "PASS $passed/$testCount：P equal exact projection NOOP"

    $manualFake = New-FakeTransport -Responses @(
        (New-RemoteIssue -Projection $pendingProjection `
            -Body ($pendingProjection.body + "`nmanual edit")),
        (New-IssueResponse)
    )
    $manualResult = Invoke-FakePublish -Fixture $pending -Fake $manualFake -IssueNumber 17
    Assert-Equal $manualResult.action 'updated' 'manual edit overwritten'
    Assert-Equal ($manualFake.Requests[1].body | ConvertFrom-Json).body `
        $pendingProjection.body 'manual body restored canonical'
    $passed++; Write-Host "PASS $passed/$testCount：Q manual body edit restored"

    $newerBody = $pendingProjection.body.Replace(
        'CODEX_DISPATCH_REVISION: 1', 'CODEX_DISPATCH_REVISION: 2'
    )
    $staleFake = New-FakeTransport -Responses @(
        (New-RemoteIssue -Projection $pendingProjection -Body $newerBody)
    )
    Assert-AdapterError -Action {
        Invoke-FakePublish -Fixture $pending -Fake $staleFake -IssueNumber 17
    } -Contains 'stale projection / refusing rollback' | Out-Null
    Assert-Equal $staleFake.Requests.Count 1 'stale rejected before PATCH'
    $passed++; Write-Host "PASS $passed/$testCount：R stale publisher rejected"

    $completedOldBody = $completedProjection.body.Replace(
        "CODEX_DISPATCH_REVISION: $($completedProjection.revision)",
        'CODEX_DISPATCH_REVISION: 1'
    )
    $completedFake = New-FakeTransport -Responses @(
        (New-RemoteIssue -Projection $completedProjection -Body $completedOldBody `
            -State 'open'),
        (New-IssueResponse)
    )
    Invoke-FakePublish -Fixture $completed -Fake $completedFake -IssueNumber 17 | Out-Null
    Assert-Equal ($completedFake.Requests[1].body | ConvertFrom-Json).state 'closed' `
        'completed PATCH closed'
    $passed++; Write-Host "PASS $passed/$testCount：S completed PATCH closes"

    $failedOldBody = $failedProjection.body.Replace(
        "CODEX_DISPATCH_REVISION: $($failedProjection.revision)",
        'CODEX_DISPATCH_REVISION: 1'
    )
    $failedFake = New-FakeTransport -Responses @(
        (New-RemoteIssue -Projection $failedProjection -Body $failedOldBody `
            -State 'closed'),
        (New-IssueResponse)
    )
    Invoke-FakePublish -Fixture $failed -Fake $failedFake -IssueNumber 17 | Out-Null
    Assert-Equal ($failedFake.Requests[1].body | ConvertFrom-Json).state 'open' `
        'failed PATCH remains open'
    $passed++; Write-Host "PASS $passed/$testCount：T failed PATCH reopens"

    $reopenFake = New-FakeTransport -Responses @(
        (New-RemoteIssue -Projection $updateProjection -State 'closed'),
        (New-IssueResponse)
    )
    Invoke-FakePublish -Fixture $workerNeeds -Fake $reopenFake -IssueNumber 17 | Out-Null
    Assert-Equal ($reopenFake.Requests[1].body | ConvertFrom-Json).state 'open' `
        'needs_input reopens manual closed Issue'
    $passed++; Write-Host "PASS $passed/$testCount：V manual close overridden by local needs_input"

    foreach ($statusCode in @(401, 403, 404)) {
        $httpFake = New-FakeTransport -Responses @(
            (New-HttpException -Status $statusCode -Message 'GitHub says denied')
        )
        $message = Assert-AdapterError -Action {
            Invoke-FakePublish -Fixture $pending -Fake $httpFake
        } -Contains "GitHub HTTP $statusCode"
        Assert-True ($message.Length -lt 2300) 'HTTP error bounded'
        $passed++; Write-Host "PASS $passed/$testCount：HTTP $statusCode bounded safe error"
    }

    $secretToken = 'actual-secret-token-43c2'
    $maliciousError = ('x' * 3000) + $secretToken + ' tail'
    $maliciousHttpFake = New-FakeTransport -Responses @(
        (New-HttpException -Status 403 -Message $maliciousError)
    )
    $leakMessage = Get-ThrownMessage -Action {
        Invoke-FakePublish -Fixture $pending -Fake $maliciousHttpFake `
            -Token $secretToken
    }
    Assert-True (-not $leakMessage.Contains($secretToken)) 'configured token redacted'
    Assert-True ($leakMessage.Length -lt 2300) 'malicious error bounded'
    $passed++; Write-Host "PASS $passed/$testCount：D/Z token absent from malicious error"

    $emptyAssignee = New-RoutingPendingFixture -Parent $testRoot -Name 'empty-assignee'
    Write-TestConfiguration -ConfigPath $emptyAssignee.Case.Config `
        -WorkspaceRoot '.\workspace' -StateDirectory '.\state' -Assignee '   '
    $emptyFake = New-FakeTransport -Responses @((New-IssueResponse))
    Invoke-FakePublish -Fixture $emptyAssignee -Fake $emptyFake | Out-Null
    $emptyPayload = $emptyFake.Requests[0].body | ConvertFrom-Json
    Assert-True ($null -eq $emptyPayload.PSObject.Properties['assignees']) `
        'trimmed empty assignee absent'
    $passed++; Write-Host "PASS $passed/$testCount：empty assignee treated absent"

    $invalidAssignee = New-RoutingPendingFixture -Parent $testRoot -Name 'bad-assignee'
    Write-TestConfiguration -ConfigPath $invalidAssignee.Case.Config `
        -WorkspaceRoot '.\workspace' -StateDirectory '.\state' -Assignee 'bad--login'
    Assert-AdapterError -Action {
        Get-Projection -Fixture $invalidAssignee
    } -Contains 'issueAssignee' | Out-Null
    $passed++; Write-Host "PASS $passed/$testCount：invalid assignee rejected"

    $typedAssignee = New-RoutingPendingFixture -Parent $testRoot -Name 'typed-assignee'
    Write-TestConfiguration -ConfigPath $typedAssignee.Case.Config `
        -WorkspaceRoot '.\workspace' -StateDirectory '.\state' -Assignee 42
    Assert-AdapterError -Action {
        Get-Projection -Fixture $typedAssignee
    } -Contains 'issueAssignee 必须是 string' | Out-Null
    $passed++; Write-Host "PASS $passed/$testCount：non-string assignee rejected"

    $badProvider = New-RoutingPendingFixture -Parent $testRoot -Name 'bad-provider'
    Write-TestConfiguration -ConfigPath $badProvider.Case.Config `
        -WorkspaceRoot '.\workspace' -StateDirectory '.\state' -Provider 'GitHub'
    Assert-AdapterError -Action {
        Get-Projection -Fixture $badProvider
    } -Contains 'provider 必须 exactly github' | Out-Null
    $passed++; Write-Host "PASS $passed/$testCount：provider exactly github"

    $badPrivacy = New-RoutingPendingFixture -Parent $testRoot -Name 'bad-privacy'
    Write-TestConfiguration -ConfigPath $badPrivacy.Case.Config `
        -WorkspaceRoot '.\workspace' -StateDirectory '.\state' `
        -ExposeThreads 'false'
    Assert-AdapterError -Action {
        Get-Projection -Fixture $badPrivacy
    } -Contains 'exposeThreadIdsInIssues 必须是 JSON bool' | Out-Null
    $passed++; Write-Host "PASS $passed/$testCount：privacy string false rejected"

    $wrongRepoResponseFake = New-FakeTransport `
        -RepositoryResponse (
            New-RepositoryMetadataResponse -FullName 'owner/repo'
        ) `
        -Responses @((New-IssueResponse -Repository 'owner/other-repo'))
    Assert-AdapterError -Action {
        Invoke-FakePublish -Fixture $caseRepository -Fake $wrongRepoResponseFake
    } -Contains 'repository context 不匹配' | Out-Null
    $passed++; Write-Host "PASS $passed/$testCount：response repository mismatch rejected"

    Assert-AdapterError -Action {
        $fake = New-FakeTransport -Responses @((New-IssueResponse))
        Invoke-FakePublish -Fixture $pending -Fake $fake -IssueNumber 0
    } -Contains 'IssueNumber 必须是 integer >= 1' | Out-Null
    $passed++; Write-Host "PASS $passed/$testCount：IssueNumber validation"

    $publicParameterNames = @(
        (Get-Command $publishScript).Parameters.Keys
    )
    foreach ($forbiddenParameter in @('Repository', 'Owner', 'Token', 'ApiBaseUri', 'Transport')) {
        Assert-True ($publicParameterNames -cnotcontains $forbiddenParameter) `
            "public Publish forbids $forbiddenParameter"
    }
    $passed++; Write-Host "PASS $passed/$testCount：public Publish surface fixed"

    $projectionParameterNames = @(
        (Get-Command $projectionScript).Parameters.Keys
    )
    Assert-True ($projectionParameterNames -cnotcontains 'Transport') `
        'projection has no transport'
    Assert-True ($projectionParameterNames -cnotcontains 'Repository') `
        'projection has no arbitrary repository'
    $passed++; Write-Host "PASS $passed/$testCount：projection is local-only API"

    $commonText = [System.IO.File]::ReadAllText($common)
    $publishText = [System.IO.File]::ReadAllText($publishScript)
    Assert-True (-not $publishText.Contains('GH_TOKEN')) 'no GH_TOKEN fallback'
    Assert-True (-not $publishText.Contains("'GITHUB_TOKEN'")) 'no GITHUB_TOKEN fallback'
    Assert-True (-not $commonText.Contains('Write-Host $Token')) 'no token logging'
    Assert-True (-not $commonText.Contains('ConvertTo-Json $Request.headers')) `
        'no header logging'
    $passed++; Write-Host "PASS $passed/$testCount：token static hygiene"

    $createBodyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
        [string]$createFake.Requests[0].body
    )
    Assert-True (-not (
        $createBodyBytes.Length -ge 3 -and $createBodyBytes[0] -eq 0xEF -and
        $createBodyBytes[1] -eq 0xBB -and $createBodyBytes[2] -eq 0xBF
    )) 'request JSON UTF-8 has no BOM'
    $passed++; Write-Host "PASS $passed/$testCount：request JSON UTF-8 no BOM"

    Assert-Equal $passed $testCount 'all test count'
    Write-Host "GitHub Issue Adapter tests: $passed/$testCount PASS"
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
