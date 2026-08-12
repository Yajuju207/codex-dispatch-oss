$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $repoRoot 'examples\private-control\dispatch.yml.example'
$documentPath = Join-Path $repoRoot 'docs\PRIVATE_CONTROL_PLANE.md'
$activeWorkflowPath = Join-Path $repoRoot '.github\workflows'

$testCount = 58
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT TRUE failed: $Message" }
}

function Assert-Equal {
    param(
        [Parameter()][AllowNull()][object]$Actual,
        [Parameter()][AllowNull()][object]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Actual -is [System.Array] -or $Expected -is [System.Array]) {
        if ((@($Actual) -join '|') -cne (@($Expected) -join '|')) {
            throw "ASSERT EQUAL failed: $Message; actual=$(@($Actual) -join '|'); expected=$(@($Expected) -join '|')"
        }
        return
    }
    if ($null -eq $Actual -and $null -eq $Expected) { return }
    if ($null -eq $Actual -or $null -eq $Expected -or
        [string]$Actual -cne [string]$Expected) {
        throw "ASSERT EQUAL failed: $Message; actual=$Actual; expected=$Expected"
    }
}

function Complete-Test {
    param([Parameter(Mandatory = $true)][string]$Name)
    $script:passed++
    Write-Host "PASS $script:passed/$testCount`: $Name"
}

Assert-True (Test-Path -LiteralPath $templatePath -PathType Leaf) `
    'inactive private-control template exists'
$template = Get-Content -Raw -LiteralPath $templatePath
$templateLines = @(Get-Content -LiteralPath $templatePath)
$document = Get-Content -Raw -LiteralPath $documentPath

Assert-True ($templatePath.EndsWith('.yml.example')) 'template is inactive by extension'
Complete-Test 'template uses inactive .yml.example extension'

$activeWorkflows = @(if (Test-Path -LiteralPath $activeWorkflowPath) {
    Get-ChildItem -LiteralPath $activeWorkflowPath -File -Recurse | Where-Object {
        $_.Extension -cin @('.yml','.yaml')
    }
})
Assert-Equal $activeWorkflows.Count 0 'active public workflow count'
Complete-Test 'public repository contains no active workflow'

Assert-True ($template -match '(?m)^on:\r?$') 'top-level on exists'
Assert-True ($template -match '(?m)^  workflow_dispatch:\r?$') 'workflow_dispatch exists'
Assert-Equal ([regex]::Matches($template, '(?m)^on:\r?$')).Count 1 `
    'single top-level on block'
Complete-Test 'workflow_dispatch is the explicit trigger'

$onStart = $template.IndexOf("on:")
$onPermissionsBoundary = $template.IndexOf("permissions:")
Assert-True ($onStart -ge 0 -and $onPermissionsBoundary -gt $onStart) `
    'trigger block boundaries'
$onBlock = $template.Substring($onStart, $onPermissionsBoundary - $onStart)
foreach ($forbiddenTrigger in @(
    'pull_request','pull_request_target','push','issue_comment','schedule',
    'workflow_call','repository_dispatch'
)) {
    Assert-True (-not ($onBlock -cmatch (
        '(?<![A-Za-z0-9_-])' + [regex]::Escape($forbiddenTrigger) +
        '(?![A-Za-z0-9_-])'
    ))) "forbidden trigger $forbiddenTrigger"
}
Complete-Test 'all forbidden workflow triggers are absent'

$inputsStart = $template.IndexOf("    inputs:")
$permissionsStart = $template.IndexOf("permissions:")
Assert-True ($inputsStart -ge 0 -and $permissionsStart -gt $inputsStart) `
    'inputs block boundaries'
$inputsBlock = $template.Substring($inputsStart, $permissionsStart - $inputsStart)
$inputMatches = [regex]::Matches($inputsBlock, '(?m)^      ([A-Za-z0-9_-]+):\r?$')
$inputNames = @($inputMatches | ForEach-Object { $_.Groups[1].Value })
Assert-Equal $inputNames @('task') 'workflow_dispatch input allowlist'
Complete-Test 'Task is the only workflow_dispatch input'

