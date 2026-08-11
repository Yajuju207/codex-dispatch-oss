[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$discovery = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\scripts\Discover-CodexProjects.ps1')
)
if (-not (Test-Path -LiteralPath $discovery -PathType Leaf)) {
    throw "找不到项目发现脚本：$discovery"
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
        [object]$ScanDepth = 1
    )

    $document = [ordered]@{
        version = 1
        workspace = [ordered]@{
            root = $WorkspaceRoot
            scanDepth = $ScanDepth
            allowReparsePoints = $false
        }
        runtime = [ordered]@{ stateDirectory = $StateDirectory }
        controlPlane = [ordered]@{
            provider = 'github'
            repository = 'example-user/private-control'
        }
        routing = [ordered]@{
            fast = [ordered]@{ enabled = $true }
            slow = [ordered]@{ enabled = $true }
        }
        codex = [ordered]@{
            command = 'codex'
        }
        privacy = [ordered]@{
            exposeLocalPathsInIssues = $false
        }
        safety = [ordered]@{
            restrictToWorkspaceRoot = $true
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
        [object]$ScanDepth = 1
    )

    $caseRoot = Join-Path $Parent $Name
    $workspace = Join-Path $caseRoot 'workspace'
    $stateDirectory = Join-Path $caseRoot 'runtime-state'
    [void](New-Item -ItemType Directory -Path $workspace -Force)
    [void](New-Item -ItemType Directory -Path $stateDirectory -Force)
    $configPath = Join-Path $caseRoot 'config.local.json'
    Write-TestConfiguration `
        -ConfigPath $configPath `
        -WorkspaceRoot $workspace `
        -StateDirectory $stateDirectory `
        -ScanDepth $ScanDepth

    return [pscustomobject]@{
        Root = $caseRoot
        Workspace = $workspace
        Config = $configPath
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

$gitCommand = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $gitCommand) {
    throw '测试要求 PATH 中存在 Git。'
}

$testRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) ('codex-dispatch-discovery-tests-' + [guid]::NewGuid().ToString('N'))

