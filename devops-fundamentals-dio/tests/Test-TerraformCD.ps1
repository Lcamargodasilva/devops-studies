# Testes locais com Azure, REST e Terraform simulados. Nenhum apply real.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('terraform-cd-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
Copy-Item (Join-Path $repo 'scripts/cd/Invoke-TerraformCD.ps1') $root
$policy = Get-Content (Join-Path $repo 'scripts/cd/policy.json') -Raw | ConvertFrom-Json
# Forçar estado desabilitado apenas na fixture, sem modificar a política real.
$policy.applyEnabled = $false
$runner = Join-Path $root 'Invoke-TerraformCD.ps1'
$policy | ConvertTo-Json | Set-Content (Join-Path $root 'policy.json') -Encoding utf8
$env:BUILD_SOURCESDIRECTORY = $repo
$env:AGENT_TEMPDIRECTORY = Join-Path $root 'temp'
$env:BUILD_ARTIFACTSTAGINGDIRECTORY = Join-Path $root 'staging'
$env:PIPELINE_WORKSPACE = Join-Path $root 'workspace'
foreach ($dir in @($env:AGENT_TEMPDIRECTORY, $env:BUILD_ARTIFACTSTAGINGDIRECTORY, $env:PIPELINE_WORKSPACE)) {
    New-Item -ItemType Directory -Path $dir | Out-Null
}
$env:BUILD_SOURCEBRANCH = 'refs/heads/main'
$env:BUILD_REASON = 'Manual'
$env:BUILD_SOURCEVERSION = 'fixture-commit'
$env:BUILD_REPOSITORY_ID = [guid]::NewGuid().ToString()
$env:BUILD_BUILDID = '123'
$env:idToken = 'fixture-not-a-token'
$env:servicePrincipalId = [guid]::NewGuid().ToString()
$env:tenantId = [guid]::NewGuid().ToString()
$env:ARM_OIDC_AZURE_SERVICE_CONNECTION_ID = [guid]::NewGuid().ToString()
$env:SYSTEM_ACCESSTOKEN = 'fixture-not-a-token'
$env:SYSTEM_OIDCREQUESTURI = 'https://example.invalid/oidc'
$env:BACKEND_STORAGE_ACCOUNT = 'fixturestorage'
$env:BACKEND_CONTAINER = 'tfstate'
$env:BACKEND_KEY = 'fixture.tfstate'
$env:PUBLISH_SAVED_PLAN = 'true'
$env:ARTIFACT_ACCESS_REVIEWED = 'true'
$global:cdFixture = @{
    head = 'fixture-commit'; disabled = $false; exists = 'true'; applyCount = 0
    change = @{mode='managed'; type='azurerm_resource_group'; name='rg'; address='azurerm_resource_group.rg'; change=@{actions=@('create')}}
}
function global:Invoke-RestMethod {
    param($Uri, $Headers)
    if ($Uri -match '/refs\?') { return @{value=@(@{name='refs/heads/main';objectId=$global:cdFixture.head})} }
    if ($Uri -match '/environments\?') { return @{value=@(@{name='dev-terraform';id=42})} }
    if ($Uri -match '/checks/configurations\?') {
        return @{value=@(@{id=7;modifiedOn='fixture-version';type=@{name='Approval'};isDisabled=$global:cdFixture.disabled;settings=@{approvers=@(@{id='fixture'});minRequiredApprovers=1}})}
    }
    throw 'Unexpected REST request in test'
}
function global:az {
    $global:LASTEXITCODE=0
    if ($args[0] -eq 'account') { return [guid]::Empty.ToString() }
    return $global:cdFixture.exists
}
function global:terraform {
    $global:LASTEXITCODE=0
    if ($args[0] -eq 'version') { return '{"terraform_version":"1.17.1","platform":"linux_amd64"}' }
    $work = $args[0].Substring(7)
    switch ($args[1]) {
        'init' { return 'PRIVATE_TEST_MARKER' }
        'validate' { return 'PRIVATE_TEST_MARKER' }
        'plan' { 'fixture-plan' | Set-Content (Join-Path $work 'review.tfplan'); $global:LASTEXITCODE=2 }
        'show' { return (@{resource_changes=@($global:cdFixture.change);outputs=@{secret='PRIVATE_TEST_MARKER'}} | ConvertTo-Json -Depth 10) }
        'apply' { $global:cdFixture.applyCount++; return 'PRIVATE_TEST_MARKER' }
        default { throw 'Unexpected Terraform command in test' }
    }
}
function Reject([string]$Mode, [string]$Pattern) {
    try { & $runner -Mode $Mode 6>&1 | Out-Null; throw 'UNEXPECTED_SUCCESS' }
    catch { if ($_.Exception.Message -notmatch $Pattern) { throw } }
}
try {
    Reject Apply 'Apply bloqueado'
    $env:BUILD_SOURCEBRANCH='refs/pull/1/merge'; Reject Plan 'CD permitido'; $env:BUILD_SOURCEBRANCH='refs/heads/main'
    $global:cdFixture.disabled=$true; Reject Plan 'manual ativa'; $global:cdFixture.disabled=$false
    $global:cdFixture.head='other'; Reject Plan 'branch principal'; $global:cdFixture.head='fixture-commit'
    $global:cdFixture.exists='false'; Reject Plan 'State existente'; $global:cdFixture.exists='true'
    $global:cdFixture.change.change.actions=@('delete','create'); Reject Plan 'Plano cont'; $global:cdFixture.change.change.actions=@('create')
    $captured = & $runner -Mode Plan 6>&1 | Out-String
    if ($captured -match 'PRIVATE_TEST_MARKER') { throw 'Private output leaked' }
    if ($LASTEXITCODE -ne 0) { throw 'plan=2 not treated as success' }
    $artifact = Join-Path $env:PIPELINE_WORKSPACE 'terraform-plan-123'
    Copy-Item (Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'terraform-plan-123') $env:PIPELINE_WORKSPACE -Recurse
    # Habilitar SOMENTE a cópia temporária para testar as barreiras seguintes.
    $policy.applyEnabled=$true
    $policy | ConvertTo-Json | Set-Content (Join-Path $root 'policy.json') -Encoding utf8
    $manifestPath = Join-Path $artifact 'manifest.json'
    $originalManifest = Get-Content $manifestPath -Raw
    $manifest = $originalManifest | ConvertFrom-Json
    $manifest.createdUtc=[DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
    $manifest | ConvertTo-Json | Set-Content $manifestPath -Encoding utf8
    Reject Apply 'Plano expirado'
    $originalManifest | Set-Content $manifestPath -Encoding utf8
    $env:BACKEND_KEY='different.tfstate'; Reject Apply 'contexto'; $env:BACKEND_KEY='fixture.tfstate'
    Add-Content (Join-Path $artifact 'review.tfplan') 'tampered'; Reject Apply 'Hash do plano'
    Copy-Item (Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'terraform-plan-123/review.tfplan') $artifact -Force
    $global:cdFixture.change.address='azurerm_storage_account.site'; Reject Apply 'Primeiro laborat'; $global:cdFixture.change.address='azurerm_resource_group.rg'
    if ($global:cdFixture.applyCount -ne 0) { throw 'A rejected case reached apply' }
    $captured = & $runner -Mode Apply 6>&1 | Out-String
    if ($global:cdFixture.applyCount -ne 1 -or $captured -match 'PRIVATE_TEST_MARKER') { throw 'Mock apply contract failed' }
    if (@(Get-ChildItem $env:AGENT_TEMPDIRECTORY -Directory -Filter 'terraform-cd-*').Count) { throw 'Temporary directory leaked' }
    Write-Output 'PASS: policy, PR, approval, branch, state, destructive plan, plan=2, expiry, context, hash, RG restriction, mock apply and cleanup.'
}
finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/') -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') -or
        [IO.Path]::GetFileName($resolved) -notmatch '^terraform-cd-test-[a-f0-9]{32}$') { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
