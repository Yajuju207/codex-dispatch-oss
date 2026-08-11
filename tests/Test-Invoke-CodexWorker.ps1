[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$worker = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\scripts\Invoke-CodexWorker.ps1')
)
if (-not (Test-Path -LiteralPath $worker -PathType Leaf)) {
    throw "找不到 Worker 脚本：$worker"
}
$workerDocs = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\docs\WORKER.md')
)
if (-not (Test-Path -LiteralPath $workerDocs -PathType Leaf)) {
    throw "找不到 Worker 文档：$workerDocs"
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

function Assert-WorkerError {
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
        -Message "预期 Worker 抛错但调用成功：$ExpectedText"
    Assert-True `
        -Condition $message.StartsWith(
            'Codex Dispatch Worker 错误：',
            [System.StringComparison]::Ordinal
        ) `
        -Message "错误未使用统一 Worker 前缀：$message"
    Assert-True `
        -Condition $message.Contains($ExpectedText) `
        -Message "错误未包含 '$ExpectedText'。实际：$message"
}

function Assert-ArgumentPair {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $matches = 0
    for ($index = 0; $index + 1 -lt $Arguments.Count; $index++) {
        if (
            [string]::Equals($Arguments[$index], $Key, [System.StringComparison]::Ordinal) -and
            [string]::Equals($Arguments[$index + 1], $Value, [System.StringComparison]::Ordinal)
        ) {
            $matches++
        }
    }
    Assert-Equal $matches 1 "CLI argument pair：$Key $Value"
}

$baselineActions = [object[]]@(
    'push', 'merge', 'publish', 'deploy', 'create-pr',
    'remote-permission-change', 'mass-delete', 'real-money-spend'
)

function Write-TestConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRoot,

        [Parameter()]
        [AllowEmptyString()]
        [string]$CodexCommand,

        [Parameter()]
        [object]$WorkerSandbox = 'workspace-write',

        [Parameter()]
        [object]$ApprovalPolicy = 'never',

        [Parameter()]
        [object]$RestrictToWorkspaceRoot = $true,

        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$ProtectedActions = $baselineActions
    )

    $document = [ordered]@{
        version = 1
        workspace = [ordered]@{
            root = $WorkspaceRoot
            scanDepth = 2
            allowReparsePoints = $false
        }
        runtime = [ordered]@{ stateDirectory = 'unused-by-worker-v0.1' }
        controlPlane = [ordered]@{
            provider = 'github'
            repository = 'owner/control-plane'
        }
        routing = [ordered]@{
            fast = [ordered]@{
                enabled = $true
                minimumStrongScore = 120
                minimumLead = 60
            }
            slow = [ordered]@{ enabled = $true; timeoutSeconds = 180 }
        }
        codex = [ordered]@{
            command = $CodexCommand
            workerSandbox = $WorkerSandbox
            routerSandbox = 'read-only'
            approvalPolicy = $ApprovalPolicy
        }
        privacy = [ordered]@{
            exposeLocalPathsInIssues = $false
            exposeThreadIdsInIssues = $false
            includeOriginalTaskInIssues = $true
        }
        safety = [ordered]@{
            restrictToWorkspaceRoot = $RestrictToWorkspaceRoot
            requireExplicitAuthorizationFor = [object[]]$ProtectedActions
        }
    }
    [System.IO.File]::WriteAllText(
        $Path,
        (ConvertTo-Json -InputObject $document -Depth 10) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Write-TestIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Projects,

        [Parameter()]
        [object]$Version = 1
    )

    $document = [ordered]@{
        version = $Version
        projects = [object[]]$Projects
    }
    [System.IO.File]::WriteAllText(
        $Path,
        (ConvertTo-Json -InputObject $document -Depth 10) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function New-TestProject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [object]$LocalPath,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Repository
    )

    return [pscustomobject][ordered]@{
        name = $Name
        localPath = $LocalPath
        githubRepository = $Repository
        tokens = [object[]]@('identity')
        trackedPathCount = 1
        indexedTrackedPathCount = 1
        truncated = $false
    }
}

function Invoke-TestGit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitPath,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $GitPath -C $RepositoryPath init --quiet 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
        throw "无法创建测试 Git repository：$RepositoryPath"
    }
}