Assert-True ($inputsBlock -match '(?m)^        required: true\r?$') 'Task required'
Assert-True ($inputsBlock -match '(?m)^        type: string\r?$') 'Task string type'
Complete-Test 'Task input is mandatory string'

Assert-True ($template.Contains('$env:CODEX_DISPATCH_TASK.Length -lt 1')) `
    'minimum Task length check'
Assert-True ($template.Contains('$env:CODEX_DISPATCH_TASK.Length -gt 16384')) `
    'maximum Task length check'
Complete-Test 'Task length is constrained to 1..16384 .NET characters'

Assert-True ($template.Contains('[string]::IsNullOrWhiteSpace($env:CODEX_DISPATCH_TASK)')) `
    'whitespace-only Task rejection'
Complete-Test 'whitespace-only Task is rejected'

Assert-True (-not ($template -match '(?i)CODEX_DISPATCH_TASK[^\r\n]*\.Trim')) `
    'Task is not trimmed'
Assert-True (-not ($template -match '(?m)^\s*\$env:CODEX_DISPATCH_TASK\s*=')) `
    'Task environment value is not rewritten in run source'
Complete-Test 'accepted Task is not trimmed or rewritten'

$taskExpressionLines = @($templateLines | Where-Object {
    $_.Contains('${{ inputs.task }}')
})
Assert-Equal $taskExpressionLines.Count 2 'Task expression mapping count'
foreach ($line in $taskExpressionLines) {
    Assert-Equal $line.Trim() 'CODEX_DISPATCH_TASK: ${{ inputs.task }}' `
        'Task expression appears only in environment mapping'
}
Complete-Test 'Task expression is used only for step-scoped environment mapping'

Assert-True ($template.Contains('-Task $env:CODEX_DISPATCH_TASK')) `
    'Task environment invocation'
Complete-Test 'Orchestrator receives Task from CODEX_DISPATCH_TASK'

$allInputExpressions = [regex]::Matches(
    $template, '\$\{\{\s*inputs\.([A-Za-z0-9_-]+)\s*\}\}'
)
$expressionInputNames = @($allInputExpressions | ForEach-Object {
    $_.Groups[1].Value
} | Select-Object -Unique)
Assert-Equal $expressionInputNames @('task') 'caller-controlled expression allowlist'
Assert-True (-not $template.Contains('github.event.inputs')) `
    'alternate caller-controlled input context absent'
Complete-Test 'no caller-controlled SHA path repository token or script expression exists'

$permissionsMatch = [regex]::Match(
    $template,
    '(?ms)^permissions:\r?\n(?<body>.*?)^concurrency:\r?$'
)
Assert-True $permissionsMatch.Success 'permissions block exists'
$permissionEntries = [regex]::Matches(
    $permissionsMatch.Groups['body'].Value,
    '(?m)^  ([A-Za-z0-9_-]+):\s*([^\r\n]+)\r?$'
)
Assert-Equal $permissionEntries.Count 1 'permission entry count'
Assert-Equal $permissionEntries[0].Groups[1].Value 'issues' 'permission name'
Assert-Equal $permissionEntries[0].Groups[2].Value 'write' 'permission value'
Complete-Test 'permissions allow only issues write'

foreach ($forbiddenPermission in @(
    'contents','pull-requests','actions','id-token'
)) {
    Assert-True (-not ($template -match (
        '(?m)^\s*' + [regex]::Escape($forbiddenPermission) + '\s*:\s*write\s*$'
    ))) "forbidden write permission $forbiddenPermission"
}
Complete-Test 'forbidden write permissions are absent'

Assert-True ($template -match '(?m)^  group: codex-dispatch-control-plane-v0-1\r?$') `
    'constant concurrency group'
Complete-Test 'constant control-plane concurrency group is configured'

Assert-True ($template -match '(?m)^  cancel-in-progress: false\r?$') `
    'cancel-in-progress false'
