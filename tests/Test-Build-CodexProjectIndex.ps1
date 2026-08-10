[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$builder = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\scripts\Build-CodexProjectIndex.ps1')
)
if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) {
    throw "找不到项目索引脚本：$builder"
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
        [string]$WorkspaceRoot
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
                enabled = $true
                minimumStrongScore = 120
                minimumLead = 60
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

function New-TestCase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Parent,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $root = Join-Path $Parent $Name
    $workspace = Join-Path $root 'workspace'
    [void](New-Item -ItemType Directory -Path $workspace -Force)
    $config = Join-Path $root 'config.local.json'
    Write-TestConfiguration -ConfigPath $config -WorkspaceRoot $workspace

    return [pscustomobject]@{
        Root = $root
        Workspace = $workspace
        Config = $config
        Output = (Join-Path $root 'project-index.json')
    }
}

function Initialize-TestRepository {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [AllowNull()]
        [string]$Origin
    )

    [void](New-Item -ItemType Directory -Path $Path -Force)
    & git init --quiet -- $Path
    if ($LASTEXITCODE -ne 0) {
        throw "测试仓库初始化失败：$Path"
    }

    if (-not [string]::IsNullOrWhiteSpace($Origin)) {
        & git -C $Path remote add origin $Origin
        if ($LASTEXITCODE -ne 0) {
            throw "测试仓库 origin 设置失败：$Path"
        }
    }
}

function Add-TrackedFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter()]
        [string]$Content = 'test-content'
    )

    $fullPath = Join-Path $Repository $RelativePath
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [System.IO.File]::WriteAllText(
        $fullPath,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
    & git -C $Repository add -- $RelativePath
    if ($LASTEXITCODE -ne 0) {
        throw "git add 失败：$RelativePath"
    }
}

function Read-Index {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

$gitCommand = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $gitCommand) {
    throw '测试要求 PATH 中存在 Git。'
}

$testRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) ('codex-dispatch-index-tests-' + [guid]::NewGuid().ToString('N'))

