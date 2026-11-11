# AulaDevOps-001 — Terraform no Azure DevOps

Laboratório DIO.me: organização `contatolcamargo`, projeto `AulaDevOps-001`, subscription informada `Desenvolvimento`.

**CD preparado em código, apply bloqueado.** Nenhum recurso foi implantado nesta implementação. A conexão, o backend e a aprovação ainda precisam ser confirmados no Azure/Azure DevOps.

## Arquitetura e arquivos

```text
Push / PR -> TerraformValidate (sem credenciais)
Execução manual na main -> TerraformValidate -> TerraformPlan
  -> plano salvo da mesma execução, se publicação autorizada
  -> aprovação externa no Environment dev-terraform
  -> TerraformApply (também bloqueado por policy.json)
```

| Arquivo | Propósito |
| --- | --- |
| `azure-pipelines.yml` | Stages, branch autorizada e deployment job |
| `pipelines/terraform-cd-steps.yml` | Instalação e AzureCLI compartilhados entre Plan/Apply |
| `scripts/ci/Install-Terraform.ps1` | Terraform 1.17.1 com checksum oficial |
| `scripts/ci/Invoke-TerraformCI.ps1` | Validação isolada; modo Plan legado não usado no novo YAML |
| `scripts/cd/Invoke-TerraformCD.ps1` | OIDC, plano salvo e verificações de segurança |
| `scripts/cd/policy.json` | Apply desabilitado, main, validade de 60 minutos e limite ao RG |
| `scripts/cd/Remove-LocalPlan.ps1` | Limpeza dos planos locais |
| `codigoTerraform/` | Recursos existentes, preservados nesta implementação |

O Terraform declara `rg-auladevops-002` e `staccdevopsrg21605` (Standard/LRS, website estático), em `westeurope`. Esse Storage é do site, não do backend. Somente um plano autenticado poderá confirmar criação, alteração, substituição ou exclusão.

## Pré-requisitos, agente e branch

- Terraform 1.17.1 e AzureRM 4.48.0, versões existentes preservadas.
- Agente padrão Microsoft-hosted `ubuntu-24.04`, já utilizado no laboratório; capacidade depende da organização.
- Alternativa: `selfHosted`, pool real autorizado, Windows/Linux x64, Git, PowerShell 7 e Azure CLI. Usar diretório dedicado, pois checkout usa `clean: true`.
- Acesso HTTPS a Azure DevOps, HashiCorp Registry/Downloads, Entra ID, ARM e Blob. Confirmar firewall/private endpoints.
- Permissões para configurar conexão, Environment, políticas e RBAC, sem criar recursos pagos automaticamente.

Na última análise remota, `feature/terraform-ci` era a branch padrão e `main` não foi retornada. Após revisar o código, estabeleça `main` no Azure Repos a partir do commit revisado e torne-a padrão. **Não envie a antiga main local**, que tem histórico diferente contendo state. Nenhuma branch foi criada por esta implementação do CD.

Proteja main por PR, revisão e política **Build Validation**. Azure Repos configura validação de PR por política da branch, não `pr:` no YAML. CI continua ativo para main e feature/terraform-ci nos caminhos monitorados; CD só aceita execução manual na main.

## Backend e estado

Confirme no Azure Portal: subscription/tenant reais, `rg-terraform-001`, nome real do Storage de backend, container privado `tfstate`, chave do blob e state autoritativo do workspace `default`. `PREENCHER_*` não representa recurso criado. `backend.hcl.example` é o modelo para uso local.

O backend usa Entra ID (`use_azuread_auth=true`) e endpoint Blob padrão. Azure DNS zone endpoints exigem adaptação e permissão Reader. O backend não é provisionado pelo código do site.

O script exige blob existente. Se só existir `.local-state-backup/terraform.tfstate`, pare: atualidade e transição devem ser analisadas e autorizadas separadamente. Não editar state, fabricar state vazio, migrar automaticamente ou usar `-reconfigure` para contornar verificações. Novo ambiente/chave também exige decisão explícita de bootstrap; este fluxo não o inicializa silenciosamente.

## Service Connection OIDC e permissões

Primeiro verifique **Project settings → Service connections** e reutilize conexão adequada. Nome/GUID ainda não foram confirmados.

Se não existir, após autorização para configurá-la:

1. **New service connection → Azure Resource Manager**.
2. Escolha identidade apropriada existente ou App registration, com **Workload Identity Federation**, nunca Client Secret.
3. Selecione subscription/tenant reais. No fluxo manual, use issuer e subject fornecidos pelo Azure DevOps na credencial federada do Entra ID; não invente esses valores.
4. Revise RBAC criado pelo assistente e evite Contributor na subscription inteira.
5. Autorize somente esta pipeline, sem acesso global a todas as pipelines.
6. Preencha nome e GUID da conexão nos parâmetros.
7. Configure Branch control na conexão para permitir apenas `refs/heads/main` protegida.

Permissões distintas:

