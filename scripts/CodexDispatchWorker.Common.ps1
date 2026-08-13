Set-StrictMode -Version 2.0

function New-WorkerError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    throw [System.InvalidOperationException]::new("Codex Dispatch Worker 错误：$Message")
}

function Test-WorkerJsonObject {
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

function Get-WorkerProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        New-WorkerError "$Context 缺少必需字段：$Name。"
    }

    if ($property.Value -is [System.Array]) {
        Write-Output -NoEnumerate $property.Value
        return
    }

    return $property.Value
}

function Test-WorkerRepositoryIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository
    )

    $match = [regex]::Match(
        $Repository,
        '^(?<owner>[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/(?<repo>[A-Za-z0-9._-]{1,100})$'
    )
    return (
        $match.Success -and
        -not $match.Groups['owner'].Value.Contains('--') -and
        $match.Groups['repo'].Value -notin @('.', '..')
    )
}

function Test-WorkerCanonicalThreadId {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ThreadId
    )

    $parsed = [guid]::Empty
    return (
        [guid]::TryParseExact($ThreadId, 'D', [ref]$parsed) -and
        [string]::Equals(
            $ThreadId,
            $parsed.ToString('D'),
            [System.StringComparison]::Ordinal
        )
    )
}

function Get-WorkerIndexPath {
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
        New-WorkerError "IndexPath 无效：$candidate。"
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        New-WorkerError "找不到 Project Index：$fullPath。"
    }

    $item = Get-Item -Force -LiteralPath $fullPath
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        New-WorkerError 'Project Index 不能是符号链接、junction 或其他 reparse point。'
    }

    return $item.FullName
}

function Get-WorkerAuthorizedProjectPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        New-WorkerError "$Context localPath 必须是绝对路径。"
    }

    try {
        $fullRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
        $fullCandidate = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    }
    catch {
        New-WorkerError "$Context localPath 无效。"
    }

    $workspacePrefix = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $fullCandidate.StartsWith(
        $workspacePrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        New-WorkerError "$Context localPath 必须严格位于 workspace.root 之下。"
    }

    if (-not (Test-Path -LiteralPath $fullCandidate -PathType Container)) {
        New-WorkerError "$Context localPath 不存在或不是目录：$fullCandidate。"
    }

    try {
        $currentPath = $fullRoot
        $currentItem = Get-Item -Force -LiteralPath $currentPath
        if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            New-WorkerError "$Context localPath 的 workspace.root 是不安全 reparse point。"
        }

        $relativePath = $fullCandidate.Substring($fullRoot.Length).TrimStart('\', '/')
        foreach ($segment in $relativePath.Split(
            @('\', '/'),
            [System.StringSplitOptions]::RemoveEmptyEntries
        )) {
            $currentPath = Join-Path -Path $currentPath -ChildPath $segment
            $currentItem = Get-Item -Force -LiteralPath $currentPath
            if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                New-WorkerError "$Context localPath 包含不安全 reparse point：$currentPath。"
            }
        }
    }
    catch {
        if ($_.Exception.Message.StartsWith(
            'Codex Dispatch Worker 错误：',
            [System.StringComparison]::Ordinal
        )) {
            throw
        }
        New-WorkerError "$Context localPath 安全检查失败：$fullCandidate。"
    }

    return (Get-Item -Force -LiteralPath $fullCandidate).FullName
}

function Resolve-WorkerApplication {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string]$Context,

        [Parameter(Mandatory = $true)]
        [string[]]$AllowedExtensions
    )

    $resolved = @(
        Get-Command -Name $Command -CommandType Application -ErrorAction SilentlyContinue
    )
    if ($resolved.Count -eq 0) {
        New-WorkerError "无法解析 $Context：$Command。"
    }

    $path = [System.IO.Path]::GetFullPath([string]$resolved[0].Source)
    $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($extension -notin $AllowedExtensions) {
        New-WorkerError "$Context 解析为不支持的文件类型：$path。"
    }

    return $path
}

function Invoke-WorkerLocalGit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitExecutable,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(
            & $GitExecutable `
                --no-optional-locks `
                -C $RepositoryPath `
                rev-parse --show-toplevel `
                2>$null
        )
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output = [object[]]$output
    }
}

function ConvertTo-WorkerCommandLineArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function ConvertTo-WorkerTomlBasicStringContent {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $builder = [System.Text.StringBuilder]::new()
    foreach ($character in $Value.ToCharArray()) {
        $codePoint = [int][char]$character
        $encoded = switch ($codePoint) {
            8 { '\b'; break }
            9 { '\t'; break }
            10 { '\n'; break }
            12 { '\f'; break }
            13 { '\r'; break }
            34 { '\"'; break }
            92 { '\\'; break }
            default {
                if ($codePoint -lt 32 -or $codePoint -eq 127) {
                    '\u{0:X4}' -f $codePoint
                }
                else {
                    [string]$character
                }
            }
        }
        [void]$builder.Append($encoded)
    }

    return $builder.ToString()
}