function New-TestCase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Parent,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [AllowEmptyString()]
        [string]$CodexCommand,

        [Parameter()]
        [object]$WorkerSandbox = 'workspace-write',

        [Parameter()]
        [object]$ApprovalPolicy = 'never',

        [Parameter()]
        [object]$RestrictToWorkspaceRoot = $true,

        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$ProtectedActions = $baselineActions
    )

    $root = Join-Path $Parent $Name
    $workspace = Join-Path $root 'workspace'
    [void](New-Item -ItemType Directory -Path $workspace -Force)
    $config = Join-Path $root 'config.local.json'
    $index = Join-Path $root 'project-index.json'
    Write-TestConfiguration `
        -Path $config `
        -WorkspaceRoot $workspace `
        -CodexCommand $CodexCommand `
        -WorkerSandbox $WorkerSandbox `
        -ApprovalPolicy $ApprovalPolicy `
        -RestrictToWorkspaceRoot $RestrictToWorkspaceRoot `
        -ProtectedActions $ProtectedActions

    return [pscustomobject]@{
        Root = $root
        Workspace = $workspace
        Config = $config
        Index = $index
    }
}

function New-TestGitProject {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Case,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$GitPath
    )

    $path = Join-Path $Case.Workspace $RelativePath
    [void](New-Item -ItemType Directory -Path $path -Force)
    Invoke-TestGit -GitPath $GitPath -RepositoryPath $path
    return New-TestProject -Name $Name -LocalPath $path -Repository $Repository
}

function New-FinalJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Report = '',

        [Parameter()]
        [AllowEmptyString()]
        [string]$Question = '',

        [Parameter()]
        [AllowEmptyString()]
        [string]$Context = '',

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Options = @()
    )

    return ConvertTo-Json -Compress -InputObject ([ordered]@{
        status = $Status
        report = $Report
        question = $Question
        context = $Context
        options = [object[]]$Options
    })
}

function Set-FakeCodexBehavior {
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$Events = '',

        [Parameter()]
        [AllowEmptyString()]
        [string]$FinalJson = '',

        [Parameter()]
        [AllowEmptyString()]
        [string]$StandardError = '',

        [Parameter()]
        [int]$ExitCode = 0,

        [Parameter()]
        [bool]$SkipFinal = $false,

        [Parameter()]
        [bool]$SkipStandardInputRead = $false,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ArgumentsCapture = '',

        [Parameter()]
        [AllowEmptyString()]
        [string]$InputCapture = '',

        [Parameter()]
        [AllowEmptyString()]
        [string]$SchemaCapture = '',

        [Parameter()]
        [AllowEmptyString()]
        [string]$WorkingDirectoryCapture = ''
    )

    $env:CODEX_WORKER_FAKE_EVENTS = $Events
    $env:CODEX_WORKER_FAKE_FINAL = $FinalJson
    $env:CODEX_WORKER_FAKE_STDERR = $StandardError
    $env:CODEX_WORKER_FAKE_EXIT_CODE = [string]$ExitCode
    $env:CODEX_WORKER_FAKE_SKIP_FINAL = if ($SkipFinal) { '1' } else { '0' }
    $env:CODEX_WORKER_FAKE_SKIP_STDIN_READ = if ($SkipStandardInputRead) { '1' } else { '0' }
    $env:CODEX_WORKER_FAKE_CAPTURE_ARGS = $ArgumentsCapture
    $env:CODEX_WORKER_FAKE_CAPTURE_STDIN = $InputCapture
    $env:CODEX_WORKER_FAKE_CAPTURE_SCHEMA = $SchemaCapture
    $env:CODEX_WORKER_FAKE_CAPTURE_CWD = $WorkingDirectoryCapture
}

function Invoke-TestWorker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Task,

        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [object]$Case
    )

    return & $worker `
        -Task $Task `
        -ProjectRepository $Repository `
        -ConfigPath $Case.Config `
        -IndexPath $Case.Index
}

function Get-WorkerTempArtifacts {
    return @(
        Get-ChildItem `
            -LiteralPath ([System.IO.Path]::GetTempPath()) `
            -Directory `
            -Filter 'codex-dispatch-worker-*' `
            -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName }
    )
}

function Assert-NoNewWorkerTempArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Before,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $set = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($path in $Before) {
        [void]$set.Add($path)
    }
    $after = @(Get-WorkerTempArtifacts | Where-Object { -not $set.Contains($_) })
    Assert-Equal $after.Count 0 $Message
}

$gitCommand = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $gitCommand) {
    throw '测试需要本地 Git。'
}
$gitPath = [System.IO.Path]::GetFullPath([string]$gitCommand.Source)
$testRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) ('codex-dispatch-worker-tests-' + [guid]::NewGuid().ToString('N'))
$environmentNames = @(
    'CODEX_WORKER_FAKE_EVENTS', 'CODEX_WORKER_FAKE_FINAL',
    'CODEX_WORKER_FAKE_STDERR', 'CODEX_WORKER_FAKE_EXIT_CODE',
    'CODEX_WORKER_FAKE_SKIP_FINAL', 'CODEX_WORKER_FAKE_SKIP_STDIN_READ',
    'CODEX_WORKER_FAKE_CAPTURE_ARGS',
    'CODEX_WORKER_FAKE_CAPTURE_STDIN', 'CODEX_WORKER_FAKE_CAPTURE_SCHEMA',
    'CODEX_WORKER_FAKE_CAPTURE_CWD', 'CODEX_HOME'
)
$originalEnvironment = @{}
foreach ($name in $environmentNames) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}

$passed = 0
$testCount = 37
$threadId = '11111111-1111-4111-8111-111111111111'
$defaultEvents = '{"type":"thread.started","thread_id":"' + $threadId + '"}'
try {
    [void](New-Item -ItemType Directory -Path $testRoot)
    $fakeExe = Join-Path $testRoot 'fake-codex-worker.exe'
    $fakeSource = @'
using System;
using System.IO;
using System.Text;

public static class FakeCodexWorker
{
    private static string Env(string name)
    {
        return Environment.GetEnvironmentVariable(name) ?? string.Empty;
    }

    public static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        Console.InputEncoding = new UTF8Encoding(false);
        string input = string.Empty;
        if (Env("CODEX_WORKER_FAKE_SKIP_STDIN_READ") != "1")
            input = Console.In.ReadToEnd();

        string argsCapture = Env("CODEX_WORKER_FAKE_CAPTURE_ARGS");
        if (argsCapture.Length > 0)
            File.WriteAllLines(argsCapture, args, new UTF8Encoding(false));

        string inputCapture = Env("CODEX_WORKER_FAKE_CAPTURE_STDIN");
        if (inputCapture.Length > 0)
            File.WriteAllText(inputCapture, input, new UTF8Encoding(false));

        string cwdCapture = Env("CODEX_WORKER_FAKE_CAPTURE_CWD");
        if (cwdCapture.Length > 0)
            File.WriteAllText(cwdCapture, Directory.GetCurrentDirectory(), new UTF8Encoding(false));

        string finalPath = string.Empty;
        for (int i = 0; i + 1 < args.Length; i++)
        {
            if (args[i] == "--output-last-message")
                finalPath = args[i + 1];
            if (args[i] == "--output-schema")
            {
                string schemaCapture = Env("CODEX_WORKER_FAKE_CAPTURE_SCHEMA");
                if (schemaCapture.Length > 0)
                    File.Copy(args[i + 1], schemaCapture, true);
            }
        }

        if (Env("CODEX_WORKER_FAKE_SKIP_FINAL") != "1" && finalPath.Length > 0)
            File.WriteAllText(finalPath, Env("CODEX_WORKER_FAKE_FINAL"), new UTF8Encoding(false));

        Console.Write(Env("CODEX_WORKER_FAKE_EVENTS"));
        Console.Error.Write(Env("CODEX_WORKER_FAKE_STDERR"));

        int exitCode;
        return Int32.TryParse(Env("CODEX_WORKER_FAKE_EXIT_CODE"), out exitCode) ? exitCode : 0;
    }
}
'@
    Add-Type `
        -TypeDefinition $fakeSource `
        -Language CSharp `
        -OutputAssembly $fakeExe `
        -OutputType ConsoleApplication

    $fakeCommandDirectory = Join-Path $testRoot 'fake command with spaces'
    [void](New-Item -ItemType Directory -Path $fakeCommandDirectory)
    $fakeCmd = Join-Path $fakeCommandDirectory 'fake-codex-worker.cmd'
    [System.IO.File]::WriteAllText(
        $fakeCmd,
        "@echo off`r`n`"$fakeExe`" %*`r`nexit /b %ERRORLEVEL%`r`n",
        [System.Text.Encoding]::ASCII
    )

    # 1. Valid completed: exact identity/path, valid thread, stable public output, Chinese round-trip.
    $case = New-TestCase -Parent $testRoot -Name 'completed' -CodexCommand $fakeExe
    $project = New-TestGitProject `
        -Case $case -RelativePath '项目甲' -Name '项目甲' `
        -Repository 'owner/project-a' -GitPath $gitPath
    Write-TestIndex -Path $case.Index -Projects @($project)
    $inputCapture = Join-Path $case.Root 'stdin.txt'
    Set-FakeCodexBehavior `
        -Events $defaultEvents `
        -FinalJson (New-FinalJson -Status 'completed' -Report '已完成中文修复并通过测试。') `
        -InputCapture $inputCapture
    $before = Get-WorkerTempArtifacts
    $result = Invoke-TestWorker -Task '修复中文功能' -Repository 'owner/project-a' -Case $case
    Assert-Equal $result.status 'completed' 'completed status'
    Assert-Equal $result.threadId $threadId 'thread id'
    Assert-Equal $result.project.name '项目甲' 'project name'
    Assert-Equal $result.project.localPath $project.localPath 'authorized localPath'
    Assert-Equal $result.project.githubRepository 'owner/project-a' 'repository identity'
    Assert-Equal $result.report '已完成中文修复并通过测试。' 'Chinese report'
    Assert-Equal $result.exitCode 0 'completed exit code'
    Assert-Equal $result.diagnostic '' 'completed diagnostic'
    Assert-Equal `
        (($result.PSObject.Properties.Name) -join ',') `
        'version,status,project,threadId,report,question,context,options,exitCode,diagnostic' `
        'public output shape'
    Assert-NoNewWorkerTempArtifacts -Before $before -Message 'completed temp cleanup'
    Write-Host "PASS 1/$testCount：valid completed / authorization / Chinese / cleanup"
    $passed++

    # 2. Valid needs_input preserves report, question, context and distinct options.
    Set-FakeCodexBehavior `
        -Events $defaultEvents `
        -FinalJson (New-FinalJson `
            -Status 'needs_input' -Report '已完成安全检查。' `
            -Question '是否允许执行发布？' -Context '发布属于受保护动作。' `
            -Options @('允许发布', '暂不发布', '允许发布'))
    $before = Get-WorkerTempArtifacts
    $result = Invoke-TestWorker -Task '准备发布但不要擅自发布' -Repository 'owner/project-a' -Case $case
    Assert-Equal $result.status 'needs_input' 'needs_input status'
    Assert-Equal $result.options.Count 2 'needs_input distinct options'
    Assert-Equal $result.question '是否允许执行发布？' 'needs_input question'
    Assert-NoNewWorkerTempArtifacts -Before $before -Message 'needs_input temp cleanup'
    Write-Host "PASS 2/$testCount：valid needs_input / deduplicated options / cleanup"
    $passed++

    # 3. Empty Task uses unified preflight error.
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task '   ' -Repository 'owner/project-a' -Case $case } `
        -ExpectedText 'Task 必须是非空字符串'
    Write-Host "PASS 3/$testCount：empty Task rejected"
    $passed++

    # 4. ProjectRepository must be a valid owner/repository identity.
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'not-a-repository' -Case $case } `
        -ExpectedText 'ProjectRepository 必须使用合法 owner/repository 格式'
    Write-Host "PASS 4/$testCount：invalid ProjectRepository rejected"
    $passed++

    # 5. Unknown repository never falls back to name or basename.
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'Owner/project-a' -Case $case } `
        -ExpectedText '找不到精确 repository'
    Write-Host "PASS 5/$testCount：unknown repository rejected"
    $passed++

    # 6. Duplicate exact repository entries are ambiguous authorization.
    $case = New-TestCase -Parent $testRoot -Name 'duplicate' -CodexCommand $fakeExe
    $first = New-TestGitProject `
        -Case $case -RelativePath 'first' -Name 'first' `
        -Repository 'owner/duplicate' -GitPath $gitPath
    $second = New-TestGitProject `
        -Case $case -RelativePath 'second' -Name 'second' `
        -Repository 'owner/duplicate' -GitPath $gitPath
    Write-TestIndex -Path $case.Index -Projects @($first, $second)
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/duplicate' -Case $case } `
        -ExpectedText '精确匹配不唯一'
    Write-Host "PASS 6/$testCount：duplicate exact repository rejected"
    $passed++

    # 7. githubRepository=null is ignored, including a stale local-only path.
    $case = New-TestCase -Parent $testRoot -Name 'null-entry' -CodexCommand $fakeExe
    $localOnly = New-TestProject `
        -Name 'local-only' -LocalPath (Join-Path $case.Workspace 'missing-local') -Repository $null
    $project = New-TestGitProject `
        -Case $case -RelativePath 'target' -Name 'target' `
        -Repository 'owner/target' -GitPath $gitPath
    Write-TestIndex -Path $case.Index -Projects @($localOnly, $project)
    Set-FakeCodexBehavior -Events $defaultEvents -FinalJson (
        New-FinalJson -Status 'completed' -Report '完成。'
    )
    $result = Invoke-TestWorker -Task 'task' -Repository 'owner/target' -Case $case
    Assert-Equal $result.status 'completed' 'null repository ignored'
    Write-Host "PASS 7/$testCount：null repository ignored before runtime authorization"
    $passed++

    # 8. Selected localPath must be absolute.
    $case = New-TestCase -Parent $testRoot -Name 'relative-path' -CodexCommand $fakeExe
    Write-TestIndex -Path $case.Index -Projects @(
        (New-TestProject -Name 'relative' -LocalPath 'relative\path' -Repository 'owner/relative')
    )
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/relative' -Case $case } `
        -ExpectedText 'localPath 必须是绝对路径'
    Write-Host "PASS 8/$testCount：relative selected path rejected"
    $passed++

    # 9. workspace.root itself is not a project capability.
    $case = New-TestCase -Parent $testRoot -Name 'root-path' -CodexCommand $fakeExe
    Write-TestIndex -Path $case.Index -Projects @(
        (New-TestProject -Name 'root' -LocalPath $case.Workspace -Repository 'owner/root')
    )
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/root' -Case $case } `
        -ExpectedText '必须严格位于 workspace.root 之下'
    Write-Host "PASS 9/$testCount：workspace.root rejected"
    $passed++

    # 10. Adjacent string prefixes cannot escape workspace authorization.
    $case = New-TestCase -Parent $testRoot -Name 'adjacent-prefix' -CodexCommand $fakeExe
    $adjacent = $case.Workspace + '2\project'
    [void](New-Item -ItemType Directory -Path $adjacent -Force)
    Write-TestIndex -Path $case.Index -Projects @(
        (New-TestProject -Name 'adjacent' -LocalPath $adjacent -Repository 'owner/adjacent')
    )
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/adjacent' -Case $case } `
        -ExpectedText '必须严格位于 workspace.root 之下'
    Write-Host "PASS 10/$testCount：adjacent prefix escape rejected"
    $passed++

    # 11. Missing selected directory is rejected.
    $case = New-TestCase -Parent $testRoot -Name 'missing-path' -CodexCommand $fakeExe
    Write-TestIndex -Path $case.Index -Projects @(
        (New-TestProject `
            -Name 'missing' -LocalPath (Join-Path $case.Workspace 'missing') `
            -Repository 'owner/missing')
    )
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/missing' -Case $case } `
        -ExpectedText 'localPath 不存在或不是目录'
    Write-Host "PASS 11/$testCount：missing selected directory rejected"
    $passed++

    # 12. Reparse points in the candidate path chain are rejected.
    $case = New-TestCase -Parent $testRoot -Name 'reparse-path' -CodexCommand $fakeExe
    $real = Join-Path $case.Workspace 'real'
    [void](New-Item -ItemType Directory -Path $real)
    Invoke-TestGit -GitPath $gitPath -RepositoryPath $real
    $junction = Join-Path $case.Workspace 'linked'
    [void](New-Item -ItemType Junction -Path $junction -Target $real)
    Write-TestIndex -Path $case.Index -Projects @(
        (New-TestProject -Name 'linked' -LocalPath $junction -Repository 'owner/linked')
    )
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/linked' -Case $case } `
        -ExpectedText '包含不安全 reparse point'
    Write-Host "PASS 12/$testCount：candidate reparse path rejected"
    $passed++

    # 13. A plain subdirectory of a parent Git repo is not an exact Git toplevel.
    $case = New-TestCase -Parent $testRoot -Name 'git-toplevel' -CodexCommand $fakeExe
    $parentRepo = Join-Path $case.Workspace 'parent'
    [void](New-Item -ItemType Directory -Path $parentRepo)
    Invoke-TestGit -GitPath $gitPath -RepositoryPath $parentRepo
    $subdirectory = Join-Path $parentRepo 'subdirectory'
    [void](New-Item -ItemType Directory -Path $subdirectory)
    Write-TestIndex -Path $case.Index -Projects @(
        (New-TestProject -Name 'subdirectory' -LocalPath $subdirectory -Repository 'owner/subdirectory')
    )
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/subdirectory' -Case $case } `
        -ExpectedText '必须精确等于 Git working tree toplevel'
    Write-Host "PASS 13/$testCount：selected directory must be exact Git toplevel"
    $passed++

    # 14. workerSandbox cannot be weakened or expanded.
    $case = New-TestCase `
        -Parent $testRoot -Name 'invalid-sandbox' -CodexCommand $fakeExe `
        -WorkerSandbox 'read-only'
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case } `
        -ExpectedText '只允许 codex.workerSandbox=workspace-write'
    Write-Host "PASS 14/$testCount：workerSandbox enforcement"
    $passed++

    # 15. approvalPolicy must remain never.
    $case = New-TestCase `
        -Parent $testRoot -Name 'invalid-approval' -CodexCommand $fakeExe `
        -ApprovalPolicy 'on-request'
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case } `
        -ExpectedText '只允许 codex.approvalPolicy=never'
    Write-Host "PASS 15/$testCount：approvalPolicy enforcement"
    $passed++

    # 16. restrictToWorkspaceRoot must be JSON true.
    foreach ($invalidRestriction in @($false, 'true')) {
        $case = New-TestCase `
            -Parent $testRoot -Name ('invalid-restriction-' + [guid]::NewGuid().ToString('N')) `
            -CodexCommand $fakeExe -RestrictToWorkspaceRoot $invalidRestriction
        Assert-WorkerError `
            -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case } `
            -ExpectedText 'safety.restrictToWorkspaceRoot 必须是 JSON true'
    }
    Write-Host "PASS 16/$testCount：restrictToWorkspaceRoot enforcement"
    $passed++

    # 17. Every baseline protected action is mandatory; malformed lists are rejected.
    $missingBaseline = @($baselineActions | Where-Object { $_ -ne 'mass-delete' })
    $case = New-TestCase `
        -Parent $testRoot -Name 'missing-protected-action' -CodexCommand $fakeExe `
        -ProtectedActions $missingBaseline
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case } `
        -ExpectedText '缺少 baseline protected action：mass-delete'
    $case = New-TestCase `
        -Parent $testRoot -Name 'invalid-protected-action' -CodexCommand $fakeExe `
        -ProtectedActions @($baselineActions + 42)
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case } `
        -ExpectedText '只能包含非空字符串'
    Write-Host "PASS 17/$testCount：protected-action baseline and types enforced"
    $passed++

    # 18. Empty and unresolved codex.command are preflight errors.
    $case = New-TestCase -Parent $testRoot -Name 'empty-command' -CodexCommand ''
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case } `
        -ExpectedText 'codex.command 必须是非空字符串'
    $case = New-TestCase `
        -Parent $testRoot -Name 'unresolved-command' -CodexCommand 'not-a-real-codex-command'
    $project = New-TestGitProject `
        -Case $case -RelativePath 'project' -Name 'project' `
        -Repository 'owner/project' -GitPath $gitPath
    Write-TestIndex -Path $case.Index -Projects @($project)
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case } `
        -ExpectedText '无法解析 codex.command'
    Write-Host "PASS 18/$testCount：empty/unresolved codex.command rejected"
    $passed++

    # 19. .cmd wrapper, exact CLI safety semantics, prompt and schema contract.
    $case = New-TestCase -Parent $testRoot -Name 'cmd wrapper with spaces' -CodexCommand $fakeCmd
    $project = New-TestGitProject `
        -Case $case -RelativePath 'project' -Name 'project' `
        -Repository 'owner/project' -GitPath $gitPath
    Write-TestIndex -Path $case.Index -Projects @($project)
    $argsCapture = Join-Path $case.Root 'args.txt'
    $stdinCapture = Join-Path $case.Root 'stdin.txt'
    $schemaCapture = Join-Path $case.Root 'schema.json'
    $cwdCapture = Join-Path $case.Root 'cwd.txt'
    $task = '实现 "安全" 功能；不要破坏现有修改'
    Set-FakeCodexBehavior `
        -Events $defaultEvents `
        -FinalJson (New-FinalJson -Status 'completed' -Report '完成。') `
        -ArgumentsCapture $argsCapture `
        -InputCapture $stdinCapture `
        -SchemaCapture $schemaCapture `
        -WorkingDirectoryCapture $cwdCapture
    $result = Invoke-TestWorker -Task $task -Repository 'owner/project' -Case $case
    $arguments = @(Get-Content -LiteralPath $argsCapture -Encoding UTF8)
    foreach ($requiredArgument in @(
        '--sandbox', 'workspace-write', '--ask-for-approval', 'never', '--cd',
        '--disable', 'plugins', 'exec', '--ignore-user-config', '--json',
        '--color', 'never', '--output-last-message', '--output-schema', '-'
    )) {
        Assert-True `
            -Condition ($arguments -contains $requiredArgument) `
            -Message "缺少 Worker CLI 参数：$requiredArgument"
    }
    foreach ($override in @(
        [pscustomobject]@{
            Key = '-c'
            Value = 'sandbox_workspace_write.network_access=false'
        },
        [pscustomobject]@{
            Key = '-c'
            Value = 'sandbox_workspace_write.writable_roots=[]'
        },
        [pscustomobject]@{
            Key = '-c'
            Value = 'web_search="disabled"'
        },
        [pscustomobject]@{
            Key = '-c'
            Value = 'shell_environment_policy.ignore_default_excludes=false'
        },
        [pscustomobject]@{
            Key = '-c'
            Value = 'features.hooks=false'
        },
        [pscustomobject]@{
            Key = '-c'
            Value = 'apps._default.enabled=false'
        },
        [pscustomobject]@{
            Key = '--disable'
            Value = 'plugins'
        }
    )) {
        Assert-ArgumentPair `
            -Arguments $arguments `
            -Key ([string]$override.Key) `
            -Value ([string]$override.Value)
    }
    Assert-Equal `
        @($arguments | Where-Object { $_ -eq '-c' }).Count `
        7 `
        'exactly seven mandatory config overrides'
    foreach ($forbiddenArgument in @(
        '--ephemeral', '--yolo', '--dangerously-bypass-approvals-and-sandbox',
        'danger-full-access', '--skip-git-repo-check', '--search', '--add-dir',
        '--ignore-rules', '--dangerously-bypass-hook-trust'
    )) {
        Assert-True `
            -Condition ($arguments -notcontains $forbiddenArgument) `
            -Message "Worker CLI 不得包含：$forbiddenArgument"
    }
    $cdIndex = [array]::IndexOf($arguments, '--cd')
    Assert-Equal $arguments[$cdIndex + 1] $project.localPath 'authorized --cd'
    Assert-Equal ([System.IO.File]::ReadAllText($cwdCapture)) $project.localPath 'process cwd'
    $prompt = [System.IO.File]::ReadAllText($stdinCapture)
    Assert-True -Condition $prompt.Contains((ConvertTo-Json $task -Compress)) -Message 'Task JSON encoding'
    Assert-True -Condition $prompt.Contains('普通、可逆的本地工程工作') -Message 'autonomous local-work policy'
    Assert-True -Condition $prompt.Contains('Protected actions') -Message 'protected-action policy'
    Assert-True -Condition $prompt.Contains('不得 revert unrelated user work') -Message 'no unrelated revert'
    Assert-True -Condition $prompt.Contains('.git metadata') -Message 'Git metadata protected policy'
    Assert-True -Condition $prompt.Contains('如果 Task 要求 commit') -Message 'commit needs_input policy'
    Assert-True `
        -Condition (-not $prompt.Contains('只有 Task 明确要求本地 commit 时才允许')) `
        -Message 'explicit Task must not permit local commit'
    Assert-True `
        -Condition $prompt.Contains('显式授权不能扩大 sandbox') `
        -Message 'authorization cannot expand runtime sandbox'
    $schema = ConvertFrom-Json ([System.IO.File]::ReadAllText($schemaCapture))
    $schemaBytes = [System.IO.File]::ReadAllBytes($schemaCapture)
    Assert-Equal $schema.additionalProperties $false 'schema additionalProperties=false'
    Assert-Equal $schema.required.Count 5 'schema required count'
    Assert-Equal (($schema.required) -join ',') 'status,report,question,context,options' 'schema required exact'
    Assert-Equal `
        (($schema.properties.PSObject.Properties.Name) -join ',') `
        'status,report,question,context,options' `
        'schema properties exact'
    Assert-Equal (($schema.properties.status.enum) -join ',') 'completed,needs_input' 'schema status enum exact'
    Assert-True `
        -Condition (-not (
            $schemaBytes.Length -ge 3 -and $schemaBytes[0] -eq 239 -and
            $schemaBytes[1] -eq 187 -and $schemaBytes[2] -eq 191
        )) `
        -Message 'temporary schema UTF-8 no BOM'
    Write-Host "PASS 19/$testCount：cmd wrapper / CLI safety / prompt / schema"
    $passed++

    # 20. Malformed final JSON is a stable failed result with cleanup.
    Set-FakeCodexBehavior -Events $defaultEvents -FinalJson '{bad'
    $before = Get-WorkerTempArtifacts
    $result = Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case
    Assert-Equal $result.status 'failed' 'malformed final status'
    Assert-Equal $result.exitCode 0 'malformed final exit code'
    Assert-True `
        -Condition (-not [string]::IsNullOrWhiteSpace($result.diagnostic)) `
        -Message 'malformed final diagnostic'
    Assert-NoNewWorkerTempArtifacts -Before $before -Message 'malformed final cleanup'
    Write-Host "PASS 20/$testCount：malformed final JSON returns failed / cleanup"
    $passed++

    # 21. Missing final result file is failed, never completed.
    Set-FakeCodexBehavior -Events $defaultEvents -SkipFinal $true
    $result = Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case
    Assert-Equal $result.status 'failed' 'missing final failed'
    Assert-True -Condition $result.diagnostic.Contains('未生成 final result file') -Message 'missing final diagnostic'
    Write-Host "PASS 21/$testCount：missing final file returns failed"
    $passed++

    # 22. Invalid completed field combinations are protocol failures.
    foreach ($invalidFinal in @(
        (New-FinalJson -Status 'completed' -Report ''),
        (New-FinalJson -Status 'completed' -Report '完成。' -Question '不应存在'),
        (New-FinalJson -Status 'completed' -Report '完成。' -Context '不应存在'),
        (New-FinalJson -Status 'completed' -Report '完成。' -Options @('不应存在'))
    )) {
        Set-FakeCodexBehavior -Events $defaultEvents -FinalJson $invalidFinal
        $result = Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case
        Assert-Equal $result.status 'failed' 'invalid completed failed'
    }
    Write-Host "PASS 22/$testCount：invalid completed combinations rejected"
    $passed++

    # 23. Invalid needs_input combinations are protocol failures.
    foreach ($invalidFinal in @(
        (New-FinalJson `
            -Status 'needs_input' -Report '' -Question '问题？' `
            -Context '上下文' -Options @('A', 'B')),
        (New-FinalJson `
            -Status 'needs_input' -Report '进度' -Question '' `
            -Context '上下文' -Options @('A', 'B')),
        (New-FinalJson `
            -Status 'needs_input' -Report '进度' -Question '问题？' `
            -Context '' -Options @('A', 'B')),
        (New-FinalJson `
            -Status 'needs_input' -Report '进度' -Question '问题？' `
            -Context '上下文' -Options @('A', 'A'))
    )) {
        Set-FakeCodexBehavior -Events $defaultEvents -FinalJson $invalidFinal
        $result = Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case
        Assert-Equal $result.status 'failed' 'invalid needs_input failed'
    }
    Write-Host "PASS 23/$testCount：invalid needs_input combinations rejected"
    $passed++

    # 24. Missing thread.started is protocol failure.
    Set-FakeCodexBehavior `
        -Events '{"type":"item.completed"}' `
        -FinalJson (New-FinalJson -Status 'completed' -Report '完成。')
    $result = Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case
    Assert-Equal $result.status 'failed' 'missing thread failed'
    Assert-True -Condition $result.diagnostic.Contains('缺少 thread.started') -Message 'missing thread diagnostic'
    Write-Host "PASS 24/$testCount：missing thread.started rejected"
    $passed++

    # 25. Invalid thread UUID is protocol failure.
    Set-FakeCodexBehavior `
        -Events '{"type":"thread.started","thread_id":"not-a-uuid"}' `
        -FinalJson (New-FinalJson -Status 'completed' -Report '完成。')
    $result = Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case
    Assert-Equal $result.status 'failed' 'invalid UUID failed'
    Assert-True -Condition $result.diagnostic.Contains('不是有效 UUID') -Message 'invalid UUID diagnostic'
    Write-Host "PASS 25/$testCount：invalid thread UUID rejected"
    $passed++

    # 26. Multiple different thread IDs are protocol failure.
    $otherThread = '22222222-2222-4222-8222-222222222222'
    $events = $defaultEvents + [Environment]::NewLine + (
        '{"type":"thread.started","thread_id":"' + $otherThread + '"}'
    )
    Set-FakeCodexBehavior `
        -Events $events `
        -FinalJson (New-FinalJson -Status 'completed' -Report '完成。')
    $result = Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case
    Assert-Equal $result.status 'failed' 'multiple thread IDs failed'
    Assert-True -Condition $result.diagnostic.Contains('多个不同 thread IDs') -Message 'multiple IDs diagnostic'
    Write-Host "PASS 26/$testCount：multiple different thread IDs rejected"
    $passed++

    # 27. Every non-empty JSONL event line must parse as an object.
    Set-FakeCodexBehavior `
        -Events ($defaultEvents + [Environment]::NewLine + '{bad') `
        -FinalJson (New-FinalJson -Status 'completed' -Report '完成。')
    $result = Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case
    Assert-Equal $result.status 'failed' 'malformed JSONL failed'
    Assert-True -Condition $result.diagnostic.Contains('JSONL event 无法解析') -Message 'JSONL diagnostic'
    Write-Host "PASS 27/$testCount：malformed JSONL event rejected"
    $passed++

    # 28. Codex non-zero exit is failed with the actual exit code.
    Set-FakeCodexBehavior `
        -Events $defaultEvents -StandardError 'local build failed' -ExitCode 7 `
        -FinalJson (New-FinalJson -Status 'completed' -Report '不应采用。')
    $before = Get-WorkerTempArtifacts
    $result = Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case
    Assert-Equal $result.status 'failed' 'nonzero status'
    Assert-Equal $result.exitCode 7 'actual nonzero exit code'
    Assert-Equal $result.diagnostic 'local build failed' 'stderr diagnostic'
    Assert-NoNewWorkerTempArtifacts -Before $before -Message 'nonzero cleanup'
    Write-Host "PASS 28/$testCount：non-zero Codex exit returns failed / cleanup"
    $passed++

    # 29. Diagnostics redact obvious credential material and truncate to 2000 chars.
    $secret = 'super-secret-value'
    $stderr = 'token=' + $secret + ' ' + [string]::new([char]120, 2500)
    Set-FakeCodexBehavior -Events $defaultEvents -StandardError $stderr -ExitCode 9
    $result = Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case
    Assert-Equal $result.status 'failed' 'diagnostic failed status'
    Assert-True -Condition (-not $result.diagnostic.Contains($secret)) -Message 'credential redacted'
    Assert-True -Condition ($result.diagnostic.Contains('[REDACTED]')) -Message 'redaction marker'
    Assert-True -Condition ($result.diagnostic.Length -le 2000) -Message 'diagnostic truncated'
    Write-Host "PASS 29/$testCount：diagnostic redaction and truncation"
    $passed++

    # 30. Repeated valid invocations produce deterministic public shape and values.
    Set-FakeCodexBehavior `
        -Events $defaultEvents `
        -FinalJson (New-FinalJson -Status 'completed' -Report '稳定结果。')
    $firstResult = Invoke-TestWorker -Task 'same task' -Repository 'owner/project' -Case $case
    $secondResult = Invoke-TestWorker -Task 'same task' -Repository 'owner/project' -Case $case
    Assert-Equal `
        (ConvertTo-Json -InputObject $firstResult -Depth 10) `
        (ConvertTo-Json -InputObject $secondResult -Depth 10) `
        'deterministic public output'
    Write-Host "PASS 30/$testCount：deterministic public output"
    $passed++

    # 31. Index contract rejects malformed JSON/version/entry fields and missing repository.
    $case = New-TestCase -Parent $testRoot -Name 'index-contract' -CodexCommand $fakeExe
    [System.IO.File]::WriteAllText($case.Index, '{bad', [System.Text.UTF8Encoding]::new($false))
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case } `
        -ExpectedText 'Project Index 不是有效 JSON'
    Write-TestIndex -Path $case.Index -Projects @() -Version 2
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case } `
        -ExpectedText 'version 必须是整数 1'
    $missingRepository = [pscustomobject][ordered]@{
        name = 'project'
        localPath = (Join-Path $case.Workspace 'project')
    }
    Write-TestIndex -Path $case.Index -Projects @($missingRepository)
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case } `
        -ExpectedText '缺少必需字段：githubRepository'
    Write-TestIndex -Path $case.Index -Projects @(
        (New-TestProject -Name 'project' -LocalPath @('bad') -Repository $null)
    )
    Assert-WorkerError `
        -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case } `
        -ExpectedText 'localPath 必须是非空字符串'
    Write-Host "PASS 31/$testCount：Project Index structural contract enforced"
    $passed++

    # 32. Index reparse is rejected when the environment permits a file symlink.
    $case = New-TestCase -Parent $testRoot -Name 'index-reparse' -CodexCommand $fakeExe
    $targetIndex = Join-Path $case.Root 'target-index.json'
    Write-TestIndex -Path $targetIndex -Projects @()
    $linkCreated = $false
    try {
        [void](New-Item `
            -ItemType SymbolicLink -Path $case.Index -Target $targetIndex -ErrorAction Stop)
        $linkCreated = $true
    }
    catch {
        # Developer Mode may be required; candidate junction test covers the same helper principle.
    }
    if ($linkCreated) {
        Assert-WorkerError `
            -Action { Invoke-TestWorker -Task 'task' -Repository 'owner/project' -Case $case } `
            -ExpectedText 'Project Index 不能是符号链接'
    }
    Write-Host "PASS 32/$testCount：Project Index reparse safety"
    $passed++

    # 33. A post-start stdin transport failure returns failed and cleans Worker temp artifacts.
    $case = New-TestCase -Parent $testRoot -Name 'transport-failure' -CodexCommand $fakeExe
    $project = New-TestGitProject `
        -Case $case -RelativePath 'project' -Name 'project' `
        -Repository 'owner/project' -GitPath $gitPath
    Write-TestIndex -Path $case.Index -Projects @($project)
    Set-FakeCodexBehavior `
        -Events $defaultEvents `
        -FinalJson (New-FinalJson -Status 'completed' -Report '不会采用。') `
        -SkipStandardInputRead $true
    $before = Get-WorkerTempArtifacts
    $largeTask = [string]::new([char]120, 4 * 1024 * 1024)
    $result = Invoke-TestWorker -Task $largeTask -Repository 'owner/project' -Case $case
    Assert-Equal $result.status 'failed' 'transport failure status'
    Assert-True `
        -Condition (-not [string]::IsNullOrWhiteSpace($result.diagnostic)) `
        -Message 'transport failure diagnostic'
    Assert-NoNewWorkerTempArtifacts -Before $before -Message 'transport failure cleanup'
    Write-Host "PASS 33/$testCount：post-start transport failure / async I/O / cleanup"
    $passed++

    # 34. Public docs state all mandatory runtime boundaries and Git capability limits.
    $docs = [System.IO.File]::ReadAllText($workerDocs)
    foreach ($requiredDocumentation in @(
        'sandbox_workspace_write.network_access=false',
        'sandbox_workspace_write.writable_roots=[]',
        'web_search="disabled"',
        'shell_environment_policy.ignore_default_excludes=false',
        '.git` metadata 保持 protected read-only',
        '显式授权不能打开网络、增加 writable root、解除 `.git` protection'
    )) {
        Assert-True `
            -Condition $docs.Contains($requiredDocumentation) `
            -Message "Worker docs 缺少安全合同：$requiredDocumentation"
    }
    Write-Host "PASS 34/$testCount：documented runtime sandbox / network / Git boundaries"
    $passed++

    # 35. Unattended extension isolation uses exact one-shot arguments and safe TOML path encoding.
    $case = New-TestCase `
        -Parent $testRoot -Name 'extension isolation' -CodexCommand $fakeExe
    $project = New-TestGitProject `
        -Case $case -RelativePath "project with spaces's quote" `
        -Name 'quoted project' -Repository 'owner/quoted-project' -GitPath $gitPath
    Write-TestIndex -Path $case.Index -Projects @($project)
    $argsCapture = Join-Path $case.Root 'args.txt'
    Set-FakeCodexBehavior `
        -Events $defaultEvents `
        -FinalJson (New-FinalJson -Status 'completed' -Report '完成。') `
        -ArgumentsCapture $argsCapture
    $result = Invoke-TestWorker `
        -Task '验证 unattended isolation' `
        -Repository 'owner/quoted-project' `
        -Case $case
    Assert-Equal $result.status 'completed' 'extension isolation invocation status'
    $arguments = @(Get-Content -LiteralPath $argsCapture -Encoding UTF8)
    Assert-Equal `
        @($arguments | Where-Object { $_ -eq '--ignore-user-config' }).Count `
        1 `
        '--ignore-user-config exact count'
    Assert-ArgumentPair -Arguments $arguments -Key '-c' -Value 'features.hooks=false'
    Assert-ArgumentPair -Arguments $arguments -Key '-c' -Value 'apps._default.enabled=false'
    Assert-ArgumentPair -Arguments $arguments -Key '--disable' -Value 'plugins'
    Assert-Equal `
        @($arguments | Where-Object { $_ -eq '--disable' }).Count `
        1 `
        '--disable exact count'
    $encodedProjectPath = $project.localPath.Replace('\', '\\').Replace('"', '\"')
    $expectedTrustOverride = (
        'projects."' + $encodedProjectPath + '".trust_level="untrusted"'
    )
    Assert-ArgumentPair `
        -Arguments $arguments -Key '-c' -Value $expectedTrustOverride
    Assert-True `
        -Condition ($expectedTrustOverride -match (
            '^projects\."(?:[^"\\]|\\["\\btnfr]|\\u[0-9A-F]{4})*"' +
            '\.trust_level="untrusted"$'
        )) `
        -Message 'project trust override must be a single TOML quoted dotted-key assignment'
    Assert-Equal `
        @($arguments | Where-Object { $_ -eq '-c' }).Count `
        7 `
        'all seven config overrides remain present'
    $execIndex = [array]::IndexOf($arguments, 'exec')
    $ignoreUserConfigIndex = [array]::IndexOf($arguments, '--ignore-user-config')
    Assert-True `
        -Condition ($execIndex -ge 0 -and $ignoreUserConfigIndex -gt $execIndex) `
        -Message '--ignore-user-config must be parsed as a codex exec option'
    Assert-True `
        -Condition ($arguments -notcontains '--dangerously-bypass-hook-trust') `
        -Message 'hook trust bypass must remain forbidden'
    Write-Host "PASS 35/$testCount：user/project/hooks/apps/plugins one-shot isolation / TOML encoding"
    $passed++

    # 36. A hostile fake CODEX_HOME config cannot alter the captured Worker security invocation.
    $case = New-TestCase `
        -Parent $testRoot -Name 'hostile user config' -CodexCommand $fakeExe
    $project = New-TestGitProject `
        -Case $case -RelativePath 'project' -Name 'project' `
        -Repository 'owner/hostile-config' -GitPath $gitPath
    Write-TestIndex -Path $case.Index -Projects @($project)
    $fakeCodeHome = Join-Path $case.Root 'fake CODEX_HOME'
    [void](New-Item -ItemType Directory -Path $fakeCodeHome)
    [System.IO.File]::WriteAllText(
        (Join-Path $fakeCodeHome 'config.toml'),
        @'
sandbox_mode = "danger-full-access"
web_search = "live"

[sandbox_workspace_write]
writable_roots = ["C:\\hostile"]
network_access = true

[features]
hooks = true
plugins = true

[apps._default]
enabled = true

[mcp_servers.hostile]
command = "hostile-mcp.exe"
'@,
        [System.Text.UTF8Encoding]::new($false)
    )
    $argsCapture = Join-Path $case.Root 'args.txt'
    $previousCodeHome = [Environment]::GetEnvironmentVariable('CODEX_HOME')
    try {
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $fakeCodeHome)
        Set-FakeCodexBehavior `
            -Events $defaultEvents `
            -FinalJson (New-FinalJson -Status 'completed' -Report '完成。') `
            -ArgumentsCapture $argsCapture
        $result = Invoke-TestWorker `
            -Task '验证 hostile user config isolation' `
            -Repository 'owner/hostile-config' `
            -Case $case
    }
    finally {
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $previousCodeHome)
    }
    Assert-Equal $result.status 'completed' 'hostile user config invocation status'
    $arguments = @(Get-Content -LiteralPath $argsCapture -Encoding UTF8)
    foreach ($securityOverride in @(
        'sandbox_workspace_write.writable_roots=[]',
        'sandbox_workspace_write.network_access=false',
        'web_search="disabled"',
        'shell_environment_policy.ignore_default_excludes=false',
        'features.hooks=false',
        'apps._default.enabled=false'
    )) {
        Assert-ArgumentPair -Arguments $arguments -Key '-c' -Value $securityOverride
    }
    Assert-Equal `
        @($arguments | Where-Object { $_ -eq '--ignore-user-config' }).Count `
        1 `
        'hostile config still receives one --ignore-user-config'
    Assert-ArgumentPair -Arguments $arguments -Key '--disable' -Value 'plugins'
    Assert-True `
        -Condition ($arguments -notcontains 'danger-full-access') `
        -Message 'hostile user sandbox must not enter Worker invocation'
    Assert-True `
        -Condition ($arguments -notcontains '--search') `
        -Message 'hostile user web search must not enter Worker invocation'
    Write-Host "PASS 36/$testCount：hostile fake user config cannot alter security invocation"
    $passed++

    # 37. Docs describe unattended extension isolation and the normal AGENTS.md boundary.
    $docs = [System.IO.File]::ReadAllText($workerDocs)
    foreach ($requiredDocumentation in @(
        '--ignore-user-config',
        'projects."<exact-authorized-project-root>".trust_level="untrusted"',
        'features.hooks=false',
        'apps._default.enabled=false',
        '--disable plugins',
        'user/project configured MCP servers',
        '`AGENTS.md` 仍作为普通 project engineering context 加载',
        'external control plane',
        'deliberate tradeoff'
    )) {
        Assert-True `
            -Condition $docs.Contains($requiredDocumentation) `
            -Message "Worker docs 缺少 unattended isolation 合同：$requiredDocumentation"
    }
    Write-Host "PASS 37/$testCount：documented unattended extension isolation boundary"
    $passed++

    Write-Host "全部 Worker 测试通过（$passed/$testCount）。"
}
finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name])
    }

    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        $tempRootPrefix = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::GetTempPath()
        ).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if (-not $resolvedTestRoot.StartsWith(
            $tempRootPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw "拒绝清理不在系统 temp 下的测试目录：$resolvedTestRoot"
        }
        for ($attempt = 0; $attempt -lt 100; $attempt++) {
            try {
                Remove-Item `
                    -LiteralPath $resolvedTestRoot `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop
                break
            }
            catch {
                if ($attempt -eq 99) {
                    throw
                }
                Start-Sleep -Milliseconds 100
            }
        }
    }
}
