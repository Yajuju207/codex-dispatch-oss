$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptsRoot = Join-Path $repoRoot 'scripts'
$commonPath = Join-Path $scriptsRoot 'CodexDispatchOrchestrator.Common.ps1'
$publicPath = Join-Path $scriptsRoot 'Invoke-CodexDispatch.ps1'
$newStatePath = Join-Path $scriptsRoot 'New-CodexDispatchState.ps1'
$getStatePath = Join-Path $scriptsRoot 'Get-CodexDispatchState.ps1'
$updateStatePath = Join-Path $scriptsRoot 'Update-CodexDispatchState.ps1'
. $commonPath

$testCount = 43
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT TRUE failed: $Message" }
}

function Assert-Equal {
    param([AllowNull()][object]$Actual, [AllowNull()][object]$Expected, [string]$Message)
    if ($Actual -is [System.Array] -or $Expected -is [System.Array]) {
        if ((@($Actual) -join '|') -cne (@($Expected) -join '|')) {
            throw "ASSERT EQUAL failed: $Message; actual=$(@($Actual) -join '|'); expected=$(@($Expected) -join '|')"
        }
        return
    }
    if ($null -eq $Actual -and $null -eq $Expected) { return }
    if ($null -eq $Actual -or $null -eq $Expected -or [string]$Actual -cne [string]$Expected) {
        throw "ASSERT EQUAL failed: $Message; actual=$Actual; expected=$Expected"
    }
}

function Assert-ThrowsLike {
    param([scriptblock]$Action, [string]$ExpectedText, [string]$Message)
    $caught = $null
    try { & $Action }
    catch { $caught = $_ }
    Assert-True ($null -ne $caught) "$Message did not throw"
    Assert-True ([string]$caught.Exception.Message).Contains($ExpectedText) `
        "$Message missing '$ExpectedText': $($caught.Exception.Message)"
}

function Complete-Test {
    param([string]$Name)
    $script:passed++
    Write-Host "PASS $script:passed/$testCount`: $Name"
}

