Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'CodexDispatchState.Common.ps1')

$script:CodexDispatchGitHubApiBaseUri = 'https://api.github.com'
$script:CodexDispatchGitHubApiVersion = '2022-11-28'
$script:CodexDispatchGitHubErrorPrefix = 'Codex Dispatch GitHub Issue 错误：'

function ConvertTo-CodexDispatchGitHubSafeDiagnostic {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter()]
        [AllowNull()]
        [string]$Token,

        [Parameter()]
        [int]$MaximumLength = 2048
    )

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if (-not [string]::IsNullOrEmpty($Token)) {
        $text = $text.Replace($Token, '[REDACTED]')
    }
    $text = $text.Replace("`r", ' ').Replace("`n", ' ')
    if ($text.Length -gt $MaximumLength) {
        $text = $text.Substring(0, $MaximumLength) + '...'
    }
    return $text
}

function New-CodexDispatchGitHubIssueError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [AllowNull()]
        [string]$Token
    )

    $safeMessage = ConvertTo-CodexDispatchGitHubSafeDiagnostic `
        -Value $Message -Token $Token
    throw [System.InvalidOperationException]::new(
        $script:CodexDispatchGitHubErrorPrefix + $safeMessage
    )
}

function ConvertTo-CodexDispatchGitHubIssueError {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory = $true)]
        [string]$Context,

        [Parameter()]
        [AllowNull()]
        [string]$Token
    )

    $message = ConvertTo-CodexDispatchGitHubSafeDiagnostic `
        -Value $ErrorRecord.Exception.Message -Token $Token
    if ($message.StartsWith(
        $script:CodexDispatchGitHubErrorPrefix,
        [System.StringComparison]::Ordinal
    )) {
        throw [System.InvalidOperationException]::new($message)
    }
    New-CodexDispatchGitHubIssueError -Message "$Context。$message" -Token $Token
}

function Get-CodexDispatchGitHubProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [switch]$Required
    )

    $property = @(
        $Object.PSObject.Properties |
            Where-Object { $_.Name -ceq $Name }
    )
    if ($property.Count -eq 0) {
        if ($Required) {
            New-CodexDispatchGitHubIssueError -Message "缺少必需字段：$Name。"
        }
        return $null
    }
    if ($property.Count -ne 1) {
        New-CodexDispatchGitHubIssueError -Message "字段重复：$Name。"
    }
    return $property[0]
}

