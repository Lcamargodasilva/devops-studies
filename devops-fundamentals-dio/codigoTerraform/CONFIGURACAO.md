# Etapa 2 — Terraform e preparação do backend

Esta etapa prepara os arquivos. Não confirma recursos no Azure, não migra estado
e não habilita implantação. O site estático da raiz foi preservado.

## Arquivos

- `site.tf`: recursos originais, com os mesmos nomes e endereços Terraform.
- `variables.tf`: região e tags; a região agora é utilizada pelo Resource Group.
- `versions.tf`: Terraform 1.17.x (teste local com 1.17.1) e AzureRM 4.48.0 fixo.
- `providers.tf`: Entra ID para operações de Storage e registro automático de
  resource providers desativado, evitando exigir essa permissão da pipeline.
- `backend.tf`: backend Azure Blob com autenticação Entra ID obrigatória.
- `backend.hcl.example`: modelo dos parâmetros do backend, sem credenciais.
- `.terraform.lock.hcl`: versões e hashes obtidos do Registry; deve ir para Git.
- `../.gitignore`: exclusões de dados locais, estados, planos e segredos.

AzureRM 4.48.0 foi escolhido como versão fixa com suporte documentado a OIDC
no Azure DevOps. Não é uma afirmação de que seja a versão mais recente.
O argumento antigo `enable_https_traffic_only` foi atualizado para
`https_traffic_only_enabled`. O bloco de website foi preservado.
A compatibilidade com a infraestrutura real dependerá de um plano revisado.
O `validate` passou com um aviso: o bloco `static_website` está obsoleto no
AzureRM 4.x e será removido no 5.x. Foi mantido para preservar a configuração
original; sua substituição pelo recurso dedicado deve ser revisada após
confirmar o estado autoritativo. A versão fixa impede atualização automática ao 5.x.

## Preservação do estado e situação do Git

O state encontrado no índice Git foi copiado, sem transformação, para
`../.local-state-backup/terraform.tfstate`. Essa pasta é ignorada pelo Git.
Não use essa cópia automaticamente: ela pode não ser o estado mais recente.
Faça também uma cópia em local seguro com acesso restrito, fora do repositório.

Na Etapa 3, a branch `feature/terraform-ci` foi criada sobre `origin/main`,
preservando os arquivos de trabalho e uma cópia do índice anterior. O state
não está no índice dessa branch. O histórico local antigo não foi reescrito;
não publique a branch `main` local antiga. Eventual saneamento desse histórico
deve ser tratado separadamente. Consulte [o fluxo de commit e pipeline](../docs/PIPELINE.md).

Antes de inicializar o backend remoto, confirme o estado autoritativo, sua
linhagem, ambiente e recursos. Se houver estado local ou blob existente, planeje
a transição separadamente. Não execute `init -migrate-state`, `-force-copy` ou
`-reconfigure` para contornar essa conferência. Não associe um backend vazio a
recursos já gerenciados: isso pode resultar em propostas de criação duplicada.

## Dados ainda necessários

1. ID real da subscription Desenvolvimento e tenant correspondente.
2. Existência de `rg-terraform-001`, nome real do Storage de backend e container
   privado `tfstate`. `staccdevopsrg21605` é o Storage do site, não o backend.
3. Chave do blob correta para este ambiente, incluindo eventual state existente.
4. Identidade federada, client ID e Service Connection autorizada.
5. Acesso de rede do executor ao Blob Storage, incluindo firewall/private endpoint.

Copie `backend.hcl.example` para `backend.hcl` e substitua os marcadores após
obter os dados. Backend não aceita `var.*`: esses parâmetros são passados ao
`init` por arquivo. Não armazene credenciais nesse arquivo, mesmo ignorado.
O backend deve existir previamente; este código não o provisiona.

## Autenticação local

O Azure CLI não foi encontrado no PATH na análise inicial. Após instalá-lo,
autentique-se interativamente e selecione a subscription. Em PowerShell:

