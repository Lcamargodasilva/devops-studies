param([Parameter(Mandatory)][ValidateSet('Staging', 'Workspace')][string]$Location)
$ErrorActionPreference = 'Stop'
if ($env:BUILD_BUILDID -notmatch '^\d+$') { throw 'Build ID inválido para limpeza.' }
$base = if ($Location -eq 'Staging') { $env:BUILD_ARTIFACTSTAGINGDIRECTORY } else { $env:PIPELINE_WORKSPACE }
if ([string]::IsNullOrWhiteSpace($base)) { throw 'Diretório do agente ausente.' }
$root = [IO.Path]::GetFullPath($base)
$target = [IO.Path]::GetFullPath((Join-Path $root ('terraform-plan-' + $env:BUILD_BUILDID)))
if ([IO.Path]::GetDirectoryName($target).TrimEnd('\', '/') -ne $root.TrimEnd('\', '/')) { throw 'Limpeza fora do escopo autorizado.' }
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