$passed = 0
try {
    [void](New-Item -ItemType Directory -Path $testRoot)

    # 1. 空工作区返回空对象数组。
    $case = New-TestCase -Parent $testRoot -Name 'empty'
    $result = @(& $discovery -ConfigPath $case.Config)
    Assert-True -Condition ($result.Count -eq 0) -Message '空工作区应返回空数组。'
    Write-Host 'PASS 1/21：空工作区'
    $passed++

    # 2. 不含 .git 的直接子目录被忽略。
    $case = New-TestCase -Parent $testRoot -Name 'non-git'
    [void](New-Item -ItemType Directory -Path (Join-Path $case.Workspace 'notes'))
    $result = @(& $discovery -ConfigPath $case.Config)
    Assert-True -Condition ($result.Count -eq 0) -Message '非 Git 目录不应产生记录。'
    Write-Host 'PASS 2/21：忽略非 Git 目录'
    $passed++

    # 3. 有效本地仓库返回 ok。
    $case = New-TestCase -Parent $testRoot -Name 'valid'
    Initialize-TestRepository -Path (Join-Path $case.Workspace 'project-one')
    $result = @(& $discovery -ConfigPath $case.Config)
    Assert-True -Condition ($result.Count -eq 1) -Message '应发现一个有效仓库。'
    Assert-True -Condition ($result[0].status -eq 'ok') -Message '有效仓库状态应为 ok。'
    Assert-True -Condition ($result[0].name -eq 'project-one') -Message '项目名不正确。'
    Write-Host 'PASS 3/21：有效仓库'
    $passed++

    # 4. HTTPS GitHub origin 可解析。
    $case = New-TestCase -Parent $testRoot -Name 'https-origin'
    Initialize-TestRepository `
        -Path (Join-Path $case.Workspace 'https-project') `
        -Origin 'https://github.com/example-owner/sample-repository.git'
    $result = @(& $discovery -ConfigPath $case.Config)
    Assert-True `
        -Condition ($result[0].githubRepository -eq 'example-owner/sample-repository') `
        -Message 'HTTPS origin 解析失败。'
    Write-Host 'PASS 4/21：HTTPS origin'
    $passed++

    # 5. SCP 风格 SSH GitHub origin 可解析。
    $case = New-TestCase -Parent $testRoot -Name 'ssh-origin'
    Initialize-TestRepository `
        -Path (Join-Path $case.Workspace 'ssh-project') `
        -Origin 'git@github.com:example-owner/sample-repository.git'
    $result = @(& $discovery -ConfigPath $case.Config)
    Assert-True `
        -Condition ($result[0].githubRepository -eq 'example-owner/sample-repository') `
        -Message 'SSH origin 解析失败。'
    Assert-True `
        -Condition ($result[0].origin -eq 'git@github.com:example-owner/sample-repository.git') `
        -Message 'SSH origin 不应被清洗。'
    Write-Host 'PASS 5/21：SSH origin'
    $passed++

    # 6. ssh:// GitHub origin 可解析。
    $case = New-TestCase -Parent $testRoot -Name 'ssh-url-origin'
    Initialize-TestRepository `
        -Path (Join-Path $case.Workspace 'ssh-url-project') `
        -Origin 'ssh://git@github.com/example-owner/sample-repository.git'
    $result = @(& $discovery -ConfigPath $case.Config)
    Assert-True `
        -Condition ($result[0].githubRepository -eq 'example-owner/sample-repository') `
        -Message 'ssh:// origin 解析失败。'
    Write-Host 'PASS 6/21：ssh:// origin'
    $passed++

    # 7. 没有 origin 的有效仓库仍为 ok，GitHub 映射为空。
    $case = New-TestCase -Parent $testRoot -Name 'no-origin'
    Initialize-TestRepository -Path (Join-Path $case.Workspace 'local-only')
    $result = @(& $discovery -ConfigPath $case.Config)
    Assert-True -Condition ($result[0].status -eq 'ok') -Message '无 origin 仓库应保持 ok。'
    Assert-True -Condition ($null -eq $result[0].origin) -Message 'origin 应为 null。'
    Assert-True `
        -Condition ($null -eq $result[0].githubRepository) `
        -Message 'githubRepository 应为 null。'
    Write-Host 'PASS 7/21：无 origin'
    $passed++

    # 8. 伪造 .git 标记返回 invalid_git。
    $case = New-TestCase -Parent $testRoot -Name 'invalid-git'
    $invalidProject = Join-Path $case.Workspace 'broken-project'
    [void](New-Item -ItemType Directory -Path $invalidProject)
    [System.IO.File]::WriteAllText(
        (Join-Path $invalidProject '.git'),
        'not-a-git-directory',
        [System.Text.UTF8Encoding]::new($false)
    )
    $result = @(& $discovery -ConfigPath $case.Config)
    Assert-True -Condition ($result.Count -eq 1) -Message '无效标记应产生一条记录。'
    Assert-True `
        -Condition ($result[0].status -eq 'invalid_git') `
        -Message '无效标记状态应为 invalid_git。'
    Write-Host 'PASS 8/21：无效 Git 标记'
    $passed++

    # 9. JSON 为 UTF-8 无 BOM，且单条结果保持顶层数组。
    $case = New-TestCase -Parent $testRoot -Name 'json-output'
    Initialize-TestRepository -Path (Join-Path $case.Workspace 'single-project')
    $outputPath = Join-Path $case.Root 'projects.json'
    $result = @(& $discovery -ConfigPath $case.Config -OutputPath $outputPath)
    $bytes = [System.IO.File]::ReadAllBytes($outputPath)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and `
        $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $jsonText = [System.IO.File]::ReadAllText($outputPath)
    Assert-True -Condition (-not $hasBom) -Message 'JSON 不应包含 UTF-8 BOM。'
    Assert-True -Condition ($jsonText.TrimStart().StartsWith('[')) -Message 'JSON 顶层必须是数组。'
    Assert-True `
        -Condition ((ConvertFrom-Json -InputObject $jsonText).Count -eq 1) `
        -Message 'JSON 应包含一条记录。'
    Write-Host 'PASS 9/21：JSON 数组与 UTF-8'
    $passed++

    # 10. 结果按目录名稳定排序。
    $case = New-TestCase -Parent $testRoot -Name 'sorting'
    Initialize-TestRepository -Path (Join-Path $case.Workspace 'zulu')
    Initialize-TestRepository -Path (Join-Path $case.Workspace 'Alpha')
    Initialize-TestRepository -Path (Join-Path $case.Workspace 'middle')
    $result = @(& $discovery -ConfigPath $case.Config)
    Assert-True `
        -Condition (($result.name -join ',') -eq 'Alpha,middle,zulu') `
        -Message "排序不稳定：$($result.name -join ',')"
    Write-Host 'PASS 10/21：稳定排序'
    $passed++

    # 11. scanDepth=1 不进入非 Git 直接子目录。
    $case = New-TestCase -Parent $testRoot -Name 'scan-depth-one'
    $group = Join-Path $case.Workspace 'group'
    Initialize-TestRepository -Path (Join-Path $group 'nested-project')
    $result = @(& $discovery -ConfigPath $case.Config)
    Assert-True -Condition ($result.Count -eq 0) -Message 'scanDepth=1 不应发现嵌套仓库。'
    Write-Host 'PASS 11/21：scanDepth=1 边界'
    $passed++

    # 12. reparse point 不被遍历；若系统不支持创建，则直接验证路径边界函数。
    $case = New-TestCase -Parent $testRoot -Name 'reparse-safety'
    $outside = Join-Path $case.Root 'outside-project'
    Initialize-TestRepository -Path $outside
    $junctionPath = Join-Path $case.Workspace 'linked-project'
    $junctionCreated = $false
    try {
        [void](New-Item -ItemType Junction -Path $junctionPath -Target $outside -ErrorAction Stop)
        $junctionCreated = $true
    }
    catch {
        . $discovery
        Assert-True `
            -Condition (-not (Test-CodexDispatchPathWithinRoot `
                -Root $case.Workspace `
                -Candidate $outside
            )) `
            -Message '路径边界函数必须拒绝工作区外路径。'
    }
    if ($junctionCreated) {
        $result = @(& $discovery -ConfigPath $case.Config -WarningAction SilentlyContinue)
        Assert-True -Condition ($result.Count -eq 0) -Message 'reparse point 不应成为项目。'
    }
    Write-Host 'PASS 12/21：reparse/越界安全'
    $passed++

    # 13. 非法 scanDepth 返回统一中文发现错误。
    $case = New-TestCase -Parent $testRoot -Name 'invalid-depth' -ScanDepth 'one'
    Assert-ThrowsLike `
        -Action { & $discovery -ConfigPath $case.Config } `
        -ExpectedText 'Codex Dispatch 项目发现错误：workspace.scanDepth'
    Write-Host 'PASS 13/21：非法 scanDepth'
    $passed++

    # 14. 空结果写入 JSON 时仍保持顶层数组。
    $case = New-TestCase -Parent $testRoot -Name 'empty-json-output'
    $outputPath = Join-Path $case.Root 'empty-projects.json'
    $result = @(& $discovery -ConfigPath $case.Config -OutputPath $outputPath)
    $jsonText = [System.IO.File]::ReadAllText($outputPath)
    Assert-True -Condition ($result.Count -eq 0) -Message '空 JSON 场景不应返回项目。'
    Assert-True `
        -Condition (($jsonText -replace '\s', '') -eq '[]') `
        -Message '空结果 JSON 必须是顶层空数组。'
    Write-Host 'PASS 14/21：空结果 JSON 数组'
    $passed++

    # 15. 非法 OutputPath 返回统一中文发现错误。
    $case = New-TestCase -Parent $testRoot -Name 'invalid-output-path'
    Assert-ThrowsLike `
        -Action {
            & $discovery `
                -ConfigPath $case.Config `
                -OutputPath (Join-Path $case.Root 'missing\projects.json')
        } `
        -ExpectedText 'Codex Dispatch 项目发现错误：OutputPath'
    Write-Host 'PASS 15/21：非法 OutputPath'
    $passed++

    # 16. 普通 .git 文件可引用 workspace 内的有效相对 gitdir。
    $case = New-TestCase -Parent $testRoot -Name 'git-file-inside'
    $worktreePath = Join-Path $case.Workspace 'linked-worktree'
    $metadataRoot = Join-Path $case.Workspace 'metadata'
    $gitDirectory = Join-Path $metadataRoot 'linked-worktree.git'
    [void](New-Item -ItemType Directory -Path $metadataRoot)
    & git init --quiet "--separate-git-dir=$gitDirectory" -- $worktreePath
    if ($LASTEXITCODE -ne 0) {
        throw '内部 gitdir 测试仓库初始化失败。'
    }
    $gitFilePath = Join-Path $worktreePath '.git'
    [System.IO.File]::SetAttributes(
        $gitFilePath,
        [System.IO.FileAttributes]::Normal
    )
    [System.IO.File]::WriteAllText(
        $gitFilePath,
        'gitdir: ..\metadata\linked-worktree.git' + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
    $result = @(& $discovery -ConfigPath $case.Config)
    Assert-True -Condition ($result.Count -eq 1) -Message '应发现普通 .git 文件工作树。'
    Assert-True -Condition ($result[0].status -eq 'ok') -Message '内部 gitdir 应为 ok。'
    Write-Host 'PASS 16/21：workspace 内部 gitdir'
    $passed++

    # 17. 普通 .git 文件引用 workspace 外 gitdir 时，在调用 Git 前拒绝。
    $case = New-TestCase -Parent $testRoot -Name 'git-file-outside'
    $worktreePath = Join-Path $case.Workspace 'escaped-worktree'
    $gitDirectory = Join-Path $case.Root 'outside-metadata.git'
    & git init --quiet "--separate-git-dir=$gitDirectory" -- $worktreePath
    if ($LASTEXITCODE -ne 0) {
        throw '外部 gitdir 测试仓库初始化失败。'
    }
    $result = @(& $discovery -ConfigPath $case.Config)
    Assert-True -Condition ($result.Count -eq 1) -Message '越界 gitdir 应产生记录。'
    Assert-True `
        -Condition ($result[0].status -eq 'unsafe_path') `
        -Message '越界 gitdir 必须为 unsafe_path。'
    Assert-True -Condition ($result[0].status -ne 'ok') -Message '越界 gitdir 不能成为 ok。'
    Write-Host 'PASS 17/21：拒绝 workspace 外部 gitdir'
    $passed++

    # 18. 已存在的 OutputPath 文件 symlink 必须被拒绝。
    $case = New-TestCase -Parent $testRoot -Name 'output-reparse'
    $outputTarget = Join-Path $case.Root 'output-target.json'
    $outputLink = Join-Path $case.Root 'output-link.json'
    [System.IO.File]::WriteAllText(
        $outputTarget,
        'unchanged',
        [System.Text.UTF8Encoding]::new($false)
    )
    $fileLinkCreated = $false
    try {
        [void](New-Item `
            -ItemType SymbolicLink `
            -Path $outputLink `
            -Target $outputTarget `
            -ErrorAction Stop
        )
        $fileLinkCreated = $true
    }
    catch {
        . $discovery
        $fallbackTarget = Join-Path $case.Root 'fallback-target'
        $fallbackLink = Join-Path $case.Root 'fallback-link'
        [void](New-Item -ItemType Directory -Path $fallbackTarget)
        [void](New-Item -ItemType Junction -Path $fallbackLink -Target $fallbackTarget)
        Assert-True `
            -Condition (Test-CodexDispatchExistingPathReparsePoint -Path $fallbackLink) `
            -Message 'OutputPath reparse helper 未识别 junction。'
    }
    if ($fileLinkCreated) {
        Assert-ThrowsLike `
            -Action {
                & $discovery -ConfigPath $case.Config -OutputPath $outputLink
            } `
            -ExpectedText 'Codex Dispatch 项目发现错误：OutputPath 已存在且是 reparse point'
        Assert-True `
            -Condition ([System.IO.File]::ReadAllText($outputTarget) -eq 'unchanged') `
            -Message '拒绝输出链接后，链接目标必须保持不变。'
    }
    Write-Host 'PASS 18/21：拒绝 OutputPath reparse'
    $passed++

    # 19. HTTPS origin 的标准 user-info 被完全移除。
    $case = New-TestCase -Parent $testRoot -Name 'https-user-info'
    Initialize-TestRepository `
        -Path (Join-Path $case.Workspace 'user-info-project') `
        -Origin 'https://user:secret@github.com/example/repo.git'
    $result = @(& $discovery -ConfigPath $case.Config)
    Assert-True `
        -Condition ($result[0].origin -eq 'https://github.com/example/repo.git') `
        -Message 'HTTPS user-info 未正确移除。'
    Assert-True `
        -Condition ($result[0].githubRepository -eq 'example/repo') `
        -Message '清洗后 GitHub 仓库映射失败。'
    Write-Host 'PASS 19/21：清洗 HTTPS user-info'
    $passed++

    # 20. 多分隔符的异常 HTTPS user-info 也不能残留敏感片段。
    $case = New-TestCase -Parent $testRoot -Name 'complex-user-info'
    Initialize-TestRepository `
        -Path (Join-Path $case.Workspace 'complex-user-info-project') `
        -Origin 'https://odd:secret%40value@@github.com/example/repo.git'
    $result = @(& $discovery -ConfigPath $case.Config)
    Assert-True `
        -Condition ($result[0].origin -eq 'https://github.com/example/repo.git') `
        -Message '复杂 HTTPS user-info 未正确移除。'
    Assert-True `
        -Condition (-not $result[0].origin.Contains('secret')) `
        -Message '输出 origin 仍包含敏感 user-info。'
    Assert-True `
        -Condition ($result[0].githubRepository -eq 'example/repo') `
        -Message '复杂 user-info 清洗后 GitHub 仓库映射失败。'
    Write-Host 'PASS 20/21：清洗复杂 HTTPS user-info'
    $passed++

    # 21. workspace.root 自身为仓库时，根 .git 目录永远不进入 BFS。
    $case = New-TestCase -Parent $testRoot -Name 'root-git-metadata' -ScanDepth 3
    & git init --quiet -- $case.Workspace
    if ($LASTEXITCODE -ne 0) {
        throw 'workspace.root 测试仓库初始化失败。'
    }
    $metadataDecoy = Join-Path $case.Workspace '.git\metadata-decoy'
    Initialize-TestRepository -Path $metadataDecoy
    $result = @(& $discovery -ConfigPath $case.Config)
    Assert-True `
        -Condition ($result.Count -eq 0) `
        -Message 'workspace.root 的 .git 内容不得进入发现结果。'
    Write-Host 'PASS 21/21：根 .git 目录永不入队'
    $passed++

    Write-Host "全部项目发现测试通过（$passed/21）。"
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
