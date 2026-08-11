[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [Alias('ConfigPath')]
    [string]$Path
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-ConfigurationError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    throw [System.InvalidOperationException]::new("Codex Dispatch 配置错误：$Message")
}

function Copy-ConfigurationSection {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Section
    )

    $copy = [ordered]@{}
    foreach ($property in $Section.PSObject.Properties) {
        $copy[$property.Name] = $property.Value
    }

    return [pscustomobject]$copy
}

function Get-ConfigurationFilePath {
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$RequestedPath
    )

    $candidate = if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        Join-Path -Path (Get-Location).Path -ChildPath 'config.local.json'
    }
    else {
        [Environment]::ExpandEnvironmentVariables($RequestedPath.Trim())
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($candidate)
    }
    catch {
        New-ConfigurationError "配置路径无效：$candidate。$($_.Exception.Message)"
    }

    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        $fullPath = Join-Path -Path $fullPath -ChildPath 'config.local.json'
    }

    $leafName = [System.IO.Path]::GetFileName($fullPath)
    if ([string]::Equals(
        $leafName,
        'config.example.json',
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        New-ConfigurationError 'config.example.json 只能作为模板，不能直接作为运行配置。请复制为 config.local.json 并填写本机值。'
    }

    $sensitiveNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in @(
        '.runner', '.runner_migrated', '.credentials', '.credentials_rsaparams',
        '.service', '.env', 'auth.json'
    )) {
        [void]$sensitiveNames.Add($name)
    }

    if (
        $sensitiveNames.Contains($leafName) -or
        $leafName -like '.credentials*' -or
        $leafName -like '.env*' -or
        $leafName -like '*.token' -or
        $leafName -like '*.secret'
    ) {
        New-ConfigurationError "拒绝加载敏感身份或凭据文件：$leafName。"
    }

    if (-not [string]::Equals(
        $leafName,
        'config.local.json',
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        New-ConfigurationError "只允许加载名为 config.local.json 的运行配置，当前文件为：$leafName。"
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $directory = [System.IO.Path]::GetDirectoryName($fullPath)
        $template = Join-Path -Path $directory -ChildPath 'config.example.json'
        $hint = if (Test-Path -LiteralPath $template -PathType Leaf) {
            '请复制同目录的 config.example.json 为 config.local.json，并替换所有占位值。'
        }
        else {
            '请先创建 config.local.json；可从仓库根目录的 config.example.json 复制模板。'
        }
        New-ConfigurationError "找不到配置文件：$fullPath。$hint"
    }

    $item = Get-Item -Force -LiteralPath $fullPath
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        New-ConfigurationError 'config.local.json 不能是符号链接、junction 或其他 reparse point，以免绕过敏感文件检查。'
    }

    return $item.FullName
}

function Get-RequiredConfigurationSection {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Document,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $Document.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        New-ConfigurationError "缺少必需配置节：$Name。"
    }

    $value = $property.Value
    if (
        $value -is [string] -or
        $value -is [System.Array] -or
        $value -is [System.ValueType]
    ) {
        New-ConfigurationError "配置节 $Name 必须是 JSON 对象。"
    }

    return $value
}

function Get-SafeConfigurationDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    if (-not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) {
        New-ConfigurationError "$Context 不存在或不是目录：$DirectoryPath。"
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($DirectoryPath)
        $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
        if ([string]::IsNullOrWhiteSpace($pathRoot)) {
            New-ConfigurationError "$Context 路径缺少 volume/root：$fullPath。"
        }

        $currentPath = $pathRoot
        $currentItem = Get-Item -Force -LiteralPath $currentPath
        if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            New-ConfigurationError "$Context 的路径链包含 reparse point：$currentPath。"
        }

        $relativePath = $fullPath.Substring($pathRoot.Length)
        foreach ($segment in $relativePath.Split(
            @('\', '/'),
            [System.StringSplitOptions]::RemoveEmptyEntries
        )) {
            $currentPath = Join-Path -Path $currentPath -ChildPath $segment
            $currentItem = Get-Item -Force -LiteralPath $currentPath
            if (-not $currentItem.PSIsContainer) {
                New-ConfigurationError "$Context 的路径链包含非目录：$currentPath。"
            }
            if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                New-ConfigurationError "$Context 的路径链包含 reparse point：$currentPath。"
            }
        }

        return (Get-Item -Force -LiteralPath $fullPath)
    }
    catch {
        if ($_.Exception.Message.StartsWith(
            'Codex Dispatch 配置错误：',
            [System.StringComparison]::Ordinal
        )) {
            throw
        }
        New-ConfigurationError "$Context 安全检查失败：$DirectoryPath。$($_.Exception.Message)"
    }
}