- Backend: `Storage Blob Data Contributor` no container para leitura, escrita e lease. Permissão de gerenciamento não substitui RBAC Blob.
- Plano: leitura dos recursos alvo e acessos de dados exigidos pelo provider.
- Apply: ações mínimas dos recursos aprovados. Criar RG requer ação em escopo de subscription; uma atribuição em RG inexistente não basta. Usar função personalizada aprovada ou bootstrap separado, sem Owner no executor.
- Um administrador deve confirmar registro de `Microsoft.Storage`; registro automático está desativado.

Nesta versão Plan/Apply usam a mesma conexão, tenant/subscription e atribuições em escopos distintos. Separar identidades exige adaptar e testar o contexto do backend salvo; não trocar somente a conexão do Apply.

`System.AccessToken` é token temporário do job, não PAT. O Build Service precisa ler repositório, Environment e configurações de checks. Erro de consulta bloqueia o fluxo; não conceder administração de checks para contornar 403. Tokens são passados por ambiente, nunca gravados no código ou impressos.

## Environment e aprovação obrigatória

Crie manualmente **Pipelines → Environments → New environment → dev-terraform**, tipo **None**, caso não exista. Não é necessário criar VM.

Em **Pipelines → Environments → dev-terraform → Approvals and checks**:

1. Adicione **Approvals**, selecione aprovador real, mínimo de uma aprovação e mantenha o check habilitado.
2. Use prazo compatível com a validade de uma hora do plano. Para separação de funções, desabilite aprovação da própria execução e escolha outra pessoa. Em laboratório individual, documente explicitamente a limitação antes de permitir aprovação manual pelo solicitante.
3. Adicione **Branch control**, permitindo somente `refs/heads/main` protegida.
4. Adicione **Exclusive lock**. O YAML usa `lockBehavior: sequential`; planos ainda precisam passar nas verificações de validade/state.
5. Em Security/Pipeline permissions, restrinja administradores e autorize só esta pipeline. Não utilizar bypass de checks.

O script verifica pela API um check Approval habilitado, com aprovadores e mínimo de um, antes de preparar artefato e novamente antes do apply. Mudança da configuração após o plano exige nova execução. Isso complementa a aprovação aplicada pelo Azure DevOps ao deployment job; não cria aprovação via YAML. Restrinja administradores, que podem alterar ou contornar políticas, e confira o histórico da aprovação.

**Não habilite `applyEnabled` antes de confirmar esses checks.** `requestApply=true` sozinho não libera implantação.

## Plano salvo e artefato sensível

`publishPlan=false` é o padrão. Planos podem conter segredos em texto claro. Antes de marcar `artifactAccessReviewed=true`:

- Use projeto privado e restrinja **View builds** e acesso à pipeline aos revisores autorizados. Aprovação do Environment não protege o download de artefatos. Pipeline Artifact não oferece ACL individual por arquivo.
- Revise **Pipelines → Settings → Retention** e escolha menor prazo permitido adequado ao laboratório (por exemplo, um dia), sem retenção indefinida. Expiração do plano não apaga o artefato remoto automaticamente.
- Restrinja edição da pipeline, acesso ao token do job e compartilhamento de links. Se as permissões forem insuficientes, não publique até definir armazenamento restrito/criptografia adicional.

O parâmetro atesta revisão operacional, não configura RBAC automaticamente. Estas permissões não foram alteradas pelo assistente.

Artefato: apenas `review.tfplan` e `manifest.json`, nomeado por Build ID. Não inclui state, cache, JSON completo ou credenciais de autenticação. O manifest associa execução, commit, ambiente, backend, tenant/subscription, conexão, versão/plataforma, hashes e data. Apply baixa somente o artefato da execução atual. SHA256 detecta corrupção; controle de acesso protege contra substituição maliciosa.

Logs privados e cópias locais são removidos. Usar agente efêmero ou política de limpeza: interrupção abrupta pode impedir limpeza. Não habilitar `TF_LOG`. O resumo exibe somente tipos, labels Terraform e ações, nunca valores before/after ou outputs.

## Executar e verificar

### CI

Reutilize a definição existente apontando para `/azure-pipelines.yml`. Após correções, use **Run new**, pois reexecução antiga usa o commit antigo. Mantenha `runAzurePlan=false`, `publishPlan=false` e `requestApply=false` para CI sem Azure.

### Plano real

1. Confirme main, Service Connection, RBAC, backend/state e subscription.
2. Execute manualmente na main com `runAzurePlan=true` e parâmetros reais.
3. Deixe `requestApply=false`; `publishPlan=false` basta para diagnóstico.
4. Revise o resumo anexado à execução. Exclusão/substituição bloqueiam o stage.
5. Publicação exige permissões revisadas, aprovação configurada, `publishPlan=true` e `artifactAccessReviewed=true`.

### Primeiro apply — autorização adicional obrigatória

A configuração atual contém Storage. Não o remova nem use `-target` para ocultar mudanças. Após inspecionar state/plano e obter autorização explícita, preparar configuração de laboratório que proponha apenas o RG, sem destruir Storage. Confirmar o nome antes do teste.