Complete-Test 'in-progress dispatch cancellation is disabled'

Assert-True ($template -match '(?m)^  queue: max\r?$') 'queue max'
Complete-Test 'pending dispatches use queue max'

Assert-True ($template.Contains("if: `${{ github.ref == format('refs/heads/{0}', github.event.repository.default_branch) }}")) `
    'default-branch job gate'
Complete-Test 'job-level default-branch gate is present'

Assert-True ($document.Contains('not an independent security boundary')) `
    'default branch caveat'
Assert-True ($document.Contains('Write access to it is equivalent')) `
    'writer trust statement'
Complete-Test 'documentation states default-branch gate is not a malicious-writer boundary'

Assert-True ($document.Contains('exact workflow path')) 'selected workflow restriction'
Assert-True ($document.Contains('refs/heads/main')) 'main ref restriction'
Assert-True ($document.Contains('full commit SHA')) 'full SHA workflow restriction'
Complete-Test 'future runner-group exact workflow restriction is documented'

foreach ($label in @('self-hosted','Windows','X64','codex-dispatch-control')) {
    Assert-True ($template -match (
        '(?m)^      - ' + [regex]::Escape($label) + '\r?$'
    )) "runner label $label"
}
Complete-Test 'dedicated Windows self-hosted runner labels are exact'

Assert-True (-not ($template -match '(?m)^\s*(?:-\s*)?uses\s*:')) `
    'zero uses entries'
Complete-Test 'privileged template contains zero uses entries'

Assert-True (-not $template.Contains('actions/checkout')) 'no checkout action'
Complete-Test 'template uses no GitHub or third-party checkout action'

$shaMatch = [regex]::Match(
    $template,
    '(?m)^  CODEX_DISPATCH_ENGINE_SHA: ([0-9a-f]{40})\r?$'
)
Assert-True $shaMatch.Success 'full lowercase engine SHA constant'
Assert-Equal $shaMatch.Groups[1].Value `
    'e311f659bc641ea9b824f3cfd17974dcaf3176d4' 'reviewed baseline SHA'
Complete-Test 'engine is pinned to the reviewed full 40-character SHA'

Assert-True ($template -match '(?m)^  CODEX_DISPATCH_ENGINE_REPOSITORY: https://github\.com/Yajuju207/codex-dispatch-oss\.git\r?$') `
    'constant public engine repository'
Complete-Test 'engine repository is a workflow constant'

Assert-True ($template.Contains("'origin', `$env:CODEX_DISPATCH_ENGINE_SHA")) `
    'fetch exact SHA'
Assert-Equal ([regex]::Matches($template, "'fetch'")).Count 1 `
    'single native Git fetch'
Assert-True (-not $template.Contains('origin/main')) 'no floating main fetch'
Assert-True (-not ($template -match '(?i)CODEX_DISPATCH_ENGINE_(BRANCH|TAG)')) `
    'no engine branch or tag variable'
Complete-Test 'native Git fetch uses the pinned SHA, not a floating branch or tag'

Assert-True ($template.Contains("'checkout', '--detach'")) 'detached checkout'
Assert-True ($template.Contains('rev-parse HEAD')) 'HEAD verification'
Assert-True ($template.Contains('$actualSha -cne $env:CODEX_DISPATCH_ENGINE_SHA')) `
    'exact SHA comparison'
Complete-Test 'detached engine checkout is verified exactly'

Assert-True ($template.Contains('& git -c credential.helper= -c core.askPass=')) `
    'credential-free native Git flags'
Assert-True ($template.Contains("$env:GIT_TERMINAL_PROMPT = '0'")) `
    'noninteractive native Git'
Assert-True ($template.Contains("$env:GIT_CONFIG_NOSYSTEM = '1'")) `
    'system Git config disabled'
Assert-True ($template.Contains('$env:GIT_CONFIG_GLOBAL = $emptyGitConfig')) `
    'fresh empty global Git config'
