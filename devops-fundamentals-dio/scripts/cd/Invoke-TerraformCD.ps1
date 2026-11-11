param([Parameter(Mandatory)][ValidateSet('Plan', 'Apply')][string]$Mode)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$policy = Get-Content (Join-Path $PSScriptRoot 'policy.json') -Raw | ConvertFrom-Json
if ($Mode -eq 'Apply' -and $policy.applyEnabled -ne $true) {
    throw 'Apply bloqueado no código. Exige autorização explícita e revisão de policy.json.'
}
if ($env:BUILD_SOURCEBRANCH -ne $policy.authorizedBranch -or $env:BUILD_REASON -ne 'Manual') {
    throw 'CD permitido somente em execução manual da branch autorizada.'
}
if (-not $env:AGENT_TEMPDIRECTORY -or -not $env:BUILD_SOURCESDIRECTORY) { throw 'Contexto do agente ausente.' }
if (-not $env:idToken -or -not $env:servicePrincipalId -or -not $env:tenantId) { throw 'Conexão WIF obrigatória.' }
if (-not $env:SYSTEM_ACCESSTOKEN) { throw 'Token temporário do job ausente.' }
$connectionId = [guid]::Empty
if (-not [guid]::TryParse($env:ARM_OIDC_AZURE_SERVICE_CONNECTION_ID, [ref]$connectionId)) { throw 'GUID da conexão inválido.' }
if ($env:SYSTEM_OIDCREQUESTURI -notmatch '^https://') { throw 'Endpoint OIDC ausente.' }
if ($env:BACKEND_STORAGE_ACCOUNT -notmatch '^[a-z0-9]{3,24}$' -or
    $env:BACKEND_CONTAINER -notmatch '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' -or
    [string]::IsNullOrWhiteSpace($env:BACKEND_KEY) -or $env:BACKEND_KEY -match 'PREENCHER|[<>\r\n]') {
    throw 'Endereço real do backend não preenchido.'
}
$publish = $env:PUBLISH_SAVED_PLAN -eq 'true'
if ($publish -and $env:ARTIFACT_ACCESS_REVIEWED -ne 'true') {
    throw 'Confirme antes as permissões e retenção dos artefatos no Azure DevOps.'
}