function Test-CodexDispatchGitHubInteger {
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

function ConvertTo-CodexDispatchGitHubIssueNumber {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    if (-not (Test-CodexDispatchGitHubInteger -Value $Value)) {
        New-CodexDispatchGitHubIssueError -Message 'IssueNumber 必须是 integer >= 1。'
    }
    try {
        $number = [int64]$Value
    }
    catch {
        New-CodexDispatchGitHubIssueError -Message 'IssueNumber 超出支持范围。'
    }
    if ($number -lt 1) {
        New-CodexDispatchGitHubIssueError -Message 'IssueNumber 必须是 integer >= 1。'
    }
    return $number
}

function Get-CodexDispatchGitHubIssueConfiguration {
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    $loader = Join-Path $PSScriptRoot 'Load-CodexDispatchConfig.ps1'
    $config = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        & $loader
    }
    else {
        & $loader -Path $ConfigPath
    }

    $providerProperty = Get-CodexDispatchGitHubProperty `
        -Object $config.controlPlane -Name 'provider' -Required
    if (
        $providerProperty.Value -isnot [string] -or
        [string]$providerProperty.Value -cne 'github'
    ) {
        New-CodexDispatchGitHubIssueError `
            -Message 'controlPlane.provider 必须 exactly github。'
    }

    $repositoryProperty = Get-CodexDispatchGitHubProperty `
        -Object $config.controlPlane -Name 'repository' -Required
    if ($repositoryProperty.Value -isnot [string]) {
        New-CodexDispatchGitHubIssueError `
            -Message 'controlPlane.repository 必须是 normalized owner/repository string。'
    }
    $repository = [string]$repositoryProperty.Value
    $repositoryPattern = '^(?<owner>[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/(?<repo>[A-Za-z0-9._-]{1,100})$'
    $repositoryMatch = [regex]::Match($repository, $repositoryPattern)
    if (
        -not $repositoryMatch.Success -or
        $repositoryMatch.Groups['owner'].Value.Contains('--') -or
        $repositoryMatch.Groups['repo'].Value -in @('.', '..') -or
        $repository -cne $repository.Trim()
    ) {
        New-CodexDispatchGitHubIssueError `
            -Message 'controlPlane.repository 必须是 normalized owner/repository。'
    }

    $issueAssignee = $null
    $assigneeProperty = Get-CodexDispatchGitHubProperty `
        -Object $config.controlPlane -Name 'issueAssignee'
    if ($null -ne $assigneeProperty) {
        if ($assigneeProperty.Value -isnot [string]) {
            New-CodexDispatchGitHubIssueError `
                -Message 'controlPlane.issueAssignee 必须是 string。'
        }
        $candidateAssignee = ([string]$assigneeProperty.Value).Trim()
        if (-not [string]::IsNullOrEmpty($candidateAssignee)) {
            if (
                $candidateAssignee -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$' -or
                $candidateAssignee.Contains('--')
            ) {
                New-CodexDispatchGitHubIssueError `
                    -Message 'controlPlane.issueAssignee 不是合法 GitHub login。'
            }
            $issueAssignee = $candidateAssignee
        }
    }

    $privacy = [ordered]@{}
    foreach ($privacyName in @(
        'exposeLocalPathsInIssues',
        'exposeThreadIdsInIssues',
        'includeOriginalTaskInIssues'
    )) {
        $privacyProperty = Get-CodexDispatchGitHubProperty `
            -Object $config.privacy -Name $privacyName -Required
        if ($privacyProperty.Value -isnot [bool]) {
            New-CodexDispatchGitHubIssueError `
                -Message "privacy.$privacyName 必须是 JSON bool。"
        }
        $privacy[$privacyName] = [bool]$privacyProperty.Value
    }

    return [pscustomobject][ordered]@{
        repository = $repository
        issueAssignee = $issueAssignee
        privacy = [pscustomobject]$privacy
        runtimeConfig = $config
    }
}

function ConvertTo-CodexDispatchGitHubLiteral {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    return $text.Replace('&', '&amp;').Replace('<', '&lt;').Replace(
        '>', '&gt;'
    ).Replace('"', '&quot;')
}

function Protect-CodexDispatchGitHubThreadIdentity {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter()]
        [AllowNull()]
        [string]$ThreadId,

        [Parameter(Mandatory = $true)]
        [bool]$ExposeThreadId
    )

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if (-not $ExposeThreadId -and -not [string]::IsNullOrEmpty($ThreadId)) {
        $text = [regex]::Replace(
            $text,
            [regex]::Escape($ThreadId),
            '[REDACTED_THREAD_ID]',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
        )
    }
    return $text
}

function Add-CodexDispatchGitHubLiteralSection {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lines,

        [Parameter(Mandatory = $true)]
        [string]$Heading,

        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter()]
        [AllowNull()]
        [string]$ThreadId,

        [Parameter(Mandatory = $true)]
        [bool]$ExposeThreadId
    )

    $Lines.Add('')
    $Lines.Add("## $Heading")
    $Lines.Add('')
    $privacySafeText = Protect-CodexDispatchGitHubThreadIdentity `
        -Value $Value -ThreadId $ThreadId -ExposeThreadId $ExposeThreadId
    $Lines.Add(
        '<pre>' + (ConvertTo-CodexDispatchGitHubLiteral -Value $privacySafeText) +
            '</pre>'
    )
}

function Get-CodexDispatchGitHubTitle {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $status = ([string]$State.status).ToUpperInvariant()
    $target = if ([string]$State.phase -ceq 'routing') {
        'ROUTING'
    }
    else {
        ([string]$State.projectRepository).Split('/')[1]
    }
    $fixedLength = '[CodexDispatch][]['.Length + $status.Length + ']'.Length
    $maximumTargetLength = 120 - $fixedLength
    if ($target.Length -gt $maximumTargetLength) {
        $target = $target.Substring(0, $maximumTargetLength - 1) + '~'
    }
    return "[CodexDispatch][$status][$target]"
}

function Get-CodexDispatchGitHubDesiredState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $pair = ([string]$State.phase) + '/' + ([string]$State.status)
    switch ($pair) {
        'routing/pending' { return 'open' }
        'routing/running' { return 'open' }
        'routing/needs_input' { return 'open' }
        'worker/running' { return 'open' }
        'worker/needs_input' { return 'open' }
        'worker/completed' { return 'closed' }
        'worker/failed' { return 'open' }
        default {
            New-CodexDispatchGitHubIssueError `
                -Message "无法投影非法 phase/status：$pair。"
        }
    }
}

