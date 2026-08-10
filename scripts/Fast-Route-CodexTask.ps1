[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [AllowEmptyString()]
    [string]$Task,

    [Parameter()]
    [AllowEmptyString()]
    [string]$ConfigPath,

    [Parameter()]
    [AllowEmptyString()]
    [string]$IndexPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-FastRouterError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    throw [System.InvalidOperationException]::new(
        "Codex Dispatch 快速路由错误：$Message"
    )
}

function Test-FastRouterObject {
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

function Get-FastRouterProperty {
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
        New-FastRouterError "$Context 缺少必需字段：$Name。"
    }

    if ($property.Value -is [System.Array]) {
        Write-Output -NoEnumerate $property.Value
        return
    }

    return $property.Value
}

function Get-FastRouterNonNegativeInteger {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $isIntegerType = (
        $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64]
    )
    if (-not $isIntegerType) {
        New-FastRouterError "$Name 必须是非负整数。"
    }

    $parsed = [int64]$Value
    if ($parsed -lt 0 -or $parsed -gt [int]::MaxValue) {
        New-FastRouterError "$Name 必须是 0 到 $([int]::MaxValue) 之间的整数。"
    }

    return [int]$parsed
}

function ConvertTo-FastRouterNormalizedText {
    param(
        [Parameter()]
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $normalized = $Value.Normalize(
        [System.Text.NormalizationForm]::FormKC
    ).ToLowerInvariant()
    $normalized = [regex]::Replace($normalized, '[_\-\./\\\s]+', ' ')
    $normalized = [regex]::Replace($normalized, '[^\p{L}\p{M}\p{Nd}]+', ' ')
    return ([regex]::Replace($normalized, '\s+', ' ')).Trim()
}

function Test-FastRouterSignalMatch {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$NormalizedTask,

        [Parameter(Mandatory = $true)]
        [string]$NormalizedSignal
    )

    if ([string]::IsNullOrWhiteSpace($NormalizedSignal)) {
        return $false
    }

    if ([regex]::IsMatch($NormalizedSignal, '[^\u0000-\u007F]')) {
        return $NormalizedTask.Contains($NormalizedSignal)
    }

    return (' ' + $NormalizedTask + ' ').Contains(
        ' ' + $NormalizedSignal + ' '
    )
}

function Get-FastRouterTokenScore {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Length
    )

    if ($Length -ge 12) {
        return 80
    }
    if ($Length -ge 8) {
        return 60
    }
    if ($Length -ge 5) {
        return 35
    }
    if ($Length -ge 3) {
        return 15
    }
    return 0
}

function Test-FastRouterStopToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NormalizedToken,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$StopTokens
    )

    foreach ($component in $NormalizedToken.Split(' ')) {
        if ($StopTokens.Contains($component)) {
            return $true
        }
    }

    return $false
}

function Compare-FastRouterTokenRecord {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Left,

        [Parameter(Mandatory = $true)]
        [object]$Right
    )

    $comparison = [string]::Compare(
        [string]$Left.Normalized,
        [string]$Right.Normalized,
        [System.StringComparison]::Ordinal
    )
    if ($comparison -ne 0) {
        return $comparison
    }

    return [string]::Compare(
        [string]$Left.Value,
        [string]$Right.Value,
        [System.StringComparison]::Ordinal
    )
}

function Sort-FastRouterTokenRecords {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Records
    )

    $sorted = [object[]]$Records.Clone()
    for ($index = 1; $index -lt $sorted.Count; $index++) {
        $current = $sorted[$index]
        $cursor = $index - 1
        while (
            $cursor -ge 0 -and
            (Compare-FastRouterTokenRecord -Left $current -Right $sorted[$cursor]) -lt 0
        ) {
            $sorted[$cursor + 1] = $sorted[$cursor]
            $cursor--
        }
        $sorted[$cursor + 1] = $current
    }

    return $sorted
}

function Compare-FastRouterCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Left,

        [Parameter(Mandatory = $true)]
        [object]$Right
    )

    if ([int]$Left.Score -ne [int]$Right.Score) {
        if ([int]$Left.Score -gt [int]$Right.Score) {
            return -1
        }
        return 1
    }

    foreach ($propertyName in @('SortName', 'SortPath', 'Name', 'LocalPath')) {
        $comparison = [string]::Compare(
            [string]$Left.$propertyName,
            [string]$Right.$propertyName,
            [System.StringComparison]::Ordinal
        )
        if ($comparison -ne 0) {
            return $comparison
        }
    }

    return 0
}