function New-WorkerProjectTrustOverride {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectPath
    )

    $quotedProjectKey = ConvertTo-WorkerTomlBasicStringContent -Value $ProjectPath
    return 'projects."' + $quotedProjectKey + '".trust_level="untrusted"'
}

function Stop-WorkerProcess {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )

    try {
        if ($Process.HasExited) {
            return
        }
    }
    catch {
        return
    }

    $taskkillPath = if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        Join-Path $env:SystemRoot 'System32\taskkill.exe'
    }
    else {
        $null
    }
    if ($null -ne $taskkillPath -and (Test-Path -LiteralPath $taskkillPath -PathType Leaf)) {
        try {
            $killInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $killInfo.FileName = $taskkillPath
            $killInfo.Arguments = "/PID $($Process.Id) /T /F"
            $killInfo.UseShellExecute = $false
            $killInfo.CreateNoWindow = $true
            $killProcess = [System.Diagnostics.Process]::new()
            $killProcess.StartInfo = $killInfo
            try {
                [void]$killProcess.Start()
                [void]$killProcess.WaitForExit(5000)
            }
            finally {
                $killProcess.Dispose()
            }
        }
        catch {
            # Process.Kill remains the root-process fallback.
        }
    }

    try {
        if (-not $Process.HasExited) {
            $Process.Kill()
        }
        [void]$Process.WaitForExit(5000)
    }
    catch {
        # The process may already have exited.
    }
}

function Invoke-WorkerProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StandardInput
    )

    $argumentText = (($Arguments | ForEach-Object {
        ConvertTo-WorkerCommandLineArgument -Value $_
    }) -join ' ')

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $extension = [System.IO.Path]::GetExtension($CommandPath).ToLowerInvariant()
    if ($extension -in @('.cmd', '.bat')) {
        $commandProcessor = $env:ComSpec
        if (
            [string]::IsNullOrWhiteSpace($commandProcessor) -or
            -not (Test-Path -LiteralPath $commandProcessor -PathType Leaf)
        ) {
            New-WorkerError '无法解析 Windows command processor，不能安全启动 .cmd/.bat Codex command。'
        }
        $innerCommand = (
            (ConvertTo-WorkerCommandLineArgument -Value $CommandPath) +
            ' ' + $argumentText
        ).Trim()
        $startInfo.FileName = $commandProcessor
        $startInfo.Arguments = '/D /S /C "' + $innerCommand + '"'
    }
    else {
        $startInfo.FileName = $CommandPath
        $startInfo.Arguments = $argumentText
    }

    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    $standardInputBytes = $utf8.GetBytes($StandardInput)

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
    }
    catch {
        $process.Dispose()
        New-WorkerError "无法启动 Codex Worker process：$($_.Exception.Message)"
    }

    $standardInputClosed = $false
    try {
        try {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $inputTask = $process.StandardInput.BaseStream.WriteAsync(
                $standardInputBytes,
                0,
                $standardInputBytes.Length
            )
            [void]$inputTask.Wait()
            $process.StandardInput.BaseStream.Close()
            $standardInputClosed = $true

            $process.WaitForExit()
            [System.Threading.Tasks.Task]::WaitAll(
                [System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask)
            )

            return [pscustomobject]@{
                ExitCode = [int]$process.ExitCode
                StandardOutput = [string]$stdoutTask.Result
                StandardError = [string]$stderrTask.Result
                TransportError = ''
            }
        }
        catch {
            $transportMessage = $_.Exception.GetBaseException().Message
            Stop-WorkerProcess -Process $process
            $exitCode = -1
            try {
                if ($process.HasExited) {
                    $exitCode = [int]$process.ExitCode
                }
            }
            catch {
                # Keep -1 when the process exit code is unavailable.
            }
            return [pscustomobject]@{
                ExitCode = $exitCode
                StandardOutput = ''
                StandardError = ''
                TransportError = $transportMessage
            }
        }
    }
    finally {
        if (-not $standardInputClosed) {
            try {
                $process.StandardInput.BaseStream.Close()
            }
            catch {
                # Process teardown may already have closed stdin.
            }
        }
        $process.Dispose()
    }
}

function New-WorkerSchema {
    return [ordered]@{
        '$schema' = 'https://json-schema.org/draft/2020-12/schema'
        type = 'object'
        additionalProperties = $false
        required = [object[]]@('status', 'report', 'question', 'context', 'options')
        properties = [ordered]@{
            status = [ordered]@{
                type = 'string'
                enum = [object[]]@('completed', 'needs_input')
            }
            report = [ordered]@{ type = 'string' }
            question = [ordered]@{ type = 'string' }
            context = [ordered]@{ type = 'string' }
            options = [ordered]@{
                type = 'array'
                items = [ordered]@{ type = 'string' }
            }
        }
    }
}