Complete-Test 'engine acquisition disables credentials and prompting'

$gitConfigCountText = '$env:GIT_CONFIG_COUNT = ''0'''
$gitConfigCountIndex = $template.IndexOf($gitConfigCountText)
$firstNativeGitIndex = $template.IndexOf('& git')
Assert-Equal ([regex]::Matches(
    $template, [regex]::Escape($gitConfigCountText)
)).Count 1 'GIT_CONFIG_COUNT assignment count'
Assert-True ($gitConfigCountIndex -ge 0) 'exact GIT_CONFIG_COUNT zero assignment'
Assert-True ($firstNativeGitIndex -gt $gitConfigCountIndex) `
    'GIT_CONFIG_COUNT assignment precedes first native Git invocation'
Complete-Test 'Git environment command-scope config pairs are disabled before native Git'

Assert-True ($template -match '(?m)^  CODEX_DISPATCH_CONTROL_ROOT: C:\\CodexDispatch\\control\r?$') `
    'stable control root'
Complete-Test 'runner-local control root is a stable workflow constant'

Assert-True ($template.Contains("Join-Path `$controlRoot 'config.local.json'")) `
    'local config path'
Assert-True ($template.Contains("Join-Path `$controlRoot 'project-index.json'")) `
    'local Index path'
Complete-Test 'config and Project Index are located under the control root'

$preflightIndex = $template.IndexOf(
    '- name: Validate local configuration and control repository identity'
)
$indexBuildIndex = $template.IndexOf(
    '- name: Rebuild current Project Index without credentials'
)
$orchestratorIndex = $template.IndexOf(
    '- name: Invoke initial dispatch and classify structured outcome'
)
Assert-True ($preflightIndex -gt 0 -and $indexBuildIndex -gt $preflightIndex -and
    $orchestratorIndex -gt $indexBuildIndex) 'step order'
Complete-Test 'identity preflight precedes Index rebuild and Orchestrator'

$tokenMappingIndex = $template.IndexOf(
    'CODEX_DISPATCH_GITHUB_TOKEN: ${{ github.token }}'
)
Assert-True ($tokenMappingIndex -gt $indexBuildIndex -and
    $tokenMappingIndex -gt $preflightIndex) 'token injection order'
Complete-Test 'Issue credential injection occurs only after preflight and Index rebuild'

Assert-True ($template.Contains('scripts\Load-CodexDispatchConfig.ps1')) `
    'Config Loader preflight'
Complete-Test 'identity preflight uses the pinned Config Loader'

Assert-True ($template.Contains('$eventRepository = [string]$env:GITHUB_REPOSITORY')) `
    'GITHUB_REPOSITORY source'
Assert-True ($template.Contains('$config.controlPlane.repository -cne $eventRepository')) `
    'ordinal exact repository comparison'
Complete-Test 'configured control repository must exactly match GITHUB_REPOSITORY'

Assert-True ($template.Contains('GITHUB_REPOSITORY identity is invalid')) `
    'event repository validation'
Assert-True ($template.Contains("Groups['owner'].Value.Contains('--')")) `
    'owner semantics'
Assert-True ($template.Contains("Groups['repo'].Value -in @('.', '..')")) `
    'repository semantics'
Complete-Test 'control-repository preflight validates repository identity semantics'

Assert-True ($template.Contains('scripts\Build-CodexProjectIndex.ps1')) `
    'Index builder invocation'
Assert-True (-not $template.Contains('Discover-CodexProjects.ps1')) `
    'no separate Discovery invocation'
Complete-Test 'workflow rebuilds Index through Build-CodexProjectIndex only'

