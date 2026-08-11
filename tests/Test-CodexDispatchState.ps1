[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$loader = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\scripts\Load-CodexDispatchConfig.ps1')
)
$newState = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\scripts\New-CodexDispatchState.ps1')
)
$getState = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\scripts\Get-CodexDispatchState.ps1')
)
$updateState = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\scripts\Update-CodexDispatchState.ps1')
)
$common = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\scripts\CodexDispatchState.Common.ps1')
)
foreach ($requiredFile in @($loader, $newState, $getState, $updateState, $common)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "找不到 Runtime State 文件：$requiredFile"
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

    if (-not $Condition) {
        throw "断言失败：$Message"
    }
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

function Assert-ThrowsLike {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedText
    )

    $message = $null
    try {
        & $Action | Out-Null
    }
    catch {
        $message = $_.Exception.Message
    }
    Assert-True `
        -Condition (-not [string]::IsNullOrWhiteSpace($message)) `
        -Message "预期异常包含 '$ExpectedText'，但调用成功。"
    Assert-True `
        -Condition $message.StartsWith(
            'Codex Dispatch Runtime State 错误：',
            [System.StringComparison]::Ordinal
        ) `
        -Message "Runtime State 错误前缀不统一：$message"
    Assert-True `
        -Condition $message.Contains($ExpectedText) `
        -Message "异常未包含 '$ExpectedText'。实际：$message"
}

function Write-TestConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory
    )

    $document = [ordered]@{
        version = 1
        workspace = [ordered]@{
            root = $WorkspaceRoot
            scanDepth = 1
            allowReparsePoints = $false
        }
        runtime = [ordered]@{ stateDirectory = $StateDirectory }
        controlPlane = [ordered]@{
            provider = 'github'
            repository = 'example-user/private-control'
            defaultBranch = 'main'
            issueAssignee = 'example-user'
        }
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
            exposeLocalPathsInIssues = $false
            exposeThreadIdsInIssues = $false
            includeOriginalTaskInIssues = $false
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
        [Parameter(Mandatory = $true)]
        [string]$Parent,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [bool]$CreateStateDirectory = $true,

        [Parameter()]
        [AllowEmptyString()]
        [string]$StateDirectoryValue = '.\state'
    )

    $root = Join-Path $Parent $Name
    $workspace = Join-Path $root 'workspace'
    $stateDirectory = Join-Path $root 'state'
    [void](New-Item -ItemType Directory -Path $workspace -Force)
    if ($CreateStateDirectory) {
        [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
    }
    $config = Join-Path $root 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $config `
        -WorkspaceRoot '.\workspace' `
        -StateDirectory $StateDirectoryValue
    return [pscustomobject]@{
        Root = $root
        Workspace = $workspace
        StateDirectory = $stateDirectory
        Config = $config
    }
}

function New-StateFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Parent,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [string]$Task = 'test task'
    )

    $case = New-TestCase -Parent $Parent -Name $Name
    $state = & $newState -Task $Task -ConfigPath $case.Config
    return [pscustomobject]@{ Case = $case; State = $state }
}