function Sort-FastRouterCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Candidates
    )

    $sorted = [object[]]$Candidates.Clone()
    for ($index = 1; $index -lt $sorted.Count; $index++) {
        $current = $sorted[$index]
        $cursor = $index - 1
        while (
            $cursor -ge 0 -and
            (Compare-FastRouterCandidate -Left $current -Right $sorted[$cursor]) -lt 0
        ) {
            $sorted[$cursor + 1] = $sorted[$cursor]
            $cursor--
        }
        $sorted[$cursor + 1] = $current
    }

    return $sorted
}

function Get-FastRouterIndexPath {
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
        New-FastRouterError "IndexPath 无效：$candidate。"
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        New-FastRouterError "找不到 Project Index：$fullPath。"
    }

    $item = Get-Item -Force -LiteralPath $fullPath
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        New-FastRouterError 'Project Index 不能是 reparse point。'
    }

    return $item.FullName
}

function Get-FastRouterProjectString {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Project,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [int]$ProjectNumber
    )

    $value = Get-FastRouterProperty `
        -Object $Project `
        -Name $Name `
        -Context "Project Index projects[$ProjectNumber]"
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
        New-FastRouterError "Project Index projects[$ProjectNumber].$Name 必须是非空字符串。"
    }

    return [string]$value
}

function ConvertTo-FastRouterProject {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Project,

        [Parameter(Mandatory = $true)]
        [int]$ProjectNumber
    )

    if (-not (Test-FastRouterObject -Value $Project)) {
        New-FastRouterError "Project Index projects[$ProjectNumber] 必须是 JSON 对象。"
    }

    $name = Get-FastRouterProjectString `
        -Project $Project `
        -Name 'name' `
        -ProjectNumber $ProjectNumber
    $localPath = Get-FastRouterProjectString `
        -Project $Project `
        -Name 'localPath' `
        -ProjectNumber $ProjectNumber

    $repositoryValue = Get-FastRouterProperty `
        -Object $Project `
        -Name 'githubRepository' `
        -Context "Project Index projects[$ProjectNumber]"
    $githubRepository = $null
    if ($null -ne $repositoryValue) {
        if ($repositoryValue -isnot [string] -or [string]::IsNullOrWhiteSpace($repositoryValue)) {
            New-FastRouterError "Project Index projects[$ProjectNumber].githubRepository 必须是字符串或 null。"
        }
        $githubRepository = ([string]$repositoryValue).Trim()
        $repositoryParts = @($githubRepository.Split('/'))
        if (
            $repositoryParts.Count -ne 2 -or
            [string]::IsNullOrWhiteSpace($repositoryParts[0]) -or
            [string]::IsNullOrWhiteSpace($repositoryParts[1])
        ) {
            New-FastRouterError "Project Index projects[$ProjectNumber].githubRepository 必须使用 owner/repository 格式。"
        }
    }

    $tokensValue = Get-FastRouterProperty `
        -Object $Project `
        -Name 'tokens' `
        -Context "Project Index projects[$ProjectNumber]"
    if ($tokensValue -isnot [System.Array]) {
        New-FastRouterError "Project Index projects[$ProjectNumber].tokens 必须是 JSON 数组。"
    }

    $tokenValues = [System.Collections.Generic.Dictionary[string,string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($tokenValue in $tokensValue) {
        if ($tokenValue -isnot [string] -or [string]::IsNullOrWhiteSpace($tokenValue)) {
            New-FastRouterError "Project Index projects[$ProjectNumber].tokens 只能包含非空字符串。"
        }

        $normalizedToken = ConvertTo-FastRouterNormalizedText -Value $tokenValue
        if ([string]::IsNullOrWhiteSpace($normalizedToken)) {
            New-FastRouterError "Project Index projects[$ProjectNumber].tokens 包含无法规范化的 token。"
        }

        if (-not $tokenValues.ContainsKey($normalizedToken)) {
            $tokenValues[$normalizedToken] = [string]$tokenValue
        }
        elseif ([string]::Compare(
            [string]$tokenValue,
            $tokenValues[$normalizedToken],
            [System.StringComparison]::Ordinal
        ) -lt 0) {
            $tokenValues[$normalizedToken] = [string]$tokenValue
        }
    }

    $trackedPathCount = Get-FastRouterNonNegativeInteger `
        -Value (Get-FastRouterProperty `
            -Object $Project `
            -Name 'trackedPathCount' `
            -Context "Project Index projects[$ProjectNumber]") `
        -Name "Project Index projects[$ProjectNumber].trackedPathCount"
    $indexedTrackedPathCount = Get-FastRouterNonNegativeInteger `
        -Value (Get-FastRouterProperty `
            -Object $Project `
            -Name 'indexedTrackedPathCount' `
            -Context "Project Index projects[$ProjectNumber]") `
        -Name "Project Index projects[$ProjectNumber].indexedTrackedPathCount"
    if ($indexedTrackedPathCount -gt $trackedPathCount) {
        New-FastRouterError "Project Index projects[$ProjectNumber] 的 indexedTrackedPathCount 不能大于 trackedPathCount。"
    }

    $truncated = Get-FastRouterProperty `
        -Object $Project `
        -Name 'truncated' `
        -Context "Project Index projects[$ProjectNumber]"
    if ($truncated -isnot [bool]) {
        New-FastRouterError "Project Index projects[$ProjectNumber].truncated 必须是 JSON 布尔值。"
    }

    $tokenRecords = New-Object 'System.Collections.Generic.List[object]'
    foreach ($normalizedToken in $tokenValues.Keys) {
        $signalLength = $normalizedToken.Replace(' ', '').Length
        [void]$tokenRecords.Add([pscustomobject][ordered]@{
            Value = $tokenValues[$normalizedToken]
            Normalized = $normalizedToken
            Length = [int]$signalLength
        })
    }
    $sortedTokenRecords = Sort-FastRouterTokenRecords `
        -Records ([object[]]$tokenRecords.ToArray())

    $normalizedName = ConvertTo-FastRouterNormalizedText -Value $name
    if ([string]::IsNullOrWhiteSpace($normalizedName)) {
        New-FastRouterError "Project Index projects[$ProjectNumber].name 无法规范化。"
    }

    $repositoryName = ''
    if ($null -ne $githubRepository) {
        $repositorySegments = @($githubRepository.Split('/'))
        $repositoryName = [string]$repositorySegments[-1]
    }

    return [pscustomobject][ordered]@{
        Name = $name
        LocalPath = $localPath
        GitHubRepository = $githubRepository
        NormalizedName = $normalizedName
        NormalizedRepositoryName = ConvertTo-FastRouterNormalizedText -Value $repositoryName
        NormalizedFullRepository = ConvertTo-FastRouterNormalizedText -Value $githubRepository
        Tokens = [object[]]$sortedTokenRecords
    }
}

function New-FastRouterCandidateOutput {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Candidate
    )

    return [pscustomobject][ordered]@{
        name = [string]$Candidate.Name
        localPath = [string]$Candidate.LocalPath
        githubRepository = $Candidate.GitHubRepository
        score = [int]$Candidate.Score
        matchedSignals = [object[]]$Candidate.MatchedSignals
    }
}

if ([string]::IsNullOrWhiteSpace($Task)) {
    New-FastRouterError 'Task 必须是非空字符串。'
}

$loaderPath = Join-Path $PSScriptRoot 'Load-CodexDispatchConfig.ps1'
if (-not (Test-Path -LiteralPath $loaderPath -PathType Leaf)) {
    New-FastRouterError "找不到配置加载器：$loaderPath。"
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
    New-FastRouterError "无法加载配置。$($_.Exception.Message)"
}

$routing = Get-FastRouterProperty `
    -Object $config `
    -Name 'routing' `
    -Context '配置'