Assert-True ($template.Contains('-ConfigPath $configPath -OutputPath $indexPath')) `
    'explicit Index paths'
Complete-Test 'Index rebuild uses fixed local config and output paths'

$credentialRemovalBlock = @"
foreach (`$name in @('CODEX_DISPATCH_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN'))
"@
Assert-True ($template.Contains($credentialRemovalBlock.Trim())) `
    'three-credential removal block'
Complete-Test 'engine preflight and Index processes remove all three GitHub credentials'

$codexTokenMappings = [regex]::Matches(
    $template,
    '(?m)^(?<indent>\s*)CODEX_DISPATCH_GITHUB_TOKEN:\s*\$\{\{ github\.token \}\}\r?$'
)
Assert-Equal $codexTokenMappings.Count 1 'CODEX token mapping count'
Assert-Equal $codexTokenMappings[0].Groups['indent'].Value.Length 10 `
    'CODEX token mapping indentation'
Complete-Test 'github.token maps only to step-scoped CODEX token'

Assert-True (-not ($template -match '(?m)^\s*GH_TOKEN\s*:')) 'GH_TOKEN mapping absent'
Assert-True (-not ($template -match '(?m)^\s*GITHUB_TOKEN\s*:')) `
    'GITHUB_TOKEN mapping absent'
Complete-Test 'GH_TOKEN and GITHUB_TOKEN are never mapped'

$githubTokenExpressions = @($templateLines | Where-Object {
    $_.Contains('${{ github.token }}')
})
Assert-Equal $githubTokenExpressions.Count 1 'github.token expression count'
Assert-Equal $githubTokenExpressions[0].Trim() `
    'CODEX_DISPATCH_GITHUB_TOKEN: ${{ github.token }}' `
    'github.token destination'
Complete-Test 'built-in Issue credential has exactly one destination'

Assert-True ($template.Contains("foreach (`$name in @('GH_TOKEN', 'GITHUB_TOKEN'))")) `
    'Orchestrator step removes alternate tokens'
Complete-Test 'Orchestrator step explicitly removes GH_TOKEN and GITHUB_TOKEN'

Assert-True ($template.Contains('scripts\Invoke-CodexDispatch.ps1')) `
    'Orchestrator command'
Assert-True ($template.Contains('-Task $env:CODEX_DISPATCH_TASK -ConfigPath $configPath')) `
    'safe Orchestrator parameters'
Complete-Test 'workflow invokes only the public initial-dispatch API'

Assert-Equal ([regex]::Matches(
    $template, 'scripts\\Invoke-CodexDispatch\.ps1'
)).Count 1 'Orchestrator invocation count'
Complete-Test 'Orchestrator has exactly one invocation and no automatic retry'

foreach ($status in @('completed','needs_input','failed')) {
    Assert-True ($template.Contains("'$status'")) "structured status $status"
}
foreach ($classification in @(
    'DISPATCH_COMPLETED','DISPATCH_NEEDS_INPUT','DISPATCH_EXECUTION_FAILED'
)) {
    Assert-True ($template.Contains("'$classification'")) `
        "outcome classification $classification"
}
Complete-Test 'structured execution outcomes are classified deterministically'

Assert-True ($template.Contains(
    "[string]`$result.issuePublication -cne 'created'"
)) 'projection failure condition'
Assert-True ($template.Contains('PROJECTION_FAILURE: durable Runtime State remains authoritative')) `
    'projection truth statement'
Complete-Test 'projection failure is distinct from durable execution truth'

Assert-True ($template.Contains('do not retry automatically')) `
    'partial-create retry prohibition'
Complete-Test 'projection failure never triggers automatic initial-dispatch retry'

Assert-True ($template.Contains('$env:GITHUB_STEP_SUMMARY')) 'safe workflow summary'
Assert-True (-not $template.Contains('projectionDiagnostic')) `
    'projection diagnostic not logged'
Assert-True (-not $template.Contains('$result.report')) 'report not logged'
Assert-True (-not $template.Contains('$result.context')) 'context not logged'
Assert-True (-not $template.Contains('$result.diagnostic')) 'diagnostic not logged'
Complete-Test 'workflow summary excludes detailed State and diagnostics'

Assert-True (-not ($template -match '(?i)upload-artifact|download-artifact')) `
    'artifact actions absent'
