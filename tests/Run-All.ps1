$ErrorActionPreference = 'Stop'

$scripts = @(
    'Test-Build-CodexProjectIndex.ps1',
    'Test-CodexDispatchGitHubIssue.ps1',
    'Test-CodexDispatchState.ps1',
    'Test-Discover-CodexProjects.ps1',
    'Test-Fast-Route-CodexTask.ps1',
    'Test-Invoke-CodexDispatch.ps1',
    'Test-Invoke-CodexDispatchResume.ps1',
    'Test-Invoke-CodexDispatchRoutingResume.ps1',
    'Test-Invoke-CodexWorker.ps1',
    'Test-Invoke-CodexWorkerResume.ps1',
    'Test-Load-CodexDispatchConfig.ps1',
    'Test-PrivateControlPlaneTemplate.ps1',
    'Test-Slow-Route-CodexTask.ps1'
)

$passed = 0
foreach ($name in $scripts) {
    $path = Join-Path $PSScriptRoot $name
    Write-Host "RUN $name"
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $path
    if ($LASTEXITCODE -ne 0) {
        throw "Release verification failed in $name with exit code $LASTEXITCODE."
    }
    $passed++
}

Write-Host "Release verification scripts: $passed/$($scripts.Count) PASS"