$passed = 0
try {
    [void](New-Item -ItemType Directory -Path $testRoot)

    # 1. 空工作区生成 version=1 且 projects=[]。
    $case = New-TestCase -Parent $testRoot -Name 'empty'
    $result = & $builder -ConfigPath $case.Config -OutputPath $case.Output
    $doc = Read-Index -Path $case.Output
    Assert-True -Condition ($doc.version -eq 1) -Message '索引 version 应为 1。'
    Assert-True -Condition (@($doc.projects).Count -eq 0) -Message '空工作区 projects 应为空。'
    Write-Host 'PASS 1/10：空索引'
    $passed++

    # 2. 项目身份与 tracked path 生成 token。
    $case = New-TestCase -Parent $testRoot -Name 'tokens'
    $repo = Join-Path $case.Workspace 'sts-mod'
    Initialize-TestRepository `
        -Path $repo `
        -Origin 'https://github.com/example-owner/sts2-mod.git'
    Add-TrackedFile -Repository $repo -RelativePath 'src\Relics\EternalWaiting.cs'
    & $builder -ConfigPath $case.Config -OutputPath $case.Output | Out-Null
    $project = @(Read-Index -Path $case.Output).projects[0]
    $tokens = @($project.tokens)
    Assert-True -Condition ($tokens -contains 'sts-mod') -Message '缺少项目目录名 token。'
    Assert-True -Condition ($tokens -contains 'sts2-mod') -Message '缺少 GitHub repository token。'
    Assert-True -Condition ($tokens -contains 'eternalwaiting') -Message '缺少文件 stem token。'
    Assert-True -Condition ($tokens -contains 'relics') -Message '缺少路径段 token。'
    Write-Host 'PASS 2/10：身份与 tracked path token'
    $passed++

    # 3. 不读取文件正文，秘密字符串不能进入 index。
    $case = New-TestCase -Parent $testRoot -Name 'no-content-read'
    $repo = Join-Path $case.Workspace 'content-safe'
    Initialize-TestRepository -Path $repo
    $secret = 'DO_NOT_LEAK_BODY_SENTINEL_847291'
    Add-TrackedFile `
        -Repository $repo `
        -RelativePath 'src\Worker.cs' `
        -Content $secret
    & $builder -ConfigPath $case.Config -OutputPath $case.Output | Out-Null
    $json = [System.IO.File]::ReadAllText($case.Output)
    Assert-True -Condition (-not $json.Contains($secret)) -Message '索引泄露了 tracked file 正文。'
    Write-Host 'PASS 3/10：不读取正文'
    $passed++

    # 4. untracked path 不进入 token。
    $case = New-TestCase -Parent $testRoot -Name 'untracked'
    $repo = Join-Path $case.Workspace 'untracked-safe'
    Initialize-TestRepository -Path $repo
    Add-TrackedFile -Repository $repo -RelativePath 'src\TrackedThing.cs'
    [System.IO.File]::WriteAllText(
        (Join-Path $repo 'UntrackedSecretName.txt'),
        'x',
        [System.Text.UTF8Encoding]::new($false)
    )
    & $builder -ConfigPath $case.Config -OutputPath $case.Output | Out-Null
    $tokens = @((Read-Index -Path $case.Output).projects[0].tokens)
    Assert-True -Condition ($tokens -contains 'trackedthing') -Message 'tracked token 缺失。'
    Assert-True -Condition (-not ($tokens -contains 'untrackedsecretname')) -Message 'untracked 文件名进入了索引。'
    Write-Host 'PASS 4/10：忽略 untracked path'
    $passed++

    # 5. tracked path 计数正确。
    $case = New-TestCase -Parent $testRoot -Name 'counts'
    $repo = Join-Path $case.Workspace 'counted'
    Initialize-TestRepository -Path $repo
    Add-TrackedFile -Repository $repo -RelativePath 'a.txt'
    Add-TrackedFile -Repository $repo -RelativePath 'b.txt'
    Add-TrackedFile -Repository $repo -RelativePath 'src\c.cs'
    & $builder -ConfigPath $case.Config -OutputPath $case.Output | Out-Null
    $project = (Read-Index -Path $case.Output).projects[0]
    Assert-True -Condition ($project.trackedPathCount -eq 3) -Message 'trackedPathCount 不正确。'
    Assert-True -Condition ($project.indexedTrackedPathCount -eq 3) -Message 'indexedTrackedPathCount 不正确。'
    Assert-True -Condition (-not $project.truncated) -Message '小型仓库不应 truncated。'
    Write-Host 'PASS 5/10：tracked path 计数'
    $passed++

    # 6. 多项目顺序稳定。
    $case = New-TestCase -Parent $testRoot -Name 'sorting'
    Initialize-TestRepository -Path (Join-Path $case.Workspace 'Zulu')
    Initialize-TestRepository -Path (Join-Path $case.Workspace 'alpha')
    Initialize-TestRepository -Path (Join-Path $case.Workspace 'Middle')
    & $builder -ConfigPath $case.Config -OutputPath $case.Output | Out-Null
    $names = @((Read-Index -Path $case.Output).projects | ForEach-Object { $_.name })
    Assert-True `
        -Condition (($names -join ',') -eq 'alpha,Middle,Zulu') `
        -Message "项目排序不稳定：$($names -join ',')"
    Write-Host 'PASS 6/10：稳定项目排序'
    $passed++

    # 7. 输出 UTF-8 无 BOM。
    $case = New-TestCase -Parent $testRoot -Name 'encoding'
    Initialize-TestRepository -Path (Join-Path $case.Workspace 'encoding-project')
    & $builder -ConfigPath $case.Config -OutputPath $case.Output | Out-Null
    $bytes = [System.IO.File]::ReadAllBytes($case.Output)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and `
        $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    Assert-True -Condition (-not $hasBom) -Message 'project-index.json 不应包含 UTF-8 BOM。'
    Write-Host 'PASS 7/10：UTF-8 无 BOM'
    $passed++

    # 8. 非 GitHub origin 不阻止本地项目进入索引。
    $case = New-TestCase -Parent $testRoot -Name 'non-github'
    $repo = Join-Path $case.Workspace 'local-project'
    Initialize-TestRepository -Path $repo -Origin 'https://example.invalid/team/repo.git'
    Add-TrackedFile -Repository $repo -RelativePath 'CoreThing.cs'
    & $builder -ConfigPath $case.Config -OutputPath $case.Output | Out-Null
    $project = (Read-Index -Path $case.Output).projects[0]
    Assert-True -Condition ($null -eq $project.githubRepository) -Message '非 GitHub origin 应映射为 null。'
    Assert-True -Condition (@($project.tokens) -contains 'local-project') -Message '本地项目 identity token 缺失。'
    Write-Host 'PASS 8/10：允许非 GitHub 本地项目'
    $passed++

    # 9. 非法 OutputPath 返回统一错误。
    $case = New-TestCase -Parent $testRoot -Name 'invalid-output'
    Assert-ThrowsLike `
        -Action {
            & $builder `
                -ConfigPath $case.Config `
                -OutputPath (Join-Path $case.Root 'missing\project-index.json')
        } `
        -ExpectedText 'Codex Dispatch 项目索引错误：OutputPath'
    Write-Host 'PASS 9/10：非法 OutputPath'
    $passed++

    # 10. 已存在的输出文件可安全覆盖并保持合法 JSON。
    $case = New-TestCase -Parent $testRoot -Name 'overwrite'
    $repo = Join-Path $case.Workspace 'overwrite-project'
    Initialize-TestRepository -Path $repo
    Add-TrackedFile -Repository $repo -RelativePath 'One.cs'
    [System.IO.File]::WriteAllText(
        $case.Output,
        'old-data',
        [System.Text.UTF8Encoding]::new($false)
    )
    & $builder -ConfigPath $case.Config -OutputPath $case.Output | Out-Null
    $doc = Read-Index -Path $case.Output
    Assert-True -Condition ($doc.version -eq 1) -Message '覆盖后不是合法 v1 索引。'
    Assert-True -Condition (@($doc.projects).Count -eq 1) -Message '覆盖后项目数量不正确。'
    Write-Host 'PASS 10/10：安全覆盖普通输出文件'
    $passed++

    Write-Host "全部项目索引测试通过（$passed/10）。"
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