function ConvertTo-WorkerSafeDiagnostic {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Fallback,

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$SensitiveValues = @(),

        [Parameter()]
        [switch]$RedactCanonicalUuids,

        [Parameter()]
        [switch]$RedactAbsolutePaths
    )

    $diagnostic = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($diagnostic)) {
        $diagnostic = $Fallback
    }

    $diagnostic = [regex]::Replace(
        $diagnostic,
        '(?i)\b(token|password|secret|authorization|api[_-]?key)\b\s*[:=]\s*[^\s,;]+',
        '$1=[REDACTED]'
    )
    $diagnostic = [regex]::Replace(
        $diagnostic,
        '(?i)\b(gh[pousr]_[A-Za-z0-9_]{8,}|sk-[A-Za-z0-9_-]{8,})\b',
        '[REDACTED]'
    )
    $diagnostic = [regex]::Replace(
        $diagnostic,
        '(?i)(https?://)[^/@\s]+:[^/@\s]+@',
        '$1[REDACTED]@'
    )

    foreach ($sensitive in @(
        $SensitiveValues |
            Where-Object { -not [string]::IsNullOrEmpty([string]$_) } |
            Sort-Object { ([string]$_).Length } -Descending -Unique
    )) {
        $diagnostic = [regex]::Replace(
            $diagnostic,
            [regex]::Escape([string]$sensitive),
            '[REDACTED]',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }

    if ($RedactCanonicalUuids) {
        $diagnostic = [regex]::Replace(
            $diagnostic,
            '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
            '[REDACTED]'
        )
    }

    if ($RedactAbsolutePaths) {
        $diagnostic = [regex]::Replace(
            $diagnostic,
            '(?i)(?:\b[A-Z]:[\\/]|\\\\)[^\r\n]+',
            '[REDACTED-PATH]'
        )
    }

    if ($diagnostic.Length -gt 2000) {
        $diagnostic = $diagnostic.Substring(0, 1997) + '...'
    }
    return $diagnostic
}

function Get-WorkerThreadId {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$EventStream
    )

    $threadGuid = $null
    foreach ($line in @($EventStream -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $event = ConvertFrom-Json -InputObject $line
        }
        catch {
            throw [System.FormatException]::new('Codex JSONL event 无法解析。')
        }
        if (-not (Test-WorkerJsonObject -Value $event)) {
            throw [System.FormatException]::new('Codex JSONL event 必须是 JSON object。')
        }

        $typeProperty = $event.PSObject.Properties['type']
        if ($null -eq $typeProperty) {
            continue
        }
        if ($typeProperty.Value -isnot [string]) {
            throw [System.FormatException]::new('Codex JSONL event type 必须是字符串。')
        }
        if (-not [string]::Equals(
            [string]$typeProperty.Value,
            'thread.started',
            [System.StringComparison]::Ordinal
        )) {
            continue
        }

        $idProperty = $event.PSObject.Properties['thread_id']
        if (
            $null -eq $idProperty -or
            $idProperty.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$idProperty.Value)
        ) {
            throw [System.FormatException]::new('thread.started 缺少有效 thread_id。')
        }

        $parsedGuid = [guid]::Empty
        if (-not [guid]::TryParse(([string]$idProperty.Value).Trim(), [ref]$parsedGuid)) {
            throw [System.FormatException]::new('thread.started.thread_id 不是有效 UUID。')
        }
        if ($null -eq $threadGuid) {
            $threadGuid = $parsedGuid
        }
        elseif ($threadGuid -ne $parsedGuid) {
            throw [System.FormatException]::new('Codex event stream 包含多个不同 thread IDs。')
        }
    }

    if ($null -eq $threadGuid) {
        throw [System.FormatException]::new('Codex event stream 缺少 thread.started。')
    }
    return $threadGuid.ToString()
}

function Assert-WorkerResumeEventStream {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$EventStream,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedThreadId
    )

    foreach ($line in @($EventStream -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $event = ConvertFrom-Json -InputObject $line
        }
        catch {
            throw [System.FormatException]::new('Codex JSONL event 无法解析。')
        }
        if (-not (Test-WorkerJsonObject -Value $event)) {
            throw [System.FormatException]::new('Codex JSONL event 必须是 JSON object。')
        }

        $typeProperty = $event.PSObject.Properties['type']
        if ($null -eq $typeProperty) {
            continue
        }
        if ($typeProperty.Value -isnot [string]) {
            throw [System.FormatException]::new('Codex JSONL event type 必须是字符串。')
        }
        if ([string]$typeProperty.Value -cne 'thread.started') {
            continue
        }

        $idProperty = $event.PSObject.Properties['thread_id']
        if (
            $null -eq $idProperty -or
            $idProperty.Value -isnot [string] -or
            -not (Test-WorkerCanonicalThreadId -ThreadId ([string]$idProperty.Value))
        ) {
            throw [System.FormatException]::new(
                'Resume thread.started.thread_id 必须是 lowercase canonical UUID D。'
            )
        }
        if ([string]$idProperty.Value -cne $ExpectedThreadId) {
            throw [System.FormatException]::new(
                'Codex Resume event stream thread ID 与请求的 ThreadId 不一致。'
            )
        }
    }
}