function Write-TestConfiguration {
    param([string]$Path, [string]$Workspace, [string]$StateDirectory)
    $document = [ordered]@{
        version = 1
        workspace = [ordered]@{
            root = $Workspace; scanDepth = 1; allowReparsePoints = $false
        }
        runtime = [ordered]@{ stateDirectory = $StateDirectory }
        controlPlane = [ordered]@{
            provider = 'github'; repository = 'example/control'
            defaultBranch = 'main'; issueAssignee = 'example'
        }
        routing = [ordered]@{
            fast = [ordered]@{ enabled = $true }
            slow = [ordered]@{ enabled = $true }
        }
        codex = [ordered]@{
            command = 'codex'; workerSandbox = 'workspace-write'
            routerSandbox = 'read-only'; approvalPolicy = 'never'
        }
        privacy = [ordered]@{
            exposeLocalPathsInIssues = $false
            exposeThreadIdsInIssues = $false
            includeOriginalTaskInIssues = $false
        }
        safety = [ordered]@{
            restrictToWorkspaceRoot = $true
            requireExplicitAuthorizationFor = @('push','deploy')
        }
    }
    [IO.File]::WriteAllText(
        $Path,
        (ConvertTo-Json $document -Depth 8) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
}

function New-TestCase {
    param([string]$Parent, [string]$Name)
    $root = Join-Path $Parent $Name
    $workspace = Join-Path $root 'workspace'
    $stateDirectory = Join-Path $root 'state'
    [void](New-Item -ItemType Directory -Path $workspace -Force)
    [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
    $config = Join-Path $root 'config.local.json'
    Write-TestConfiguration -Path $config -Workspace $workspace `
        -StateDirectory $stateDirectory
    $indexPath = Join-Path $root 'project-index.json'
    [IO.File]::WriteAllText(
        $indexPath,
        '{"version":1,"projects":[]}' + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    return [pscustomobject]@{
        Root = $root; Workspace = $workspace; StateDirectory = $stateDirectory
        Config = $config; IndexPath = [IO.Path]::GetFullPath($indexPath)
    }
}

function New-FastResult {
    param([string]$Status = 'strong', [AllowNull()][object]$Repository = 'owner/project')
    $selected = $null
    if ($Status -ceq 'strong') {
        $selected = [pscustomobject][ordered]@{
            name = 'project'; localPath = 'C:\untrusted\router-path'
            githubRepository = $Repository; score = 200
            matchedSignals = [object[]]@()
        }
    }
    return [pscustomobject][ordered]@{
        version = 1; status = $Status; topScore = 200; lead = 200
        selectedProject = $selected; candidates = [object[]]@()
    }
}

function New-SlowResult {
    param([string]$Status = 'routed')
    $selected = $null
    $confidence = $null
    $reason = ''
    $question = ''
    $options = [string[]]@()
    if ($Status -ceq 'routed') {
        $selected = [pscustomobject][ordered]@{
            name = 'slow-project'; localPath = 'C:\untrusted\slow-path'
            githubRepository = 'owner/slow-project'
        }
        $confidence = 0.95
        $reason = 'Selected by identity.'
    }
    elseif ($Status -ceq 'needs_input') {
        $confidence = 0.5
        $reason = 'Multiple candidates.'
        $question = 'Which repository should be used?'
        $options = [string[]]@('owner/one','owner/two')
    }
    elseif ($Status -ceq 'no_match') {
        $reason = 'No project matched the task.'
    }
    else {
        $reason = 'Slow Router is disabled.'
    }
    return [pscustomobject][ordered]@{
        version = 1; status = $Status; selectedProject = $selected
        confidence = $confidence; reason = $reason; question = $question
        options = $options
    }
}

function New-WorkerResult {
    param([string]$Status = 'completed', [string]$Diagnostic = 'worker failed')
    $threadId = if ($Status -ceq 'failed') { $null } else {
        '11111111-1111-1111-1111-111111111111'
    }
    $options = [string[]]@()
    if ($Status -ceq 'needs_input') { $options = [string[]]@('Continue','Stop') }
    return [pscustomobject][ordered]@{
        version = 1; status = $Status
        project = [pscustomobject][ordered]@{
            name = 'project'; localPath = 'C:\authorized\worker-path'
            githubRepository = 'owner/project'
        }
        threadId = $threadId
        report = if ($Status -ceq 'completed') { 'Work completed.' } elseif ($Status -ceq 'needs_input') { 'Input required.' } else { '' }
        question = if ($Status -ceq 'needs_input') { 'Continue?' } else { '' }
        context = if ($Status -ceq 'needs_input') { 'Choose an option.' } else { '' }
        options = $options
        exitCode = if ($Status -ceq 'failed') { 1 } else { 0 }
        diagnostic = if ($Status -ceq 'failed') { $Diagnostic } else { '' }
    }
}

function Get-CredentialPresence {
    $environment = [Environment]::GetEnvironmentVariables(
        [EnvironmentVariableTarget]::Process
    )
    return [pscustomobject]@{
        Codex = $environment.Contains('CODEX_DISPATCH_GITHUB_TOKEN')
        Gh = $environment.Contains('GH_TOKEN')
        Github = $environment.Contains('GITHUB_TOKEN')
        CodexValue = if ($environment.Contains('CODEX_DISPATCH_GITHUB_TOKEN')) {
            [string]$environment['CODEX_DISPATCH_GITHUB_TOKEN']
        } else { $null }
    }
}

function Get-ChildCredentialPresence {
    $command = @'
$environment = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process)
$ProgressPreference = 'SilentlyContinue'
Write-Output ((@(
    [int]$environment.Contains('CODEX_DISPATCH_GITHUB_TOKEN'),
    [int]$environment.Contains('GH_TOKEN'),
    [int]$environment.Contains('GITHUB_TOKEN')
) -join ','))
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $output = & powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded
    if ($LASTEXITCODE -ne 0) { throw "credential child exited $LASTEXITCODE" }
    return ([string]$output).Trim()
}

function New-FakeDependencies {
    param(
        [object]$Case,
        [string]$FastMode = 'strong',
        [string]$SlowMode = 'routed',
        [string]$WorkerMode = 'completed',
        [string]$PublisherMode = 'created'
    )
    $context = [pscustomobject]@{
        FastMode = $FastMode; SlowMode = $SlowMode
        WorkerMode = $WorkerMode; PublisherMode = $PublisherMode
        FastCalls = 0; SlowCalls = 0; WorkerCalls = 0; PublisherCalls = 0
        UpdateCalls = 0; FailUpdateNumber = 0
        Requests = New-Object 'System.Collections.Generic.List[object]'
        WorkerObservedState = $null; PublisherObservedState = $null
        SlowEnvironment = $null; WorkerEnvironment = $null
        PublisherEnvironment = $null; SlowChild = ''; WorkerChild = ''
        ObserveSlowChild = $false; ObserveWorkerChild = $false
        FastError = 'fake Fast Router exception'
        SlowError = 'fake Slow Router exception'
        WorkerError = 'fake Worker preflight exception'
        PublisherError = 'fake Issue publication exception'
        WorkerDiagnostic = 'worker failed'
    }
    $caseConfig = $Case.Config
    $newStateScriptPath = $script:newStatePath
    $getStateScriptPath = $script:getStatePath
    $updateStateScriptPath = $script:updateStatePath

    $newState = { param($Request); & $newStateScriptPath @Request }.GetNewClosure()
    $getState = { param($Request); & $getStateScriptPath @Request }.GetNewClosure()
    $updateState = {
        param($Request)
        $context.UpdateCalls++
        [void]$context.Requests.Add([pscustomobject]@{
            Component = 'UpdateState'; Request = $Request
        })
        if ($context.FailUpdateNumber -gt 0 -and $context.UpdateCalls -eq $context.FailUpdateNumber) {
            throw 'fake Runtime State update failure'
        }
        & $updateStateScriptPath @Request
    }.GetNewClosure()
    $fast = {
        param($Request)
        $context.FastCalls++
        [void]$context.Requests.Add([pscustomobject]@{ Component = 'Fast'; Request = $Request })
        if ($context.FastMode -ceq 'throw') { throw $context.FastError }
        if ($context.FastMode -ceq 'malformed') { return [pscustomobject]@{ status = 'strong' } }
        if ($context.FastMode -ceq 'local-only') { return New-FastResult -Status strong -Repository $null }
        return New-FastResult -Status $context.FastMode -Repository 'owner/project'
    }.GetNewClosure()
    $slow = {
        param($Request)
        $context.SlowCalls++
        $context.SlowEnvironment = Get-CredentialPresence
        if ($context.ObserveSlowChild) { $context.SlowChild = Get-ChildCredentialPresence }
        [void]$context.Requests.Add([pscustomobject]@{ Component = 'Slow'; Request = $Request })
        if ($context.SlowMode -ceq 'throw') { throw $context.SlowError }
        if ($context.SlowMode -ceq 'malformed') { return [pscustomobject]@{ status = 'routed' } }
        return New-SlowResult -Status $context.SlowMode
    }.GetNewClosure()
    $worker = {
        param($Request)
        $context.WorkerCalls++
        $context.WorkerEnvironment = Get-CredentialPresence
        if ($context.ObserveWorkerChild) { $context.WorkerChild = Get-ChildCredentialPresence }
        $context.WorkerObservedState = $null
        $stateFiles = @(
            Get-ChildItem -LiteralPath $Case.StateDirectory -Filter '*.json' -Recurse
        )
        if ($stateFiles.Count -eq 1) {
            $context.WorkerObservedState = Get-Content -Raw -LiteralPath $stateFiles[0].FullName | ConvertFrom-Json
        }
        [void]$context.Requests.Add([pscustomobject]@{ Component = 'Worker'; Request = $Request })
        if ($context.WorkerMode -ceq 'throw') { throw $context.WorkerError }
        if ($context.WorkerMode -ceq 'malformed') { return [pscustomobject]@{ status = 'completed' } }
        return New-WorkerResult -Status $context.WorkerMode -Diagnostic $context.WorkerDiagnostic
    }.GetNewClosure()
    $publisher = {
        param($Request)
        $context.PublisherCalls++
        $context.PublisherEnvironment = Get-CredentialPresence
        $context.PublisherObservedState = & $getStateScriptPath `
            -DispatchId $Request.DispatchId -ConfigPath $caseConfig
        [void]$context.Requests.Add([pscustomobject]@{ Component = 'Publisher'; Request = $Request })
        if ($context.PublisherMode -cin @('throw','private-fail','partial-fail')) {
            throw $context.PublisherError
        }
        $action = $context.PublisherMode
        return [pscustomobject][ordered]@{
            version = 1; action = $action; dispatchId = $Request.DispatchId
            revision = [int64]$context.PublisherObservedState.revision
            repository = 'example/control'; issueNumber = [int64]42
            issueUrl = 'https://github.com/example/control/issues/42'
        }
    }.GetNewClosure()
    return [pscustomobject]@{
        Dependencies = [pscustomobject][ordered]@{
            NewState = $newState; GetState = $getState; UpdateState = $updateState
            FastRouter = $fast; SlowRouter = $slow; Worker = $worker
            Publisher = $publisher
        }
        Context = $context
    }
}

function Invoke-TestDispatch {
    param([object]$Case, [object]$Fixture, [string]$Task = 'Implement the task')
    Push-Location $Case.Root
    try {
        return Invoke-CodexDispatchOrchestratorInternal `
            -Task $Task -ConfigPath $Case.Config `
            -Dependencies $Fixture.Dependencies
    }
    finally { Pop-Location }
}

function Get-OnlyState {
    param([object]$Case)
    $files = @(
        Get-ChildItem -LiteralPath $Case.StateDirectory -Filter '*.json' -Recurse
    )
    Assert-Equal $files.Count 1 'one durable state file'
    return Get-Content -Raw -LiteralPath $files[0].FullName | ConvertFrom-Json
}

$suiteEnvironment = Get-CodexDispatchOrchestratorCredentialSnapshot
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'codex-dispatch-orchestrator-' + [guid]::NewGuid().ToString('N')
)
[void](New-Item -ItemType Directory -Path $tempRoot)