```powershell
az login
az account set --subscription "Desenvolvimento"
$env:ARM_SUBSCRIPTION_ID = az account show --query id -o tsv
$env:ARM_TENANT_ID = az account show --query tenantId -o tsv
$env:ARM_USE_CLI = "true"
$env:ARM_USE_OIDC = "false"
```

Não use Client Secret, Access Key ou SAS. Não habilite `TF_LOG` em execuções com
credenciais. A seleção por nome exige que a subscription seja inequívoca; use
o ID confirmado se houver nomes duplicados.

## Preparação OIDC para Azure DevOps

O provider e o backend recebem autenticação pelo ambiente. Na futura pipeline,
a task com a Service Connection federada deve fornecer, durante sua execução:

| Variável | Origem/finalidade |
| --- | --- |
| `ARM_SUBSCRIPTION_ID` | Subscription autorizada para provisionamento |
| `ARM_TENANT_ID` | Tenant da identidade federada |
| `ARM_CLIENT_ID` | Client ID da identidade autorizada |
| `ARM_USE_OIDC=true` | Habilita autenticação federada |
| `ARM_USE_CLI=false` | Evita fallback para sessão CLI na pipeline |
| `ARM_OIDC_AZURE_SERVICE_CONNECTION_ID` | ID real da Service Connection |
| `SYSTEM_OIDCREQUESTURI` | Endpoint OIDC fornecido pelo Azure DevOps |
| `SYSTEM_ACCESSTOKEN` | Token temporário do job, mapeado pela task/YAML |

O token do job é temporário, não é PAT nem Client Secret. Nunca copie seu valor
para arquivos, outputs ou logs. A integração executável será feita na Etapa 3;
a criação e autorização manual da Service Connection será detalhada na Etapa 4.

As permissões são distintas: backend requer acesso ao plano de dados Blob,
normalmente `Storage Blob Data Contributor` no container; provisionamento exige
permissões de gerenciamento dos recursos alvo. Não conceda Owner ao executor.
Reader no Storage só é necessário ao backend quando precisar consultar seu
endpoint pelo plano de gerenciamento. O website pode exigir permissões de dados
adicionais no Storage do site, separadas das permissões do backend.

Como o código ainda gerencia a criação de um Resource Group, uma identidade
limitada a um RG preexistente não necessariamente poderá executar essa criação.
Antes do CD, decidir entre um bootstrap autorizado do RG com importação revisada
ou uma função personalizada com escopo apropriado. Não ampliar para Contributor
na subscription inteira apenas para contornar falha de permissão.
Um administrador deve verificar previamente o registro de `Microsoft.Storage`.

## Validação sem acessar o Azure

Execute da raiz do projeto:

```powershell
terraform -chdir=codigoTerraform fmt -check
terraform -chdir=codigoTerraform init -backend=false -input=false
terraform -chdir=codigoTerraform validate
```

O `init -backend=false` baixa providers e gera o lockfile, mas não inicializa nem
migra o backend. Não execute `plan`/`apply` nessa preparação. Depois da conferência
e autorização do estado, a inicialização remota utilizará `-backend-config=backend.hcl`.
Esta documentação não autoriza executar essa transição agora.

Validação realizada nesta etapa: `fmt -check` passou; `init -backend=false`
instalou o provider assinado pela HashiCorp e gerou o lockfile; `validate` passou
com o aviso descrito acima. A cópia do state foi comparada byte a byte por hash
Git com o blob original. Nenhum `plan`, `apply`, `destroy` ou migração foi executado.

## Referências

- [Backend AzureRM e autenticação Entra ID/OIDC](https://developer.hashicorp.com/terraform/language/backend/azurerm)
- [Provider AzureRM 4.48.0](https://registry.terraform.io/providers/hashicorp/azurerm/4.48.0/docs)
- [OIDC com Azure DevOps](https://registry.terraform.io/providers/hashicorp/azurerm/4.48.0/docs/guides/service_principal_oidc)