function ConvertFrom-WorkerFinalResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Document
    )

    if (-not (Test-WorkerJsonObject -Value $Document)) {
        throw [System.FormatException]::new('Worker final result 必须是 JSON object。')
    }

    $requiredNames = @('status', 'report', 'question', 'context', 'options')
    $allowedNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($name in $requiredNames) {
        [void]$allowedNames.Add($name)
        if ($null -eq $Document.PSObject.Properties[$name]) {
            throw [System.FormatException]::new("Worker final result 缺少必需字段：$name。")
        }
    }
    foreach ($property in $Document.PSObject.Properties) {
        if (-not $allowedNames.Contains($property.Name)) {
            throw [System.FormatException]::new("Worker final result 包含未知字段：$($property.Name)。")
        }
    }

    $status = $Document.status
    $report = $Document.report
    $question = $Document.question
    $context = $Document.context
    $optionsValue = $Document.options
    if ($status -isnot [string] -or $status -notin @('completed', 'needs_input')) {
        throw [System.FormatException]::new('Worker final result status 必须是 completed 或 needs_input。')
    }
    foreach ($field in @(
        [pscustomobject]@{ Name = 'report'; Value = $report },
        [pscustomobject]@{ Name = 'question'; Value = $question },
        [pscustomobject]@{ Name = 'context'; Value = $context }
    )) {
        if ($field.Value -isnot [string]) {
            throw [System.FormatException]::new("Worker final result $($field.Name) 必须是字符串。")
        }
    }
    if ($optionsValue -isnot [System.Array]) {
        throw [System.FormatException]::new('Worker final result options 必须是字符串数组。')
    }

    $options = New-Object 'System.Collections.Generic.List[string]'
    $optionSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($option in $optionsValue) {
        if ($option -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$option)) {
            throw [System.FormatException]::new('Worker final result options 只能包含非空字符串。')
        }
        $trimmedOption = ([string]$option).Trim()
        if ($optionSet.Add($trimmedOption)) {
            [void]$options.Add($trimmedOption)
        }
    }

    if ([string]$status -eq 'completed') {
        if ([string]::IsNullOrWhiteSpace([string]$report)) {
            throw [System.FormatException]::new('completed result report 必须非空。')
        }
        if (
            ([string]$question).Length -ne 0 -or
            ([string]$context).Length -ne 0 -or
            $options.Count -ne 0
        ) {
            throw [System.FormatException]::new('completed result 必须使用空 question/context/options。')
        }
    }
    else {
        if (
            [string]::IsNullOrWhiteSpace([string]$report) -or
            [string]::IsNullOrWhiteSpace([string]$question) -or
            [string]::IsNullOrWhiteSpace([string]$context)
        ) {
            throw [System.FormatException]::new('needs_input result 的 report/question/context 必须非空。')
        }
        if ($options.Count -lt 2) {
            throw [System.FormatException]::new('needs_input result 至少需要两个不同的非空 options。')
        }
    }

    return [pscustomobject][ordered]@{
        status = [string]$status
        report = [string]$report
        question = [string]$question
        context = [string]$context
        options = [object[]]$options.ToArray()
    }
}

function New-WorkerOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [object]$Project,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ThreadId = '',

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
        [string[]]$Options = @(),

        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Diagnostic = ''
    )

    return [pscustomobject][ordered]@{
        version = 1
        status = $Status
        project = $Project
        threadId = $ThreadId
        report = $Report
        question = $Question
        context = $Context
        options = [object[]]$Options
        exitCode = $ExitCode
        diagnostic = $Diagnostic
    }
}

