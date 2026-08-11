Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:CodexDispatchStatePropertyOrder = [string[]]@(
    'version', 'dispatchId', 'revision', 'createdAtUtc', 'updatedAtUtc',
    'phase', 'status', 'task', 'projectRepository', 'threadId', 'report',
    'question', 'context', 'options', 'diagnostic'
)

function New-CodexDispatchRuntimeStateError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    throw [System.InvalidOperationException]::new(
        "Codex Dispatch Runtime State 错误：$Message"
    )
}

function ConvertTo-CodexDispatchRuntimeStateError {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $message = [string]$ErrorRecord.Exception.Message
    if ($message.StartsWith(
        'Codex Dispatch Runtime State 错误：',
        [System.StringComparison]::Ordinal
    )) {
        throw $ErrorRecord.Exception
    }
    New-CodexDispatchRuntimeStateError "$Context。$message"
}

function Test-CodexDispatchStateJsonObject {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    return (
        $null -ne $Value -and
        $Value -isnot [string] -and
        $Value -isnot [System.Array] -and
        $Value -isnot [System.ValueType]
    )
}

function Test-CodexDispatchStateInteger {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    return (
        $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
    )
}

function Get-CodexDispatchStateProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = @(
        $State.PSObject.Properties |
            Where-Object { $_.Name -ceq $Name }
    )
    if ($property.Count -ne 1) {
        New-CodexDispatchRuntimeStateError "state 文件缺少必需字段：$Name。"
    }
    if ($property[0].Value -is [System.Array]) {
        Write-Output -NoEnumerate $property[0].Value
        return
    }
    return $property[0].Value
}

function ConvertTo-CodexDispatchCanonicalGuid {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        New-CodexDispatchRuntimeStateError "$Context 无效：必须是 UUID D 格式字符串。"
    }
    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact([string]$Value, 'D', [ref]$parsed)) {
        New-CodexDispatchRuntimeStateError "$Context 无效：$Value。"
    }
    return $parsed.ToString('D').ToLowerInvariant()
}

function ConvertTo-CodexDispatchRepositoryIdentity {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Context,

        [Parameter()]
        [switch]$AllowNull
    )

    if ($null -eq $Value) {
        if ($AllowNull) {
            return $null
        }
        New-CodexDispatchRuntimeStateError "$Context 必须是合法 owner/repository。"
    }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        New-CodexDispatchRuntimeStateError "$Context 必须是合法 owner/repository。"
    }

    $identity = ([string]$Value).Trim()
    $match = [regex]::Match(
        $identity,
        '^(?<owner>[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/(?<repo>[A-Za-z0-9._-]{1,100})$'
    )
    if (
        -not $match.Success -or
        $match.Groups['owner'].Value.Contains('--') -or
        $match.Groups['repo'].Value -in @('.', '..')
    ) {
        New-CodexDispatchRuntimeStateError "$Context 格式无效：$identity。"
    }
    return $identity
}

function ConvertTo-CodexDispatchCanonicalThreadId {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Context,

        [Parameter()]
        [switch]$AllowNull
    )

    if ($null -eq $Value) {
        if ($AllowNull) {
            return $null
        }
        New-CodexDispatchRuntimeStateError "$Context 必须是 canonical UUID。"
    }
    return ConvertTo-CodexDispatchCanonicalGuid -Value $Value -Context $Context
}

function ConvertTo-CodexDispatchUtcTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    if ($Value -isnot [string]) {
        New-CodexDispatchRuntimeStateError "$Context 必须是 UTC round-trip timestamp。"
    }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact(
        [string]$Value,
        'o',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed
    )) {
        New-CodexDispatchRuntimeStateError "$Context 不是有效 round-trip timestamp：$Value。"
    }
    if ($parsed.Kind -ne [System.DateTimeKind]::Utc) {
        New-CodexDispatchRuntimeStateError "$Context 必须明确使用 UTC。"
    }
    $canonical = $parsed.ToString(
        'o',
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    if (-not [string]::Equals(
        $canonical,
        [string]$Value,
        [System.StringComparison]::Ordinal
    )) {
        New-CodexDispatchRuntimeStateError "$Context 必须使用 canonical round-trip 格式。"
    }
    return $parsed
}