$fast = Get-FastRouterProperty `
    -Object $routing `
    -Name 'fast' `
    -Context '配置 routing'
if (-not (Test-FastRouterObject -Value $fast)) {
    New-FastRouterError '配置 routing.fast 必须是 JSON 对象。'
}

$enabled = Get-FastRouterProperty `
    -Object $fast `
    -Name 'enabled' `
    -Context '配置 routing.fast'
if ($enabled -isnot [bool]) {
    New-FastRouterError '配置 routing.fast.enabled 必须是 JSON 布尔值。'
}
$minimumStrongScore = Get-FastRouterNonNegativeInteger `
    -Value (Get-FastRouterProperty `
        -Object $fast `
        -Name 'minimumStrongScore' `
        -Context '配置 routing.fast') `
    -Name '配置 routing.fast.minimumStrongScore'
$minimumLead = Get-FastRouterNonNegativeInteger `
    -Value (Get-FastRouterProperty `
        -Object $fast `
        -Name 'minimumLead' `
        -Context '配置 routing.fast') `
    -Name '配置 routing.fast.minimumLead'

if (-not $enabled) {
    return [pscustomobject][ordered]@{
        version = 1
        status = 'disabled'
        topScore = 0
        lead = 0
        selectedProject = $null
        candidates = [object[]]@()
    }
}

$resolvedIndexPath = Get-FastRouterIndexPath -RequestedPath $IndexPath
try {
    $indexText = [System.IO.File]::ReadAllText(
        $resolvedIndexPath,
        [System.Text.UTF8Encoding]::new($false, $true)
    )
}
catch {
    New-FastRouterError "无法读取 Project Index：$resolvedIndexPath。"
}

try {
    $indexDocument = ConvertFrom-Json -InputObject $indexText
}
catch {
    New-FastRouterError 'Project Index 不是有效 JSON。'
}
if (-not (Test-FastRouterObject -Value $indexDocument)) {
    New-FastRouterError 'Project Index 顶层必须是 JSON 对象。'
}

$indexVersion = Get-FastRouterNonNegativeInteger `
    -Value (Get-FastRouterProperty `
        -Object $indexDocument `
        -Name 'version' `
        -Context 'Project Index') `
    -Name 'Project Index version'
if ($indexVersion -ne 1) {
    New-FastRouterError "不支持 Project Index version=$indexVersion；当前仅支持 version=1。"
}

$projectsValue = Get-FastRouterProperty `
    -Object $indexDocument `
    -Name 'projects' `
    -Context 'Project Index'