function New-CodexDispatchGitHubIssueProjectionFromState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [object]$AdapterConfiguration
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $exposeThreadId = [bool]$AdapterConfiguration.privacy.exposeThreadIdsInIssues
    $lines.Add("<!-- CODEX_DISPATCH_ID: $($State.dispatchId) -->")
    $lines.Add("<!-- CODEX_DISPATCH_REVISION: $($State.revision) -->")
    $lines.Add('')
    $lines.Add("# Codex Dispatch · $(([string]$State.status).ToUpperInvariant())")
    $lines.Add('')
    $lines.Add("- Dispatch ID: ``$($State.dispatchId)``")
    $lines.Add("- Revision: ``$($State.revision)``")
    $lines.Add("- Phase / Status: ``$($State.phase)`` / ``$($State.status)``")
    if ($null -ne $State.projectRepository) {
        $lines.Add("- Project: ``$($State.projectRepository)``")
    }
    if (
        $AdapterConfiguration.privacy.exposeThreadIdsInIssues -and
        $null -ne $State.threadId
    ) {
        $lines.Add("- Thread ID: ``$($State.threadId)``")
    }

    Add-CodexDispatchGitHubLiteralSection `
        -Lines $lines -Heading 'Report' -Value $State.report `
        -ThreadId $State.threadId -ExposeThreadId $exposeThreadId
    Add-CodexDispatchGitHubLiteralSection `
        -Lines $lines -Heading 'Question' -Value $State.question `
        -ThreadId $State.threadId -ExposeThreadId $exposeThreadId
    Add-CodexDispatchGitHubLiteralSection `
        -Lines $lines -Heading 'Context' -Value $State.context `
        -ThreadId $State.threadId -ExposeThreadId $exposeThreadId

    $lines.Add('')
    $lines.Add('## Options')
    $lines.Add('')
    if ($State.options.Count -eq 0) {
        $lines.Add('<ol></ol>')
    }
    else {
        $lines.Add('<ol>')
        foreach ($option in $State.options) {
            $privacySafeOption = Protect-CodexDispatchGitHubThreadIdentity `
                -Value $option -ThreadId $State.threadId `
                -ExposeThreadId $exposeThreadId
            $lines.Add(
                '<li><pre>' +
                    (ConvertTo-CodexDispatchGitHubLiteral -Value $privacySafeOption) +
                    '</pre></li>'
            )
        }
        $lines.Add('</ol>')
    }

    if ([string]$State.phase -ceq 'worker' -and [string]$State.status -ceq 'failed') {
        $lines.Add('')
        $lines.Add('## Failure')
        $lines.Add('')
        $lines.Add('Dispatch failed.')
        Add-CodexDispatchGitHubLiteralSection `
            -Lines $lines -Heading 'Diagnostic' -Value $State.diagnostic `
            -ThreadId $State.threadId -ExposeThreadId $exposeThreadId
    }

    if ($AdapterConfiguration.privacy.includeOriginalTaskInIssues) {
        Add-CodexDispatchGitHubLiteralSection `
            -Lines $lines -Heading 'Original Task' -Value $State.task `
            -ThreadId $State.threadId -ExposeThreadId $exposeThreadId
    }

    return [pscustomobject][ordered]@{
        version = 1
        dispatchId = [string]$State.dispatchId
        revision = [int64]$State.revision
        title = Get-CodexDispatchGitHubTitle -State $State
        body = $lines -join "`n"
        desiredState = Get-CodexDispatchGitHubDesiredState -State $State
    }
}