function Assert-CodexDispatchSafeDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    if (-not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) {
        New-CodexDispatchRuntimeStateError "$Context 不存在或不是目录：$DirectoryPath。"
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($DirectoryPath)
        $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
        if ([string]::IsNullOrWhiteSpace($pathRoot)) {
            New-CodexDispatchRuntimeStateError "$Context 缺少 volume/root。"
        }

        $currentPath = $pathRoot
        $currentItem = Get-Item -Force -LiteralPath $currentPath
        if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            New-CodexDispatchRuntimeStateError "$Context 路径链包含 reparse point：$currentPath。"
        }
        $relativePath = $fullPath.Substring($pathRoot.Length)
        foreach ($segment in $relativePath.Split(
            @('\', '/'),
            [System.StringSplitOptions]::RemoveEmptyEntries
        )) {
            $currentPath = Join-Path -Path $currentPath -ChildPath $segment
            $currentItem = Get-Item -Force -LiteralPath $currentPath
            if (-not $currentItem.PSIsContainer) {
                New-CodexDispatchRuntimeStateError "$Context 路径链包含非目录：$currentPath。"
            }
            if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                New-CodexDispatchRuntimeStateError "$Context 路径链包含 reparse point：$currentPath。"
            }
        }
        return (Get-Item -Force -LiteralPath $fullPath)
    }
    catch {
        if ($_.Exception.Message.StartsWith(
            'Codex Dispatch Runtime State 错误：',
            [System.StringComparison]::Ordinal
        )) {
            throw
        }
        New-CodexDispatchRuntimeStateError "$Context 安全检查失败。$($_.Exception.Message)"
    }
}

function Get-CodexDispatchRuntimeConfiguration {
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    $loaderPath = Join-Path $PSScriptRoot 'Load-CodexDispatchConfig.ps1'
    try {
        $config = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
            & $loaderPath
        }
        else {
            & $loaderPath -Path $ConfigPath
        }
    }
    catch {
        New-CodexDispatchRuntimeStateError "配置无效。$($_.Exception.Message)"
    }
    if ($null -eq $config.runtime -or [string]::IsNullOrWhiteSpace(
        [string]$config.runtime.stateDirectory
    )) {
        New-CodexDispatchRuntimeStateError '配置未返回 runtime.stateDirectory。'
    }
    $stateItem = Assert-CodexDispatchSafeDirectory `
        -DirectoryPath ([string]$config.runtime.stateDirectory) `
        -Context 'runtime.stateDirectory'
    if (-not [string]::Equals(
        [System.IO.Path]::GetFullPath([string]$config.runtime.stateDirectory).TrimEnd('\', '/'),
        [System.IO.Path]::GetFullPath($stateItem.FullName).TrimEnd('\', '/'),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        New-CodexDispatchRuntimeStateError 'runtime.stateDirectory 在运行前发生路径替换。'
    }
    return $config
}

function Get-CodexDispatchesDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter()]
        [switch]$Create
    )

    $stateItem = Assert-CodexDispatchSafeDirectory `
        -DirectoryPath $StateDirectory `
        -Context 'runtime.stateDirectory'
    $dispatchesPath = Join-Path $stateItem.FullName 'dispatches'
    if (Test-Path -LiteralPath $dispatchesPath) {
        if (-not (Test-Path -LiteralPath $dispatchesPath -PathType Container)) {
            New-CodexDispatchRuntimeStateError 'dispatches 路径已存在但不是目录。'
        }
        $dispatchesItem = Assert-CodexDispatchSafeDirectory `
            -DirectoryPath $dispatchesPath `
            -Context 'dispatches directory'
        return $dispatchesItem.FullName
    }
    if (-not $Create) {
        return $null
    }

    try {
        [void][System.IO.Directory]::CreateDirectory($dispatchesPath)
    }
    catch {
        New-CodexDispatchRuntimeStateError "无法创建 dispatches directory。$($_.Exception.Message)"
    }
    $createdItem = Assert-CodexDispatchSafeDirectory `
        -DirectoryPath $dispatchesPath `
        -Context 'dispatches directory'
    return $createdItem.FullName
}