Assert-True (-not ($template -match '(?im)^\s*artifact\s*:')) `
    'artifact configuration absent'
Complete-Test 'template uploads no config Index State Task or other artifacts'

foreach ($forbiddenPublicParameter in @(
    '-ProjectPath','-ProjectRepository','-Repository','-DispatchId','-IssueNumber',
    '-ThreadId','-Token','-ApiBaseUri','-Transport','-ScriptPath','-IndexPath',
    '-Force','-SkipAuthorization','-SkipRouting'
)) {
    Assert-True (-not $template.Contains($forbiddenPublicParameter)) `
        "forbidden public parameter $forbiddenPublicParameter"
}
Complete-Test 'template passes no caller authority or bypass parameter'

Assert-True ($document.Contains('does not implement Runner registration')) `
    'no runner setup scope'
Assert-True ($document.Contains('does not implement Runner registration, setup automation')) `
    'no setup helper scope'
Complete-Test 'documentation excludes runner registration and setup helper'

foreach ($excluded in @('issue_comment','Resume','codex exec resume')) {
    Assert-True ($document.Contains($excluded)) "documented exclusion $excluded"
}
Complete-Test 'Resume and issue-comment handling remain excluded'

Assert-True ($document.Contains('Runtime State is the dispatch lifecycle source of truth')) `
    'Runtime State truth'
Assert-True ($document.Contains('must never trigger an automatic retry')) `
    'projection retry boundary'
Complete-Test 'documentation preserves State-first projection semantics'

Assert-True ($document.Contains('Build-CodexProjectIndex.ps1')) `
    'documented Index builder'
Assert-True ($document.Contains('must not call `Discover-CodexProjects.ps1` separately')) `
    'documented no separate Discovery'
Complete-Test 'documentation assigns Index freshness to the workflow layer'

Assert-True ($document.Contains('not mapped to `GH_TOKEN` or `GITHUB_TOKEN`')) `
    'documented alternate credential absence'
Assert-True ($document -match 'temporarily\s+restores only `CODEX_DISPATCH_GITHUB_TOKEN`') `
    'documented Orchestrator isolation'
Complete-Test 'documentation defines exact credential visibility boundary'

Assert-True ($document.Contains('All unspecified permissions are `none`')) `
    'documented least permissions'
Assert-True ($document.Contains('Cross-repository publication is out of scope')) `
    'documented repository scope'
Complete-Test 'documentation limits Issue permission to the private control repository'

$runBlocks = New-Object 'System.Collections.Generic.List[string]'
for ($lineIndex = 0; $lineIndex -lt $templateLines.Count; $lineIndex++) {
    if ($templateLines[$lineIndex] -cne '        run: |') { continue }
    $body = New-Object 'System.Collections.Generic.List[string]'
    for ($bodyIndex = $lineIndex + 1; $bodyIndex -lt $templateLines.Count; $bodyIndex++) {
        $line = [string]$templateLines[$bodyIndex]
        if (-not [string]::IsNullOrEmpty($line) -and
            $line -notmatch '^          ') {
            break
        }
        if ($line.StartsWith('          ')) {
            [void]$body.Add($line.Substring(10))
        }
        else {
            [void]$body.Add('')
        }
    }
    [void]$runBlocks.Add(($body.ToArray() -join [Environment]::NewLine))
}
Assert-Equal $runBlocks.Count 5 'PowerShell run block count'
$embeddedParserErrors = New-Object 'System.Collections.Generic.List[object]'
foreach ($runBlock in $runBlocks) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput(
        $runBlock, [ref]$tokens, [ref]$errors
    )
    foreach ($error in $errors) { [void]$embeddedParserErrors.Add($error) }
}
Assert-Equal $embeddedParserErrors.Count 0 'embedded WinPS parser error count'
Complete-Test 'all embedded PowerShell run blocks parse without errors'

Assert-Equal $script:passed $testCount 'private control-plane template test total'
Write-Host "Private Control Plane template tests: $script:passed/$testCount PASS"
