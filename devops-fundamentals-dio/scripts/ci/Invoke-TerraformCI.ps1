param(
    [Parameter(Mandatory)]
    [ValidateSet('Validate', 'Plan')]
    [string]$Mode
)
$ErrorActionPreference = 'Stop'
# O código de saída nativo é tratado explicitamente, inclusive plan=2.
$PSNativeCommandUseErrorActionPreference = $false
if (-not $env:AGENT_TEMPDIRECTORY -or -not $env:BUILD_SOURCESDIRECTORY) {
    throw 'Execute em um agente Azure Pipelines ou forneça os diretórios de teste.'
}

# Evitar logs detalhados, opções herdadas e credenciais estáticas em agentes próprios.
Get-ChildItem Env: | Where-Object {
    $_.Name -match '^TF_(LOG|CLI_ARGS)' -or
    $_.Name -in @('ARM_CLIENT_SECRET', 'ARM_ACCESS_KEY', 'ARM_SAS_TOKEN', 'ARM_OIDC_TOKEN', 'ARM_CLIENT_CERTIFICATE_PATH', 'ARM_CLIENT_CERTIFICATE_PASSWORD')
} | ForEach-Object { Remove-Item -LiteralPath ('Env:' + $_.Name) }
$env:TF_IN_AUTOMATION = 'true'
$env:TF_INPUT = 'false'
$env:TF_WORKSPACE = 'default'

$tempRoot = [System.IO.Path]::GetFullPath($env:AGENT_TEMPDIRECTORY)
$workDir = Join-Path $tempRoot ('terraform-ci-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir | Out-Null
$logFile = Join-Path $workDir 'private-command.log'
# Ignorar TF_DATA_DIR herdado para não compartilhar backend/cache entre execuções.
$env:TF_DATA_DIR = Join-Path $workDir '.terraform'

function Invoke-PrivateTerraform {
    param([string[]]$TerraformArguments, [int[]]$AllowedExitCodes = @(0))
    & terraform "-chdir=$workDir" @TerraformArguments *> $logFile
    $result = $LASTEXITCODE
    if ($result -notin $AllowedExitCodes) {
        throw "Terraform $($TerraformArguments[0]) falhou (código $result). Saída omitida por conter possíveis dados sensíveis; consulte docs/PIPELINE.md."
    }
    return $result
}

try {
    $sourceDir = Join-Path $env:BUILD_SOURCESDIRECTORY 'codigoTerraform'
    # O projeto atual não tem módulos locais. Não copiar state, tfvars ou cache.
    Get-ChildItem -LiteralPath $sourceDir -Filter '*.tf' -File | Copy-Item -Destination $workDir
    Copy-Item -LiteralPath (Join-Path $sourceDir '.terraform.lock.hcl') -Destination $workDir

    if ($Mode -eq 'Validate') {
        & terraform "-chdir=$workDir" fmt -check -recursive
        if ($LASTEXITCODE -ne 0) { throw 'Formatação inválida; execute terraform fmt localmente.' }
        & terraform "-chdir=$workDir" init -backend=false -input=false -lockfile=readonly -no-color
        if ($LASTEXITCODE -ne 0) { throw 'Falha instalando providers com o lockfile versionado.' }
        & terraform "-chdir=$workDir" validate -no-color
        if ($LASTEXITCODE -ne 0) { throw 'Configuração Terraform inválida.' }
    }
    else {
        if ($env:BUILD_SOURCEBRANCH -ne 'refs/heads/main' -or $env:BUILD_REASON -ne 'Manual') {
            throw 'Plano Azure permitido somente em execução manual da main.'
        }
        if (-not $env:idToken -or -not $env:servicePrincipalId -or -not $env:tenantId) {
            throw 'A Service Connection deve usar Workload Identity Federation.'
        }
        $connectionId = [guid]::Empty
        if (-not [guid]::TryParse($env:ARM_OIDC_AZURE_SERVICE_CONNECTION_ID, [ref]$connectionId)) {
            throw 'Informe o GUID real da Service Connection.'
        }
        if (-not $env:SYSTEM_ACCESSTOKEN -or $env:SYSTEM_OIDCREQUESTURI -notmatch '^https://') {
            throw 'Contexto OIDC do job indisponível.'
        }
        if ($env:BACKEND_STORAGE_ACCOUNT -notmatch '^[a-z0-9]{3,24}$' -or
            $env:BACKEND_CONTAINER -notmatch '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' -or
            [string]::IsNullOrWhiteSpace($env:BACKEND_KEY) -or
            $env:BACKEND_KEY -match 'PREENCHER|[<>\r\n]') {
            throw 'Preencha os parâmetros reais do backend.'
        }

        $env:ARM_CLIENT_ID = $env:servicePrincipalId
        $env:ARM_TENANT_ID = $env:tenantId
        $env:ARM_USE_OIDC = 'true'
        $env:ARM_USE_CLI = 'false'
        $env:ARM_USE_AZUREAD = 'true'
        # Provider/backend solicitam e renovam tokens pelo endpoint do job.
        $subscription = & az account show --query id -o tsv --only-show-errors 2> $logFile
        if ($LASTEXITCODE -ne 0) { throw 'Não foi possível identificar a subscription da conexão.' }
        $env:ARM_SUBSCRIPTION_ID = "$subscription".Trim()

        # Exigir blob existente evita iniciar silenciosamente um state vazio.
        # Sua associação ao ambiente deve ser conferida manualmente antes deste job.
        $exists = & az storage blob exists --auth-mode login --account-name $env:BACKEND_STORAGE_ACCOUNT --container-name $env:BACKEND_CONTAINER --name $env:BACKEND_KEY --query exists -o tsv --only-show-errors 2> $logFile
        if ($LASTEXITCODE -ne 0 -or "$exists".Trim() -ne 'true') {
            throw 'State remoto não encontrado ou sem acesso. Conferir RBAC, rede e a transição manual do state; não será criado um backend vazio.'
        }
        $null = Invoke-PrivateTerraform -TerraformArguments @(
            'init', '-input=false', '-lockfile=readonly', '-no-color',
            "-backend-config=storage_account_name=$env:BACKEND_STORAGE_ACCOUNT",
            "-backend-config=container_name=$env:BACKEND_CONTAINER",
            "-backend-config=key=$env:BACKEND_KEY"
        )
        $null = Invoke-PrivateTerraform -TerraformArguments @('validate', '-no-color')
        $planExit = Invoke-PrivateTerraform -TerraformArguments @(
            'plan', '-input=false', '-no-color', '-lock-timeout=60s', '-detailed-exitcode', '-out=review.tfplan'
        ) -AllowedExitCodes @(0, 2)
        if ($planExit -eq 2) { Write-Host 'Plano gerado: há alterações propostas. Nenhuma implantação executada.' }
        else { Write-Host 'Plano gerado: sem alterações propostas.' }
        Write-Host 'Artefato sensível não publicado nesta etapa; plano e logs temporários serão removidos.'
    }
}
finally {
    # Excluir somente o diretório exclusivo criado por esta execução.
    $resolved = [System.IO.Path]::GetFullPath($workDir)
    $parent = [System.IO.Path]::GetDirectoryName($resolved)
    if ($parent.TrimEnd('\', '/') -ne $tempRoot.TrimEnd('\', '/') -or
        [System.IO.Path]::GetFileName($resolved) -notmatch '^terraform-ci-[a-f0-9]{32}$') {
        throw 'Diretório de limpeza fora do escopo autorizado.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
# AzureCLI@2 verifica LASTEXITCODE ao final; plan=2 é sucesso com mudanças.
$global:LASTEXITCODE = 0