function Get-CodexDispatchStateFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DispatchesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$CanonicalDispatchId
    )

    return Join-Path $DispatchesDirectory ($CanonicalDispatchId + '.json')
}

function Assert-CodexDispatchStateFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateFilePath
    )

    if (-not (Test-Path -LiteralPath $StateFilePath)) {
        New-CodexDispatchRuntimeStateError "找不到 dispatch state：$StateFilePath。"
    }
    $item = Get-Item -Force -LiteralPath $StateFilePath
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        New-CodexDispatchRuntimeStateError "state 文件不能是 reparse point：$StateFilePath。"
    }
    if ($item.PSIsContainer) {
        New-CodexDispatchRuntimeStateError "state 文件路径是目录：$StateFilePath。"
    }
    return $item
}

function ConvertTo-CodexDispatchOptionsArray {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    if ($Value -isnot [System.Array]) {
        New-CodexDispatchRuntimeStateError "$Context 必须是 JSON string array。"
    }
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($option in [System.Array]$Value) {
        if ($option -isnot [string]) {
            New-CodexDispatchRuntimeStateError "$Context 只能包含 string。"
        }
        $result.Add([string]$option)
    }
    return ,([string[]]$result.ToArray())
}

function Assert-CodexDispatchNeedsInputOptions {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Options,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $distinct = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($option in $Options) {
        if ([string]::IsNullOrWhiteSpace($option)) {
            New-CodexDispatchRuntimeStateError "$Context options 必须是 non-empty strings。"
        }
        if (-not $distinct.Add($option)) {
            New-CodexDispatchRuntimeStateError "$Context options 必须 distinct。"
        }
    }
    if ($distinct.Count -lt 2) {
        New-CodexDispatchRuntimeStateError "$Context 至少需要 2 个 distinct non-empty options。"
    }
}

function Assert-CodexDispatchStateSemantics {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $pair = ([string]$State.phase) + '/' + ([string]$State.status)
    $outputFieldsEmpty = (
        $State.report.Length -eq 0 -and
        $State.question.Length -eq 0 -and
        $State.context.Length -eq 0 -and
        $State.options.Count -eq 0 -and
        $State.diagnostic.Length -eq 0
    )
    switch ($pair) {
        'routing/pending' {
            if ($null -ne $State.projectRepository -or $null -ne $State.threadId -or -not $outputFieldsEmpty) {
                New-CodexDispatchRuntimeStateError 'routing/pending 字段组合无效。'
            }
        }
        'routing/running' {
            if ($null -ne $State.projectRepository -or $null -ne $State.threadId -or -not $outputFieldsEmpty) {
                New-CodexDispatchRuntimeStateError 'routing/running 字段组合无效。'
            }
        }
        'routing/needs_input' {
            if (
                $null -ne $State.projectRepository -or $null -ne $State.threadId -or
                [string]::IsNullOrWhiteSpace($State.report) -or
                [string]::IsNullOrWhiteSpace($State.question) -or
                [string]::IsNullOrWhiteSpace($State.context) -or
                $State.diagnostic.Length -ne 0
            ) {
                New-CodexDispatchRuntimeStateError 'routing/needs_input 字段组合无效。'
            }
            Assert-CodexDispatchNeedsInputOptions `
                -Options $State.options `
                -Context 'routing/needs_input'
        }
        'worker/running' {
            if ($null -eq $State.projectRepository -or -not $outputFieldsEmpty) {
                New-CodexDispatchRuntimeStateError 'worker/running 字段组合无效。'
            }
        }
        'worker/completed' {
            if (
                $null -eq $State.projectRepository -or $null -eq $State.threadId -or
                [string]::IsNullOrWhiteSpace($State.report) -or
                $State.question.Length -ne 0 -or $State.context.Length -ne 0 -or
                $State.options.Count -ne 0 -or $State.diagnostic.Length -ne 0
            ) {
                New-CodexDispatchRuntimeStateError 'worker/completed 字段组合无效。'
            }
        }
        'worker/needs_input' {
            if (
                $null -eq $State.projectRepository -or $null -eq $State.threadId -or
                [string]::IsNullOrWhiteSpace($State.report) -or
                [string]::IsNullOrWhiteSpace($State.question) -or
                [string]::IsNullOrWhiteSpace($State.context) -or
                $State.diagnostic.Length -ne 0
            ) {
                New-CodexDispatchRuntimeStateError 'worker/needs_input 字段组合无效。'
            }
            Assert-CodexDispatchNeedsInputOptions `
                -Options $State.options `
                -Context 'worker/needs_input'
        }
        'worker/failed' {
            if (
                $null -eq $State.projectRepository -or
                [string]::IsNullOrWhiteSpace($State.diagnostic) -or
                $State.question.Length -ne 0 -or $State.context.Length -ne 0 -or
                $State.options.Count -ne 0
            ) {
                New-CodexDispatchRuntimeStateError 'worker/failed 字段组合无效。'
            }
        }
        default {
            New-CodexDispatchRuntimeStateError "非法 phase/status 组合：$pair。"
        }
    }
}

