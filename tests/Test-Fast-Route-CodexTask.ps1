[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$router = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\scripts\Fast-Route-CodexTask.ps1')
)
if (-not (Test-Path -LiteralPath $router -PathType Leaf)) {
    throw "找不到快速路由脚本：$router"
}

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

    if ($Actual -ne $Expected) {
        throw "断言失败：$Message。预期：$Expected；实际：$Actual"
    }
}

function Assert-FastRouterError {
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
        -Message "预期快速路由抛错，但调用成功：$ExpectedText"
    Assert-True `
        -Condition $message.StartsWith(
            'Codex Dispatch 快速路由错误：',
            [System.StringComparison]::Ordinal
        ) `
        -Message "错误未使用统一前缀：$message"
    Assert-True `
        -Condition $message.Contains($ExpectedText) `
        -Message "错误未包含 '$ExpectedText'。实际：$message"
}

function Write-TestConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory = $true)]
        [bool]$FastEnabled,

        [Parameter()]
        [int]$MinimumStrongScore = 120,

        [Parameter()]
        [int]$MinimumLead = 60
    )

    $document = [ordered]@{
        version = 1
        workspace = [ordered]@{
            root = $WorkspaceRoot
            scanDepth = 1
            allowReparsePoints = $false
        }
        controlPlane = [ordered]@{
            provider = 'github'
            repository = 'example-user/private-control'
            defaultBranch = 'main'
            issueAssignee = 'example-user'
        }
        routing = [ordered]@{
            fast = [ordered]@{
                enabled = $FastEnabled
                minimumStrongScore = $MinimumStrongScore
                minimumLead = $MinimumLead
            }
            slow = [ordered]@{
                enabled = $true
                timeoutSeconds = 180
            }
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
            includeOriginalTaskInIssues = $true
        }
        safety = [ordered]@{
            restrictToWorkspaceRoot = $true
            requireExplicitAuthorizationFor = @('push', 'merge', 'publish')
        }
    }

    [System.IO.File]::WriteAllText(
        $ConfigPath,
        (ConvertTo-Json -InputObject $document -Depth 10) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function New-TestProject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$LocalPath,

        [Parameter()]
        [AllowNull()]
        [object]$GitHubRepository,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Tokens
    )

    return [pscustomobject][ordered]@{
        name = $Name
        localPath = $LocalPath
        githubRepository = $GitHubRepository
        tokens = [object[]]$Tokens
        trackedPathCount = [int]$Tokens.Count
        indexedTrackedPathCount = [int]$Tokens.Count
        truncated = $false
    }
}

function Write-TestIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IndexPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Projects
    )

    $document = [ordered]@{
        version = 1
        projects = [object[]]$Projects
    }
    [System.IO.File]::WriteAllText(
        $IndexPath,
        (ConvertTo-Json -InputObject $document -Depth 10) + [Environment]::NewLine,
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
        [bool]$FastEnabled = $true,

        [Parameter()]
        [int]$MinimumStrongScore = 120,

        [Parameter()]
        [int]$MinimumLead = 60
    )

    $root = Join-Path $Parent $Name
    $workspace = Join-Path $root 'workspace'
    [void](New-Item -ItemType Directory -Path $workspace -Force)
    $config = Join-Path $root 'config.local.json'
    $index = Join-Path $root 'project-index.json'
    Write-TestConfiguration `
        -ConfigPath $config `
        -WorkspaceRoot $workspace `
        -FastEnabled $FastEnabled `
        -MinimumStrongScore $MinimumStrongScore `
        -MinimumLead $MinimumLead

    return [pscustomobject]@{
        Root = $root
        Workspace = $workspace
        Config = $config
        Index = $index
    }
}

function Invoke-TestRouter {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Task,

        [Parameter(Mandatory = $true)]
        [object]$Case
    )

    return & $router `
        -Task $Task `
        -ConfigPath $Case.Config `
        -IndexPath $Case.Index
}

$testRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) ('codex-dispatch-fast-router-tests-' + [guid]::NewGuid().ToString('N'))