function Get-DevOps([string]$RelativePath) {
    # Somente a organização/projeto deste laboratório; nunca registrar cabeçalhos.
    $base = 'https://dev.azure.com/contatolcamargo/AulaDevOps-001/_apis/'
    try { Invoke-RestMethod -Uri ($base + $RelativePath) -Headers @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" } }
    catch { throw 'Consulta de segurança Azure DevOps falhou. Verifique permissão de leitura do Build Service; execução bloqueada.' }
}
function Assert-CurrentCommit {
    $repo = [uri]::EscapeDataString($env:BUILD_REPOSITORY_ID)
    $branch = [uri]::EscapeDataString($policy.authorizedBranch.Substring(5))
    $refs = Get-DevOps "git/repositories/$repo/refs?filter=$branch&api-version=7.1"
    $match = @($refs.value | Where-Object { $_.name -eq $policy.authorizedBranch })
    if ($match.Count -ne 1 -or $match[0].objectId -ne $env:BUILD_SOURCEVERSION) {
        throw 'A branch principal mudou ou não existe. Gere um novo plano em nova execução.'
    }
}
function Get-ApprovalFingerprint {
    $environments = Get-DevOps ('distributedtask/environments?name=' + $policy.environment + '&api-version=7.1')
    $environments = @($environments.value | Where-Object { $_.name -eq $policy.environment })
    if ($environments.Count -ne 1) { throw 'Environment dev-terraform deve existir previamente.' }
    $environmentId = $environments[0].id
    $checks = Get-DevOps ('pipelines/checks/configurations?resourceType=environment&resourceId=' + $environmentId + '&$expand=settings&api-version=7.1-preview.1')
    $approvals = @($checks.value | Where-Object {
        $_.type.name -eq 'Approval' -and $_.isDisabled -ne $true -and
        @($_.settings.approvers).Count -gt 0 -and $_.settings.minRequiredApprovers -ge 1
    })
    if ($approvals.Count -eq 0) { throw 'Aprovação manual ativa com aprovadores não confirmada; apply/publicação bloqueados.' }
    # Uma alteração dos checks depois do plano exige novo plano/aprovação.
    return (@($approvals | Sort-Object id | ForEach-Object { "$environmentId/$($_.id)/$($_.modifiedOn)" }) -join ';')
}

Get-ChildItem Env: | Where-Object {
    $_.Name -match '^TF_(LOG|CLI_ARGS)' -or $_.Name -in @(
        'ARM_CLIENT_SECRET', 'ARM_CLIENT_SECRET_FILE_PATH', 'ARM_ACCESS_KEY', 'ARM_SAS_TOKEN',
        'ARM_OIDC_TOKEN', 'ARM_CLIENT_CERTIFICATE_PATH', 'ARM_CLIENT_CERTIFICATE_PASSWORD'
    )
} | ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_.Name) }
$env:ARM_CLIENT_ID = $env:servicePrincipalId
$env:ARM_TENANT_ID = $env:tenantId
$env:ARM_USE_OIDC = 'true'
$env:ARM_USE_CLI = 'false'
$env:ARM_USE_AZUREAD = 'true'
$env:TF_IN_AUTOMATION = 'true'
$env:TF_INPUT = 'false'
$env:TF_WORKSPACE = 'default'
$tempRoot = [IO.Path]::GetFullPath($env:AGENT_TEMPDIRECTORY)
$work = Join-Path $tempRoot ('terraform-cd-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$env:TF_DATA_DIR = Join-Path $work '.terraform'
$log = Join-Path $work 'private.log'
function Invoke-TF([string[]]$Arguments, [int[]]$Allowed = @(0)) {
    & terraform "-chdir=$work" @Arguments *> $log
    $code = $LASTEXITCODE
    if ($code -notin $Allowed) { throw "Terraform $($Arguments[0]) falhou ($code). Log privado não publicado; consulte README." }
    return $code
}
function Read-Plan {
    & terraform "-chdir=$work" show -json review.tfplan > (Join-Path $work 'plan.json') 2> $log
    if ($LASTEXITCODE -ne 0) { throw 'Não foi possível examinar o plano salvo.' }
    return (Get-Content (Join-Path $work 'plan.json') -Raw | ConvertFrom-Json)
}
function Assert-PlanSafe($Plan, [switch]$ForApply) {
    if (@($Plan.resource_changes | Where-Object { $_.change.actions -contains 'delete' }).Count -gt 0) {
        throw 'Plano contém exclusão ou substituição; bloqueado. Revise um resumo autorizado e corrija a configuração.'
    }
    if ($ForApply) {
        $unexpected = @($Plan.resource_changes | Where-Object {
            $_.mode -eq 'managed' -and ($_.change.actions -join ',') -ne 'no-op' -and
            $_.address -notin $policy.allowedApplyAddresses
        })
        if ($unexpected.Count -gt 0) { throw 'Primeiro laboratório permite mudanças somente em azurerm_resource_group.rg; demais recursos exigem revisão.' }
    }
}
try {
    Assert-CurrentCommit
    $approval = if ($publish -or $Mode -eq 'Apply') { Get-ApprovalFingerprint } else { '' }
    $source = Join-Path $env:BUILD_SOURCESDIRECTORY 'codigoTerraform'
    Get-ChildItem $source -Filter '*.tf' -File | Copy-Item -Destination $work
    Copy-Item (Join-Path $source '.terraform.lock.hcl') -Destination $work
    $lockHash = (Get-FileHash (Join-Path $work '.terraform.lock.hcl') -Algorithm SHA256).Hash
    $version = & terraform version -json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $version.terraform_version -ne '1.17.1') { throw 'Versão Terraform inesperada.' }
    $subscription = & az account show --query id -o tsv --only-show-errors 2> $log
    if ($LASTEXITCODE -ne 0) { throw 'Subscription da conexão não identificada.' }
    $env:ARM_SUBSCRIPTION_ID = "$subscription".Trim()
    $context = [ordered]@{
        buildId = $env:BUILD_BUILDID; commit = $env:BUILD_SOURCEVERSION
        branch = $policy.authorizedBranch; environment = $policy.environment
        storage = $env:BACKEND_STORAGE_ACCOUNT; container = $env:BACKEND_CONTAINER; key = $env:BACKEND_KEY
        workspace = 'default'; subscription = $env:ARM_SUBSCRIPTION_ID; tenant = $env:ARM_TENANT_ID
        connection = $env:ARM_OIDC_AZURE_SERVICE_CONNECTION_ID
        terraform = $version.terraform_version; platform = $version.platform; lockHash = $lockHash
        approval = $approval
    }
    if ($Mode -eq 'Apply') {
        $artifact = Join-Path $env:PIPELINE_WORKSPACE ('terraform-plan-' + $env:BUILD_BUILDID)
        $manifest = Get-Content (Join-Path $artifact 'manifest.json') -Raw | ConvertFrom-Json
        foreach ($key in $context.Keys) {
            if ([string]$manifest.$key -cne [string]$context[$key]) { throw "Plano não corresponde ao contexto: $key." }
        }
        $age = [DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($manifest.createdUtc)
        if ($age.TotalMinutes -lt 0 -or $age.TotalMinutes -gt $policy.maxPlanAgeMinutes) { throw 'Plano expirado. Gere outro plano e obtenha nova aprovação.' }
        if ((Get-FileHash (Join-Path $artifact 'review.tfplan') -Algorithm SHA256).Hash -cne $manifest.planHash) { throw 'Hash do plano divergente.' }
        Copy-Item (Join-Path $artifact 'review.tfplan') -Destination $work
    }
    $exists = & az storage blob exists --auth-mode login --account-name $env:BACKEND_STORAGE_ACCOUNT --container-name $env:BACKEND_CONTAINER --name $env:BACKEND_KEY --query exists -o tsv --only-show-errors 2> $log
    if ($LASTEXITCODE -ne 0 -or "$exists".Trim() -ne 'true') { throw 'State existente não confirmado. Nenhuma migração ou criação de state vazio será realizada.' }
    $null = Invoke-TF @('init', '-input=false', '-lockfile=readonly', '-no-color',
        "-backend-config=storage_account_name=$env:BACKEND_STORAGE_ACCOUNT",
        "-backend-config=container_name=$env:BACKEND_CONTAINER", "-backend-config=key=$env:BACKEND_KEY")
    $null = Invoke-TF @('validate', '-no-color')
    if ($Mode -eq 'Plan') {
        $null = Invoke-TF @('plan', '-input=false', '-no-color', '-lock-timeout=60s', '-detailed-exitcode', '-out=review.tfplan') @(0, 2)
        $plan = Read-Plan
        # Somente tipos, labels de configuração e ações; nunca before/after ou outputs.
        $summary = @('# Resumo Terraform', '', '| Tipo | Label | Ações |', '| --- | --- | --- |')
        foreach ($resource in $plan.resource_changes) {
            $summary += "| $($resource.type) | $($resource.name) | $($resource.change.actions -join ', ') |"
        }
        $summaryPath = Join-Path $env:AGENT_TEMPDIRECTORY ('terraform-summary-' + $env:BUILD_BUILDID + '.md')
        $summary | Set-Content $summaryPath -Encoding utf8
        Write-Host "##vso[task.uploadsummary]$summaryPath"
        Assert-PlanSafe $plan
        if ($publish) {
            # Sem copiar cache, JSON do plano, state, tokens ou logs.
            $output = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY ('terraform-plan-' + $env:BUILD_BUILDID)
            if (Test-Path $output) { throw 'Diretório de artefato já existe; inicie nova execução.' }
            New-Item -ItemType Directory -Path $output | Out-Null
            Copy-Item (Join-Path $work 'review.tfplan') -Destination $output
            $context.createdUtc = [DateTimeOffset]::UtcNow.ToString('o')
            $context.planHash = (Get-FileHash (Join-Path $work 'review.tfplan') -Algorithm SHA256).Hash
            $context | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $output 'manifest.json') -Encoding utf8
            Write-Host 'Plano salvo preparado para publicação restrita nesta execução.'
        }
        else { Write-Host 'Somente resumo; plano binário não publicado.' }
    }
    else {
        Assert-PlanSafe (Read-Plan) -ForApply
        Assert-CurrentCommit
        if ((Get-ApprovalFingerprint) -cne $approval) { throw 'Configuração da aprovação mudou; nova execução necessária.' }
        if (([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($manifest.createdUtc)).TotalMinutes -gt $policy.maxPlanAgeMinutes) {
            throw 'Plano expirou durante a preparação. Nova execução e aprovação necessárias.'
        }
        # O deployment job já passou pelo check externo do Environment.
        # Não gerar outro plano, não usar -auto-approve e não aceitar comandos livres.
        $null = Invoke-TF @('apply', '-input=false', '-no-color', '-lock-timeout=60s', 'review.tfplan')
        Write-Host 'Plano aprovado aplicado. Confira o resultado no Azure Portal.'
    }
}
finally {
    $resolved = [IO.Path]::GetFullPath($work)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\', '/') -ne $tempRoot.TrimEnd('\', '/') -or
        [IO.Path]::GetFileName($resolved) -notmatch '^terraform-cd-[a-f0-9]{32}$') { throw 'Limpeza fora do diretório autorizado.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
$global:LASTEXITCODE = 0