try {
    Remove-CodexDispatchOrchestratorCredentials

    $case = New-TestCase $tempRoot '01-direct-completed'
    $fixture = New-FakeDependencies $case
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $result.phase 'worker' 'direct phase'
    Assert-Equal $result.status 'completed' 'direct completed'
    Assert-Equal $result.projectRepository 'owner/project' 'direct identity'
    Assert-Equal $fixture.Context.SlowCalls 0 'direct skips Slow Router'
    Assert-Equal $fixture.Context.WorkerCalls 1 'direct Worker count'
    Complete-Test 'direct Fast strong to Worker completed'

    $case = New-TestCase $tempRoot '02-ambiguous-slow'
    $fixture = New-FakeDependencies $case -FastMode ambiguous
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $fixture.Context.SlowCalls 1 'ambiguous invokes Slow Router'
    Assert-Equal $result.projectRepository 'owner/slow-project' 'Slow identity'
    Assert-Equal $result.status 'completed' 'Slow completed'
    Complete-Test 'Fast ambiguous to Slow routed to completed'

    $case = New-TestCase $tempRoot '03-local-only'
    $fixture = New-FakeDependencies $case -FastMode local-only
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $fixture.Context.SlowCalls 1 'local-only invokes Slow Router'
    Assert-Equal $result.projectRepository 'owner/slow-project' 'local-only ignores localPath'
    Complete-Test 'Fast strong local-only falls back to Slow Router'

    $case = New-TestCase $tempRoot '04-slow-needs-input'
    $fixture = New-FakeDependencies $case -FastMode ambiguous -SlowMode needs_input
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $result.phase 'routing' 'routing needs_input phase'
    Assert-Equal $result.status 'needs_input' 'routing needs_input status'
    Assert-Equal $result.question 'Which repository should be used?' 'Router question'
    Assert-Equal $result.options @('owner/one','owner/two') 'Router options'
    Complete-Test 'Slow Router needs_input mapping'

    $case = New-TestCase $tempRoot '05-slow-no-match'
    $fixture = New-FakeDependencies $case -FastMode no_match -SlowMode no_match
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $result.status 'needs_input' 'no_match maps needs_input'
    Assert-Equal $result.options @('Retry routing','Stop dispatch') 'no_match options'
    Assert-True ($result.context.Contains('No project matched')) 'no_match context'
    Complete-Test 'Slow Router no_match deterministic intervention'

    $case = New-TestCase $tempRoot '06-slow-disabled'
    $fixture = New-FakeDependencies $case -FastMode disabled -SlowMode disabled
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $result.status 'needs_input' 'disabled maps needs_input'
    Assert-True ($result.context.Contains('disabled')) 'disabled context'
    Complete-Test 'Slow Router disabled deterministic intervention'

    $case = New-TestCase $tempRoot '07-fast-throw'
    $fixture = New-FakeDependencies $case -FastMode throw
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $result.phase 'routing' 'Fast throw routing phase'
    Assert-Equal $result.status 'needs_input' 'Fast throw needs_input'
    Assert-Equal $fixture.Context.SlowCalls 0 'Fast throw stops before Slow Router'
    Complete-Test 'Fast Router throw maps technical intervention'

    $case = New-TestCase $tempRoot '08-fast-malformed'
    $fixture = New-FakeDependencies $case -FastMode malformed
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $result.status 'needs_input' 'Fast malformed needs_input'
    Assert-Equal $fixture.Context.SlowCalls 0 'Fast malformed stops before Slow Router'
    Complete-Test 'Fast Router malformed contract maps technical intervention'

    $case = New-TestCase $tempRoot '09-slow-throw'
    $fixture = New-FakeDependencies $case -FastMode ambiguous -SlowMode throw
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $result.status 'needs_input' 'Slow throw needs_input'
    Assert-Equal $fixture.Context.WorkerCalls 0 'Slow throw stops before Worker'
    Complete-Test 'Slow Router throw maps technical intervention'

    $case = New-TestCase $tempRoot '10-slow-malformed'
    $fixture = New-FakeDependencies $case -FastMode ambiguous -SlowMode malformed
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $result.status 'needs_input' 'Slow malformed needs_input'
    Assert-Equal $fixture.Context.WorkerCalls 0 'Slow malformed stops before Worker'
    Complete-Test 'Slow Router malformed contract maps technical intervention'

    $case = New-TestCase $tempRoot '11-worker-needs-input'
    $fixture = New-FakeDependencies $case -WorkerMode needs_input
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $result.status 'needs_input' 'Worker needs_input status'
    Assert-Equal $result.question 'Continue?' 'Worker question'
    Assert-Equal $result.options @('Continue','Stop') 'Worker options'
    Complete-Test 'Worker needs_input mapping'

    $case = New-TestCase $tempRoot '12-worker-failed'
    $fixture = New-FakeDependencies $case -WorkerMode failed
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $result.status 'failed' 'structured failed status'
    Assert-Equal $result.diagnostic 'worker failed' 'structured failed diagnostic'
    Complete-Test 'Worker structured failed mapping'

    $case = New-TestCase $tempRoot '13-worker-throw'
    $fixture = New-FakeDependencies $case -WorkerMode throw
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $result.status 'failed' 'Worker throw status'
    Assert-True ($result.diagnostic.Contains('preflight')) 'Worker throw diagnostic'
    Complete-Test 'Worker preflight throw maps worker failed'

    $case = New-TestCase $tempRoot '14-running-before-worker'
    $fixture = New-FakeDependencies $case
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $fixture.Context.WorkerObservedState.phase 'worker' 'Worker observed phase'
    Assert-Equal $fixture.Context.WorkerObservedState.status 'running' 'Worker observed durable running'
    Assert-Equal $fixture.Context.WorkerObservedState.projectRepository 'owner/project' 'Worker observed identity'
    Complete-Test 'worker/running state write precedes Worker invocation'

    $case = New-TestCase $tempRoot '15-final-before-publish'
    $fixture = New-FakeDependencies $case
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $fixture.Context.PublisherObservedState.status 'completed' 'Publisher observed completed'
    Assert-Equal $fixture.Context.PublisherObservedState.revision $result.revision 'Publisher observed final revision'
    Complete-Test 'final durable state write precedes Issue publication'

    $case = New-TestCase $tempRoot '16-state-failure'
    $fixture = New-FakeDependencies $case
    $fixture.Context.FailUpdateNumber = 3
    Assert-ThrowsLike { Invoke-TestDispatch $case $fixture } 'Runtime State update failure' 'final State write failure'
    Assert-Equal $fixture.Context.PublisherCalls 0 'State failure publisher count'
    Complete-Test 'State update failure fails stop before Publisher'

    $case = New-TestCase $tempRoot '17-create-failure'
    $fixture = New-FakeDependencies $case -PublisherMode throw
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $result.status 'completed' 'create failure execution truth'
    Assert-Equal $result.issuePublication 'failed' 'create failure metadata'
    Assert-Equal (Get-OnlyState $case).status 'completed' 'create failure durable truth'
    Complete-Test 'Issue create failure does not alter completed State'

    $case = New-TestCase $tempRoot '18-private-preflight'
    $fixture = New-FakeDependencies $case -PublisherMode private-fail
    $fixture.Context.PublisherError = 'GitHub repository must be private.'
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $result.status 'completed' 'private preflight truth'
    Assert-Equal (Get-OnlyState $case).status 'completed' 'private preflight durable truth'
    Complete-Test 'Issue private-repository failure leaves State unchanged'

    $case = New-TestCase $tempRoot '19-partial-create'
    $fixture = New-FakeDependencies $case -PublisherMode partial-fail
    $fixture.Context.PublisherError = 'Issue already created as #42; synchronization failed.'
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $fixture.Context.PublisherCalls 1 'partial-create no retry'
    Assert-Equal $result.issuePublication 'failed' 'partial-create metadata'
    Assert-Equal $result.issueNumber $null 'partial-create number not parsed'
    Assert-Equal (Get-OnlyState $case).status 'completed' 'partial-create State truth'
    Complete-Test 'partial-create failure is captured without retry or parsing'

    [Environment]::SetEnvironmentVariable('CODEX_DISPATCH_GITHUB_TOKEN','cd-secret','Process')
    [Environment]::SetEnvironmentVariable('GH_TOKEN','gh-secret','Process')
    [Environment]::SetEnvironmentVariable('GITHUB_TOKEN','github-secret','Process')
    $case = New-TestCase $tempRoot '20-slow-environment'
    $fixture = New-FakeDependencies $case -FastMode ambiguous
    $result = Invoke-TestDispatch $case $fixture
    Assert-True (-not $fixture.Context.SlowEnvironment.Codex) 'Slow CODEX credential absent'
    Assert-True (-not $fixture.Context.SlowEnvironment.Gh) 'Slow GH credential absent'
    Assert-True (-not $fixture.Context.SlowEnvironment.Github) 'Slow GITHUB credential absent'
    Complete-Test 'all control-plane credentials absent inside Slow Router'

    $case = New-TestCase $tempRoot '21-slow-child'
    $fixture = New-FakeDependencies $case -FastMode ambiguous
    $fixture.Context.ObserveSlowChild = $true
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $fixture.Context.SlowChild '0,0,0' 'Slow Router child environment'
    Complete-Test 'Slow Router child inherits no control-plane credentials'

    $case = New-TestCase $tempRoot '22-worker-environment'
    $fixture = New-FakeDependencies $case
    $result = Invoke-TestDispatch $case $fixture
    Assert-True (-not $fixture.Context.WorkerEnvironment.Codex) 'Worker CODEX credential absent'
    Assert-True (-not $fixture.Context.WorkerEnvironment.Gh) 'Worker GH credential absent'
    Assert-True (-not $fixture.Context.WorkerEnvironment.Github) 'Worker GITHUB credential absent'
    Complete-Test 'all control-plane credentials absent inside Worker'

    $case = New-TestCase $tempRoot '23-worker-child'
    $fixture = New-FakeDependencies $case
    $fixture.Context.ObserveWorkerChild = $true
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $fixture.Context.WorkerChild '0,0,0' 'Worker child environment'
    Complete-Test 'Worker child inherits no control-plane credentials'

    $case = New-TestCase $tempRoot '24-publisher-environment'
    $fixture = New-FakeDependencies $case
    $result = Invoke-TestDispatch $case $fixture
    Assert-True $fixture.Context.PublisherEnvironment.Codex 'Publisher CODEX credential restored'
    Assert-Equal $fixture.Context.PublisherEnvironment.CodexValue 'cd-secret' 'Publisher CODEX value'
    Assert-True (-not $fixture.Context.PublisherEnvironment.Gh) 'Publisher GH absent'
    Assert-True (-not $fixture.Context.PublisherEnvironment.Github) 'Publisher GITHUB absent'
    Complete-Test 'Publisher sees only CODEX_DISPATCH_GITHUB_TOKEN'

    $case = New-TestCase $tempRoot '25-success-restore'
    $fixture = New-FakeDependencies $case
    $result = Invoke-TestDispatch $case $fixture
    $presence = Get-CredentialPresence
    Assert-Equal $presence.CodexValue 'cd-secret' 'success CODEX restore'
    Assert-Equal ([Environment]::GetEnvironmentVariable('GH_TOKEN','Process')) 'gh-secret' 'success GH restore'
    Assert-Equal ([Environment]::GetEnvironmentVariable('GITHUB_TOKEN','Process')) 'github-secret' 'success GITHUB restore'
    Complete-Test 'caller environment exactly restored after success'

    $case = New-TestCase $tempRoot '26-worker-throw-restore'
    $fixture = New-FakeDependencies $case -WorkerMode throw
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal ([Environment]::GetEnvironmentVariable('CODEX_DISPATCH_GITHUB_TOKEN','Process')) 'cd-secret' 'Worker throw CODEX restore'
    Assert-Equal ([Environment]::GetEnvironmentVariable('GH_TOKEN','Process')) 'gh-secret' 'Worker throw GH restore'
    Assert-Equal ([Environment]::GetEnvironmentVariable('GITHUB_TOKEN','Process')) 'github-secret' 'Worker throw GITHUB restore'
    Complete-Test 'caller environment exactly restored after Worker throw'

    $case = New-TestCase $tempRoot '27-publisher-throw-restore'
    $fixture = New-FakeDependencies $case -PublisherMode throw
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal ([Environment]::GetEnvironmentVariable('CODEX_DISPATCH_GITHUB_TOKEN','Process')) 'cd-secret' 'Publisher throw CODEX restore'
    Assert-Equal ([Environment]::GetEnvironmentVariable('GH_TOKEN','Process')) 'gh-secret' 'Publisher throw GH restore'
    Assert-Equal ([Environment]::GetEnvironmentVariable('GITHUB_TOKEN','Process')) 'github-secret' 'Publisher throw GITHUB restore'
    Complete-Test 'caller environment exactly restored after Publisher throw'

    [Environment]::SetEnvironmentVariable('CODEX_DISPATCH_GITHUB_TOKEN',$null,'Process')
    Set-CodexDispatchOrchestratorEmptyEnvironmentVariable -Name 'GH_TOKEN'
    [Environment]::SetEnvironmentVariable('GITHUB_TOKEN','nonempty','Process')
    $case = New-TestCase $tempRoot '28-empty-restore'
    $fixture = New-FakeDependencies $case
    $result = Invoke-TestDispatch $case $fixture
    $environment = [Environment]::GetEnvironmentVariables('Process')
    Assert-True (-not $environment.Contains('CODEX_DISPATCH_GITHUB_TOKEN')) 'absent remains absent'
    Assert-True $environment.Contains('GH_TOKEN') 'empty remains present'
    Assert-Equal ([string]$environment['GH_TOKEN']) '' 'empty value remains empty'
    Assert-Equal ([string]$environment['GITHUB_TOKEN']) 'nonempty' 'nonempty restored'
    Complete-Test 'absent versus present-empty environment restoration is exact'

    Remove-CodexDispatchOrchestratorCredentials
    $command = Get-Command -Name $publicPath
    $commonParameters = @('Verbose','Debug','ErrorAction','WarningAction','InformationAction','ProgressAction','ErrorVariable','WarningVariable','InformationVariable','OutVariable','OutBuffer','PipelineVariable')
    $publicParameters = @($command.Parameters.Keys | Where-Object { $_ -notin $commonParameters } | Sort-Object)
    Assert-Equal $publicParameters @('ConfigPath','Task') 'public parameter names'
    $taskParameterAttribute = @(
        $command.Parameters['Task'].Attributes | Where-Object {
            $_ -is [Management.Automation.ParameterAttribute]
        }
    )[0]
    Assert-True $taskParameterAttribute.Mandatory 'Task mandatory'
    Assert-Equal $taskParameterAttribute.Position 0 'Task position'
    Complete-Test 'public command parameter contract is exact'

    foreach ($forbidden in @('DispatchId','IssueNumber')) {
        Assert-True (-not $command.Parameters.ContainsKey($forbidden)) "forbidden $forbidden"
    }
    Complete-Test 'no DispatchId or IssueNumber public parameter'

    foreach ($forbidden in @(
        'ProjectPath','ProjectRepository','Repository','Token','ApiBaseUri','Transport',
        'ThreadId','Force','SkipAuthorization','SkipRouting','IndexPath'
    )) {
        Assert-True (-not $command.Parameters.ContainsKey($forbidden)) "forbidden $forbidden"
    }
    Complete-Test 'no authority or transport bypass public parameter'

    $caseA = New-TestCase $tempRoot '31-duplicate-a'
    $fixtureA = New-FakeDependencies $caseA
    $first = Invoke-TestDispatch $caseA $fixtureA -Task 'identical task'
    $caseB = New-TestCase $tempRoot '31-duplicate-b'
    $fixtureB = New-FakeDependencies $caseB
    $second = Invoke-TestDispatch $caseB $fixtureB -Task 'identical task'
    Assert-True ($first.dispatchId -cne $second.dispatchId) 'duplicate task IDs distinct'
    Complete-Test 'same Task creates distinct dispatch IDs'

    $case = New-TestCase $tempRoot '32-output-order'
    $fixture = New-FakeDependencies $case
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal @($result.PSObject.Properties.Name) @(
        'version','dispatchId','revision','phase','status','projectRepository',
        'report','question','context','options','diagnostic','issuePublication',
        'issueNumber','issueUrl','projectionDiagnostic'
    ) 'output field order'
    Assert-True ($result.version -is [int]) 'version type'
    Assert-True ($result.revision -is [int64]) 'revision type'
    Complete-Test 'public output exact field order and core types'

    $serialized = ConvertTo-Json $result -Depth 8
    foreach ($forbidden in @('threadId','localPath','"task"','cd-secret','gh-secret','github-secret')) {
        Assert-True (-not $serialized.Contains($forbidden)) "output excludes $forbidden"
    }
    Complete-Test 'public output excludes threadId localPath Task and token data'

    $case = New-TestCase $tempRoot '34-publisher-updated'
    $fixture = New-FakeDependencies $case -PublisherMode updated
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $result.status 'completed' 'updated truth'
    Assert-Equal $result.issuePublication 'failed' 'updated is projection failure'
    Complete-Test 'Publisher action updated is a projection contract failure'

    $case = New-TestCase $tempRoot '35-publisher-noop'
    $fixture = New-FakeDependencies $case -PublisherMode noop
    $result = Invoke-TestDispatch $case $fixture
    Assert-Equal $result.status 'completed' 'noop truth'
    Assert-Equal $result.issuePublication 'failed' 'noop is projection failure'
    Complete-Test 'Publisher action noop is a projection contract failure'

    $case = New-TestCase $tempRoot '36-index-path'
    $fixture = New-FakeDependencies $case -FastMode ambiguous
    $result = Invoke-TestDispatch $case $fixture
    $routerWorkerRequests = @($fixture.Context.Requests | Where-Object {
        $_.Component -cin @('Fast','Slow','Worker')
    })
    Assert-Equal $routerWorkerRequests.Count 3 'three indexed components'
    foreach ($entry in $routerWorkerRequests) {
        Assert-Equal $entry.Request.IndexPath $case.IndexPath "$($entry.Component) IndexPath"
    }
    Assert-Equal $routerWorkerRequests[2].Request.ProjectRepository 'owner/slow-project' 'Worker repository identity'
    Assert-True (-not $routerWorkerRequests[2].Request.Contains('ProjectPath')) 'Worker no ProjectPath'
    Complete-Test 'same resolved IndexPath reaches Routers and Worker; no Router localPath authority'

    $source = Get-Content -Raw -LiteralPath $commonPath
    Assert-True (-not $source.Contains('Discover-CodexProjects.ps1')) 'no Discovery invocation'
    Complete-Test 'Orchestrator never invokes Discovery'

    Assert-True (-not $source.Contains('Build-CodexProjectIndex.ps1')) 'no Index builder invocation'
    Complete-Test 'Orchestrator never invokes Index builder'

    $case = New-TestCase $tempRoot '39-whitespace'
    $fixture = New-FakeDependencies $case
    Assert-ThrowsLike { Invoke-TestDispatch $case $fixture -Task '   ' } 'Task 必须是非空字符串' 'whitespace Task'
    Assert-Equal @(
        Get-ChildItem $case.StateDirectory -Filter '*.json' -Recurse
    ).Count 0 'whitespace creates no state'
    Complete-Test 'whitespace-only Task throws before State creation'

    [Environment]::SetEnvironmentVariable('CODEX_DISPATCH_GITHUB_TOKEN','scrub-cd','Process')
    [Environment]::SetEnvironmentVariable('GH_TOKEN','scrub-gh','Process')
    [Environment]::SetEnvironmentVariable('GITHUB_TOKEN','scrub-github','Process')
    $case = New-TestCase $tempRoot '40-routing-scrub'
    $fixture = New-FakeDependencies $case -FastMode throw
    $fixture.Context.FastError = 'failure scrub-cd scrub-gh scrub-github'
    $result = Invoke-TestDispatch $case $fixture
    Assert-True (-not $result.context.Contains('scrub-cd')) 'routing scrub CODEX'
    Assert-True (-not $result.context.Contains('scrub-gh')) 'routing scrub GH'
    Assert-True (-not $result.context.Contains('scrub-github')) 'routing scrub GITHUB'
    Assert-True ($result.context.Contains('[REDACTED]')) 'routing redaction marker'
    Complete-Test 'routing technical diagnostic scrubs captured credentials'

    $case = New-TestCase $tempRoot '41-worker-scrub'
    $fixture = New-FakeDependencies $case -WorkerMode failed
    $fixture.Context.WorkerDiagnostic = 'failure scrub-cd scrub-gh scrub-github'
    $result = Invoke-TestDispatch $case $fixture
    Assert-True (-not $result.diagnostic.Contains('scrub-cd')) 'Worker scrub CODEX'
    Assert-True (-not $result.diagnostic.Contains('scrub-gh')) 'Worker scrub GH'
    Assert-True (-not $result.diagnostic.Contains('scrub-github')) 'Worker scrub GITHUB'
    Complete-Test 'Worker diagnostic scrubs captured credentials'

    $case = New-TestCase $tempRoot '42-projection-scrub'
    $fixture = New-FakeDependencies $case -PublisherMode throw
    $fixture.Context.PublisherError = ('scrub-cd scrub-gh scrub-github ' + ('x' * 3000))
    $result = Invoke-TestDispatch $case $fixture
    Assert-True (-not $result.projectionDiagnostic.Contains('scrub-cd')) 'projection scrub CODEX'
    Assert-True (-not $result.projectionDiagnostic.Contains('scrub-gh')) 'projection scrub GH'
    Assert-True (-not $result.projectionDiagnostic.Contains('scrub-github')) 'projection scrub GITHUB'
    Assert-True ($result.projectionDiagnostic.Length -le 2048) 'projection diagnostic bounded'
    Assert-Equal $fixture.Context.PublisherCalls 1 'fake publisher only once'
    Assert-Equal $fixture.Context.WorkerCalls 1 'fake Worker only once'
    Assert-Equal $script:passed 42 'all prior fake-only tests passed'
    Complete-Test 'projection diagnostic bounded and scrubbed; no real network or Codex'

    Assert-Equal $script:passed $testCount 'orchestrator total'
    Write-Host "Orchestrator: $script:passed/$testCount PASS"
}
finally {
    Restore-CodexDispatchOrchestratorCredentials -Snapshot $suiteEnvironment
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected test path: $resolvedTemp"
        }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
