[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [Alias('Path')]
    [string]$ConfigPath,

    [Parameter()]
    [AllowEmptyString()]
    [string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$MaxTrackedPathsPerProject = 5000
$MaxTokensPerProject = 4096
$MinTokenLength = 2
$MaxTokenLength = 128

function New-ProjectIndexError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    throw [System.InvalidOperationException]::new(
        "Codex Dispatch 项目索引错误：$Message"
    )
}

function Test-CodexDispatchIndexPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Candidate,

        [Parameter()]
        [switch]$AllowRoot
    )

    try {
        $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
        $normalizedCandidate = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
    }
    catch {
        return $false
    }

    if ($AllowRoot -and [string]::Equals(
        $normalizedRoot,
        $normalizedCandidate,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        return $true
    }

    $rootPrefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    return $normalizedCandidate.StartsWith(
        $rootPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Test-CodexDispatchIndexReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item
    )

    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-CodexDispatchIndexPathChainSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Candidate
    )

    if (-not (Test-CodexDispatchIndexPathWithinRoot `
        -Root $Root `
        -Candidate $Candidate `
        -AllowRoot
    )) {
        return $false
    }

    try {
        $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
        $normalizedCandidate = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
        $currentPath = $normalizedRoot
        $currentItem = Get-Item -Force -LiteralPath $currentPath
        if (Test-CodexDispatchIndexReparsePoint -Item $currentItem) {
            return $false
        }

        if ([string]::Equals(
            $normalizedRoot,
            $normalizedCandidate,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            return $true
        }

        $relativePath = $normalizedCandidate.Substring($normalizedRoot.Length).TrimStart('\', '/')
        foreach ($segment in $relativePath.Split(@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $currentPath = Join-Path -Path $currentPath -ChildPath $segment
            $currentItem = Get-Item -Force -LiteralPath $currentPath
            if (Test-CodexDispatchIndexReparsePoint -Item $currentItem) {
                return $false
            }
        }
    }
    catch {
        return $false
    }

    return $true
}

function Get-CodexDispatchIndexOutputPath {
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$RequestedPath
    )

    $candidate = if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        Join-Path -Path (Get-Location).Path -ChildPath 'project-index.json'
    }
    else {
        [Environment]::ExpandEnvironmentVariables($RequestedPath.Trim())
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($candidate)
    }
    catch {
        New-ProjectIndexError "OutputPath 无效：$candidate。"
    }

    $existing = Get-Item -Force -LiteralPath $fullPath -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        if ($existing -is [System.IO.DirectoryInfo]) {
            New-ProjectIndexError "OutputPath 必须是文件路径，不能是目录：$fullPath。"
        }
        if (Test-CodexDispatchIndexReparsePoint -Item $existing) {
            New-ProjectIndexError 'OutputPath 已存在且是 reparse point，拒绝写入。'
        }
    }

    $parentPath = [System.IO.Path]::GetDirectoryName($fullPath)
    if (
        [string]::IsNullOrWhiteSpace($parentPath) -or
        -not (Test-Path -LiteralPath $parentPath -PathType Container)
    ) {
        New-ProjectIndexError "OutputPath 的父目录不存在：$parentPath。"
    }

    $parentItem = Get-Item -Force -LiteralPath $parentPath
    if (Test-CodexDispatchIndexReparsePoint -Item $parentItem) {
        New-ProjectIndexError 'OutputPath 的父目录不能是 reparse point。'
    }

    return $fullPath
}

function Invoke-CodexDispatchIndexGit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(
            & $GitExecutable --no-optional-locks -C $RepositoryPath @Arguments 2>$null
        )
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Add-CodexDispatchIndexToken {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$Set,

        [Parameter()]
        [AllowNull()]
        [string]$Value
    )

    if ($Set.Count -ge $MaxTokensPerProject) {
        return
    }
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    $token = $Value.Trim().ToLowerInvariant()
    if ($token.Length -lt $MinTokenLength -or $token.Length -gt $MaxTokenLength) {
        return
    }
    if ($token.IndexOfAny([char[]]@("`0", "`r", "`n", "`t")) -ge 0) {
        return
    }

    [void]$Set.Add($token)
}

function Add-CodexDispatchIndexIdentityTokens {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$Set,

        [Parameter(Mandatory = $true)]
        [object]$Project
    )

    Add-CodexDispatchIndexToken -Set $Set -Value ([string]$Project.name)

    $repositoryProperty = $Project.PSObject.Properties['githubRepository']
    if ($null -ne $repositoryProperty -and -not [string]::IsNullOrWhiteSpace([string]$repositoryProperty.Value)) {
        $repository = ([string]$repositoryProperty.Value).Trim()
        Add-CodexDispatchIndexToken -Set $Set -Value $repository
        foreach ($segment in $repository.Split('/')) {
            Add-CodexDispatchIndexToken -Set $Set -Value $segment
        }
    }
}

function Add-CodexDispatchIndexTrackedPathTokens {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$Set,

        [Parameter(Mandatory = $true)]
        [string]$TrackedPath
    )

    if ([string]::IsNullOrWhiteSpace($TrackedPath)) {
        return
    }

    $normalized = $TrackedPath.Replace('\', '/')
    foreach ($segment in $normalized.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }

        Add-CodexDispatchIndexToken -Set $Set -Value $segment
        try {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($segment)
            if (-not [string]::Equals($stem, $segment, [System.StringComparison]::OrdinalIgnoreCase)) {
                Add-CodexDispatchIndexToken -Set $Set -Value $stem
            }
        }
        catch {
            # Ignore a malformed path segment; Git path remains local and no file content is read.
        }
    }
}

function New-CodexDispatchIndexProject {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Project,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory = $true)]
        [string]$GitExecutable
    )

    $localPath = [string]$Project.localPath
    if ([string]::IsNullOrWhiteSpace($localPath)) {
        return $null
    }

    try {
        $localPath = [System.IO.Path]::GetFullPath($localPath)
    }
    catch {
        return $null
    }

    if (-not (Test-CodexDispatchIndexPathWithinRoot `
        -Root $WorkspaceRoot `
        -Candidate $localPath
    )) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $localPath -PathType Container)) {
        return $null
    }
    if (-not (Test-CodexDispatchIndexPathChainSafe `
        -Root $WorkspaceRoot `
        -Candidate $localPath
    )) {
        return $null
    }

    $rootResult = Invoke-CodexDispatchIndexGit `
        -GitExecutable $GitExecutable `
        -RepositoryPath $localPath `
        -Arguments @('rev-parse', '--show-toplevel')
    if ($rootResult.ExitCode -ne 0 -or $rootResult.Output.Count -eq 0) {
        return $null
    }

    try {
        $gitRoot = [System.IO.Path]::GetFullPath(([string]$rootResult.Output[-1]).Trim())
    }
    catch {
        return $null
    }
    if (-not [string]::Equals(
        $gitRoot.TrimEnd('\', '/'),
        $localPath.TrimEnd('\', '/'),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        return $null
    }

    $trackedResult = Invoke-CodexDispatchIndexGit `
        -GitExecutable $GitExecutable `
        -RepositoryPath $localPath `
        -Arguments @('-c', 'core.quotepath=false', 'ls-files')
    if ($trackedResult.ExitCode -ne 0) {
        return $null
    }

    $trackedPaths = @(
        $trackedResult.Output |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object
    )
    $trackedPathCount = $trackedPaths.Count
    $indexedTrackedPaths = @($trackedPaths | Select-Object -First $MaxTrackedPathsPerProject)

    $tokens = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    Add-CodexDispatchIndexIdentityTokens -Set $tokens -Project $Project
    foreach ($trackedPath in $indexedTrackedPaths) {
        if ($tokens.Count -ge $MaxTokensPerProject) {
            break
        }
        Add-CodexDispatchIndexTrackedPathTokens -Set $tokens -TrackedPath $trackedPath
    }

    $sortedTokens = @($tokens | Sort-Object)
    $repository = $null
    $repositoryProperty = $Project.PSObject.Properties['githubRepository']
    if ($null -ne $repositoryProperty -and -not [string]::IsNullOrWhiteSpace([string]$repositoryProperty.Value)) {
        $repository = ([string]$repositoryProperty.Value).Trim()
    }

    return [pscustomobject][ordered]@{
        name = [string]$Project.name
        localPath = $localPath
        githubRepository = $repository
        tokens = [object[]]$sortedTokens
        trackedPathCount = [int]$trackedPathCount
        indexedTrackedPathCount = [int]$indexedTrackedPaths.Count
        truncated = [bool]($trackedPathCount -gt $indexedTrackedPaths.Count -or $tokens.Count -ge $MaxTokensPerProject)
    }
}

$loaderPath = Join-Path $PSScriptRoot 'Load-CodexDispatchConfig.ps1'
$discoveryPath = Join-Path $PSScriptRoot 'Discover-CodexProjects.ps1'
foreach ($requiredPath in @($loaderPath, $discoveryPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        New-ProjectIndexError "找不到必需脚本：$requiredPath。"
    }
}

$config = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    & $loaderPath
}
else {
    & $loaderPath -Path $ConfigPath
}

$workspaceRoot = [System.IO.Path]::GetFullPath([string]$config.workspace.root)
$workspaceRootItem = Get-Item -Force -LiteralPath $workspaceRoot
if (Test-CodexDispatchIndexReparsePoint -Item $workspaceRootItem) {
    New-ProjectIndexError 'workspace.root 是 reparse point，v0.1 无法保证索引边界。'
}

$gitCommand = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $gitCommand) {
    New-ProjectIndexError '找不到 git 可执行文件，请先安装 Git 并加入 PATH。'
}

$resolvedOutputPath = Get-CodexDispatchIndexOutputPath -RequestedPath $OutputPath
$discovered = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    @(& $discoveryPath)
}
else {
    @(& $discoveryPath -ConfigPath $ConfigPath)
}

$validProjects = @(
    $discovered |
        Where-Object { $_.status -eq 'ok' } |
        Sort-Object `
            @{ Expression = { ([string]$_.name).ToLowerInvariant() } }, `
            @{ Expression = { ([string]$_.localPath).ToLowerInvariant() } }
)

$indexedProjects = New-Object 'System.Collections.Generic.List[object]'
foreach ($project in $validProjects) {
    $indexed = New-CodexDispatchIndexProject `
        -Project $project `
        -WorkspaceRoot $workspaceRoot `
        -GitExecutable $gitCommand.Source
    if ($null -ne $indexed) {
        [void]$indexedProjects.Add($indexed)
    }
}

$document = [pscustomobject][ordered]@{
    version = 1
    projects = [object[]]@($indexedProjects)
}

try {
    $json = ConvertTo-Json -InputObject $document -Depth 8
    [System.IO.File]::WriteAllText(
        $resolvedOutputPath,
        $json + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}
catch {
    New-ProjectIndexError "无法写入 OutputPath：$resolvedOutputPath。"
}

$document
