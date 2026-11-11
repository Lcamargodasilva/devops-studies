# Compatível com agentes Windows/Linux x64 com PowerShell 7.
$ErrorActionPreference = 'Stop'
$version = '1.17.1'
if (-not $env:AGENT_TEMPDIRECTORY) { throw 'Agent.TempDirectory não informado.' }
if ($env:AGENT_OSARCHITECTURE -ne 'X64') { throw 'Este instalador exige agente x64.' }
$platform = switch ($env:AGENT_OS) {
    'Windows_NT' { 'windows' }
    'Linux' { 'linux' }
    default { throw 'Use agente Windows ou Linux.' }
}
$installDir = Join-Path $env:AGENT_TEMPDIRECTORY ('terraform-cli-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $installDir | Out-Null
$archiveName = "terraform_${version}_${platform}_amd64.zip"
$baseUrl = "https://releases.hashicorp.com/terraform/$version"
$archive = Join-Path $installDir $archiveName
$checksums = Join-Path $installDir 'SHA256SUMS'
Invoke-WebRequest -Uri "$baseUrl/$archiveName" -OutFile $archive
Invoke-WebRequest -Uri "$baseUrl/terraform_${version}_SHA256SUMS" -OutFile $checksums
$matchesForArchive = @(Get-Content -LiteralPath $checksums | Where-Object {
    $_ -match ('^[a-fA-F0-9]{64}\s+\*?' + [regex]::Escape($archiveName) + '$')
})
if ($matchesForArchive.Count -ne 1) { throw 'Checksum oficial ausente ou ambíguo.' }
$expected = ($matchesForArchive[0] -split '\s+')[0]
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected) {
    throw 'Checksum do Terraform divergente.'
}
Expand-Archive -LiteralPath $archive -DestinationPath $installDir
$binary = Join-Path $installDir $(if ($platform -eq 'windows') { 'terraform.exe' } else { 'terraform' })
if ($platform -eq 'linux') {
    & chmod +x $binary
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao permitir execução do Terraform.' }
}
$versionInfo = & $binary version -json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $versionInfo.terraform_version -ne $version) {
    throw 'Versão instalada diferente da esperada.'
}
Write-Host "Terraform $version instalado e checksum conferido."
Write-Host "##vso[task.prependpath]$installDir"