if ($projectsValue -isnot [System.Array]) {
    New-FastRouterError 'Project Index projects 必须是 JSON 数组。'
}

$projects = New-Object 'System.Collections.Generic.List[object]'
for ($projectIndex = 0; $projectIndex -lt $projectsValue.Count; $projectIndex++) {
    [void]$projects.Add(
        (ConvertTo-FastRouterProject `
            -Project $projectsValue[$projectIndex] `
            -ProjectNumber $projectIndex)
    )
}
$projectArray = [object[]]$projects.ToArray()

$tokenProjectCounts = [System.Collections.Generic.Dictionary[string,int]]::new(
    [System.StringComparer]::Ordinal
)
foreach ($project in $projectArray) {
    foreach ($tokenRecord in $project.Tokens) {
        if ($tokenProjectCounts.ContainsKey($tokenRecord.Normalized)) {
            $tokenProjectCounts[$tokenRecord.Normalized]++
        }
        else {
            $tokenProjectCounts[$tokenRecord.Normalized] = 1
        }
    }
}

$stopTokens = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal
)
foreach ($stopToken in @(
    'src', 'source', 'test', 'tests', 'doc', 'docs', 'script', 'scripts',
    'build', 'main', 'readme', 'license', 'config', 'git', 'github',
    'code', 'app', 'lib'
)) {
    [void]$stopTokens.Add($stopToken)
}

