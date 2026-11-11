# Pipeline Terraform

A documentação atual de CI/CD está no [README](../README.md). O job único foi substituído por TerraformValidate, TerraformPlan e TerraformApply, reutilizando instalador, validação e backend.

Apply continua bloqueado em `scripts/cd/policy.json`. O deployment job não configura a aprovação no portal. Siga o procedimento do Environment `dev-terraform` no README.

Revise `git status` e `git diff`, adicione somente arquivos revisados e envie a feature branch para revisão. Nunca adicione state, planos, cache ou backups. Não use push --force/--all nem publique a antiga main local.

Reutilize a pipeline existente. Se necessário cadastrá-la, use Pipelines → New pipeline → Azure Repos Git → AulaDevOps-001 → Existing Azure Pipelines YAML file, selecionando a branch correta e `/azure-pipelines.yml`.

Comece com `runAzurePlan=false`. Após enviar correções, use Run new: reexecutar jobs antigos usa o commit antigo. O CD exige estabelecer main revisada no remoto e confirmar conexão WIF, backend/state e aprovação.