Somente então alterar `applyEnabled` em `scripts/cd/policy.json` por revisão de código, preservando o limite ao endereço `azurerm_resource_group.rg`. Gerar NOVA execução manual na main, com plano, publicação e requestApply habilitados e acesso ao artefato confirmado.

O deployment aguardará aprovação do Environment. O aprovador confere resumo, commit, backend e subscription. O apply usa o plano salvo, sem novo plan nem destroy. Plano salvo não pede confirmação interativa do Terraform: a barreira é a aprovação do Azure DevOps.

Plano com mais de 60 minutos, outro contexto/execução, avanço da main ou state desatualizado é rejeitado. Gerar novo plano e nova aprovação, nunca replanejar silenciosamente dentro do Apply. Alterações externas sem atualização do state podem causar divergência; evitar mudanças manuais durante a janela.

No Portal, selecione a subscription confirmada e abra **Resource groups**. Confira nome, região e tags contra o plano aprovado, e examine Activity log e identidade responsável. Verifique também o deployment no Environment. Não publique state para comprovar resultado.

## Testes locais seguros

```powershell
terraform -chdir=codigoTerraform fmt -check
terraform -chdir=codigoTerraform init -backend=false -input=false -lockfile=readonly
terraform -chdir=codigoTerraform validate
pwsh -NoProfile -File tests/Test-TerraformCD.ps1
```

Ao atualizar providers:

```powershell
terraform -chdir=codigoTerraform providers lock -platform=windows_amd64 -platform=linux_amd64
```

Após instalar Azure CLI, use `az login` e `az account set --subscription "Desenvolvimento"`; use ID confirmado se houver nomes duplicados. Configure `ARM_SUBSCRIPTION_ID`/`ARM_TENANT_ID` reais e `ARM_USE_CLI=true`, `ARM_USE_OIDC=false`. Nunca salvar senha, token ou chave. Init remoto/plano autenticado aguardam confirmação do state.

## Troubleshooting

| Sintoma | Ação |
| --- | --- |
| Stages Azure ausentes | Conferir parâmetros; inclusão é condicional |
| Branch bloqueada | Estabelecer main revisada no remoto, sem liberar CD na feature |
| Pool indisponível | Conferir capacidade hospedada ou pool próprio autorizado |
| Checksum Linux | Registrar hashes de ambas as plataformas; manter verificação |
| WIF/issuer/subject inválido | Conferir conexão e credencial federada com valores fornecidos pelo serviço |
| 403 Blob | Conferir RBAC de dados, container, propagação e rede |
| 403 ao consultar checks | Conceder leitura apropriada ao Build Service; não ignorar verificação |
| Aprovação não confirmada | Check habilitado, aprovadores e mínimo requerido |
| Plano vencido/check mudou/main avançou | Nova execução, novo plano e nova aprovação |
| State ausente/conflito | Parar e revisar estado autoritativo; não editar/migrar/forçar desbloqueio |
| Apply bloqueado | Esperado até autorização explícita e revisão da política |
| Storage proposto no apply | Rever configuração/state; primeiro laboratório permite só RG |
| Terraform com saída omitida | Reproduzir autorizadamente em ambiente privado; não publicar logs completos |

## Remoção segura

Não há destroy na pipeline. Após autorização específica, identificar recursos do laboratório, verificar ausência de recursos compartilhados e preparar plano de remoção separado para revisão/aprovação. Não excluir `rg-terraform-001` ou backend na limpeza. Preservar state e evidências. Este documento não autoriza remoção nem fornece destruição automática.

## Verificações desta implementação

`fmt -check`, `init -backend=false -lockfile=readonly` e `validate` passaram localmente; permanece o aviso já conhecido sobre o bloco `static_website` obsoleto. O YAML foi lido por parser local, e os scripts passaram na análise sintática PowerShell. Testes simulados verificaram política desabilitada, PR, aprovação desativada, avanço da branch, state ausente, exclusão/substituição, códigos do plan, validade, contexto, hash, limite ao RG e limpeza. O teste de apply usa uma cópia temporária da política e um comando simulado; não executa Terraform real.

Não foi executado plano autenticado nem apply. A compilação no serviço Azure DevOps, respostas reais da API de checks e OIDC ainda precisam ser verificadas após configurar os recursos externos. O teste local usou Windows PowerShell com Bypass somente no processo de teste; o agente utiliza PowerShell 7.

## Referências oficiais

- [Aprovações e checks](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/approvals?view=azure-devops)
- [ARM Service Connection](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/connect-to-azure?view=azure-devops)
- [API de checks](https://learn.microsoft.com/en-us/rest/api/azure/devops/approvalsandchecks/check-configurations/list?view=azure-devops-rest-7.1)
- [Plano salvo](https://developer.hashicorp.com/terraform/cli/commands/plan)
- [Backend AzureRM](https://developer.hashicorp.com/terraform/language/backend/azurerm)


---

**Repositório do desafio:** [DevOps Fundamentals](https://github.com/Lcamargodasilva/auladevopsfundamentals)