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
            stateDirectory = 'unused-by-v0.1-loader'
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
try {
    [void](New-Item -ItemType Directory -Path $testRoot)

    $normalDirectory = Join-Path $testRoot 'normal'
    $workspaceDirectory = Join-Path $normalDirectory 'workspace'
    [void](New-Item -ItemType Directory -Path $workspaceDirectory -Force)
    Write-TestConfiguration `
        -ConfigPath (Join-Path $normalDirectory 'config.local.json') `
        -WorkspaceRoot '.\workspace'

    Push-Location $normalDirectory
    try {
        $config = & $loader
    }
    finally {
        Pop-Location
    }

    $topLevelNames = @($config.PSObject.Properties.Name)
    Assert-True `
        -Condition (($topLevelNames -join ',') -eq 'workspace,controlPlane,routing,codex,privacy,safety') `
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
        -Condition ($null -eq $config.PSObject.Properties['runtime']) `
        -Message 'v0.1 统一返回对象不应包含 runtime。'
    Write-Host 'PASS 1/8：正常配置'
    $passed++

    $missingConfig = Join-Path $testRoot 'missing\config.local.json'
    Assert-ThrowsLike `
        -Action { & $loader -Path $missingConfig } `
        -ExpectedText '找不到配置文件'
    Write-Host 'PASS 2/8：缺失配置'
    $passed++

    $invalidDirectory = Join-Path $testRoot 'invalid-workspace'
    [void](New-Item -ItemType Directory -Path $invalidDirectory)
    $invalidConfig = Join-Path $invalidDirectory 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $invalidConfig `
        -WorkspaceRoot '.\does-not-exist'
    Assert-ThrowsLike `
        -Action { & $loader -Path $invalidConfig } `
        -ExpectedText 'workspace.root 不存在或不是目录'
    Write-Host 'PASS 3/8：非法路径'
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
    Write-Host 'PASS 4/8：拒绝 config.example.json'
    $passed++

    $credentialPath = Join-Path $testRoot '.credentials'
    Assert-ThrowsLike `
        -Action { & $loader -Path $credentialPath } `
        -ExpectedText '拒绝加载敏感身份或凭据文件'
    Write-Host 'PASS 5/8：拒绝敏感 Runner 文件'
    $passed++

    $envPath = Join-Path $testRoot '.environment-backup'
    Assert-ThrowsLike `
        -Action { & $loader -Path $envPath } `
        -ExpectedText '拒绝加载敏感身份或凭据文件'
    Write-Host 'PASS 6/8：拒绝 .env* 敏感文件'
    $passed++

    $invalidRepositoryDirectory = Join-Path $testRoot 'invalid-repository'
    $invalidRepositoryWorkspace = Join-Path $invalidRepositoryDirectory 'workspace'
    [void](New-Item -ItemType Directory -Path $invalidRepositoryWorkspace -Force)
    $invalidRepositoryConfig = Join-Path $invalidRepositoryDirectory 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $invalidRepositoryConfig `
        -WorkspaceRoot '.\workspace' `
        -Repository 'not a github repository'
    Assert-ThrowsLike `
        -Action { & $loader -Path $invalidRepositoryConfig } `
        -ExpectedText 'controlPlane.repository 格式无效'
    Write-Host 'PASS 7/8：非法 controlPlane.repository'
    $passed++

    $invalidVersionDirectory = Join-Path $testRoot 'invalid-version'
    $invalidVersionWorkspace = Join-Path $invalidVersionDirectory 'workspace'
    [void](New-Item -ItemType Directory -Path $invalidVersionWorkspace -Force)
    $invalidVersionConfig = Join-Path $invalidVersionDirectory 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $invalidVersionConfig `
        -WorkspaceRoot '.\workspace' `
        -Version 'abc'
    Assert-ThrowsLike `
        -Action { & $loader -Path $invalidVersionConfig } `
        -ExpectedText 'version 必须是整数 1'
    Write-Host 'PASS 8/8：非法 version 类型'
    $passed++

    Write-Host "全部配置加载测试通过（$passed/8）。"
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