$normalizedTask = ConvertTo-FastRouterNormalizedText -Value $Task
$candidateRecords = New-Object 'System.Collections.Generic.List[object]'
foreach ($project in $projectArray) {
    $score = 0
    $matchedSignals = New-Object 'System.Collections.Generic.List[object]'
    $identityTokens = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($identityToken in @(
        $project.NormalizedName,
        $project.NormalizedRepositoryName,
        $project.NormalizedFullRepository
    )) {
        if (-not [string]::IsNullOrWhiteSpace($identityToken)) {
            [void]$identityTokens.Add($identityToken)
        }
    }

    if (
        -not [string]::IsNullOrWhiteSpace($project.NormalizedFullRepository) -and
        (Test-FastRouterSignalMatch `
            -NormalizedTask $normalizedTask `
            -NormalizedSignal $project.NormalizedFullRepository)
    ) {
        $score += 220
        [void]$matchedSignals.Add([pscustomobject][ordered]@{
            kind = 'owner_repository'
            value = $project.GitHubRepository
            score = 220
        })
    }
    elseif (Test-FastRouterSignalMatch `
        -NormalizedTask $normalizedTask `
        -NormalizedSignal $project.NormalizedName
    ) {
        $score += 180
        [void]$matchedSignals.Add([pscustomobject][ordered]@{
            kind = 'project_name'
            value = $project.Name
            score = 180
        })
    }
    elseif (
        -not [string]::IsNullOrWhiteSpace($project.NormalizedRepositoryName) -and
        (Test-FastRouterSignalMatch `
            -NormalizedTask $normalizedTask `
            -NormalizedSignal $project.NormalizedRepositoryName)
    ) {
        $score += 180
        [void]$matchedSignals.Add([pscustomobject][ordered]@{
            kind = 'repository_name'
            value = ([string]$project.GitHubRepository).Split('/')[-1]
            score = 180
        })
    }

    foreach ($tokenRecord in $project.Tokens) {
        if (
            $identityTokens.Contains($tokenRecord.Normalized) -or
            (Test-FastRouterStopToken `
                -NormalizedToken $tokenRecord.Normalized `
                -StopTokens $stopTokens) -or
            -not (Test-FastRouterSignalMatch `
                -NormalizedTask $normalizedTask `
                -NormalizedSignal $tokenRecord.Normalized)
        ) {
            continue
        }

        $baseScore = Get-FastRouterTokenScore -Length $tokenRecord.Length
        if ($baseScore -eq 0) {
            continue
        }

        $uniqueBonus = 0
        if ($tokenProjectCounts[$tokenRecord.Normalized] -eq 1) {
            if ($tokenRecord.Length -ge 8) {
                $uniqueBonus = 60
            }
            elseif ($tokenRecord.Length -ge 5) {
                $uniqueBonus = 25
            }
        }

        $signalScore = $baseScore + $uniqueBonus
        $score += $signalScore
        [void]$matchedSignals.Add([pscustomobject][ordered]@{
            kind = 'token'
            value = $tokenRecord.Value
            normalizedValue = $tokenRecord.Normalized
            score = [int]$signalScore
            baseScore = [int]$baseScore
            uniqueBonus = [int]$uniqueBonus
        })
    }

    [void]$candidateRecords.Add([pscustomobject][ordered]@{
        Name = $project.Name
        LocalPath = $project.LocalPath
        GitHubRepository = $project.GitHubRepository
        Score = [int]$score
        MatchedSignals = [object[]]$matchedSignals.ToArray()
        SortName = $project.NormalizedName
        SortPath = ConvertTo-FastRouterNormalizedText -Value $project.LocalPath
    })
}

$rankedCandidates = @(Sort-FastRouterCandidates `
    -Candidates ([object[]]$candidateRecords.ToArray()))
$topScore = if ($rankedCandidates.Count -gt 0) {
    [int]$rankedCandidates[0].Score
}
else {
    0
}
$lead = if ($rankedCandidates.Count -gt 1) {
    [int]$rankedCandidates[0].Score - [int]$rankedCandidates[1].Score
}
else {
    $topScore
}

$status = if ($topScore -eq 0) {
    'no_match'
}
elseif (
    $topScore -ge $minimumStrongScore -and
    $lead -ge $minimumLead
) {
    'strong'
}
else {
    'ambiguous'
}

$candidateOutputs = New-Object 'System.Collections.Generic.List[object]'
$candidateOutputCount = [Math]::Min(3, $rankedCandidates.Count)
for ($candidateIndex = 0; $candidateIndex -lt $candidateOutputCount; $candidateIndex++) {
    [void]$candidateOutputs.Add(
        (New-FastRouterCandidateOutput -Candidate $rankedCandidates[$candidateIndex])
    )
}

$selectedProject = $null
if ($status -eq 'strong') {
    $winner = $rankedCandidates[0]
    $selectedProject = [pscustomobject][ordered]@{
        name = [string]$winner.Name
        localPath = [string]$winner.LocalPath
        githubRepository = $winner.GitHubRepository
        score = [int]$winner.Score
        matchedSignals = [object[]]$winner.MatchedSignals
    }
}

[pscustomobject][ordered]@{
    version = 1
    status = $status
    topScore = [int]$topScore
    lead = [int]$lead
    selectedProject = $selectedProject
    candidates = [object[]]$candidateOutputs.ToArray()
}