function ConvertTo-CodexDispatchCanonicalState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,

        [Parameter()]
        [AllowNull()]
        [string]$ExpectedDispatchId
    )

    if (-not (Test-CodexDispatchStateJsonObject -Value $State)) {
        New-CodexDispatchRuntimeStateError 'state JSON 顶层必须是 object。'
    }
    $actualNames = [string[]]@($State.PSObject.Properties.Name)
    foreach ($actualName in $actualNames) {
        if ($script:CodexDispatchStatePropertyOrder -cnotcontains $actualName) {
            New-CodexDispatchRuntimeStateError "state 文件包含未知字段：$actualName。"
        }
    }
    foreach ($expectedName in $script:CodexDispatchStatePropertyOrder) {
        if ($actualNames -cnotcontains $expectedName) {
            New-CodexDispatchRuntimeStateError "state 文件缺少必需字段：$expectedName。"
        }
    }
    if ($actualNames.Count -ne $script:CodexDispatchStatePropertyOrder.Count) {
        New-CodexDispatchRuntimeStateError 'state 文件字段数量无效。'
    }

    $version = Get-CodexDispatchStateProperty -State $State -Name 'version'
    if (-not (Test-CodexDispatchStateInteger -Value $version) -or [int64]$version -ne 1) {
        New-CodexDispatchRuntimeStateError 'version 必须是 integer exactly 1。'
    }
    $dispatchIdValue = Get-CodexDispatchStateProperty -State $State -Name 'dispatchId'
    $dispatchId = ConvertTo-CodexDispatchCanonicalGuid `
        -Value $dispatchIdValue `
        -Context 'dispatchId'
    if (-not [string]::Equals(
        [string]$dispatchIdValue,
        $dispatchId,
        [System.StringComparison]::Ordinal
    )) {
        New-CodexDispatchRuntimeStateError 'dispatchId 必须是 lowercase canonical UUID D。'
    }
    if (
        -not [string]::IsNullOrWhiteSpace($ExpectedDispatchId) -and
        -not [string]::Equals($dispatchId, $ExpectedDispatchId, [System.StringComparison]::Ordinal)
    ) {
        New-CodexDispatchRuntimeStateError 'state JSON dispatchId 与 filename 不匹配。'
    }

    $revisionValue = Get-CodexDispatchStateProperty -State $State -Name 'revision'
    if (-not (Test-CodexDispatchStateInteger -Value $revisionValue)) {
        New-CodexDispatchRuntimeStateError 'revision 必须是 integer >= 1。'
    }
    try {
        $revision = [int64]$revisionValue
    }
    catch {
        New-CodexDispatchRuntimeStateError 'revision 超出支持范围。'
    }
    if ($revision -lt 1) {
        New-CodexDispatchRuntimeStateError 'revision 必须是 integer >= 1。'
    }

    $createdAtUtc = Get-CodexDispatchStateProperty -State $State -Name 'createdAtUtc'
    $updatedAtUtc = Get-CodexDispatchStateProperty -State $State -Name 'updatedAtUtc'
    $createdTimestamp = ConvertTo-CodexDispatchUtcTimestamp `
        -Value $createdAtUtc -Context 'createdAtUtc'
    $updatedTimestamp = ConvertTo-CodexDispatchUtcTimestamp `
        -Value $updatedAtUtc -Context 'updatedAtUtc'
    if ($updatedTimestamp -lt $createdTimestamp) {
        New-CodexDispatchRuntimeStateError 'updatedAtUtc 不能早于 createdAtUtc。'
    }

    $phase = Get-CodexDispatchStateProperty -State $State -Name 'phase'
    $status = Get-CodexDispatchStateProperty -State $State -Name 'status'
    if ($phase -isnot [string] -or [string]$phase -cnotin @('routing', 'worker')) {
        New-CodexDispatchRuntimeStateError "phase 无效：$phase。"
    }
    if ($status -isnot [string] -or [string]$status -cnotin @(
        'pending', 'running', 'needs_input', 'completed', 'failed'
    )) {
        New-CodexDispatchRuntimeStateError "status 无效：$status。"
    }

    $task = Get-CodexDispatchStateProperty -State $State -Name 'task'
    if ($task -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$task)) {
        New-CodexDispatchRuntimeStateError 'task 必须是 non-empty string。'
    }
    $projectRepositoryValue = Get-CodexDispatchStateProperty `
        -State $State -Name 'projectRepository'
    $projectRepository = ConvertTo-CodexDispatchRepositoryIdentity `
        -Value $projectRepositoryValue `
        -Context 'projectRepository' `
        -AllowNull
    if (
        $null -ne $projectRepositoryValue -and
        -not [string]::Equals(
            [string]$projectRepositoryValue,
            [string]$projectRepository,
            [System.StringComparison]::Ordinal
        )
    ) {
        New-CodexDispatchRuntimeStateError 'projectRepository 必须是 normalized owner/repository。'
    }

    $threadIdValue = Get-CodexDispatchStateProperty -State $State -Name 'threadId'
    $threadId = ConvertTo-CodexDispatchCanonicalThreadId `
        -Value $threadIdValue -Context 'threadId' -AllowNull
    if (
        $null -ne $threadIdValue -and
        -not [string]::Equals(
            [string]$threadIdValue,
            [string]$threadId,
            [System.StringComparison]::Ordinal
        )
    ) {
        New-CodexDispatchRuntimeStateError 'threadId 必须是 lowercase canonical UUID D。'
    }

    $strings = [ordered]@{}
    foreach ($fieldName in @('report', 'question', 'context', 'diagnostic')) {
        $fieldValue = Get-CodexDispatchStateProperty -State $State -Name $fieldName
        if ($fieldValue -isnot [string]) {
            New-CodexDispatchRuntimeStateError "$fieldName 必须是 string。"
        }
        $strings[$fieldName] = [string]$fieldValue
    }
    $options = ConvertTo-CodexDispatchOptionsArray `
        -Value (Get-CodexDispatchStateProperty -State $State -Name 'options') `
        -Context 'options'

    $canonical = [pscustomobject][ordered]@{
        version = 1
        dispatchId = $dispatchId
        revision = $revision
        createdAtUtc = [string]$createdAtUtc
        updatedAtUtc = [string]$updatedAtUtc
        phase = [string]$phase
        status = [string]$status
        task = [string]$task
        projectRepository = $projectRepository
        threadId = $threadId
        report = [string]$strings['report']
        question = [string]$strings['question']
        context = [string]$strings['context']
        options = [string[]]$options
        diagnostic = [string]$strings['diagnostic']
    }
    Assert-CodexDispatchStateSemantics -State $canonical
    return $canonical
}

function Read-CodexDispatchStateFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateFilePath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedDispatchId,

        [Parameter()]
        [switch]$Exclusive
    )

    $coordinationStream = $null
    $coordinationPath = [System.IO.Path]::ChangeExtension($StateFilePath, '.lock')
    $stream = $null
    try {
        if (-not $Exclusive) {
            $coordinationStream = Enter-CodexDispatchStateLock -LockPath $coordinationPath
        }
        [void](Assert-CodexDispatchStateFile -StateFilePath $StateFilePath)
        $share = if ($Exclusive) {
            [System.IO.FileShare]::Read
        }
        else {
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        }
        try {
            $stream = [System.IO.FileStream]::new(
                $StateFilePath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                $share
            )
            if (-not [string]::Equals(
                [System.IO.Path]::GetFullPath($stream.Name),
                [System.IO.Path]::GetFullPath($StateFilePath),
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                New-CodexDispatchRuntimeStateError '打开的 state handle 与预期路径不一致。'
            }
            if ($stream.Length -gt [int]::MaxValue) {
                New-CodexDispatchRuntimeStateError 'state 文件过大。'
            }
            $bytes = [byte[]]::new([int]$stream.Length)
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
                if ($read -eq 0) {
                    break
                }
                $offset += $read
            }
            if ($offset -ne $bytes.Length) {
                New-CodexDispatchRuntimeStateError 'state 文件读取不完整。'
            }
        }
        catch {
            if ($_.Exception.Message.StartsWith(
                'Codex Dispatch Runtime State 错误：',
                [System.StringComparison]::Ordinal
            )) {
                throw
            }
            New-CodexDispatchRuntimeStateError "无法读取 state 文件。$($_.Exception.Message)"
        }
        finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }

        if (
            $bytes.Length -ge 3 -and
            $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
        ) {
            New-CodexDispatchRuntimeStateError 'state JSON 必须使用 UTF-8 no BOM。'
        }
        try {
            $jsonText = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        }
        catch {
            New-CodexDispatchRuntimeStateError 'state 文件不是有效 strict UTF-8。'
        }
        try {
            $document = ConvertFrom-Json -InputObject $jsonText
        }
        catch {
            New-CodexDispatchRuntimeStateError "state 文件不是有效 JSON。$($_.Exception.Message)"
        }
        return ConvertTo-CodexDispatchCanonicalState `
            -State $document `
            -ExpectedDispatchId $ExpectedDispatchId
    }
    finally {
        if ($null -ne $coordinationStream) {
            Exit-CodexDispatchStateLock `
                -LockStream $coordinationStream `
                -LockPath $coordinationPath
        }
    }
}

function ConvertTo-CodexDispatchStateJson {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $canonical = ConvertTo-CodexDispatchCanonicalState `
        -State $State `
        -ExpectedDispatchId ([string]$State.dispatchId)
    return (ConvertTo-Json -InputObject $canonical -Depth 8) + [Environment]::NewLine
}

function Write-CodexDispatchStateTempFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DispatchesDirectory,

        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $tempPath = Join-Path $DispatchesDirectory (
        '.codex-dispatch-state-' + [guid]::NewGuid().ToString('N') + '.tmp'
    )
    $stream = $null
    try {
        $json = ConvertTo-CodexDispatchStateJson -State $State
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream = [System.IO.FileStream]::new(
            $tempPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        return $tempPath
    }
    catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if ($_.Exception.Message.StartsWith(
            'Codex Dispatch Runtime State 错误：',
            [System.StringComparison]::Ordinal
        )) {
            throw
        }
        New-CodexDispatchRuntimeStateError "无法写入 state temporary file。$($_.Exception.Message)"
    }
}

function Write-CodexDispatchStateCreate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $canonical = ConvertTo-CodexDispatchCanonicalState `
        -State $State `
        -ExpectedDispatchId ([string]$State.dispatchId)
    $dispatchesDirectory = Get-CodexDispatchesDirectory `
        -StateDirectory $StateDirectory `
        -Create
    $targetPath = Get-CodexDispatchStateFilePath `
        -DispatchesDirectory $dispatchesDirectory `
        -CanonicalDispatchId $canonical.dispatchId
    if (Test-Path -LiteralPath $targetPath) {
        New-CodexDispatchRuntimeStateError "dispatch state 已存在，拒绝覆盖：$($canonical.dispatchId)。"
    }

    $tempPath = $null
    try {
        $tempPath = Write-CodexDispatchStateTempFile `
            -DispatchesDirectory $dispatchesDirectory `
            -State $canonical
        [System.IO.File]::Move($tempPath, $targetPath)
        $tempPath = $null
    }
    catch {
        if ($_.Exception.Message.StartsWith(
            'Codex Dispatch Runtime State 错误：',
            [System.StringComparison]::Ordinal
        )) {
            throw
        }
        New-CodexDispatchRuntimeStateError "无法原子创建 dispatch state。$($_.Exception.Message)"
    }
    finally {
        if ($null -ne $tempPath -and (Test-Path -LiteralPath $tempPath -PathType Leaf)) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
    return $canonical
}

function Enter-CodexDispatchStateLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LockPath
    )

    for ($attempt = 0; $attempt -lt 600; $attempt++) {
        $stream = $null
        try {
            $stream = [System.IO.FileStream]::new(
                $LockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            if (-not [string]::Equals(
                [System.IO.Path]::GetFullPath($stream.Name),
                [System.IO.Path]::GetFullPath($LockPath),
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                $stream.Dispose()
                New-CodexDispatchRuntimeStateError '打开的 coordination lock handle 与预期路径不一致。'
            }
            $openedItem = Get-Item -Force -LiteralPath $LockPath
            if (($openedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $stream.Dispose()
                New-CodexDispatchRuntimeStateError 'state coordination lock 在打开期间变为 reparse point。'
            }
            return $stream
        }
        catch [System.IO.IOException] {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
            Start-Sleep -Milliseconds 25
        }
        catch [System.Management.Automation.ItemNotFoundException] {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
            Start-Sleep -Milliseconds 25
        }
        catch {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
            if ($_.Exception.Message.StartsWith(
                'Codex Dispatch Runtime State 错误：',
                [System.StringComparison]::Ordinal
            )) {
                throw
            }
            New-CodexDispatchRuntimeStateError "无法取得 state coordination lock。$($_.Exception.Message)"
        }
    }
    New-CodexDispatchRuntimeStateError 'state coordination lock 等待超时。'
}

function Exit-CodexDispatchStateLock {
    param(
        [Parameter()]
        [AllowNull()]
        [System.IO.FileStream]$LockStream,

        [Parameter(Mandatory = $true)]
        [string]$LockPath
    )

    if ($null -ne $LockStream) {
        $LockStream.Dispose()
    }
    try {
        if (Test-Path -LiteralPath $LockPath -PathType Leaf) {
            $item = Get-Item -Force -LiteralPath $LockPath
            if (
                ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and
                $item.Length -eq 0
            ) {
                Remove-Item -LiteralPath $LockPath -Force
            }
        }
    }
    catch {
        # A concurrent waiter may already own the same lock file; never delete through it.
    }
}

function Assert-CodexDispatchStateTransition {
    param(
        [Parameter(Mandatory = $true)]
        [object]$CurrentState,

        [Parameter(Mandatory = $true)]
        [string]$Phase,

        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    $from = $CurrentState.phase + '/' + $CurrentState.status
    $to = $Phase + '/' + $Status
    $allowed = [ordered]@{
        'routing/pending' = [string[]]@('routing/running', 'routing/needs_input')
        'routing/running' = [string[]]@('routing/needs_input', 'worker/running')
        'routing/needs_input' = [string[]]@('routing/running')
        'worker/running' = [string[]]@(
            'worker/completed', 'worker/needs_input', 'worker/failed'
        )
        'worker/needs_input' = [string[]]@('worker/running')
        'worker/completed' = [string[]]@()
        'worker/failed' = [string[]]@()
    }
    if (-not $allowed.Contains($from) -or $allowed[$from] -cnotcontains $to) {
        New-CodexDispatchRuntimeStateError "非法状态转换：$from -> $to。"
    }
}

function Update-CodexDispatchStateTransaction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [string]$CanonicalDispatchId,

        [Parameter(Mandatory = $true)]
        [int64]$ExpectedRevision,

        [Parameter(Mandatory = $true)]
        [string]$Phase,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Changes
    )

    $dispatchesDirectory = Get-CodexDispatchesDirectory -StateDirectory $StateDirectory
    if ([string]::IsNullOrWhiteSpace($dispatchesDirectory)) {
        New-CodexDispatchRuntimeStateError "找不到 dispatch state：$CanonicalDispatchId。"
    }
    $statePath = Get-CodexDispatchStateFilePath `
        -DispatchesDirectory $dispatchesDirectory `
        -CanonicalDispatchId $CanonicalDispatchId
    $lockPath = Join-Path $dispatchesDirectory ($CanonicalDispatchId + '.lock')
    $lockStream = $null
    $tempPath = $null
    $backupPath = $null
    try {
        $lockStream = Enter-CodexDispatchStateLock -LockPath $lockPath
        $current = Read-CodexDispatchStateFile `
            -StateFilePath $statePath `
            -ExpectedDispatchId $CanonicalDispatchId `
            -Exclusive
        if ($current.revision -ne $ExpectedRevision) {
            New-CodexDispatchRuntimeStateError (
                "revision 冲突：expected $ExpectedRevision，current $($current.revision)。"
            )
        }
        if ($current.revision -eq [int64]::MaxValue) {
            New-CodexDispatchRuntimeStateError 'revision 已达到最大值。'
        }
        Assert-CodexDispatchStateTransition `
            -CurrentState $current `
            -Phase $Phase `
            -Status $Status

        $values = [ordered]@{
            projectRepository = $current.projectRepository
            threadId = $current.threadId
            report = $current.report
            question = $current.question
            context = $current.context
            options = [string[]]$current.options
            diagnostic = $current.diagnostic
        }
        foreach ($changeName in $Changes.Keys) {
            $values[$changeName] = $Changes[$changeName]
        }
        $now = [datetime]::UtcNow.ToString(
            'o',
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        $candidate = [pscustomobject][ordered]@{
            version = 1
            dispatchId = $current.dispatchId
            revision = $current.revision + 1
            createdAtUtc = $current.createdAtUtc
            updatedAtUtc = $now
            phase = $Phase
            status = $Status
            task = $current.task
            projectRepository = $values['projectRepository']
            threadId = $values['threadId']
            report = $values['report']
            question = $values['question']
            context = $values['context']
            options = [string[]]$values['options']
            diagnostic = $values['diagnostic']
        }
        $candidate = ConvertTo-CodexDispatchCanonicalState `
            -State $candidate `
            -ExpectedDispatchId $CanonicalDispatchId

        [void](Assert-CodexDispatchStateFile -StateFilePath $statePath)
        $tempPath = Write-CodexDispatchStateTempFile `
            -DispatchesDirectory $dispatchesDirectory `
            -State $candidate
        $backupPath = Join-Path $dispatchesDirectory (
            '.codex-dispatch-state-' + [guid]::NewGuid().ToString('N') + '.bak'
        )
        [System.IO.File]::Replace($tempPath, $statePath, $backupPath)
        $tempPath = $null
        Remove-Item -LiteralPath $backupPath -Force
        $backupPath = $null
        $readBack = Read-CodexDispatchStateFile `
            -StateFilePath $statePath `
            -ExpectedDispatchId $CanonicalDispatchId `
            -Exclusive
        if ($readBack.revision -ne $candidate.revision) {
            New-CodexDispatchRuntimeStateError 'atomic update readback revision 不匹配。'
        }
        return $readBack
    }
    catch {
        if ($_.Exception.Message.StartsWith(
            'Codex Dispatch Runtime State 错误：',
            [System.StringComparison]::Ordinal
        )) {
            throw
        }
        New-CodexDispatchRuntimeStateError "update transaction 失败。$($_.Exception.Message)"
    }
    finally {
        if ($null -ne $tempPath -and (Test-Path -LiteralPath $tempPath -PathType Leaf)) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
        Exit-CodexDispatchStateLock -LockStream $lockStream -LockPath $lockPath
    }
}