function Get-CodexDispatchGitHubProjectionContext {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$DispatchId,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    $canonicalDispatchId = ConvertTo-CodexDispatchCanonicalGuid `
        -Value $DispatchId -Context 'dispatchId'
    $adapterConfiguration = Get-CodexDispatchGitHubIssueConfiguration `
        -ConfigPath $ConfigPath
    $getState = Join-Path $PSScriptRoot 'Get-CodexDispatchState.ps1'
    $state = & $getState `
        -DispatchId $canonicalDispatchId `
        -ConfigPath $ConfigPath
    $projection = New-CodexDispatchGitHubIssueProjectionFromState `
        -State $state `
        -AdapterConfiguration $adapterConfiguration
    return [pscustomobject][ordered]@{
        configuration = $adapterConfiguration
        projection = $projection
    }
}

function Read-CodexDispatchGitHubIssueMarkers {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Body
    )

    $pattern = '\A<!-- CODEX_DISPATCH_ID: (?<dispatchId>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) -->\r?\n<!-- CODEX_DISPATCH_REVISION: (?<revision>[1-9][0-9]*) -->\r?\n\r?\n'
    $match = [regex]::Match(
        $Body,
        $pattern,
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if (-not $match.Success) {
        New-CodexDispatchGitHubIssueError `
            -Message 'existing Issue body marker prefix malformed or missing。'
    }
    $dispatchId = ConvertTo-CodexDispatchCanonicalGuid `
        -Value $match.Groups['dispatchId'].Value `
        -Context 'existing Issue dispatchId'
    if ($dispatchId -cne $match.Groups['dispatchId'].Value) {
        New-CodexDispatchGitHubIssueError `
            -Message 'existing Issue dispatchId marker 必须是 lowercase canonical UUID D。'
    }
    $revision = [int64]0
    if (-not [int64]::TryParse(
        $match.Groups['revision'].Value,
        [System.Globalization.NumberStyles]::None,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$revision
    ) -or $revision -lt 1) {
        New-CodexDispatchGitHubIssueError `
            -Message 'existing Issue revision marker 必须是 positive integer。'
    }
    return [pscustomobject][ordered]@{
        dispatchId = $dispatchId
        revision = $revision
    }
}

function Assert-CodexDispatchGitHubRepositoryResponse {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response,

        [Parameter(Mandatory = $true)]
        [string]$Repository
    )

    $repositoryUrlProperty = Get-CodexDispatchGitHubProperty `
        -Object $Response -Name 'repository_url'
    if ($null -ne $repositoryUrlProperty) {
        $expected = "$($script:CodexDispatchGitHubApiBaseUri)/repos/$Repository"
        if (
            $repositoryUrlProperty.Value -isnot [string] -or
            -not [string]::Equals(
                [string]$repositoryUrlProperty.Value,
                $expected,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            New-CodexDispatchGitHubIssueError `
                -Message 'GitHub response repository context 不匹配。'
        }
    }
}

function Get-CodexDispatchGitHubValidatedIssueResponse {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response,

        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter()]
        [AllowNull()]
        [object]$ExpectedNumber,

        [Parameter()]
        [AllowNull()]
        [object]$ExpectedState
    )

    if (
        $null -eq $Response -or $Response -is [string] -or
        $Response -is [System.Array] -or $Response -is [System.ValueType]
    ) {
        New-CodexDispatchGitHubIssueError -Message 'GitHub Issue response 必须是 object。'
    }
    $numberProperty = Get-CodexDispatchGitHubProperty `
        -Object $Response -Name 'number' -Required
    $number = ConvertTo-CodexDispatchGitHubIssueNumber -Value $numberProperty.Value
    if ($null -ne $ExpectedNumber -and $number -ne [int64]$ExpectedNumber) {
        New-CodexDispatchGitHubIssueError `
            -Message 'GitHub response Issue number 不匹配。'
    }
    $urlProperty = Get-CodexDispatchGitHubProperty `
        -Object $Response -Name 'html_url' -Required
    if (
        $urlProperty.Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$urlProperty.Value)
    ) {
        New-CodexDispatchGitHubIssueError `
            -Message 'GitHub response html_url 必须是 non-empty string。'
    }
    Assert-CodexDispatchGitHubRepositoryResponse `
        -Response $Response -Repository $Repository
    if ($PSBoundParameters.ContainsKey('ExpectedState')) {
        if (
            $ExpectedState -isnot [string] -or
            [string]$ExpectedState -cnotin @('open', 'closed')
        ) {
            New-CodexDispatchGitHubIssueError `
                -Message 'ExpectedState 必须 exactly open 或 closed。'
        }
        $stateProperty = Get-CodexDispatchGitHubProperty `
            -Object $Response -Name 'state' -Required
        if (
            $stateProperty.Value -isnot [string] -or
            [string]$stateProperty.Value -cne [string]$ExpectedState
        ) {
            New-CodexDispatchGitHubIssueError -Message (
                'GitHub response Issue state 与 expected state 不匹配：' +
                "expected $ExpectedState。"
            )
        }
    }
    return [pscustomobject][ordered]@{
        number = $number
        url = [string]$urlProperty.Value
    }
}

function Get-CodexDispatchGitHubHttpErrorDetail {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $status = $null
    $githubMessage = $null
    if ($ErrorRecord.Exception.Data.Contains('StatusCode')) {
        $status = $ErrorRecord.Exception.Data['StatusCode']
    }
    if ($ErrorRecord.Exception.Data.Contains('GitHubMessage')) {
        $githubMessage = $ErrorRecord.Exception.Data['GitHubMessage']
    }
    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if (
        $null -eq $status -and
        $null -ne $responseProperty -and
        $null -ne $responseProperty.Value
    ) {
        try { $status = [int]$responseProperty.Value.StatusCode } catch { }
    }
    if (
        [string]::IsNullOrWhiteSpace([string]$githubMessage) -and
        $null -ne $ErrorRecord.ErrorDetails -and
        -not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ErrorDetails.Message)
    ) {
        $boundedErrorDetails = ConvertTo-CodexDispatchGitHubSafeDiagnostic `
            -Value $ErrorRecord.ErrorDetails.Message `
            -Token $Token `
            -MaximumLength 4096
        try {
            $errorDocument = ConvertFrom-Json -InputObject $boundedErrorDetails
            $messageProperty = $errorDocument.PSObject.Properties['message']
            if (
                $null -ne $messageProperty -and
                $messageProperty.Value -is [string] -and
                -not [string]::IsNullOrWhiteSpace([string]$messageProperty.Value)
            ) {
                $githubMessage = [string]$messageProperty.Value
            }
            else {
                $githubMessage = $boundedErrorDetails
            }
        }
        catch {
            $githubMessage = $boundedErrorDetails
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$githubMessage)) {
        $githubMessage = $ErrorRecord.Exception.Message
    }
    $safeStatus = if ($null -eq $status) { 'unknown' } else { [string]$status }
    $safeMessage = ConvertTo-CodexDispatchGitHubSafeDiagnostic `
        -Value $githubMessage -Token $Token -MaximumLength 2048
    return "GitHub HTTP $safeStatus：$safeMessage；endpoint $Path"
}

function Invoke-CodexDispatchGitHubRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter()]
        [AllowNull()]
        [string]$Body,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Transport
    )

    $request = [pscustomobject][ordered]@{
        method = $Method
        uri = $script:CodexDispatchGitHubApiBaseUri + $Path
        path = $Path
        headers = [ordered]@{
            Authorization = "Bearer $Token"
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = $script:CodexDispatchGitHubApiVersion
        }
        contentType = 'application/json; charset=utf-8'
        body = $Body
    }
    try {
        return & $Transport $request
    }
    catch {
        $detail = Get-CodexDispatchGitHubHttpErrorDetail `
            -ErrorRecord $_ -Path $Path -Token $Token
        New-CodexDispatchGitHubIssueError -Message $detail -Token $Token
    }
}

function Get-CodexDispatchGitHubDefaultTransport {
    return {
        param($Request)

        $parameters = @{
            Method = $Request.method
            Uri = $Request.uri
            Headers = $Request.headers
            ContentType = $Request.contentType
            ErrorAction = 'Stop'
        }
        if ($null -ne $Request.body) {
            $parameters['Body'] = [System.Text.UTF8Encoding]::new($false).GetBytes(
                [string]$Request.body
            )
        }
        Invoke-RestMethod @parameters
    }
}

function ConvertTo-CodexDispatchGitHubJson {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Payload
    )

    return ConvertTo-Json -InputObject $Payload -Depth 8 -Compress
}

function Assert-CodexDispatchGitHubPrivateControlRepository {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Transport
    )

    $repositoryPath = "/repos/$Repository"
    $metadata = Invoke-CodexDispatchGitHubRequest `
        -Method 'GET' -Path $repositoryPath -Token $Token `
        -Transport $Transport
    if (
        $null -eq $metadata -or $metadata -is [string] -or
        $metadata -is [System.Array] -or $metadata -is [System.ValueType]
    ) {
        New-CodexDispatchGitHubIssueError `
            -Message 'control-plane repository metadata response 必须是 object。' `
            -Token $Token
    }

    $fullNameProperty = Get-CodexDispatchGitHubProperty `
        -Object $metadata -Name 'full_name'
    if (
        $null -eq $fullNameProperty -or
        $fullNameProperty.Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$fullNameProperty.Value) -or
        -not [string]::Equals(
            [string]$fullNameProperty.Value,
            $Repository,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        New-CodexDispatchGitHubIssueError `
            -Message 'control-plane repository identity 与配置不匹配，拒绝发布。' `
            -Token $Token
    }

    $privateProperty = Get-CodexDispatchGitHubProperty `
        -Object $metadata -Name 'private'
    if (
        $null -eq $privateProperty -or
        $privateProperty.Value -isnot [bool] -or
        -not [bool]$privateProperty.Value
    ) {
        New-CodexDispatchGitHubIssueError -Message (
            'control-plane repository 必须是 private repository，' +
            '拒绝发布可能包含敏感信息的 dispatch projection。'
        ) -Token $Token
    }
}

function New-CodexDispatchGitHubPublishResult {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('created', 'updated', 'noop')]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [object]$Projection,

        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [int64]$IssueNumber,

        [Parameter(Mandatory = $true)]
        [string]$IssueUrl
    )

    return [pscustomobject][ordered]@{
        version = 1
        action = $Action
        dispatchId = [string]$Projection.dispatchId
        revision = [int64]$Projection.revision
        repository = $Repository
        issueNumber = $IssueNumber
        issueUrl = $IssueUrl
    }
}

function Invoke-CodexDispatchGitHubIssuePublishInternal {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$DispatchId,

        [Parameter()]
        [AllowNull()]
        [object]$IssueNumber,

        [Parameter()]
        [AllowEmptyString()]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Transport
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        New-CodexDispatchGitHubIssueError `
            -Message '缺少 CODEX_DISPATCH_GITHUB_TOKEN。'
    }
    $canonicalIssueNumber = if ($null -eq $IssueNumber) {
        $null
    }
    else {
        ConvertTo-CodexDispatchGitHubIssueNumber -Value $IssueNumber
    }
    $context = Get-CodexDispatchGitHubProjectionContext `
        -DispatchId $DispatchId -ConfigPath $ConfigPath
    $projection = $context.projection
    $repository = [string]$context.configuration.repository
    Assert-CodexDispatchGitHubPrivateControlRepository `
        -Repository $repository -Token $Token -Transport $Transport

    if ($null -eq $canonicalIssueNumber) {
        $payload = [ordered]@{
            title = [string]$projection.title
            body = [string]$projection.body
        }
        if ($null -ne $context.configuration.issueAssignee) {
            $payload['assignees'] = [string[]]@(
                [string]$context.configuration.issueAssignee
            )
        }
        $path = "/repos/$repository/issues"
        $response = Invoke-CodexDispatchGitHubRequest `
            -Method 'POST' -Path $path -Token $Token `
            -Body (ConvertTo-CodexDispatchGitHubJson -Payload $payload) `
            -Transport $Transport
        $validated = Get-CodexDispatchGitHubValidatedIssueResponse `
            -Response $response -Repository $repository `
            -ExpectedState 'open'
        if ([string]$projection.desiredState -ceq 'closed') {
            $createdIssuePath = "/repos/$repository/issues/$($validated.number)"
            $closedPayload = [ordered]@{
                title = [string]$projection.title
                body = [string]$projection.body
                state = 'closed'
            }
            try {
                $closedResponse = Invoke-CodexDispatchGitHubRequest `
                    -Method 'PATCH' -Path $createdIssuePath -Token $Token `
                    -Body (ConvertTo-CodexDispatchGitHubJson -Payload $closedPayload) `
                    -Transport $Transport
                [void](Get-CodexDispatchGitHubValidatedIssueResponse `
                    -Response $closedResponse -Repository $repository `
                    -ExpectedNumber $validated.number -ExpectedState 'closed')
            }
            catch {
                $detail = ConvertTo-CodexDispatchGitHubSafeDiagnostic `
                    -Value $_.Exception.Message -Token $Token -MaximumLength 2048
                New-CodexDispatchGitHubIssueError -Message (
                    'Issue 已创建，但 final desired-state synchronization 失败。' +
                    "IssueNumber=$($validated.number)；" +
                    "IssueUrl=$($validated.url)；desiredState=closed。$detail"
                ) -Token $Token
            }
        }
        return New-CodexDispatchGitHubPublishResult `
            -Action created -Projection $projection -Repository $repository `
            -IssueNumber $validated.number -IssueUrl $validated.url
    }

    $issuePath = "/repos/$repository/issues/$canonicalIssueNumber"
    $existing = Invoke-CodexDispatchGitHubRequest `
        -Method 'GET' -Path $issuePath -Token $Token `
        -Transport $Transport
    $validatedExisting = Get-CodexDispatchGitHubValidatedIssueResponse `
        -Response $existing -Repository $repository `
        -ExpectedNumber $canonicalIssueNumber
    $pullRequestProperty = Get-CodexDispatchGitHubProperty `
        -Object $existing -Name 'pull_request'
    if ($null -ne $pullRequestProperty) {
        New-CodexDispatchGitHubIssueError `
            -Message '拒绝修改 pull_request shaped Issue。' -Token $Token
    }
    $bodyProperty = Get-CodexDispatchGitHubProperty `
        -Object $existing -Name 'body' -Required
    if ($bodyProperty.Value -isnot [string]) {
        New-CodexDispatchGitHubIssueError `
            -Message 'existing Issue body 必须存在且为 string。' -Token $Token
    }
    $markers = Read-CodexDispatchGitHubIssueMarkers `
        -Body ([string]$bodyProperty.Value)
    if ($markers.dispatchId -cne $projection.dispatchId) {
        New-CodexDispatchGitHubIssueError `
            -Message 'existing Issue dispatchId 与 caller DispatchId 不匹配。' `
            -Token $Token
    }
    if ($markers.revision -gt $projection.revision) {
        New-CodexDispatchGitHubIssueError `
            -Message 'stale projection / refusing rollback。' -Token $Token
    }

    $titleProperty = Get-CodexDispatchGitHubProperty `
        -Object $existing -Name 'title' -Required
    $stateProperty = Get-CodexDispatchGitHubProperty `
        -Object $existing -Name 'state' -Required
    $remoteCanonical = (
        $titleProperty.Value -is [string] -and
        [string]$titleProperty.Value -ceq [string]$projection.title -and
        [string]$bodyProperty.Value -ceq [string]$projection.body -and
        $stateProperty.Value -is [string] -and
        [string]$stateProperty.Value -ceq [string]$projection.desiredState
    )
    if ($markers.revision -eq $projection.revision -and $remoteCanonical) {
        return New-CodexDispatchGitHubPublishResult `
            -Action noop -Projection $projection -Repository $repository `
            -IssueNumber $validatedExisting.number -IssueUrl $validatedExisting.url
    }

    $updatePayload = [ordered]@{
        title = [string]$projection.title
        body = [string]$projection.body
        state = [string]$projection.desiredState
    }
    $updated = Invoke-CodexDispatchGitHubRequest `
        -Method 'PATCH' -Path $issuePath -Token $Token `
        -Body (ConvertTo-CodexDispatchGitHubJson -Payload $updatePayload) `
        -Transport $Transport
    $validatedUpdated = Get-CodexDispatchGitHubValidatedIssueResponse `
        -Response $updated -Repository $repository `
        -ExpectedNumber $canonicalIssueNumber `
        -ExpectedState ([string]$projection.desiredState)
    return New-CodexDispatchGitHubPublishResult `
        -Action updated -Projection $projection -Repository $repository `
        -IssueNumber $validatedUpdated.number -IssueUrl $validatedUpdated.url
}