function Test-ConfigurationPathDescendant {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CandidatePath,

        [Parameter(Mandatory = $true)]
        [string]$ParentPath
    )

    $candidate = [System.IO.Path]::GetFullPath($CandidatePath).TrimEnd('\', '/')
    $parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\', '/')
    $parentPrefix = $parent + [System.IO.Path]::DirectorySeparatorChar
    return $candidate.StartsWith(
        $parentPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Assert-ConfigurationDirectoryOutsideGitWorkingTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath
    )

    try {
        $currentPath = [System.IO.Path]::GetFullPath($DirectoryPath)
        while ($true) {
            $gitMarker = Join-Path -Path $currentPath -ChildPath '.git'
            if (Test-Path -LiteralPath $gitMarker) {
                New-ConfigurationError (
                    'runtime.stateDirectory 不能位于 Git working tree 内，' +
                    '以免本地 dispatch state 被意外纳入版本控制。'
                )
            }

            $parent = [System.IO.Directory]::GetParent($currentPath)
            if ($null -eq $parent) {
                break
            }
            $currentPath = $parent.FullName
        }
    }
    catch {
        if ($_.Exception.Message.StartsWith(
            'Codex Dispatch 配置错误：',
            [System.StringComparison]::Ordinal
        )) {
            throw
        }
        New-ConfigurationError (
            'runtime.stateDirectory Git working tree 安全检查失败：' +
            "$DirectoryPath。$($_.Exception.Message)"
        )
    }
}

$configFile = Get-ConfigurationFilePath -RequestedPath $Path

try {
    $jsonText = [System.IO.File]::ReadAllText(
        $configFile,
        [System.Text.UTF8Encoding]::new($false)
    )
}
catch {
    New-ConfigurationError "无法读取配置文件 $configFile。$($_.Exception.Message)"
}

try {
    $document = ConvertFrom-Json -InputObject $jsonText
}
catch {
    New-ConfigurationError "config.local.json 不是有效 JSON。$($_.Exception.Message)"
}

if ($null -eq $document -or $document -is [System.Array]) {
    New-ConfigurationError 'config.local.json 的顶层必须是 JSON 对象。'
}

$versionProperty = $document.PSObject.Properties['version']
if ($null -ne $versionProperty) {
    $parsedVersion = 0
    $versionText = ([string]$versionProperty.Value).Trim()
    if (
        $versionProperty.Value -is [bool] -or
        -not [int]::TryParse($versionText, [ref]$parsedVersion)
    ) {
        New-ConfigurationError "version 必须是整数 1，当前值为：$($versionProperty.Value)。"
    }
    if ($parsedVersion -ne 1) {
        New-ConfigurationError "不支持配置版本 $($versionProperty.Value)；当前仅支持 version=1。"
    }
}

$workspace = Copy-ConfigurationSection (
    Get-RequiredConfigurationSection -Document $document -Name 'workspace'
)
$runtime = Copy-ConfigurationSection (
    Get-RequiredConfigurationSection -Document $document -Name 'runtime'
)
$controlPlane = Copy-ConfigurationSection (
    Get-RequiredConfigurationSection -Document $document -Name 'controlPlane'
)
$routing = Copy-ConfigurationSection (
    Get-RequiredConfigurationSection -Document $document -Name 'routing'
)
$codex = Copy-ConfigurationSection (
    Get-RequiredConfigurationSection -Document $document -Name 'codex'
)
$privacy = Copy-ConfigurationSection (
    Get-RequiredConfigurationSection -Document $document -Name 'privacy'
)
$safety = Copy-ConfigurationSection (
    Get-RequiredConfigurationSection -Document $document -Name 'safety'
)

$workspaceRootProperty = $workspace.PSObject.Properties['root']
if (
    $null -eq $workspaceRootProperty -or
    [string]::IsNullOrWhiteSpace([string]$workspaceRootProperty.Value)
) {
    New-ConfigurationError '缺少必需配置：workspace.root。'
}

$workspaceRootText = [Environment]::ExpandEnvironmentVariables(
    ([string]$workspaceRootProperty.Value).Trim()
)
$configDirectory = [System.IO.Path]::GetDirectoryName($configFile)
try {
    $workspaceRoot = if ([System.IO.Path]::IsPathRooted($workspaceRootText)) {
        [System.IO.Path]::GetFullPath($workspaceRootText)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $configDirectory $workspaceRootText))
    }
}
catch {
    New-ConfigurationError "workspace.root 路径无效：$workspaceRootText。$($_.Exception.Message)"
}

if (-not (Test-Path -LiteralPath $workspaceRoot -PathType Container)) {
    New-ConfigurationError "workspace.root 不存在或不是目录：$workspaceRoot。"
}

