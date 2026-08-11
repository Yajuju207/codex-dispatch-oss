[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$loader = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\scripts\Load-CodexDispatchConfig.ps1')
)
if (-not (Test-Path -LiteralPath $loader -PathType Leaf)) {
    throw "找不到配置加载器：$loader"
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
        -Message "预期抛出包含 '$ExpectedText' 的异常，但调用成功。"
    Assert-True `
        -Condition $message.Contains($ExpectedText) `
        -Message "异常未包含 '$ExpectedText'。实际异常：$message"
}

function Write-TestConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter()]
        [string]$Repository = 'example-user/private-control',

        [Parameter()]
        [object]$Version = 1
    )

    $document = [ordered]@{
        version = $Version
        workspace = [ordered]@{
            root = $WorkspaceRoot
            scanDepth = 1
            allowReparsePoints = $false
        }
        runtime = [ordered]@{
            stateDirectory = $StateDirectory
        }
        controlPlane = [ordered]@{
            provider = 'github'
            repository = $Repository
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

    $json = ConvertTo-Json -InputObject $document -Depth 8
    [System.IO.File]::WriteAllText(
        $ConfigPath,
        $json + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

$testRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) ('codex-dispatch-config-tests-' + [guid]::NewGuid().ToString('N'))

$passed = 0
$testCount = 19
try {
    [void](New-Item -ItemType Directory -Path $testRoot)

    $sharedStateDirectory = Join-Path $testRoot 'runtime-state'
    [void](New-Item -ItemType Directory -Path $sharedStateDirectory)

    $normalDirectory = Join-Path $testRoot 'normal'
    $workspaceDirectory = Join-Path $normalDirectory 'workspace'
    [void](New-Item -ItemType Directory -Path $workspaceDirectory -Force)
    Write-TestConfiguration `
        -ConfigPath (Join-Path $normalDirectory 'config.local.json') `
        -WorkspaceRoot '.\workspace' `
        -StateDirectory '..\runtime-state'

    Push-Location $normalDirectory
    try {
        $config = & $loader
    }
    finally {
        Pop-Location
    }

    $topLevelNames = @($config.PSObject.Properties.Name)
    Assert-True `
        -Condition (($topLevelNames -join ',') -eq 'workspace,runtime,controlPlane,routing,codex,privacy,safety') `
        -Message "返回对象的顶层属性不统一：$($topLevelNames -join ', ')"
    Assert-True `
        -Condition ([string]::Equals(
            $config.workspace.root,
            (Get-Item -LiteralPath $workspaceDirectory).FullName,
            [System.StringComparison]::OrdinalIgnoreCase
        )) `
        -Message 'workspace.root 未规范化为现有绝对路径。'
    Assert-True `
        -Condition ($config.controlPlane.repository -eq 'example-user/private-control') `
        -Message 'controlPlane.repository 未正确加载。'
    Assert-True `
        -Condition ([string]::Equals(
            $config.runtime.stateDirectory,
            (Get-Item -LiteralPath $sharedStateDirectory).FullName,
            [System.StringComparison]::OrdinalIgnoreCase
        )) `
        -Message 'runtime.stateDirectory 未相对 config directory 规范化。'
    Write-Host "PASS 1/$testCount：正常配置 / runtime section / relative state path"
    $passed++

    $missingConfig = Join-Path $testRoot 'missing\config.local.json'
    Assert-ThrowsLike `
        -Action { & $loader -Path $missingConfig } `
        -ExpectedText '找不到配置文件'
    Write-Host "PASS 2/$testCount：缺失配置"
    $passed++

    $invalidDirectory = Join-Path $testRoot 'invalid-workspace'
    [void](New-Item -ItemType Directory -Path $invalidDirectory)
    $invalidConfig = Join-Path $invalidDirectory 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $invalidConfig `
        -WorkspaceRoot '.\does-not-exist' `
        -StateDirectory $sharedStateDirectory
    Assert-ThrowsLike `
        -Action { & $loader -Path $invalidConfig } `
        -ExpectedText 'workspace.root 不存在或不是目录'
    Write-Host "PASS 3/$testCount：非法路径"
    $passed++

    $templatePath = Join-Path $testRoot 'config.example.json'
    [System.IO.File]::WriteAllText(
        $templatePath,
        '{}',
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-ThrowsLike `
        -Action { & $loader -Path $templatePath } `
        -ExpectedText '只能作为模板'
    Write-Host "PASS 4/$testCount：拒绝 config.example.json"
    $passed++

    $credentialPath = Join-Path $testRoot '.credentials'
    Assert-ThrowsLike `
        -Action { & $loader -Path $credentialPath } `
        -ExpectedText '拒绝加载敏感身份或凭据文件'
    Write-Host "PASS 5/$testCount：拒绝敏感 Runner 文件"
    $passed++

    $envPath = Join-Path $testRoot '.environment-backup'
    Assert-ThrowsLike `
        -Action { & $loader -Path $envPath } `
        -ExpectedText '拒绝加载敏感身份或凭据文件'
    Write-Host "PASS 6/$testCount：拒绝 .env* 敏感文件"
    $passed++

    $invalidRepositoryDirectory = Join-Path $testRoot 'invalid-repository'
    $invalidRepositoryWorkspace = Join-Path $invalidRepositoryDirectory 'workspace'
    [void](New-Item -ItemType Directory -Path $invalidRepositoryWorkspace -Force)
    $invalidRepositoryConfig = Join-Path $invalidRepositoryDirectory 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $invalidRepositoryConfig `
        -WorkspaceRoot '.\workspace' `
        -StateDirectory $sharedStateDirectory `
        -Repository 'not a github repository'
    Assert-ThrowsLike `
        -Action { & $loader -Path $invalidRepositoryConfig } `
        -ExpectedText 'controlPlane.repository 格式无效'
    Write-Host "PASS 7/$testCount：非法 controlPlane.repository"
    $passed++

    $invalidVersionDirectory = Join-Path $testRoot 'invalid-version'
    $invalidVersionWorkspace = Join-Path $invalidVersionDirectory 'workspace'
    [void](New-Item -ItemType Directory -Path $invalidVersionWorkspace -Force)
    $invalidVersionConfig = Join-Path $invalidVersionDirectory 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $invalidVersionConfig `
        -WorkspaceRoot '.\workspace' `
        -StateDirectory $sharedStateDirectory `
        -Version 'abc'
    Assert-ThrowsLike `
        -Action { & $loader -Path $invalidVersionConfig } `
        -ExpectedText 'version 必须是整数 1'
    Write-Host "PASS 8/$testCount：非法 version 类型"
    $passed++

    $absoluteDirectory = Join-Path $testRoot 'absolute-state-config'
    $absoluteWorkspace = Join-Path $absoluteDirectory 'workspace'
    [void](New-Item -ItemType Directory -Path $absoluteWorkspace -Force)
    $absoluteConfig = Join-Path $absoluteDirectory 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $absoluteConfig `
        -WorkspaceRoot '.\workspace' `
        -StateDirectory $sharedStateDirectory
    $absoluteResult = & $loader -Path $absoluteConfig
    Assert-True `
        -Condition ([string]::Equals(
            $absoluteResult.runtime.stateDirectory,
            (Get-Item -LiteralPath $sharedStateDirectory).FullName,
            [System.StringComparison]::OrdinalIgnoreCase
        )) `
        -Message 'absolute runtime.stateDirectory 未规范化。'
    Write-Host "PASS 9/$testCount：absolute state path"
    $passed++

    $missingStateDirectory = Join-Path $testRoot 'missing-state-directory'
    $missingStateConfigDirectory = Join-Path $testRoot 'missing-state-config'
    $missingStateWorkspace = Join-Path $missingStateConfigDirectory 'workspace'
    [void](New-Item -ItemType Directory -Path $missingStateWorkspace -Force)
    $missingStateConfig = Join-Path $missingStateConfigDirectory 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $missingStateConfig `
        -WorkspaceRoot '.\workspace' `
        -StateDirectory $missingStateDirectory
    Assert-ThrowsLike `
        -Action { & $loader -Path $missingStateConfig } `
        -ExpectedText 'runtime.stateDirectory 不存在或不是目录'
    Assert-True `
        -Condition (-not (Test-Path -LiteralPath $missingStateDirectory)) `
        -Message 'Config Loader 不得创建 missing stateDirectory。'
    Write-Host "PASS 10/$testCount：missing state directory rejected without side effects"
    $passed++

    $reparseTarget = Join-Path $testRoot 'reparse-target'
    $reparseState = Join-Path $testRoot 'reparse-state'
    $reparseConfigDirectory = Join-Path $testRoot 'reparse-config'
    [void](New-Item -ItemType Directory -Path $reparseTarget)
    [void](New-Item -ItemType Junction -Path $reparseState -Target $reparseTarget)
    [void](New-Item -ItemType Directory -Path (Join-Path $reparseConfigDirectory 'workspace') -Force)
    $reparseConfig = Join-Path $reparseConfigDirectory 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $reparseConfig `
        -WorkspaceRoot '.\workspace' `
        -StateDirectory $reparseState
    Assert-ThrowsLike `
        -Action { & $loader -Path $reparseConfig } `
        -ExpectedText '路径链包含 reparse point'
    Write-Host "PASS 11/$testCount：state directory reparse rejected"
    $passed++

    $nestedWorkspace = Join-Path $testRoot 'workspace-parent'
    $nestedState = Join-Path $nestedWorkspace 'runtime-state'
    $nestedConfigDirectory = Join-Path $testRoot 'state-inside-workspace-config'
    [void](New-Item -ItemType Directory -Path $nestedState -Force)
    [void](New-Item -ItemType Directory -Path $nestedConfigDirectory)
    $nestedConfig = Join-Path $nestedConfigDirectory 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $nestedConfig `
        -WorkspaceRoot $nestedWorkspace `
        -StateDirectory $nestedState
    Assert-ThrowsLike `
        -Action { & $loader -Path $nestedConfig } `
        -ExpectedText 'runtime.stateDirectory 不能位于 workspace.root 内部'
    Write-Host "PASS 12/$testCount：state directory inside workspace rejected"
    $passed++

    $parentState = Join-Path $testRoot 'parent-state'
    $workspaceInsideState = Join-Path $parentState 'workspace'
    $workspaceInsideStateConfigDirectory = Join-Path $testRoot 'workspace-inside-state-config'
    [void](New-Item -ItemType Directory -Path $workspaceInsideState -Force)
    [void](New-Item -ItemType Directory -Path $workspaceInsideStateConfigDirectory)
    $workspaceInsideStateConfig = Join-Path $workspaceInsideStateConfigDirectory 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $workspaceInsideStateConfig `
        -WorkspaceRoot $workspaceInsideState `
        -StateDirectory $parentState
    Assert-ThrowsLike `
        -Action { & $loader -Path $workspaceInsideStateConfig } `
        -ExpectedText 'workspace.root 不能位于 runtime.stateDirectory 内部'
    Write-Host "PASS 13/$testCount：workspace inside state directory rejected"
    $passed++

    $prefixRoot = Join-Path $testRoot 'prefix-boundary'
    $prefixWorkspace = Join-Path $prefixRoot 'Projects'
    $prefixState = Join-Path $prefixRoot 'Projects2'
    $prefixConfigDirectory = Join-Path $testRoot 'prefix-config'
    [void](New-Item -ItemType Directory -Path $prefixWorkspace -Force)
    [void](New-Item -ItemType Directory -Path $prefixState -Force)
    [void](New-Item -ItemType Directory -Path $prefixConfigDirectory)
    $prefixConfig = Join-Path $prefixConfigDirectory 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $prefixConfig `
        -WorkspaceRoot $prefixWorkspace `
        -StateDirectory $prefixState
    $prefixResult = & $loader -Path $prefixConfig
    Assert-True `
        -Condition ([string]::Equals(
            $prefixResult.runtime.stateDirectory,
            (Get-Item -LiteralPath $prefixState).FullName,
            [System.StringComparison]::OrdinalIgnoreCase
        )) `
        -Message 'adjacent path prefix 被错误识别为目录包含关系。'
    Write-Host "PASS 14/$testCount：adjacent prefix remains separate"
    $passed++

    $gitDirectoryRoot = Join-Path $testRoot 'git-directory-marker'
    $gitDirectoryRepository = Join-Path $gitDirectoryRoot 'repo'
    $gitDirectoryState = Join-Path $gitDirectoryRepository 'state'
    $gitDirectoryWorkspace = Join-Path $gitDirectoryRoot 'workspace'
    [void](New-Item -ItemType Directory -Path (Join-Path $gitDirectoryRepository '.git') -Force)
    [void](New-Item -ItemType Directory -Path $gitDirectoryState)
    [void](New-Item -ItemType Directory -Path $gitDirectoryWorkspace)
    $gitDirectoryConfig = Join-Path $gitDirectoryRoot 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $gitDirectoryConfig `
        -WorkspaceRoot $gitDirectoryWorkspace `
        -StateDirectory $gitDirectoryState
    Assert-ThrowsLike `
        -Action { & $loader -Path $gitDirectoryConfig } `
        -ExpectedText 'runtime.stateDirectory 不能位于 Git working tree 内'
    Write-Host "PASS 15/$testCount：state inside .git directory marker rejected"
    $passed++

    $gitFileRoot = Join-Path $testRoot 'git-file-marker'
    $gitFileRepository = Join-Path $gitFileRoot 'repo'
    $gitFileState = Join-Path $gitFileRepository 'state'
    $gitFileWorkspace = Join-Path $gitFileRoot 'workspace'
    [void](New-Item -ItemType Directory -Path $gitFileState -Force)
    [void](New-Item -ItemType Directory -Path $gitFileWorkspace)
    [System.IO.File]::WriteAllText(
        (Join-Path $gitFileRepository '.git'),
        'conservative marker only',
        [System.Text.UTF8Encoding]::new($false)
    )
    $gitFileConfig = Join-Path $gitFileRoot 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $gitFileConfig `
        -WorkspaceRoot $gitFileWorkspace `
        -StateDirectory $gitFileState
    Assert-ThrowsLike `
        -Action { & $loader -Path $gitFileConfig } `
        -ExpectedText 'runtime.stateDirectory 不能位于 Git working tree 内'
    Write-Host "PASS 16/$testCount：state inside .git file marker rejected"
    $passed++

    $siblingRoot = Join-Path $testRoot 'sibling-git-repository'
    $siblingRepository = Join-Path $siblingRoot 'repo'
    $siblingState = Join-Path $siblingRoot 'state'
    $siblingWorkspace = Join-Path $siblingRoot 'workspace'
    [void](New-Item -ItemType Directory -Path (Join-Path $siblingRepository '.git') -Force)
    [void](New-Item -ItemType Directory -Path $siblingState)
    [void](New-Item -ItemType Directory -Path $siblingWorkspace)
    $siblingConfig = Join-Path $siblingRoot 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $siblingConfig `
        -WorkspaceRoot $siblingWorkspace `
        -StateDirectory $siblingState
    $siblingResult = & $loader -Path $siblingConfig
    Assert-True `
        -Condition ([string]::Equals(
            $siblingResult.runtime.stateDirectory,
            (Get-Item -LiteralPath $siblingState).FullName,
            [System.StringComparison]::OrdinalIgnoreCase
        )) `
        -Message 'descendant/sibling Git repository must not reject stateDirectory.'
    Write-Host "PASS 17/$testCount：sibling Git repository ignored"
    $passed++

    $relativeEscapeRoot = Join-Path $testRoot 'relative-git-escape'
    $relativeRepository = Join-Path $relativeEscapeRoot 'repo'
    $relativeConfigDirectory = Join-Path $relativeRepository 'config'
    $relativePrivateState = Join-Path $relativeEscapeRoot 'private-state'
    $relativeWorkspace = Join-Path $relativeEscapeRoot 'workspace'
    [void](New-Item -ItemType Directory -Path (Join-Path $relativeRepository '.git') -Force)
    [void](New-Item -ItemType Directory -Path $relativeConfigDirectory)
    [void](New-Item -ItemType Directory -Path $relativePrivateState)
    [void](New-Item -ItemType Directory -Path $relativeWorkspace)
    $relativeEscapeConfig = Join-Path $relativeConfigDirectory 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $relativeEscapeConfig `
        -WorkspaceRoot '..\..\workspace' `
        -StateDirectory '..\..\private-state'
    $relativeEscapeResult = & $loader -Path $relativeEscapeConfig
    Assert-True `
        -Condition ([string]::Equals(
            $relativeEscapeResult.runtime.stateDirectory,
            (Get-Item -LiteralPath $relativePrivateState).FullName,
            [System.StringComparison]::OrdinalIgnoreCase
        )) `
        -Message 'relative stateDirectory escaping Git checkout must remain supported.'
    Write-Host "PASS 18/$testCount：relative path outside Git checkout accepted"
    $passed++

    $runtimeContractDirectory = Join-Path $testRoot 'runtime-contract'
    $runtimeContractWorkspace = Join-Path $runtimeContractDirectory 'workspace'
    [void](New-Item -ItemType Directory -Path $runtimeContractWorkspace -Force)
    $runtimeContractConfig = Join-Path $runtimeContractDirectory 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $runtimeContractConfig `
        -WorkspaceRoot '.\workspace' `
        -StateDirectory $sharedStateDirectory
    $runtimeContractDocument = ConvertFrom-Json (
        [System.IO.File]::ReadAllText($runtimeContractConfig)
    )
    $runtimeContractDocument.PSObject.Properties.Remove('runtime')
    [System.IO.File]::WriteAllText(
        $runtimeContractConfig,
        (ConvertTo-Json $runtimeContractDocument -Depth 8) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-ThrowsLike `
        -Action { & $loader -Path $runtimeContractConfig } `
        -ExpectedText '缺少必需配置节：runtime'
    Write-Host "PASS 19/$testCount：runtime section is mandatory"
    $passed++

    Write-Host "全部配置加载测试通过（$passed/$testCount）。"
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