function New-WorkerRunningFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Parent,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $fixture = New-StateFixture -Parent $Parent -Name $Name
    $routing = & $updateState `
        -DispatchId $fixture.State.dispatchId `
        -ExpectedRevision 1 `
        -Phase routing `
        -Status running `
        -ConfigPath $fixture.Case.Config
    $worker = & $updateState `
        -DispatchId $routing.dispatchId `
        -ExpectedRevision $routing.revision `
        -Phase worker `
        -Status running `
        -ProjectRepository 'Owner/repository' `
        -ConfigPath $fixture.Case.Config
    return [pscustomobject]@{ Case = $fixture.Case; State = $worker }
}

function Get-TestStatePath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Case,

        [Parameter(Mandatory = $true)]
        [string]$DispatchId
    )

    return Join-Path (Join-Path $Case.StateDirectory 'dispatches') ($DispatchId + '.json')
}

function Write-TestStateDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Document
    )

    [System.IO.File]::WriteAllText(
        $Path,
        (ConvertTo-Json -InputObject $Document -Depth 8) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

$testRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) ('codex-dispatch-state-tests-' + [guid]::NewGuid().ToString('N'))
$passed = 0
$testCount = 49

try {
    [void](New-Item -ItemType Directory -Path $testRoot)

    # A. Config Loader formally returns runtime in the stable top-level order.
    $case = New-TestCase -Parent $testRoot -Name 'config-runtime-section'
    $config = & $loader -Path $case.Config
    Assert-Equal `
        -Actual (($config.PSObject.Properties.Name) -join ',') `
        -Expected 'workspace,runtime,controlPlane,routing,codex,privacy,safety' `
        -Message 'Config Loader top-level order'
    Write-Host "PASS 1/$testCount：runtime config section"
    $passed++

    # B. Relative stateDirectory resolves from config.local.json directory.
    Assert-True `
        -Condition ([string]::Equals(
            $config.runtime.stateDirectory,
            (Get-Item -LiteralPath $case.StateDirectory).FullName,
            [System.StringComparison]::OrdinalIgnoreCase
        )) `
        -Message 'relative stateDirectory normalization'
    Write-Host "PASS 2/$testCount：relative stateDirectory normalization"
    $passed++

    # C. Absolute stateDirectory is normalized.
    $absoluteRoot = Join-Path $testRoot 'absolute'
    $absoluteWorkspace = Join-Path $absoluteRoot 'workspace'
    $absoluteState = Join-Path $testRoot 'absolute-state-private'
    [void](New-Item -ItemType Directory -Path $absoluteWorkspace -Force)
    [void](New-Item -ItemType Directory -Path $absoluteState -Force)
    $absoluteConfig = Join-Path $absoluteRoot 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $absoluteConfig `
        -WorkspaceRoot '.\workspace' `
        -StateDirectory $absoluteState
    $absoluteResult = & $loader -Path $absoluteConfig
    Assert-Equal `
        -Actual $absoluteResult.runtime.stateDirectory `
        -Expected (Get-Item -LiteralPath $absoluteState).FullName `
        -Message 'absolute stateDirectory normalization'
    Write-Host "PASS 3/$testCount：absolute stateDirectory normalization"
    $passed++

    # D. Missing stateDirectory is rejected and never created by the Loader.
    $case = New-TestCase `
        -Parent $testRoot -Name 'missing-state' -CreateStateDirectory $false
    Assert-ThrowsLike `
        -Action { & $newState -Task 'task' -ConfigPath $case.Config } `
        -ExpectedText 'runtime.stateDirectory 不存在或不是目录'
    Assert-True `
        -Condition (-not (Test-Path -LiteralPath $case.StateDirectory)) `
        -Message 'Loader side-effect-free missing directory'
    Write-Host "PASS 4/$testCount：missing stateDirectory rejected"
    $passed++

    # E. A reparse point anywhere at the state directory endpoint is rejected.
    $reparseRoot = Join-Path $testRoot 'state-reparse'
    $reparseWorkspace = Join-Path $reparseRoot 'workspace'
    $reparseTarget = Join-Path $reparseRoot 'target'
    $reparseState = Join-Path $reparseRoot 'state'
    [void](New-Item -ItemType Directory -Path $reparseWorkspace -Force)
    [void](New-Item -ItemType Directory -Path $reparseTarget)
    [void](New-Item -ItemType Junction -Path $reparseState -Target $reparseTarget)
    $reparseConfig = Join-Path $reparseRoot 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $reparseConfig `
        -WorkspaceRoot '.\workspace' `
        -StateDirectory '.\state'
    Assert-ThrowsLike `
        -Action { & $newState -Task 'task' -ConfigPath $reparseConfig } `
        -ExpectedText '路径链包含 reparse point'
    Write-Host "PASS 5/$testCount：stateDirectory reparse rejected"
    $passed++

    # F. State directory inside workspace is rejected.
    $insideRoot = Join-Path $testRoot 'state-inside-workspace'
    $insideWorkspace = Join-Path $insideRoot 'workspace'
    $insideState = Join-Path $insideWorkspace 'state'
    [void](New-Item -ItemType Directory -Path $insideState -Force)
    $insideConfig = Join-Path $insideRoot 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $insideConfig `
        -WorkspaceRoot '.\workspace' `
        -StateDirectory '.\workspace\state'
    Assert-ThrowsLike `
        -Action { & $newState -Task 'task' -ConfigPath $insideConfig } `
        -ExpectedText 'runtime.stateDirectory 不能位于 workspace.root 内部'
    Write-Host "PASS 6/$testCount：stateDirectory inside workspace rejected"
    $passed++

    # G. Workspace inside state directory is rejected.
    $inverseRoot = Join-Path $testRoot 'workspace-inside-state'
    $inverseState = Join-Path $inverseRoot 'state'
    $inverseWorkspace = Join-Path $inverseState 'workspace'
    [void](New-Item -ItemType Directory -Path $inverseWorkspace -Force)
    $inverseConfig = Join-Path $inverseRoot 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $inverseConfig `
        -WorkspaceRoot '.\state\workspace' `
        -StateDirectory '.\state'
    Assert-ThrowsLike `
        -Action { & $newState -Task 'task' -ConfigPath $inverseConfig } `
        -ExpectedText 'workspace.root 不能位于 runtime.stateDirectory 内部'
    Write-Host "PASS 7/$testCount：workspace inside stateDirectory rejected"
    $passed++

    # H. Adjacent textual prefixes are not mistaken for descendants.
    $prefixRoot = Join-Path $testRoot 'prefix-boundary'
    $prefixWorkspace = Join-Path $prefixRoot 'Projects'
    $prefixState = Join-Path $prefixRoot 'Projects2'
    [void](New-Item -ItemType Directory -Path $prefixWorkspace -Force)
    [void](New-Item -ItemType Directory -Path $prefixState -Force)
    $prefixConfig = Join-Path $prefixRoot 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $prefixConfig `
        -WorkspaceRoot '.\Projects' `
        -StateDirectory '.\Projects2'
    $prefixResult = & $loader -Path $prefixConfig
    Assert-Equal `
        -Actual $prefixResult.runtime.stateDirectory `
        -Expected (Get-Item -LiteralPath $prefixState).FullName `
        -Message 'path-boundary comparison'
    Write-Host "PASS 8/$testCount：adjacent prefix accepted"
    $passed++

    # I-P. Create/read persistence contract.
    $roundTripTask = "修复 `"解析器`"`r`n保持原始任务。"
    $fixture = New-StateFixture `
        -Parent $testRoot -Name 'create-read' -Task $roundTripTask
    $state = $fixture.State
    $dispatches = Join-Path $fixture.Case.StateDirectory 'dispatches'
    $dispatchesItem = Get-Item -Force -LiteralPath $dispatches
    Assert-True `
        -Condition ($dispatchesItem.PSIsContainer -and (
            $dispatchesItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint
        ) -eq 0) `
        -Message 'safe dispatches directory creation'
    Write-Host "PASS 9/$testCount：dispatches directory created safely"
    $passed++

    Assert-True `
        -Condition ($state.dispatchId -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') `
        -Message 'canonical GUID v4 dispatchId'
    Write-Host "PASS 10/$testCount：canonical UUID v4 dispatchId"
    $passed++

    Assert-Equal $state.revision ([int64]1) 'initial revision'
    Write-Host "PASS 11/$testCount：initial revision=1"
    $passed++

    $created = ConvertTo-CodexDispatchUtcTimestamp $state.createdAtUtc 'createdAtUtc'
    $updated = ConvertTo-CodexDispatchUtcTimestamp $state.updatedAtUtc 'updatedAtUtc'
    Assert-Equal $state.createdAtUtc $state.updatedAtUtc 'create timestamps equality'
    Assert-Equal $created.Kind ([System.DateTimeKind]::Utc) 'create timestamp UTC'
    Assert-Equal $updated.Kind ([System.DateTimeKind]::Utc) 'update timestamp UTC'
    Write-Host "PASS 12/$testCount：UTC equal create timestamps"
    $passed++

    Assert-Equal $state.task $roundTripTask 'Task exact round-trip'
    Write-Host "PASS 13/$testCount：Chinese/quotes/multiline Task exact"
    $passed++

    $statePath = Get-TestStatePath -Case $fixture.Case -DispatchId $state.dispatchId
    $bytes = [System.IO.File]::ReadAllBytes($statePath)
    Assert-True `
        -Condition (-not (
            $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and
            $bytes[1] -eq 187 -and $bytes[2] -eq 191
        )) `
        -Message 'state JSON UTF-8 no BOM'
    Write-Host "PASS 14/$testCount：state JSON UTF-8 no BOM"
    $passed++

    $jsonText = [System.IO.File]::ReadAllText(
        $statePath,
        [System.Text.UTF8Encoding]::new($false, $true)
    )
    $jsonPropertyOrder = [regex]::Matches(
        $jsonText,
        '(?m)^\s{4}"(?<name>[A-Za-z]+)"\s*:'
    ) | ForEach-Object { $_.Groups['name'].Value }
    Assert-Equal `
        -Actual ($jsonPropertyOrder -join ',') `
        -Expected ($script:CodexDispatchStatePropertyOrder -join ',') `
        -Message 'persisted property order'
    Write-Host "PASS 15/$testCount：stable property order"
    $passed++

    $readState = & $getState -DispatchId $state.dispatchId -ConfigPath $fixture.Case.Config
    Assert-Equal `
        -Actual (ConvertTo-Json $readState -Depth 8 -Compress) `
        -Expected (ConvertTo-Json $state -Depth 8 -Compress) `
        -Message 'Get exact canonical state'
    Write-Host "PASS 16/$testCount：Get exact state"
    $passed++

    # Q. Invalid and non-D dispatch identifiers never become paths.
    foreach ($invalidId in @(
        '..\foo', 'random text',
        ('{' + [guid]::NewGuid().ToString('D') + '}'),
        [guid]::NewGuid().ToString('N')
    )) {
        Assert-ThrowsLike `
            -Action { & $getState -DispatchId $invalidId -ConfigPath $fixture.Case.Config } `
            -ExpectedText 'dispatchId 无效'
    }
    Write-Host "PASS 17/$testCount：invalid dispatchId rejected"
    $passed++

    # R. A canonical but absent ID has no fuzzy fallback.
    $missingId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
    Assert-ThrowsLike `
        -Action { & $getState -DispatchId $missingId -ConfigPath $fixture.Case.Config } `
        -ExpectedText '找不到 dispatch state'
    Write-Host "PASS 18/$testCount：missing state rejected"
    $passed++

    # S. State reparse targets are rejected.
    $case = New-TestCase -Parent $testRoot -Name 'state-file-reparse'
    $dispatches = Join-Path $case.StateDirectory 'dispatches'
    [void](New-Item -ItemType Directory -Path $dispatches)
    $reparseId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
    $reparseTarget = Join-Path $case.Root 'state-target-directory'
    [void](New-Item -ItemType Directory -Path $reparseTarget)
    [void](New-Item `
        -ItemType Junction `
        -Path (Join-Path $dispatches ($reparseId + '.json')) `
        -Target $reparseTarget)
    Assert-ThrowsLike `
        -Action { & $getState -DispatchId $reparseId -ConfigPath $case.Config } `
        -ExpectedText 'state 文件不能是 reparse point'
    Write-Host "PASS 19/$testCount：state file reparse rejected"
    $passed++

    # T. Unknown fields are rejected.
    $fixture = New-StateFixture -Parent $testRoot -Name 'unknown-field'
    $path = Get-TestStatePath $fixture.Case $fixture.State.dispatchId
    $document = ConvertFrom-Json ([System.IO.File]::ReadAllText($path))
    Add-Member -InputObject $document -NotePropertyName localPath -NotePropertyValue 'forbidden'
    Write-TestStateDocument -Path $path -Document $document
    Assert-ThrowsLike `
        -Action { & $getState -DispatchId $fixture.State.dispatchId -ConfigPath $fixture.Case.Config } `
        -ExpectedText 'state 文件包含未知字段：localPath'
    Write-Host "PASS 20/$testCount：unknown field rejected"
    $passed++

    # U. Malformed JSON is rejected.
    $fixture = New-StateFixture -Parent $testRoot -Name 'malformed-json'
    $path = Get-TestStatePath $fixture.Case $fixture.State.dispatchId
    [System.IO.File]::WriteAllText($path, '{bad', [System.Text.UTF8Encoding]::new($false))
    Assert-ThrowsLike `
        -Action { & $getState -DispatchId $fixture.State.dispatchId -ConfigPath $fixture.Case.Config } `
        -ExpectedText 'state 文件不是有效 JSON'
    Write-Host "PASS 21/$testCount：malformed JSON rejected"
    $passed++

    # V. Invalid UTF-8 is rejected before JSON parsing.
    $fixture = New-StateFixture -Parent $testRoot -Name 'invalid-utf8'
    $path = Get-TestStatePath $fixture.Case $fixture.State.dispatchId
    [System.IO.File]::WriteAllBytes($path, [byte[]]@(123, 34, 255, 34, 58, 49, 125))
    Assert-ThrowsLike `
        -Action { & $getState -DispatchId $fixture.State.dispatchId -ConfigPath $fixture.Case.Config } `
        -ExpectedText 'state 文件不是有效 strict UTF-8'
    Write-Host "PASS 22/$testCount：invalid UTF-8 rejected"
    $passed++

    # W. JSON identity must equal its canonical filename ID.
    $fixture = New-StateFixture -Parent $testRoot -Name 'identity-mismatch'
    $path = Get-TestStatePath $fixture.Case $fixture.State.dispatchId
    $document = ConvertFrom-Json ([System.IO.File]::ReadAllText($path))
    $document.dispatchId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
    Write-TestStateDocument -Path $path -Document $document
    Assert-ThrowsLike `
        -Action { & $getState -DispatchId $fixture.State.dispatchId -ConfigPath $fixture.Case.Config } `
        -ExpectedText 'dispatchId 与 filename 不匹配'
    Write-Host "PASS 23/$testCount：dispatchId/filename mismatch rejected"
    $passed++

    # X. Illegal schema types and values are rejected.
    foreach ($mutation in @('version', 'revision', 'options', 'timestamp')) {
        $fixture = New-StateFixture -Parent $testRoot -Name ('schema-' + $mutation)
        $path = Get-TestStatePath $fixture.Case $fixture.State.dispatchId
        $document = ConvertFrom-Json ([System.IO.File]::ReadAllText($path))
        switch ($mutation) {
            'version' { $document.version = $true }
            'revision' { $document.revision = '1' }
            'options' { $document.options = 'not-an-array' }
            'timestamp' { $document.updatedAtUtc = '2026-01-01' }
        }
        Write-TestStateDocument -Path $path -Document $document
        Assert-ThrowsLike `
            -Action { & $getState -DispatchId $fixture.State.dispatchId -ConfigPath $fixture.Case.Config } `
            -ExpectedText $(if ($mutation -eq 'timestamp') { 'updatedAtUtc' } else { $mutation })
    }
    Write-Host "PASS 24/$testCount：illegal schema fields/types rejected"
    $passed++

    # Y-AB. Complete valid routing path into worker/running.
    $fixture = New-StateFixture -Parent $testRoot -Name 'routing-path'
    $routingRunning = & $updateState `
        -DispatchId $fixture.State.dispatchId -ExpectedRevision 1 `
        -Phase routing -Status running -ConfigPath $fixture.Case.Config
    Assert-Equal ($routingRunning.phase + '/' + $routingRunning.status) 'routing/running' 'pending to running'
    Write-Host "PASS 25/$testCount：routing pending -> running"
    $passed++

    $routingNeedsInput = & $updateState `
        -DispatchId $routingRunning.dispatchId -ExpectedRevision 2 `
        -Phase routing -Status needs_input `
        -Report '需要选择。' -Question '选择哪个项目？' -Context '路由不唯一。' `
        -Options @('项目 A', '项目 B') -ConfigPath $fixture.Case.Config
    Assert-Equal ($routingNeedsInput.phase + '/' + $routingNeedsInput.status) 'routing/needs_input' 'running to needs_input'
    Write-Host "PASS 26/$testCount：routing running -> needs_input"
    $passed++

    $routingResumed = & $updateState `
        -DispatchId $routingNeedsInput.dispatchId -ExpectedRevision 3 `
        -Phase routing -Status running `
        -Report '' -Question '' -Context '' -Options @() `
        -ConfigPath $fixture.Case.Config
    Assert-Equal ($routingResumed.phase + '/' + $routingResumed.status) 'routing/running' 'needs_input to running'
    Write-Host "PASS 27/$testCount：routing needs_input -> running"
    $passed++

    $workerRunning = & $updateState `
        -DispatchId $routingResumed.dispatchId -ExpectedRevision 4 `
        -Phase worker -Status running `
        -ProjectRepository 'Owner/repository' -ConfigPath $fixture.Case.Config
    Assert-Equal ($workerRunning.phase + '/' + $workerRunning.status) 'worker/running' 'routing to worker'
    Assert-Equal $workerRunning.projectRepository 'Owner/repository' 'repository case preserved'
    Write-Host "PASS 28/$testCount：routing running -> worker running"
    $passed++

    # AC. worker/running -> completed.
    $fixtureCompleted = New-WorkerRunningFixture -Parent $testRoot -Name 'completed'
    $threadId = [guid]::NewGuid().ToString('D').ToUpperInvariant()
    $completed = & $updateState `
        -DispatchId $fixtureCompleted.State.dispatchId `
        -ExpectedRevision $fixtureCompleted.State.revision `
        -Phase worker -Status completed `
        -ThreadId $threadId -Report '安全完成。' `
        -ConfigPath $fixtureCompleted.Case.Config
    Assert-Equal ($completed.phase + '/' + $completed.status) 'worker/completed' 'worker completed'
    Assert-Equal $completed.threadId $threadId.ToLowerInvariant() 'thread canonicalization'
    Write-Host "PASS 29/$testCount：worker running -> completed"
    $passed++

    # AD. worker/running -> needs_input.
    $fixtureNeedsInput = New-WorkerRunningFixture -Parent $testRoot -Name 'worker-needs-input'
    $workerNeedsInput = & $updateState `
        -DispatchId $fixtureNeedsInput.State.dispatchId `
        -ExpectedRevision $fixtureNeedsInput.State.revision `
        -Phase worker -Status needs_input `
        -ThreadId ([guid]::NewGuid().ToString('D')) `
        -Report '已完成检查。' -Question '采用哪个方案？' -Context '需要产品决定。' `
        -Options @('方案 A', '方案 B') `
        -ConfigPath $fixtureNeedsInput.Case.Config
    Assert-Equal ($workerNeedsInput.phase + '/' + $workerNeedsInput.status) 'worker/needs_input' 'worker needs input'
    Write-Host "PASS 30/$testCount：worker running -> needs_input"
    $passed++

    # AE. worker/running -> failed.
    $fixtureFailed = New-WorkerRunningFixture -Parent $testRoot -Name 'failed'
    $failed = & $updateState `
        -DispatchId $fixtureFailed.State.dispatchId `
        -ExpectedRevision $fixtureFailed.State.revision `
        -Phase worker -Status failed `
        -Diagnostic 'local process failed safely' `
        -ConfigPath $fixtureFailed.Case.Config
    Assert-Equal ($failed.phase + '/' + $failed.status) 'worker/failed' 'worker failed'
    Write-Host "PASS 31/$testCount：worker running -> failed"
    $passed++

    # AF. worker/needs_input -> running.
    $workerResumed = & $updateState `
        -DispatchId $workerNeedsInput.dispatchId `
        -ExpectedRevision $workerNeedsInput.revision `
        -Phase worker -Status running `
        -Report '' -Question '' -Context '' -Options @() `
        -ConfigPath $fixtureNeedsInput.Case.Config
    Assert-Equal ($workerResumed.phase + '/' + $workerResumed.status) 'worker/running' 'worker resume'
    Write-Host "PASS 32/$testCount：worker needs_input -> running"
    $passed++

    # AG. completed is immutable.
    Assert-ThrowsLike `
        -Action {
            & $updateState `
                -DispatchId $completed.dispatchId -ExpectedRevision $completed.revision `
                -Phase worker -Status running -Report '' `
                -ConfigPath $fixtureCompleted.Case.Config
        } `
        -ExpectedText '非法状态转换'
    Write-Host "PASS 33/$testCount：completed terminal immutable"
    $passed++

    # AH. failed is immutable.
    Assert-ThrowsLike `
        -Action {
            & $updateState `
                -DispatchId $failed.dispatchId -ExpectedRevision $failed.revision `
                -Phase worker -Status running -Diagnostic '' `
                -ConfigPath $fixtureFailed.Case.Config
        } `
        -ExpectedText '非法状态转换'
    Write-Host "PASS 34/$testCount：failed terminal immutable"
    $passed++

    # AI. Other state jumps are rejected without changing the file.
    $fixture = New-StateFixture -Parent $testRoot -Name 'illegal-transition'
    $path = Get-TestStatePath $fixture.Case $fixture.State.dispatchId
    $beforeBytes = [System.IO.File]::ReadAllBytes($path)
    Assert-ThrowsLike `
        -Action {
            & $updateState `
                -DispatchId $fixture.State.dispatchId -ExpectedRevision 1 `
                -Phase worker -Status completed `
                -ProjectRepository 'owner/repo' `
                -ThreadId ([guid]::NewGuid().ToString('D')) -Report 'bad jump' `
                -ConfigPath $fixture.Case.Config
        } `
        -ExpectedText '非法状态转换'
    $afterBytes = [System.IO.File]::ReadAllBytes($path)
    Assert-True -Condition ([System.Linq.Enumerable]::SequenceEqual($beforeBytes, $afterBytes)) -Message 'illegal transition unchanged file'
    Write-Host "PASS 35/$testCount：illegal transition rejected unchanged"
    $passed++

    # AJ. needs_input options must be distinct and at least two.
    $fixture = New-StateFixture -Parent $testRoot -Name 'invalid-options'
    Assert-ThrowsLike `
        -Action {
            & $updateState `
                -DispatchId $fixture.State.dispatchId -ExpectedRevision 1 `
                -Phase routing -Status needs_input `
                -Report 'report' -Question 'question' -Context 'context' `
                -Options @('same', 'same') -ConfigPath $fixture.Case.Config
        } `
        -ExpectedText 'options 必须 distinct'
    Write-Host "PASS 36/$testCount：needs_input options invariant"
    $passed++

    # AK. completed requires identity/thread/report and empty interaction fields.
    $fixture = New-WorkerRunningFixture -Parent $testRoot -Name 'invalid-completed'
    Assert-ThrowsLike `
        -Action {
            & $updateState `
                -DispatchId $fixture.State.dispatchId -ExpectedRevision $fixture.State.revision `
                -Phase worker -Status completed -Report '' `
                -ConfigPath $fixture.Case.Config
        } `
        -ExpectedText 'worker/completed 字段组合无效'
    Write-Host "PASS 37/$testCount：completed semantic invariant"
    $passed++

    # AL. failed requires diagnostic.
    $fixture = New-WorkerRunningFixture -Parent $testRoot -Name 'invalid-failed'
    Assert-ThrowsLike `
        -Action {
            & $updateState `
                -DispatchId $fixture.State.dispatchId -ExpectedRevision $fixture.State.revision `
                -Phase worker -Status failed -Diagnostic '' `
                -ConfigPath $fixture.Case.Config
        } `
        -ExpectedText 'worker/failed 字段组合无效'
    Write-Host "PASS 38/$testCount：failed diagnostic invariant"
    $passed++

    # AM. Worker states require repository identity.
    $fixture = New-StateFixture -Parent $testRoot -Name 'missing-worker-identity'
    $routing = & $updateState `
        -DispatchId $fixture.State.dispatchId -ExpectedRevision 1 `
        -Phase routing -Status running -ConfigPath $fixture.Case.Config
    Assert-ThrowsLike `
        -Action {
            & $updateState `
                -DispatchId $routing.dispatchId -ExpectedRevision $routing.revision `
                -Phase worker -Status running -ConfigPath $fixture.Case.Config
        } `
        -ExpectedText 'worker/running 字段组合无效'
    Write-Host "PASS 39/$testCount：worker identity required"
    $passed++

    # AN. Revision increments by exactly one.
    Assert-Equal $routing.revision ([int64]2) 'revision exact increment'
    Write-Host "PASS 40/$testCount：revision increments exactly one"
    $passed++

    # AO. Wrong ExpectedRevision is rejected and target bytes remain unchanged.
    $path = Get-TestStatePath $fixture.Case $routing.dispatchId
    $beforeBytes = [System.IO.File]::ReadAllBytes($path)
    Assert-ThrowsLike `
        -Action {
            & $updateState `
                -DispatchId $routing.dispatchId -ExpectedRevision 1 `
                -Phase worker -Status running -ProjectRepository 'owner/repo' `
                -ConfigPath $fixture.Case.Config
        } `
        -ExpectedText 'revision 冲突'
    $afterBytes = [System.IO.File]::ReadAllBytes($path)
    Assert-True -Condition ([System.Linq.Enumerable]::SequenceEqual($beforeBytes, $afterBytes)) -Message 'revision conflict unchanged file'
    Write-Host "PASS 41/$testCount：stale revision rejected unchanged"
    $passed++

    # AP. Two concurrent revision-1 updaters cannot both succeed.
    $fixture = New-StateFixture -Parent $testRoot -Name 'concurrent-stale'
    $jobs = @(
        1..2 | ForEach-Object {
            Start-Job -ScriptBlock {
                param($UpdateScript, $DispatchId, $ConfigPath)
                try {
                    & $UpdateScript `
                        -DispatchId $DispatchId -ExpectedRevision 1 `
                        -Phase routing -Status running -ConfigPath $ConfigPath | Out-Null
                    'SUCCESS'
                }
                catch {
                    'FAILURE:' + $_.Exception.Message
                }
            } -ArgumentList $updateState, $fixture.State.dispatchId, $fixture.Case.Config
        }
    )
    try {
        [void]($jobs | Wait-Job -Timeout 30)
        $jobResults = @($jobs | Receive-Job)
    }
    finally {
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    Assert-Equal @($jobResults | Where-Object { $_ -eq 'SUCCESS' }).Count 1 'exactly one concurrent updater succeeds'
    $concurrentState = & $getState -DispatchId $fixture.State.dispatchId -ConfigPath $fixture.Case.Config
    Assert-Equal $concurrentState.revision ([int64]2) 'concurrent resulting revision'
    Write-Host "PASS 42/$testCount：concurrent stale writers serialized"
    $passed++

    # AQ. Concurrent reads during repeated atomic replaces always see valid state.
    $fixture = New-WorkerRunningFixture -Parent $testRoot -Name 'atomic-visibility'
    $reader = Start-Job -ScriptBlock {
        param($GetScript, $DispatchId, $ConfigPath)
        try {
            for ($index = 0; $index -lt 200; $index++) {
                & $GetScript -DispatchId $DispatchId -ConfigPath $ConfigPath | Out-Null
                Start-Sleep -Milliseconds 2
            }
            'SUCCESS'
        }
        catch {
            'FAILURE:' + $_.Exception.Message
        }
    } -ArgumentList $getState, $fixture.State.dispatchId, $fixture.Case.Config
    $current = $fixture.State
    for ($index = 0; $index -lt 10; $index++) {
        $current = & $updateState `
            -DispatchId $current.dispatchId -ExpectedRevision $current.revision `
            -Phase worker -Status needs_input `
            -ThreadId ([guid]::NewGuid().ToString('D')) `
            -Report 'progress' -Question 'continue?' -Context 'atomic test' `
            -Options @('yes', 'no') -ConfigPath $fixture.Case.Config
        $current = & $updateState `
            -DispatchId $current.dispatchId -ExpectedRevision $current.revision `
            -Phase worker -Status running `
            -Report '' -Question '' -Context '' -Options @() `
            -ConfigPath $fixture.Case.Config
    }
    try {
        [void]($reader | Wait-Job -Timeout 30)
        $readerResult = @($reader | Receive-Job)
    }
    finally {
        $reader | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    Assert-True -Condition ($readerResult -contains 'SUCCESS') -Message "atomic reader failed: $($readerResult -join '; ')"
    Write-Host "PASS 43/$testCount：atomic target never exposed malformed JSON"
    $passed++

    # AR. A bounded 200-update stress run exposes only complete revision-correlated states.
    $fixture = New-WorkerRunningFixture -Parent $testRoot -Name 'atomic-stress'
    $stressStopPath = Join-Path $fixture.Case.Root 'stop.signal'
    $stressStagePath = Join-Path $fixture.Case.Root 'writer-stage.txt'
    $stressReadyPrefix = Join-Path $fixture.Case.Root 'reader-ready'
    $stressStatePath = Get-TestStatePath $fixture.Case $fixture.State.dispatchId
    $stressDispatchesPath = Split-Path -Parent $stressStatePath
    $stressThreadId = '11111111-1111-4111-8111-111111111111'
    $stressStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $stressReaders = @(
        1..3 | ForEach-Object {
            Start-Job -ScriptBlock {
                param(
                    $GetScript,
                    $DispatchId,
                    $ConfigPath,
                    $StopPath,
                    $StagePath,
                    $ReadyPath,
                    $StatePath,
                    $DispatchesPath,
                    $ExpectedThreadId
                )
                $ErrorActionPreference = 'Stop'
                $readCount = 0
                try {
                    [System.IO.File]::WriteAllText($ReadyPath, 'ready')
                    $deadline = [datetime]::UtcNow.AddSeconds(150)
                    while (-not [System.IO.File]::Exists($StopPath)) {
                        if ([datetime]::UtcNow -ge $deadline) {
                            throw [System.TimeoutException]::new('atomic stress reader exceeded 150 seconds')
                        }
                        $state = & $GetScript -DispatchId $DispatchId -ConfigPath $ConfigPath
                        $readCount++
                        if ($state.revision -lt 3 -or $state.revision -gt 203) {
                            throw [System.IO.InvalidDataException]::new(
                                "unexpected revision $($state.revision)"
                            )
                        }
                        if ($state.phase -cne 'worker' -or $state.status -cnotin @('running', 'needs_input')) {
                            throw [System.IO.InvalidDataException]::new(
                                "unexpected phase/status $($state.phase)/$($state.status) at revision $($state.revision)"
                            )
                        }
                        if ($state.revision -eq 3) {
                            if (
                                $state.status -cne 'running' -or $null -ne $state.threadId -or
                                $state.report.Length -ne 0 -or $state.question.Length -ne 0 -or
                                $state.context.Length -ne 0 -or $state.options.Count -ne 0
                            ) {
                                throw [System.IO.InvalidDataException]::new('mixed fields at initial revision 3')
                            }
                            continue
                        }
                        if ($state.threadId -cne $ExpectedThreadId) {
                            throw [System.IO.InvalidDataException]::new(
                                "mixed threadId at revision $($state.revision)"
                            )
                        }
                        if (($state.revision % 2) -eq 0) {
                            $marker = "revision-$($state.revision)"
                            if (
                                $state.status -cne 'needs_input' -or
                                $state.report -cne "report-$marker" -or
                                $state.question -cne "question-$marker" -or
                                $state.context -cne "context-$marker" -or
                                ($state.options -join ',') -cne "yes-$marker,no-$marker"
                            ) {
                                throw [System.IO.InvalidDataException]::new(
                                    "mixed fields at needs_input revision $($state.revision)"
                                )
                            }
                        }
                        elseif (
                            $state.status -cne 'running' -or
                            $state.report.Length -ne 0 -or $state.question.Length -ne 0 -or
                            $state.context.Length -ne 0 -or $state.options.Count -ne 0
                        ) {
                            throw [System.IO.InvalidDataException]::new(
                                "mixed fields at running revision $($state.revision)"
                            )
                        }
                    }
                    [pscustomobject]@{
                        Kind = 'SUCCESS'
                        ReadCount = $readCount
                    }
                }
                catch {
                    $exception = $_.Exception
                    $entries = @()
                    if ([System.IO.Directory]::Exists($DispatchesPath)) {
                        $entries = @(
                            [System.IO.Directory]::EnumerateFiles($DispatchesPath) |
                                ForEach-Object { [System.IO.Path]::GetFileName($_) }
                        )
                    }
                    $writerStage = if ([System.IO.File]::Exists($StagePath)) {
                        [System.IO.File]::ReadAllText($StagePath)
                    }
                    else {
                        '<not-written>'
                    }
                    [pscustomobject]@{
                        Kind = 'FAILURE'
                        ReadCount = $readCount
                        ExceptionType = $exception.GetType().FullName
                        Message = $exception.Message
                        HResult = ('0x{0:X8}' -f ($exception.HResult -band 0xffffffffL))
                        ScriptStackTrace = $_.ScriptStackTrace
                        ReaderPathRole = 'target'
                        TargetExists = [System.IO.File]::Exists($StatePath)
                        WriterStage = $writerStage
                        DirectoryEntries = $entries -join ','
                    }
                }
            } -ArgumentList @(
                $getState,
                $fixture.State.dispatchId,
                $fixture.Case.Config,
                $stressStopPath,
                $stressStagePath,
                ($stressReadyPrefix + '-' + $_ + '.signal'),
                $stressStatePath,
                $stressDispatchesPath,
                $stressThreadId
            )
        }
    )
    $stressWriter = $null
    try {
        $readyDeadline = [datetime]::UtcNow.AddSeconds(15)
        do {
            $readyCount = @(
                1..3 | Where-Object {
                    [System.IO.File]::Exists($stressReadyPrefix + '-' + $_ + '.signal')
                }
            ).Count
            if ($readyCount -eq 3) {
                break
            }
            Start-Sleep -Milliseconds 25
        } while ([datetime]::UtcNow -lt $readyDeadline)
        Assert-Equal $readyCount 3 'all atomic stress readers became ready'

        $stressWriter = Start-Job -ScriptBlock {
            param(
                $UpdateScript,
                $InitialState,
                $ConfigPath,
                $StopPath,
                $StagePath,
                $ThreadId
            )
            $ErrorActionPreference = 'Stop'
            $current = $InitialState
            try {
                for ($index = 1; $index -le 200; $index++) {
                    $nextRevision = [int64]$current.revision + 1
                    [System.IO.File]::WriteAllText($StagePath, "$nextRevision`:before-update-api")
                    if (($nextRevision % 2) -eq 0) {
                        $marker = "revision-$nextRevision"
                        $current = & $UpdateScript `
                            -DispatchId $current.dispatchId `
                            -ExpectedRevision $current.revision `
                            -Phase worker -Status needs_input `
                            -ThreadId $ThreadId `
                            -Report "report-$marker" `
                            -Question "question-$marker" `
                            -Context "context-$marker" `
                            -Options @("yes-$marker", "no-$marker") `
                            -ConfigPath $ConfigPath
                    }
                    else {
                        $current = & $UpdateScript `
                            -DispatchId $current.dispatchId `
                            -ExpectedRevision $current.revision `
                            -Phase worker -Status running `
                            -ThreadId $ThreadId `
                            -Report '' -Question '' -Context '' -Options @() `
                            -ConfigPath $ConfigPath
                    }
                    [System.IO.File]::WriteAllText(
                        $StagePath,
                        "$($current.revision)`:after-update-api"
                    )
                }
                [pscustomobject]@{
                    Kind = 'SUCCESS'
                    Revision = [int64]$current.revision
                }
            }
            catch {
                $exception = $_.Exception
                [pscustomobject]@{
                    Kind = 'FAILURE'
                    Revision = [int64]$current.revision
                    ExceptionType = $exception.GetType().FullName
                    Message = $exception.Message
                    HResult = ('0x{0:X8}' -f ($exception.HResult -band 0xffffffffL))
                    ScriptStackTrace = $_.ScriptStackTrace
                }
            }
            finally {
                [System.IO.File]::WriteAllText($StopPath, 'stop')
            }
        } -ArgumentList @(
            $updateState,
            $fixture.State,
            $fixture.Case.Config,
            $stressStopPath,
            $stressStagePath,
            $stressThreadId
        )
        Assert-True `
            -Condition ($null -ne (Wait-Job -Job $stressWriter -Timeout 120)) `
            -Message 'atomic stress writer exceeded 120 seconds'
        $stressWriterResult = @($stressWriter | Receive-Job)
        Assert-Equal $stressWriterResult.Count 1 'atomic stress writer result count'
        Assert-Equal $stressWriterResult[0].Kind 'SUCCESS' "atomic stress writer failed: $($stressWriterResult | ConvertTo-Json -Compress)"
        Assert-Equal $stressWriterResult[0].Revision ([int64]203) 'atomic stress final writer revision'

        [void]($stressReaders | Wait-Job -Timeout 30)
        $stressReaderResults = @($stressReaders | Receive-Job)
    }
    finally {
        if (-not [System.IO.File]::Exists($stressStopPath)) {
            [System.IO.File]::WriteAllText($stressStopPath, 'stop')
        }
        if ($null -ne $stressWriter) {
            $stressWriter | Remove-Job -Force -ErrorAction SilentlyContinue
        }
        $stressReaders | Remove-Job -Force -ErrorAction SilentlyContinue
        $stressStopwatch.Stop()
    }
    Assert-Equal $stressReaderResults.Count 3 'atomic stress reader result count'
    $stressFailures = @($stressReaderResults | Where-Object { $_.Kind -ne 'SUCCESS' })
    Assert-Equal `
        $stressFailures.Count `
        0 `
        "atomic stress reader failures: $($stressFailures | ConvertTo-Json -Depth 5 -Compress)"
    $stressReadCount = [int64](
        ($stressReaderResults | Measure-Object -Property ReadCount -Sum).Sum
    )
    Assert-True -Condition ($stressReadCount -ge 200) -Message "atomic stress read count below 200: $stressReadCount"
    Assert-True -Condition ($stressStopwatch.Elapsed.TotalSeconds -lt 150) -Message 'atomic stress suite upper bound exceeded'
    $stressFinal = & $getState `
        -DispatchId $fixture.State.dispatchId `
        -ConfigPath $fixture.Case.Config
    Assert-Equal $stressFinal.revision ([int64]203) 'atomic stress final target revision'
    Assert-Equal $stressFinal.status 'running' 'atomic stress final target status'
    Assert-True -Condition ([System.IO.File]::Exists($stressStatePath)) -Message 'atomic stress final target exists'
    $stressArtifacts = @(
        Get-ChildItem -LiteralPath $stressDispatchesPath -Force -File |
            Where-Object { $_.Name -like '*.tmp' -or $_.Name -like '*.bak' -or $_.Name -like '*.lock' }
    )
    Assert-Equal $stressArtifacts.Count 0 'atomic stress temporary/backup/lock cleanup'
    Write-Host "PASS 44/$testCount：200-update atomic reader stress ($stressReadCount reads)"
    $passed++

    # AS. Internal fixed-ID create helper refuses collision; public API has no ID parameter.
    $case = New-TestCase -Parent $testRoot -Name 'create-collision'
    $fixedNow = [datetime]::UtcNow.ToString('o')
    $fixedState = [pscustomobject][ordered]@{
        version = 1
        dispatchId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
        revision = [int64]1
        createdAtUtc = $fixedNow
        updatedAtUtc = $fixedNow
        phase = 'routing'
        status = 'pending'
        task = 'fixed collision test'
        projectRepository = $null
        threadId = $null
        report = ''
        question = ''
        context = ''
        options = [string[]]@()
        diagnostic = ''
    }
    [void](Write-CodexDispatchStateCreate -StateDirectory $case.StateDirectory -State $fixedState)
    Assert-ThrowsLike `
        -Action { Write-CodexDispatchStateCreate -StateDirectory $case.StateDirectory -State $fixedState } `
        -ExpectedText 'dispatch state 已存在'
    Write-Host "PASS 45/$testCount：create collision refused"
    $passed++

    # AT. Success and failure leave no temporary or coordination files.
    $transientArtifacts = @(
        Get-ChildItem -LiteralPath $testRoot -Recurse -Force -File |
            Where-Object { $_.Name -like '*.tmp' -or $_.Name -like '*.lock' }
    )
    Assert-Equal $transientArtifacts.Count 0 'temporary/lock cleanup'
    Write-Host "PASS 46/$testCount：temporary artifacts cleaned"
    $passed++

    # AU. Persisted state has no localPath capability field.
    $persistedNames = @((ConvertFrom-Json ([System.IO.File]::ReadAllText(
        (Get-TestStatePath $case $fixedState.dispatchId)
    ))).PSObject.Properties.Name)
    Assert-True -Condition ($persistedNames -cnotcontains 'localPath') -Message 'localPath must never persist'
    Write-Host "PASS 47/$testCount：PERSIST IDENTITY NOT CAPABILITY"
    $passed++

    # AV. Static privacy scan excludes credential/environment/raw-event capability fields.
    $forbiddenPersistedNames = @(
        'localPath', 'environment', 'rawEvents', 'githubToken', 'openAiToken',
        'credentials', 'authMaterial', 'runnerCredentials'
    )
    foreach ($forbiddenName in $forbiddenPersistedNames) {
        Assert-True `
            -Condition ($persistedNames -cnotcontains $forbiddenName) `
            -Message "forbidden persisted field: $forbiddenName"
    }
    Assert-Equal ($persistedNames -join ',') ($script:CodexDispatchStatePropertyOrder -join ',') 'privacy schema exact fields'
    Write-Host "PASS 48/$testCount：privacy/static schema scan"
    $passed++

    # AW. Runtime State APIs inherit the Loader's Git working-tree location boundary.
    $gitStateRoot = Join-Path $testRoot 'runtime-git-location'
    $gitStateRepository = Join-Path $gitStateRoot 'repo'
    $gitStateDirectory = Join-Path $gitStateRepository 'state'
    $gitStateWorkspace = Join-Path $gitStateRoot 'workspace'
    [void](New-Item -ItemType Directory -Path (Join-Path $gitStateRepository '.git') -Force)
    [void](New-Item -ItemType Directory -Path $gitStateDirectory)
    [void](New-Item -ItemType Directory -Path $gitStateWorkspace)
    $gitStateConfig = Join-Path $gitStateRoot 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $gitStateConfig `
        -WorkspaceRoot $gitStateWorkspace `
        -StateDirectory $gitStateDirectory
    Assert-ThrowsLike `
        -Action { & $newState -Task 'location boundary' -ConfigPath $gitStateConfig } `
        -ExpectedText 'runtime.stateDirectory 不能位于 Git working tree 内'
    Assert-True `
        -Condition (-not (Test-Path -LiteralPath (Join-Path $gitStateDirectory 'dispatches'))) `
        -Message 'rejected Git working-tree state location must remain side-effect free'
    Write-Host "PASS 49/$testCount：Runtime API rejects Git working-tree state location"
    $passed++

    Write-Host "全部 Runtime State 测试通过（$passed/$testCount）。"
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        $tempPrefix = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::GetTempPath()
        ).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if (-not $resolvedTestRoot.StartsWith(
            $tempPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw "拒绝清理不在系统 temp 下的测试目录：$resolvedTestRoot"
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