$passed = 0
try {
    [void](New-Item -ItemType Directory -Path $testRoot)

    # 1. 完整 project name 是强 identity 证据。
    $case = New-TestCase -Parent $testRoot -Name 'project-name'
    Write-TestIndex -IndexPath $case.Index -Projects @(
        (New-TestProject `
            -Name 'alpha-project' `
            -LocalPath 'C:\projects\alpha-project' `
            -GitHubRepository $null `
            -Tokens @())
    )
    $result = Invoke-TestRouter -Task 'please update alpha_project' -Case $case
    Assert-Equal $result.status 'strong' 'project name 应 strong'
    Assert-Equal $result.topScore 180 'project name 分数'
    Assert-Equal $result.lead 180 '单项目 lead'
    Assert-Equal $result.selectedProject.name 'alpha-project' '选中项目'
    Assert-Equal $result.candidates[0].matchedSignals[0].kind 'project_name' 'identity signal 类型'
    Write-Host 'PASS 1/19：direct project name strong'
    $passed++

    # 2. repository name 是强 identity 证据。
    $case = New-TestCase -Parent $testRoot -Name 'repository-name'
    Write-TestIndex -IndexPath $case.Index -Projects @(
        (New-TestProject `
            -Name 'local-folder' `
            -LocalPath 'C:\projects\local-folder' `
            -GitHubRepository 'example-owner/router-core' `
            -Tokens @())
    )
    $result = Invoke-TestRouter -Task 'fix ROUTER_core today' -Case $case
    Assert-Equal $result.status 'strong' 'repository name 应 strong'
    Assert-Equal $result.topScore 180 'repository name 分数'
    Assert-Equal $result.selectedProject.name 'local-folder' 'repository identity 选中项目'
    Assert-Equal $result.candidates[0].matchedSignals[0].kind 'repository_name' 'repository signal 类型'
    Write-Host 'PASS 2/19：repository identity strong'
    $passed++

    # 3. 唯一长 token 80+60=140，可单独 strong。
    $case = New-TestCase -Parent $testRoot -Name 'unique-long'
    Write-TestIndex -IndexPath $case.Index -Projects @(
        (New-TestProject `
            -Name 'mod-one' `
            -LocalPath 'C:\projects\mod-one' `
            -GitHubRepository $null `
            -Tokens @('eternalwaiting')),
        (New-TestProject `
            -Name 'mod-two' `
            -LocalPath 'C:\projects\mod-two' `
            -GitHubRepository $null `
            -Tokens @('somethingelse'))
    )
    $result = Invoke-TestRouter -Task 'repair EternalWaiting behavior' -Case $case
    Assert-Equal $result.status 'strong' '唯一长 token 应 strong'
    Assert-Equal $result.topScore 140 '唯一长 token 分数'
    Assert-Equal $result.lead 140 '唯一长 token lead'
    Assert-Equal $result.selectedProject.name 'mod-one' '唯一长 token 选中项目'
    Assert-Equal $result.candidates[0].matchedSignals[0].uniqueBonus 60 '唯一长 token bonus'
    Write-Host 'PASS 3/19：unique long token strong'
    $passed++

    # 4. 两个唯一中等 token 各 35+25，合计 120。
    $case = New-TestCase -Parent $testRoot -Name 'multiple-medium'
    Write-TestIndex -IndexPath $case.Index -Projects @(
        (New-TestProject `
            -Name 'combat-module' `
            -LocalPath 'C:\projects\combat-module' `
            -GitHubRepository $null `
            -Tokens @('relics', 'powers')),
        (New-TestProject `
            -Name 'other-module' `
            -LocalPath 'C:\projects\other-module' `
            -GitHubRepository $null `
            -Tokens @('assets'))
    )
    $result = Invoke-TestRouter -Task 'change relics and powers' -Case $case
    Assert-Equal $result.status 'strong' '多个中等 token 应 strong'
    Assert-Equal $result.topScore 120 '多个中等 token 总分'
    Assert-Equal $result.lead 120 '多个中等 token lead'
    Assert-Equal $result.candidates[0].matchedSignals.Count 2 '两个 matched token'
    Write-Host 'PASS 4/19：multiple medium tokens strong'
    $passed++

    # 5. shared token 无唯一 bonus，且并列 ambiguous。
    $case = New-TestCase -Parent $testRoot -Name 'shared-token'
    Write-TestIndex -IndexPath $case.Index -Projects @(
        (New-TestProject `
            -Name 'alpha' `
            -LocalPath 'C:\projects\alpha' `
            -GitHubRepository $null `
            -Tokens @('dispatcher')),
        (New-TestProject `
            -Name 'beta' `
            -LocalPath 'C:\projects\beta' `
            -GitHubRepository $null `
            -Tokens @('dispatcher'))
    )
    $result = Invoke-TestRouter -Task 'update dispatcher' -Case $case
    Assert-Equal $result.status 'ambiguous' 'shared token 应 ambiguous'
    Assert-Equal $result.topScore 60 'shared token 分数'
    Assert-Equal $result.lead 0 'shared token lead'
    Assert-Equal $result.candidates[0].name 'alpha' '并列时 name ordinal 排序'
    Assert-Equal $result.candidates[0].matchedSignals[0].uniqueBonus 0 'shared token 无 bonus'
    Write-Host 'PASS 5/19：shared token ambiguous'
    $passed++

    # 6. 3 字符弱 token 只有 15 分。
    $case = New-TestCase -Parent $testRoot -Name 'weak-token'
    Write-TestIndex -IndexPath $case.Index -Projects @(
        (New-TestProject `
            -Name 'service-one' `
            -LocalPath 'C:\projects\service-one' `
            -GitHubRepository $null `
            -Tokens @('api'))
    )
    $result = Invoke-TestRouter -Task 'adjust api' -Case $case
    Assert-Equal $result.status 'ambiguous' '弱 token 应 ambiguous'
    Assert-Equal $result.topScore 15 '弱 token 分数'
    Assert-Equal $result.lead 15 '弱 token lead'
    Assert-True -Condition ($null -eq $result.selectedProject) -Message 'ambiguous 不应选中项目'
    Write-Host 'PASS 6/19：weak token ambiguous'
    $passed++

    # 7. 所有项目 0 分时 no_match。
    $case = New-TestCase -Parent $testRoot -Name 'no-match'
    Write-TestIndex -IndexPath $case.Index -Projects @(
        (New-TestProject `
            -Name 'alpha' `
            -LocalPath 'C:\projects\alpha' `
            -GitHubRepository $null `
            -Tokens @('relics')),
        (New-TestProject `
            -Name 'beta' `
            -LocalPath 'C:\projects\beta' `
            -GitHubRepository $null `
            -Tokens @('powers'))
    )
    $result = Invoke-TestRouter -Task 'completely unrelated request' -Case $case
    Assert-Equal $result.status 'no_match' '无匹配应 no_match'
    Assert-Equal $result.topScore 0 'no_match topScore'
    Assert-Equal $result.lead 0 'no_match lead'
    Assert-True -Condition ($null -eq $result.selectedProject) -Message 'no_match 不应选中项目'
    Write-Host 'PASS 7/19：no match'
    $passed++

    # 8. 中文项目名允许出现在无空格中文句子中。
    $case = New-TestCase -Parent $testRoot -Name 'chinese-identity'
    Write-TestIndex -IndexPath $case.Index -Projects @(
        (New-TestProject `
            -Name '王二卡牌' `
            -LocalPath 'C:\projects\王二卡牌' `
            -GitHubRepository $null `
            -Tokens @())
    )
    $result = Invoke-TestRouter -Task '请修改王二卡牌的路由逻辑' -Case $case
    Assert-Equal $result.status 'strong' '中文 identity 应 strong'
    Assert-Equal $result.topScore 180 '中文 identity 分数'
    Assert-Equal $result.selectedProject.name '王二卡牌' '中文项目选择'
    Write-Host 'PASS 8/19：Chinese project identity'
    $passed++

    # 9. 大小写与指定 separator 等价。
    $case = New-TestCase -Parent $testRoot -Name 'normalization'
    Write-TestIndex -IndexPath $case.Index -Projects @(
        (New-TestProject `
            -Name 'Codex.Dispatch_Router' `
            -LocalPath 'C:\projects\router' `
            -GitHubRepository $null `
            -Tokens @())
    )
    $result = Invoke-TestRouter -Task 'fix CODEX-dispatch/router now' -Case $case
    Assert-Equal $result.status 'strong' 'case/separator normalization 应 strong'
    Assert-Equal $result.topScore 180 'case/separator identity 分数'
    Write-Host 'PASS 9/19：case/separator normalization'
    $passed++

    # 10. disabled 不读取缺失 index。
    $case = New-TestCase -Parent $testRoot -Name 'disabled' -FastEnabled $false
    $result = Invoke-TestRouter -Task 'alpha project' -Case $case
    Assert-Equal $result.status 'disabled' 'fast.enabled=false 应 disabled'
    Assert-Equal $result.topScore 0 'disabled topScore'
    Assert-Equal $result.candidates.Count 0 'disabled candidates'
    Write-Host 'PASS 10/19：fast disabled'
    $passed++

    # 11. 缺失或损坏 index 都使用统一错误，不降级 no_match。
    $case = New-TestCase -Parent $testRoot -Name 'invalid-index'
    Assert-FastRouterError `
        -Action { Invoke-TestRouter -Task 'anything' -Case $case } `
        -ExpectedText '找不到 Project Index'
    [System.IO.File]::WriteAllText(
        $case.Index,
        '{ invalid json',
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-FastRouterError `
        -Action { Invoke-TestRouter -Task 'anything' -Case $case } `
        -ExpectedText 'Project Index 不是有效 JSON'
    Write-Host 'PASS 11/19：invalid/missing index unified error'
    $passed++

    # 12. 排名、topScore、lead 与解释输出完全确定。
    $case = New-TestCase -Parent $testRoot -Name 'deterministic-ranking'
    Write-TestIndex -IndexPath $case.Index -Projects @(
        (New-TestProject `
            -Name 'Gamma' `
            -LocalPath 'C:\projects\gamma' `
            -GitHubRepository $null `
            -Tokens @('tiny')),
        (New-TestProject `
            -Name 'Beta' `
            -LocalPath 'C:\projects\beta' `
            -GitHubRepository $null `
            -Tokens @('routingbeta')),
        (New-TestProject `
            -Name 'Alpha' `
            -LocalPath 'C:\projects\alpha' `
            -GitHubRepository $null `
            -Tokens @('routingalpha'))
    )
    $first = Invoke-TestRouter `
        -Task 'routingalpha routingbeta tiny' `
        -Case $case
    $second = Invoke-TestRouter `
        -Task 'routingalpha routingbeta tiny' `
        -Case $case
    Assert-Equal $first.status 'ambiguous' 'lead 不足应 ambiguous'
    Assert-Equal $first.topScore 140 '确定性 topScore'
    Assert-Equal $first.lead 20 '确定性 lead'
    Assert-Equal (($first.candidates.name) -join ',') 'Alpha,Beta,Gamma' '候选排名'
    Assert-Equal `
        (ConvertTo-Json -InputObject $first -Depth 10) `
        (ConvertTo-Json -InputObject $second -Depth 10) `
        '重复路由输出必须相同'
    Write-Host 'PASS 12/19：deterministic ranking / topScore / lead'
    $passed++

    # 13. 完整 owner/repository 使用 220 分且优先于 repository name。
    $case = New-TestCase -Parent $testRoot -Name 'owner-repository'
    Write-TestIndex -IndexPath $case.Index -Projects @(
        (New-TestProject `
            -Name 'local-router' `
            -LocalPath 'C:\projects\local-router' `
            -GitHubRepository 'example-owner/router-core' `
            -Tokens @())
    )
    $result = Invoke-TestRouter `
        -Task 'update example_owner/router.core' `
        -Case $case
    Assert-Equal $result.status 'strong' 'owner/repository 应 strong'
    Assert-Equal $result.topScore 220 'owner/repository 分数'
    Assert-Equal $result.candidates[0].matchedSignals.Count 1 '只保留最具体 identity'
    Assert-Equal $result.candidates[0].matchedSignals[0].kind 'owner_repository' '完整 repository signal'
    Write-Host 'PASS 13/19：owner/repository identity'
    $passed++

    # 14. 内置 stop tokens 不产生 token 分数。
    $case = New-TestCase -Parent $testRoot -Name 'stop-tokens'
    Write-TestIndex -IndexPath $case.Index -Projects @(
        (New-TestProject `
            -Name 'neutral-project' `
            -LocalPath 'C:\projects\neutral-project' `
            -GitHubRepository $null `
            -Tokens @(
                'src', 'source', 'test', 'tests', 'doc', 'docs',
                'script', 'scripts', 'build', 'main', 'readme',
                'license', 'config', 'git', 'github', 'code', 'app', 'lib',
                'readme.md', 'config.local', 'github-client'
            ))
    )
    $result = Invoke-TestRouter `
        -Task 'src source test tests doc docs script scripts build main readme license config git github code app lib readme.md config_local github-client' `
        -Case $case
    Assert-Equal $result.status 'no_match' 'stop tokens 不应匹配'
    Assert-Equal $result.topScore 0 'stop tokens 总分'
    Assert-Equal $result.candidates[0].matchedSignals.Count 0 'stop tokens 无 signal'
    Write-Host 'PASS 14/19：stop tokens ignored'
    $passed++

    # 15. 同一规范化 token 每项目只计一次。
    $case = New-TestCase -Parent $testRoot -Name 'deduplicate-token'
    Write-TestIndex -IndexPath $case.Index -Projects @(
        (New-TestProject `
            -Name 'dedupe-project' `
            -LocalPath 'C:\projects\dedupe-project' `
            -GitHubRepository $null `
            -Tokens @('EternalWaiting', 'eternalwaiting'))
    )
    $result = Invoke-TestRouter -Task 'eternalwaiting' -Case $case
    Assert-Equal $result.topScore 140 '重复 token 只计一次'
    Assert-Equal $result.candidates[0].matchedSignals.Count 1 '重复 token 只有一个 signal'
    Write-Host 'PASS 15/19：matched token deduplicated'
    $passed++

    # 16. 不支持的 index schema version 是系统错误。
    $case = New-TestCase -Parent $testRoot -Name 'invalid-schema'
    [System.IO.File]::WriteAllText(
        $case.Index,
        '{"version":2,"projects":[]}',
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-FastRouterError `
        -Action { Invoke-TestRouter -Task 'anything' -Case $case } `
        -ExpectedText '不支持 Project Index version=2'
    Write-Host 'PASS 16/19：invalid index schema unified error'
    $passed++

    # 17. 缺失或损坏配置统一包装为快速路由错误。
    $case = New-TestCase -Parent $testRoot -Name 'invalid-config'
    Remove-Item -LiteralPath $case.Config -Force
    Assert-FastRouterError `
        -Action { Invoke-TestRouter -Task 'anything' -Case $case } `
        -ExpectedText '无法加载配置'
    [System.IO.File]::WriteAllText(
        $case.Config,
        '{ invalid json',
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-FastRouterError `
        -Action { Invoke-TestRouter -Task 'anything' -Case $case } `
        -ExpectedText '无法加载配置'
    Write-Host 'PASS 17/19：invalid/missing config unified error'
    $passed++

    # 18. 合法空索引是 no_match，而不是系统错误。
    $case = New-TestCase -Parent $testRoot -Name 'empty-index'
    Write-TestIndex -IndexPath $case.Index -Projects @()
    $result = Invoke-TestRouter -Task 'anything' -Case $case
    Assert-Equal $result.status 'no_match' '空索引应 no_match'
    Assert-Equal $result.topScore 0 '空索引 topScore'
    Assert-Equal $result.lead 0 '空索引 lead'
    Assert-Equal $result.candidates.Count 0 '空索引 candidates'
    Write-Host 'PASS 18/19：empty index no_match'
    $passed++

    # 19. Task 必须是非空字符串，且先于配置/index 访问验证。
    $case = New-TestCase -Parent $testRoot -Name 'empty-task'
    Assert-FastRouterError `
        -Action { Invoke-TestRouter -Task '   ' -Case $case } `
        -ExpectedText 'Task 必须是非空字符串'
    Write-Host 'PASS 19/19：empty task unified error'
    $passed++

    Write-Host "全部快速路由测试通过（$passed/19）。"
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        $resolvedTempRoot = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::GetTempPath()
        ).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar

        if (-not $resolvedTestRoot.StartsWith(
            $resolvedTempRoot,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw "拒绝清理临时目录，因为路径不在系统临时目录内：$resolvedTestRoot"
        }

        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