$workspaceRootItem = Get-Item -Force -LiteralPath $workspaceRoot
$allowReparsePoints = $false
$allowReparseProperty = $workspace.PSObject.Properties['allowReparsePoints']
if ($null -ne $allowReparseProperty) {
    if ($allowReparseProperty.Value -isnot [bool]) {
        New-ConfigurationError 'workspace.allowReparsePoints 必须是 JSON 布尔值。'
    }
    $allowReparsePoints = [bool]$allowReparseProperty.Value
}
if (
    -not $allowReparsePoints -and
    ($workspaceRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
) {
    New-ConfigurationError 'workspace.root 是 reparse point，但 workspace.allowReparsePoints 未启用。'
}
$workspace.root = $workspaceRootItem.FullName

$stateDirectoryProperty = $runtime.PSObject.Properties['stateDirectory']
if (
    $null -eq $stateDirectoryProperty -or
    $stateDirectoryProperty.Value -isnot [string] -or
    [string]::IsNullOrWhiteSpace([string]$stateDirectoryProperty.Value)
) {
    New-ConfigurationError 'runtime.stateDirectory 必须是非空字符串。'
}

$stateDirectoryText = [Environment]::ExpandEnvironmentVariables(
    ([string]$stateDirectoryProperty.Value).Trim()
)
try {
    $stateDirectory = if ([System.IO.Path]::IsPathRooted($stateDirectoryText)) {
        [System.IO.Path]::GetFullPath($stateDirectoryText)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $configDirectory $stateDirectoryText))
    }
}
catch {
    New-ConfigurationError "runtime.stateDirectory 路径无效：$stateDirectoryText。$($_.Exception.Message)"
}

$stateDirectoryItem = Get-SafeConfigurationDirectory `
    -DirectoryPath $stateDirectory `
    -Context 'runtime.stateDirectory'
Assert-ConfigurationDirectoryOutsideGitWorkingTree `
    -DirectoryPath $stateDirectoryItem.FullName
$normalizedWorkspaceRoot = [System.IO.Path]::GetFullPath(
    $workspaceRootItem.FullName
).TrimEnd('\', '/')
$normalizedStateDirectory = [System.IO.Path]::GetFullPath(
    $stateDirectoryItem.FullName
).TrimEnd('\', '/')
if ([string]::Equals(
    $normalizedWorkspaceRoot,
    $normalizedStateDirectory,
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    New-ConfigurationError 'runtime.stateDirectory 不能等于 workspace.root；两者必须位于彼此分离的目录树。'
}
if (Test-ConfigurationPathDescendant `
    -CandidatePath $normalizedStateDirectory `
    -ParentPath $normalizedWorkspaceRoot
) {
    New-ConfigurationError 'runtime.stateDirectory 不能位于 workspace.root 内部。'
}
if (Test-ConfigurationPathDescendant `
    -CandidatePath $normalizedWorkspaceRoot `
    -ParentPath $normalizedStateDirectory
) {
    New-ConfigurationError 'workspace.root 不能位于 runtime.stateDirectory 内部。'
}
$runtime.stateDirectory = $stateDirectoryItem.FullName

$repositoryProperty = $controlPlane.PSObject.Properties['repository']
if (
    $null -eq $repositoryProperty -or
    [string]::IsNullOrWhiteSpace([string]$repositoryProperty.Value)
) {
    New-ConfigurationError '缺少必需配置：controlPlane.repository。'
}

$providerProperty = $controlPlane.PSObject.Properties['provider']
if (
    $null -ne $providerProperty -and
    -not [string]::Equals(
        ([string]$providerProperty.Value).Trim(),
        'github',
        [System.StringComparison]::OrdinalIgnoreCase
    )
) {
    New-ConfigurationError 'v0.1 仅支持 controlPlane.provider=github。'
}

$repository = ([string]$repositoryProperty.Value).Trim()
$repositoryPattern = '^(?<owner>[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/(?<repo>[A-Za-z0-9._-]{1,100})$'
$repositoryMatch = [regex]::Match($repository, $repositoryPattern)
if (
    -not $repositoryMatch.Success -or
    $repositoryMatch.Groups['owner'].Value.Contains('--') -or
    $repositoryMatch.Groups['repo'].Value -in @('.', '..')
) {
    New-ConfigurationError "controlPlane.repository 格式无效：$repository。必须使用 GitHub 的 owner/repository 格式。"
}
$controlPlane.repository = $repository

[pscustomobject][ordered]@{
    workspace = $workspace
    runtime = $runtime
    controlPlane = $controlPlane
    routing = $routing
    codex = $codex
    privacy = $privacy
    safety = $safety
}