function Get-WorkerExecutionContext {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ProjectRepository,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ConfigPath,

        [Parameter()]
        [AllowEmptyString()]
        [string]$IndexPath,

        [Parameter(Mandatory = $true)]
        [string]$ScriptsRoot
    )

    if ([string]::IsNullOrWhiteSpace($ProjectRepository)) {
        New-WorkerError 'ProjectRepository 必须是非空 owner/repository 字符串。'
    }
    $requestedRepository = $ProjectRepository
    if (-not (Test-WorkerRepositoryIdentity -Repository $requestedRepository)) {
        New-WorkerError 'ProjectRepository 必须使用合法 owner/repository 格式。'
    }

    $loaderPath = Join-Path $ScriptsRoot 'Load-CodexDispatchConfig.ps1'
    if (-not (Test-Path -LiteralPath $loaderPath -PathType Leaf)) {
        New-WorkerError "找不到配置加载器：$loaderPath。"
    }
    try {
        $config = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
            & $loaderPath
        }
        else {
            & $loaderPath -Path $ConfigPath
        }
    }
    catch {
        New-WorkerError "配置加载失败：$($_.Exception.Message)"
    }

    $commandValue = Get-WorkerProperty -Object $config.codex -Name 'command' -Context 'codex'
    if ($commandValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$commandValue)) {
        New-WorkerError 'codex.command 必须是非空字符串。'
    }
    $commandText = ([string]$commandValue).Trim()

    $workerSandbox = Get-WorkerProperty -Object $config.codex -Name 'workerSandbox' -Context 'codex'
    if (
        $workerSandbox -isnot [string] -or
        -not [string]::Equals(
            [string]$workerSandbox,
            'workspace-write',
            [System.StringComparison]::Ordinal
        )
    ) {
        New-WorkerError 'Worker v0.1 只允许 codex.workerSandbox=workspace-write。'
    }

    $approvalPolicy = Get-WorkerProperty -Object $config.codex -Name 'approvalPolicy' -Context 'codex'
    if (
        $approvalPolicy -isnot [string] -or
        -not [string]::Equals(
            [string]$approvalPolicy,
            'never',
            [System.StringComparison]::Ordinal
        )
    ) {
        New-WorkerError 'Worker v0.1 只允许 codex.approvalPolicy=never。'
    }

    $restrictToRoot = Get-WorkerProperty `
        -Object $config.safety `
        -Name 'restrictToWorkspaceRoot' `
        -Context 'safety'
    if ($restrictToRoot -isnot [bool] -or -not [bool]$restrictToRoot) {
        New-WorkerError 'safety.restrictToWorkspaceRoot 必须是 JSON true。'
    }

    $protectedActionsValue = Get-WorkerProperty `
        -Object $config.safety `
        -Name 'requireExplicitAuthorizationFor' `
        -Context 'safety'
    if ($protectedActionsValue -isnot [System.Array]) {
        New-WorkerError 'safety.requireExplicitAuthorizationFor 必须是字符串数组。'
    }
    $protectedActions = New-Object 'System.Collections.Generic.List[string]'
    $protectedActionSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($action in $protectedActionsValue) {
        if ($action -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$action)) {
            New-WorkerError 'safety.requireExplicitAuthorizationFor 只能包含非空字符串。'
        }
        $normalizedAction = ([string]$action).Trim().ToLowerInvariant()
        if ($protectedActionSet.Add($normalizedAction)) {
            [void]$protectedActions.Add($normalizedAction)
        }
    }
    $baselineActions = @(
        'push', 'merge', 'publish', 'deploy', 'create-pr',
        'remote-permission-change', 'mass-delete', 'real-money-spend'
    )
    foreach ($requiredAction in $baselineActions) {
        if (-not $protectedActionSet.Contains($requiredAction)) {
            New-WorkerError "safety.requireExplicitAuthorizationFor 缺少 baseline protected action：$requiredAction。"
        }
    }

    $workspaceRoot = [System.IO.Path]::GetFullPath([string]$config.workspace.root)
    $resolvedIndexPath = Get-WorkerIndexPath -RequestedPath $IndexPath
    try {
        $indexText = [System.IO.File]::ReadAllText(
            $resolvedIndexPath,
            [System.Text.UTF8Encoding]::new($false, $true)
        )
    }
    catch {
        New-WorkerError "无法读取 Project Index：$resolvedIndexPath。"
    }
    try {
        $indexDocument = ConvertFrom-Json -InputObject $indexText
    }
    catch {
        New-WorkerError 'Project Index 不是有效 JSON。'
    }
    if (-not (Test-WorkerJsonObject -Value $indexDocument)) {
        New-WorkerError 'Project Index 顶层必须是 JSON object。'
    }

    $indexVersion = Get-WorkerProperty -Object $indexDocument -Name 'version' -Context 'Project Index'
    $integerVersion = (
        $indexVersion -is [byte] -or $indexVersion -is [sbyte] -or
        $indexVersion -is [int16] -or $indexVersion -is [uint16] -or
        $indexVersion -is [int32] -or $indexVersion -is [uint32] -or
        $indexVersion -is [int64]
    )
    if (-not $integerVersion -or [int64]$indexVersion -ne 1) {
        New-WorkerError 'Project Index version 必须是整数 1。'
    }

    $projectsValue = Get-WorkerProperty -Object $indexDocument -Name 'projects' -Context 'Project Index'
    if ($projectsValue -isnot [System.Array]) {
        New-WorkerError 'Project Index projects 必须是 JSON 数组。'
    }

    $matches = New-Object 'System.Collections.Generic.List[object]'
    # ROUTER SELECTION != WORKER AUTHORIZATION. Identity is resolved again from the current Index.
    for ($projectIndex = 0; $projectIndex -lt $projectsValue.Count; $projectIndex++) {
        $project = $projectsValue[$projectIndex]
        $context = "Project Index projects[$projectIndex]"
        if (-not (Test-WorkerJsonObject -Value $project)) {
            New-WorkerError "$context 必须是 JSON object。"
        }

        $nameValue = Get-WorkerProperty -Object $project -Name 'name' -Context $context
        if ($nameValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$nameValue)) {
            New-WorkerError "$context.name 必须是非空字符串。"
        }
        $pathValue = Get-WorkerProperty -Object $project -Name 'localPath' -Context $context
        if ($pathValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$pathValue)) {
            New-WorkerError "$context.localPath 必须是非空字符串。"
        }
        $repositoryValue = Get-WorkerProperty `
            -Object $project -Name 'githubRepository' -Context $context
        if ($null -eq $repositoryValue) {
            continue
        }
        if (
            $repositoryValue -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$repositoryValue)
        ) {
            New-WorkerError "$context.githubRepository 必须是合法 owner/repository 字符串或 null。"
        }
        $repository = [string]$repositoryValue
        if (-not (Test-WorkerRepositoryIdentity -Repository $repository)) {
            New-WorkerError "$context.githubRepository 必须使用合法 owner/repository 格式。"
        }

        if ([string]::Equals(
            $repository,
            $requestedRepository,
            [System.StringComparison]::Ordinal
        )) {
            [void]$matches.Add([pscustomobject][ordered]@{
                Name = ([string]$nameValue).Trim()
                LocalPath = [string]$pathValue
                GitHubRepository = $repository
                Context = $context
            })
        }
    }

    if ($matches.Count -eq 0) {
        New-WorkerError "Project Index 中找不到精确 repository：$requestedRepository。"
    }
    if ($matches.Count -gt 1) {
        New-WorkerError "Project Index 中 repository 精确匹配不唯一：$requestedRepository。"
    }
    $selected = $matches[0]
    $authorizedPath = Get-WorkerAuthorizedProjectPath `
        -Path ([string]$selected.LocalPath) `
        -WorkspaceRoot $workspaceRoot `
        -Context ([string]$selected.Context)

    $gitPath = Resolve-WorkerApplication `
        -Command 'git' `
        -Context 'git command' `
        -AllowedExtensions @('.exe', '.com', '.cmd', '.bat')
    $gitResult = Invoke-WorkerLocalGit `
        -GitExecutable $gitPath `
        -RepositoryPath $authorizedPath
    if ($gitResult.ExitCode -ne 0 -or $gitResult.Output.Count -ne 1) {
        New-WorkerError '授权项目不是有效的 Git working tree root。'
    }
    try {
        $gitRoot = [System.IO.Path]::GetFullPath(
            ([string]$gitResult.Output[0]).Trim()
        ).TrimEnd('\', '/')
    }
    catch {
        New-WorkerError 'git rev-parse 返回了无效 working tree root。'
    }
    if (-not [string]::Equals(
        $gitRoot,
        $authorizedPath.TrimEnd('\', '/'),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        New-WorkerError '授权 localPath 必须精确等于 Git working tree toplevel。'
    }

    $commandPath = Resolve-WorkerApplication `
        -Command $commandText `
        -Context 'codex.command' `
        -AllowedExtensions @('.exe', '.com', '.cmd', '.bat')
    $publicProject = [pscustomobject][ordered]@{
        name = [string]$selected.Name
        localPath = $authorizedPath
        githubRepository = [string]$selected.GitHubRepository
    }

    return [pscustomobject][ordered]@{
        RequestedRepository = $requestedRepository
        AuthorizedPath = $authorizedPath
        CommandPath = $commandPath
        PublicProject = $publicProject
        ProtectedActions = [object[]]$protectedActions.ToArray()
        ResolvedIndexPath = $resolvedIndexPath
    }
}

