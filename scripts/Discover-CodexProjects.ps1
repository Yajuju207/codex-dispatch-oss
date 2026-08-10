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

function New-ProjectDiscoveryError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    throw [System.InvalidOperationException]::new(
        "Codex Dispatch 项目发现错误：$Message"
    )
}

function Test-CodexDispatchPathWithinRoot {
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

function Test-CodexDispatchReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item
    )

    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-CodexDispatchExistingPathReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $item = Get-Item -Force -LiteralPath $Path -ErrorAction SilentlyContinue
    return ($null -ne $item -and (Test-CodexDispatchReparsePoint -Item $item))
}

function Test-CodexDispatchPathChainSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Candidate
    )

    if (-not (Test-CodexDispatchPathWithinRoot `
        -Root $Root `
        -Candidate $Candidate `
        -AllowRoot
    )) {
        return $false
    }

    try {
        $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
        $normalizedCandidate = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
        $currentItem = Get-Item -Force -LiteralPath $normalizedRoot
        if (Test-CodexDispatchReparsePoint -Item $currentItem) {
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
        $currentPath = $normalizedRoot
        foreach ($segment in $relativePath.Split(@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $currentPath = Join-Path -Path $currentPath -ChildPath $segment
            $currentItem = Get-Item -Force -LiteralPath $currentPath
            if (Test-CodexDispatchReparsePoint -Item $currentItem) {
                return $false
            }
        }
    }
    catch {
        return $false
    }

    return $true
}

function Resolve-CodexDispatchGitFileTarget {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$GitFile,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRoot
    )

    if ($GitFile.Length -gt 4096) {
        return [pscustomobject]@{
            Status = 'invalid_git'
            Path = $null
            Reason = '.git 文件超过 v0.1 的安全解析上限。'
        }
    }

    $reader = $null
    try {
        $reader = [System.IO.File]::OpenText($GitFile.FullName)
        $firstLine = $reader.ReadLine()
    }
    catch {
        return [pscustomobject]@{
            Status = 'invalid_git'
            Path = $null
            Reason = '无法读取 .git 文件的 gitdir 声明。'
        }
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }

    $match = [regex]::Match(
        [string]$firstLine,
        '^gitdir:\s*(?<path>\S(?:.*\S)?)\s*$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $match.Success) {
        return [pscustomobject]@{
            Status = 'invalid_git'
            Path = $null
            Reason = '.git 文件不包含可解析的 gitdir 声明。'
        }
    }

    $gitDirectoryText = $match.Groups['path'].Value
    try {
        $gitDirectoryPath = if ([System.IO.Path]::IsPathRooted($gitDirectoryText)) {
            [System.IO.Path]::GetFullPath($gitDirectoryText)
        }
        else {
            [System.IO.Path]::GetFullPath(
                (Join-Path -Path $GitFile.DirectoryName -ChildPath $gitDirectoryText)
            )
        }
    }
    catch {
        return [pscustomobject]@{
            Status = 'invalid_git'
            Path = $null
            Reason = '.git 文件中的 gitdir 路径无效。'
        }
    }

    if (-not (Test-CodexDispatchPathWithinRoot `
        -Root $WorkspaceRoot `
        -Candidate $gitDirectoryPath
    )) {
        return [pscustomobject]@{
            Status = 'unsafe_path'
            Path = $gitDirectoryPath
            Reason = '.git 文件中的 gitdir 越过 workspace.root，未调用 Git。'
        }
    }

    if (-not (Test-Path -LiteralPath $gitDirectoryPath -PathType Container)) {
        return [pscustomobject]@{
            Status = 'invalid_git'
            Path = $gitDirectoryPath
            Reason = '.git 文件中的 gitdir 不存在或不是目录。'
        }
    }

    if (-not (Test-CodexDispatchPathChainSafe `
        -Root $WorkspaceRoot `
        -Candidate $gitDirectoryPath
    )) {
        return [pscustomobject]@{
            Status = 'unsafe_path'
            Path = $gitDirectoryPath
            Reason = '.git 文件中的 gitdir 路径包含不安全 reparse point，未调用 Git。'
        }
    }

    return [pscustomobject]@{
        Status = 'ok'
        Path = $gitDirectoryPath
        Reason = $null
    }
}

function ConvertTo-GitHubRepositoryName {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Origin
    )

    if ([string]::IsNullOrWhiteSpace($Origin)) {
        return $null
    }

    $patterns = @(
        '^(?i:https)://github\.com/(?<owner>[A-Za-z0-9][A-Za-z0-9-]*)/(?<repo>[A-Za-z0-9._-]+?)(?:\.git)?/?$',
        '^git@github\.com:(?<owner>[A-Za-z0-9][A-Za-z0-9-]*)/(?<repo>[A-Za-z0-9._-]+?)(?:\.git)?$',
        '^ssh://git@github\.com/(?<owner>[A-Za-z0-9][A-Za-z0-9-]*)/(?<repo>[A-Za-z0-9._-]+?)(?:\.git)?/?$'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match(
            $Origin.Trim(),
            $pattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($match.Success) {
            return '{0}/{1}' -f (
                $match.Groups['owner'].Value,
                $match.Groups['repo'].Value
            )
        }
    }

    return $null
}

function Protect-CodexDispatchOrigin {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Origin
    )

    if ([string]::IsNullOrWhiteSpace($Origin)) {
        return $null
    }

    $trimmedOrigin = $Origin.Trim()
    $httpMatch = [regex]::Match(
        $trimmedOrigin,
        '^(?<scheme>https?://)(?<authority>[^/?#]*)(?<suffix>.*)$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $httpMatch.Success) {
        return $trimmedOrigin
    }

    $authority = $httpMatch.Groups['authority'].Value
    $userInfoSeparator = $authority.LastIndexOf('@')
    if ($userInfoSeparator -ge 0) {
        $authority = $authority.Substring($userInfoSeparator + 1)
    }

    return $httpMatch.Groups['scheme'].Value +
        $authority +
        $httpMatch.Groups['suffix'].Value
}

function New-ProjectRecord {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.DirectoryInfo]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter()]
        [AllowNull()]
        [string]$GitRoot,

        [Parameter()]
        [AllowNull()]
        [string]$Origin,

        [Parameter()]
        [AllowNull()]
        [string]$GitHubRepository,

        [Parameter()]
        [AllowNull()]
        [string]$Reason
    )

    $recordGitRoot = if ([string]::IsNullOrWhiteSpace($GitRoot)) { $null } else { $GitRoot }
    $recordOrigin = if ([string]::IsNullOrWhiteSpace($Origin)) { $null } else { $Origin }
    $recordRepository = if ([string]::IsNullOrWhiteSpace($GitHubRepository)) {
        $null
    }
    else {
        $GitHubRepository
    }
    $recordReason = if ([string]::IsNullOrWhiteSpace($Reason)) { $null } else { $Reason }

    return [pscustomobject][ordered]@{
        name = $Directory.Name
        localPath = $Directory.FullName
        status = $Status
        gitRoot = $recordGitRoot
        origin = $recordOrigin
        githubRepository = $recordRepository
        reason = $recordReason
    }
}

function Get-ValidatedOutputPath {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RequestedPath
    )

    if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        New-ProjectDiscoveryError 'OutputPath 不能为空。'
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables($RequestedPath.Trim())
        )
    }
    catch {
        New-ProjectDiscoveryError "OutputPath 无效：$RequestedPath。"
    }

    if (Test-CodexDispatchExistingPathReparsePoint -Path $fullPath) {
        New-ProjectDiscoveryError 'OutputPath 已存在且是 reparse point，拒绝写入。'
    }

    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        New-ProjectDiscoveryError "OutputPath 必须是文件路径，不能是目录：$fullPath。"
    }

    $parentPath = [System.IO.Path]::GetDirectoryName($fullPath)
    if (
        [string]::IsNullOrWhiteSpace($parentPath) -or
        -not (Test-Path -LiteralPath $parentPath -PathType Container)
    ) {
        New-ProjectDiscoveryError "OutputPath 的父目录不存在：$parentPath。"
    }

    $parentItem = Get-Item -Force -LiteralPath $parentPath
    if (Test-CodexDispatchReparsePoint -Item $parentItem) {
        New-ProjectDiscoveryError 'OutputPath 的父目录不能是 reparse point。'
    }

    return $fullPath
}

function Invoke-LocalGit {
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
        # Windows PowerShell 5.1 can promote native stderr to an error record.
        # Keep the process exit code authoritative and suppress Git diagnostics.
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

function Invoke-CodexProjectDiscovery {
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$RequestedConfigPath,

        [Parameter()]
        [bool]$WriteJson,

        [Parameter()]
        [AllowEmptyString()]
        [string]$RequestedOutputPath
    )

    $loaderPath = Join-Path $PSScriptRoot 'Load-CodexDispatchConfig.ps1'
    if (-not (Test-Path -LiteralPath $loaderPath -PathType Leaf)) {
        New-ProjectDiscoveryError "找不到配置加载器：$loaderPath。"
    }

    $config = if ([string]::IsNullOrWhiteSpace($RequestedConfigPath)) {
        & $loaderPath
    }
    else {
        & $loaderPath -Path $RequestedConfigPath
    }

    $scanDepthProperty = $config.workspace.PSObject.Properties['scanDepth']
    if ($null -eq $scanDepthProperty) {
        New-ProjectDiscoveryError '缺少必需配置：workspace.scanDepth。'
    }

    $scanDepth = $scanDepthProperty.Value
    if (
        ($scanDepth -isnot [int] -and $scanDepth -isnot [long]) -or
        [long]$scanDepth -lt 1 -or
        [long]$scanDepth -gt 32
    ) {
        New-ProjectDiscoveryError 'workspace.scanDepth 必须是 1 到 32 之间的 JSON 整数。'
    }
    $scanDepth = [int]$scanDepth

    $workspaceRootItem = Get-Item -Force -LiteralPath $config.workspace.root
    if (Test-CodexDispatchReparsePoint -Item $workspaceRootItem) {
        New-ProjectDiscoveryError 'workspace.root 是 reparse point，v0.1 无法保证扫描边界。'
    }

    $workspaceRoot = [System.IO.Path]::GetFullPath($workspaceRootItem.FullName)
    if (-not (Test-CodexDispatchPathWithinRoot `
        -Root $workspaceRoot `
        -Candidate $workspaceRoot `
        -AllowRoot
    )) {
        New-ProjectDiscoveryError 'workspace.root 无法通过规范路径安全检查。'
    }

    $gitCommand = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $gitCommand) {
        New-ProjectDiscoveryError '找不到 git 可执行文件，请先安装 Git 并加入 PATH。'
    }

    $validatedOutputPath = $null
    if ($WriteJson) {
        $validatedOutputPath = Get-ValidatedOutputPath -RequestedPath $RequestedOutputPath
    }

    $records = New-Object 'System.Collections.Generic.List[object]'
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    $queue.Enqueue([pscustomobject]@{
        Directory = $workspaceRootItem
        Depth = 0
    })

    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        try {
            $children = @(
                Get-ChildItem -Force -LiteralPath $parent.Directory.FullName -Directory |
                    Sort-Object -Property Name, FullName
            )
        }
        catch {
            if ($parent.Depth -eq 0) {
                New-ProjectDiscoveryError "无法枚举 workspace.root：$workspaceRoot。"
            }
            Write-Warning "Codex Dispatch 项目发现警告：无法枚举目录，已跳过：$($parent.Directory.FullName)。"
            continue
        }

        foreach ($child in $children) {
            if ([string]::Equals(
                $child.Name,
                '.git',
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                continue
            }

            $childDepth = [int]$parent.Depth + 1
            $childPath = [System.IO.Path]::GetFullPath($child.FullName)

            if (-not (Test-CodexDispatchPathWithinRoot `
                -Root $workspaceRoot `
                -Candidate $childPath
            )) {
                Write-Warning "Codex Dispatch 项目发现警告：目录越过 workspace.root，已跳过：$childPath。"
                continue
            }

            if (Test-CodexDispatchReparsePoint -Item $child) {
                Write-Warning "Codex Dispatch 项目发现警告：reparse point 不会被遍历或识别为项目：$childPath。"
                continue
            }

            $gitMarkerPath = Join-Path $childPath '.git'
            $gitMarker = Get-Item -Force -LiteralPath $gitMarkerPath -ErrorAction SilentlyContinue
            if ($null -ne $gitMarker) {
                if (Test-CodexDispatchReparsePoint -Item $gitMarker) {
                    [void]$records.Add((New-ProjectRecord `
                        -Directory $child `
                        -Status 'unsafe_path' `
                        -Reason '.git 标记是 reparse point，未调用 Git。'
                    ))
                    continue
                }

                if ($gitMarker -is [System.IO.FileInfo]) {
                    $gitFileTarget = Resolve-CodexDispatchGitFileTarget `
                        -GitFile $gitMarker `
                        -WorkspaceRoot $workspaceRoot
                    if ($gitFileTarget.Status -ne 'ok') {
                        [void]$records.Add((New-ProjectRecord `
                            -Directory $child `
                            -Status $gitFileTarget.Status `
                            -Reason $gitFileTarget.Reason
                        ))
                        continue
                    }
                }
                elseif ($gitMarker -isnot [System.IO.DirectoryInfo]) {
                    [void]$records.Add((New-ProjectRecord `
                        -Directory $child `
                        -Status 'invalid_git' `
                        -Reason '.git 标记既不是普通文件也不是目录。'
                    ))
                    continue
                }

                $rootResult = Invoke-LocalGit `
                    -GitExecutable $gitCommand.Source `
                    -RepositoryPath $childPath `
                    -Arguments @('rev-parse', '--show-toplevel')

                if ($rootResult.ExitCode -ne 0 -or $rootResult.Output.Count -eq 0) {
                    [void]$records.Add((New-ProjectRecord `
                        -Directory $child `
                        -Status 'invalid_git' `
                        -Reason '存在 .git 标记，但无法验证为有效 Git 工作树。'
                    ))
                    continue
                }

                try {
                    $gitRoot = [System.IO.Path]::GetFullPath(
                        ([string]$rootResult.Output[-1]).Trim()
                    )
                }
                catch {
                    [void]$records.Add((New-ProjectRecord `
                        -Directory $child `
                        -Status 'invalid_git' `
                        -Reason 'Git 返回了无效的工作树根路径。'
                    ))
                    continue
                }

                if (-not (Test-CodexDispatchPathWithinRoot `
                    -Root $workspaceRoot `
                    -Candidate $gitRoot
                )) {
                    [void]$records.Add((New-ProjectRecord `
                        -Directory $child `
                        -Status 'unsafe_path' `
                        -GitRoot $gitRoot `
                        -Reason 'Git 工作树根目录越过 workspace.root。'
                    ))
                    continue
                }

                if (-not [string]::Equals(
                    $gitRoot.TrimEnd('\', '/'),
                    $childPath.TrimEnd('\', '/'),
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                    [void]$records.Add((New-ProjectRecord `
                        -Directory $child `
                        -Status 'invalid_git' `
                        -GitRoot $gitRoot `
                        -Reason 'Git 工作树根目录与候选目录不一致。'
                    ))
                    continue
                }

                $originResult = Invoke-LocalGit `
                    -GitExecutable $gitCommand.Source `
                    -RepositoryPath $childPath `
                    -Arguments @('remote', 'get-url', 'origin')
                $origin = $null
                if ($originResult.ExitCode -eq 0 -and $originResult.Output.Count -gt 0) {
                    $origin = Protect-CodexDispatchOrigin `
                        -Origin ([string]$originResult.Output[-1])
                }

                [void]$records.Add((New-ProjectRecord `
                    -Directory $child `
                    -Status 'ok' `
                    -GitRoot $gitRoot `
                    -Origin $origin `
                    -GitHubRepository (ConvertTo-GitHubRepositoryName -Origin $origin) `
                    -Reason $null
                ))
                continue
            }

            if ($childDepth -lt $scanDepth) {
                $queue.Enqueue([pscustomobject]@{
                    Directory = $child
                    Depth = $childDepth
                })
            }
        }
    }

    $sortedRecords = @(
        $records |
            Sort-Object `
                @{ Expression = { $_.name.ToLowerInvariant() } }, `
                @{ Expression = { $_.localPath.ToLowerInvariant() } }
    )

    if ($WriteJson) {
        try {
            $json = ConvertTo-Json -InputObject ([object[]]$sortedRecords) -Depth 6
            [System.IO.File]::WriteAllText(
                $validatedOutputPath,
                $json + [Environment]::NewLine,
                [System.Text.UTF8Encoding]::new($false)
            )
        }
        catch {
            New-ProjectDiscoveryError "无法写入 OutputPath：$validatedOutputPath。"
        }
    }

    return $sortedRecords
}

# Dot-sourcing is supported for direct unit testing of the path-safety helper.
if ($MyInvocation.InvocationName -eq '.') {
    return
}

Invoke-CodexProjectDiscovery `
    -RequestedConfigPath $ConfigPath `
    -WriteJson $PSBoundParameters.ContainsKey('OutputPath') `
    -RequestedOutputPath $OutputPath