function New-WorkerSecurityArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AuthorizedPath
    )

    $projectTrustOverride = New-WorkerProjectTrustOverride -ProjectPath $AuthorizedPath
    return [string[]]@(
        '-c', 'sandbox_workspace_write.writable_roots=[]',
        '-c', 'sandbox_workspace_write.network_access=false',
        '-c', 'web_search="disabled"',
        '-c', 'shell_environment_policy.ignore_default_excludes=false',
        '-c', 'features.hooks=false',
        '-c', 'apps._default.enabled=false',
        '-c', $projectTrustOverride,
        '-c', 'approval_policy="never"',
        '--disable', 'plugins',
        '--sandbox', 'workspace-write',
        '--cd', $AuthorizedPath
    )
}

function Invoke-WorkerCodexExecution {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Initial', 'Resume')]
        [string]$Mode,

        [Parameter(Mandatory = $true)]
        [object]$WorkerContext,

        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter()]
        [AllowEmptyString()]
        [string]$RequestedThreadId = '',

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$DiagnosticSensitiveValues = @()
    )

    if ($Mode -ceq 'Resume' -and -not (Test-WorkerCanonicalThreadId -ThreadId $RequestedThreadId)) {
        New-WorkerError 'Resume RequestedThreadId 必须是 lowercase canonical UUID D。'
    }

    $tempPrefix = if ($Mode -ceq 'Resume') {
        'codex-dispatch-worker-resume-'
    }
    else {
        'codex-dispatch-worker-'
    }
    $tempDirectory = Join-Path (
        [System.IO.Path]::GetTempPath()
    ) ($tempPrefix + [guid]::NewGuid().ToString('N'))
    $schemaPath = Join-Path $tempDirectory 'output-schema.json'
    $finalResultPath = Join-Path $tempDirectory 'final-result.json'
    try {
        [void](New-Item -ItemType Directory -Path $tempDirectory)
        $schemaJson = ConvertTo-Json -InputObject (New-WorkerSchema) -Depth 10
        [System.IO.File]::WriteAllText(
            $schemaPath,
            $schemaJson + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )

        $processArguments = New-Object 'System.Collections.Generic.List[string]'
        foreach ($argument in @(New-WorkerSecurityArguments `
            -AuthorizedPath ([string]$WorkerContext.AuthorizedPath))) {
            [void]$processArguments.Add([string]$argument)
        }
        foreach ($argument in @(
            'exec',
            '--ignore-user-config',
            '--json',
            '--color', 'never',
            '--output-last-message', $finalResultPath,
            '--output-schema', $schemaPath
        )) {
            [void]$processArguments.Add([string]$argument)
        }
        if ($Mode -ceq 'Resume') {
            [void]$processArguments.Add('resume')
            [void]$processArguments.Add($RequestedThreadId)
        }
        [void]$processArguments.Add('-')

        $sensitiveValues = if ($Mode -ceq 'Resume') {
            [string[]]@(
                @($DiagnosticSensitiveValues) +
                @(
                    [string]$WorkerContext.AuthorizedPath,
                    [string]$WorkerContext.CommandPath,
                    $tempDirectory,
                    $schemaPath,
                    $finalResultPath
                )
            )
        }
        else {
            [string[]]@()
        }

        try {
            $processResult = Invoke-WorkerProcess `
                -CommandPath ([string]$WorkerContext.CommandPath) `
                -Arguments ([string[]]$processArguments.ToArray()) `
                -WorkingDirectory ([string]$WorkerContext.AuthorizedPath) `
                -StandardInput $Prompt
        }
        catch {
            if ($Mode -ceq 'Initial') {
                throw
            }
            $diagnostic = ConvertTo-WorkerSafeDiagnostic `
                -Value $_.Exception.Message `
                -Fallback 'Codex Worker process start failure。' `
                -SensitiveValues $sensitiveValues `
                -RedactCanonicalUuids:($Mode -ceq 'Resume') `
                -RedactAbsolutePaths:($Mode -ceq 'Resume')
            return New-WorkerOutput `
                -Status 'failed' `
                -Project $WorkerContext.PublicProject `
                -ThreadId $RequestedThreadId `
                -ExitCode -1 `
                -Diagnostic $diagnostic
        }

        $outputThreadId = if ($Mode -ceq 'Resume') { $RequestedThreadId } else { '' }
        if (-not [string]::IsNullOrWhiteSpace([string]$processResult.TransportError)) {
            $diagnostic = ConvertTo-WorkerSafeDiagnostic `
                -Value $processResult.TransportError `
                -Fallback 'Codex Worker process transport failure。' `
                -SensitiveValues $sensitiveValues `
                -RedactCanonicalUuids:($Mode -ceq 'Resume') `
                -RedactAbsolutePaths:($Mode -ceq 'Resume')
            return New-WorkerOutput `
                -Status 'failed' `
                -Project $WorkerContext.PublicProject `
                -ThreadId $outputThreadId `
                -ExitCode ([int]$processResult.ExitCode) `
                -Diagnostic $diagnostic
        }

        if ($processResult.ExitCode -ne 0) {
            $diagnostic = ConvertTo-WorkerSafeDiagnostic `
                -Value $processResult.StandardError `
                -Fallback "Codex CLI 退出码为 $($processResult.ExitCode)，stderr 为空。" `
                -SensitiveValues $sensitiveValues `
                -RedactCanonicalUuids:($Mode -ceq 'Resume') `
                -RedactAbsolutePaths:($Mode -ceq 'Resume')
            return New-WorkerOutput `
                -Status 'failed' `
                -Project $WorkerContext.PublicProject `
                -ThreadId $outputThreadId `
                -ExitCode ([int]$processResult.ExitCode) `
                -Diagnostic $diagnostic
        }

        try {
            if ($Mode -ceq 'Initial') {
                $outputThreadId = Get-WorkerThreadId `
                    -EventStream ([string]$processResult.StandardOutput)
            }
            else {
                Assert-WorkerResumeEventStream `
                    -EventStream ([string]$processResult.StandardOutput) `
                    -ExpectedThreadId $RequestedThreadId
            }
        }
        catch {
            $diagnostic = ConvertTo-WorkerSafeDiagnostic `
                -Value $_.Exception.Message `
                -Fallback 'Codex event stream protocol failure。' `
                -SensitiveValues $sensitiveValues `
                -RedactCanonicalUuids:($Mode -ceq 'Resume') `
                -RedactAbsolutePaths:($Mode -ceq 'Resume')
            return New-WorkerOutput `
                -Status 'failed' `
                -Project $WorkerContext.PublicProject `
                -ThreadId $outputThreadId `
                -ExitCode 0 `
                -Diagnostic $diagnostic
        }

        if (-not (Test-Path -LiteralPath $finalResultPath -PathType Leaf)) {
            return New-WorkerOutput `
                -Status 'failed' `
                -Project $WorkerContext.PublicProject `
                -ThreadId $outputThreadId `
                -ExitCode 0 `
                -Diagnostic 'Codex CLI 未生成 final result file。'
        }
        $finalItem = Get-Item -Force -LiteralPath $finalResultPath
        if (($finalItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return New-WorkerOutput `
                -Status 'failed' `
                -Project $WorkerContext.PublicProject `
                -ThreadId $outputThreadId `
                -ExitCode 0 `
                -Diagnostic 'Codex final result file 不能是 reparse point。'
        }

        try {
            $finalText = [System.IO.File]::ReadAllText(
                $finalResultPath,
                [System.Text.UTF8Encoding]::new($false, $true)
            )
        }
        catch {
            return New-WorkerOutput `
                -Status 'failed' `
                -Project $WorkerContext.PublicProject `
                -ThreadId $outputThreadId `
                -ExitCode 0 `
                -Diagnostic '无法安全读取 Codex final result file。'
        }
        try {
            $finalDocument = ConvertFrom-Json -InputObject $finalText
        }
        catch {
            return New-WorkerOutput `
                -Status 'failed' `
                -Project $WorkerContext.PublicProject `
                -ThreadId $outputThreadId `
                -ExitCode 0 `
                -Diagnostic 'Codex final result 不是有效 JSON。'
        }
        try {
            $validatedResult = ConvertFrom-WorkerFinalResult -Document $finalDocument
        }
        catch {
            $diagnostic = ConvertTo-WorkerSafeDiagnostic `
                -Value $_.Exception.Message `
                -Fallback 'Codex final result protocol failure。' `
                -SensitiveValues $sensitiveValues `
                -RedactCanonicalUuids:($Mode -ceq 'Resume') `
                -RedactAbsolutePaths:($Mode -ceq 'Resume')
            return New-WorkerOutput `
                -Status 'failed' `
                -Project $WorkerContext.PublicProject `
                -ThreadId $outputThreadId `
                -ExitCode 0 `
                -Diagnostic $diagnostic
        }

        return New-WorkerOutput `
            -Status ([string]$validatedResult.status) `
            -Project $WorkerContext.PublicProject `
            -ThreadId $outputThreadId `
            -Report ([string]$validatedResult.report) `
            -Question ([string]$validatedResult.question) `
            -Context ([string]$validatedResult.context) `
            -Options ([string[]]$validatedResult.options) `
            -ExitCode 0
    }
    finally {
        if (Test-Path -LiteralPath $tempDirectory) {
            $resolvedTempDirectory = [System.IO.Path]::GetFullPath($tempDirectory)
            $tempRootPrefix = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::GetTempPath()
            ).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
            if (-not $resolvedTempDirectory.StartsWith(
                $tempRootPrefix,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                if ($Mode -ceq 'Resume') {
                    New-WorkerError '拒绝清理不在系统 temp 下的 Worker artifact。'
                }
                New-WorkerError "拒绝清理不在系统 temp 下的 Worker artifact：$resolvedTempDirectory。"
            }
            try {
                Remove-Item -LiteralPath $resolvedTempDirectory -Recurse -Force -ErrorAction Stop
            }
            catch {
                if ($Mode -ceq 'Resume') {
                    New-WorkerError 'Worker temporary artifact cleanup failed。'
                }
                throw
            }
        }
    }
}
