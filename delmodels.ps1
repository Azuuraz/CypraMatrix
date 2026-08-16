param(
    [ValidateSet('','Agents','All')]
    [string]$Mode = ''
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Store = Join-Path $ProjectRoot "OllamaModels"

Write-Host "CypraTeam portable model store:"
Write-Host $Store
Write-Host ""
Write-Host "This deletes ONLY models in this project's Ollama store."
Write-Host "The host Ollama install and global store are not touched."
Write-Host ""

$env:OLLAMA_HOST = "127.0.0.1:11435"
$env:OLLAMA_MODELS = $Store

if (-not (Test-Path $Store)) {
    New-Item -ItemType Directory -Path $Store -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($Mode)) {
    Write-Host " [1] Agent models only  (keep the base weights)"
    Write-Host " [2] Everything in this store  (agents + base model)"
    Write-Host " [Q] Cancel"
    Write-Host ""
    $pick = Read-Host "Select"
    switch -Regex ($pick) {
        '^1$' { $Mode = 'Agents' }
        '^2$' { $Mode = 'All' }
        default {
            Write-Host "Cancelled."
            exit 0
        }
    }
}

$confirmWord = if ($Mode -eq 'All') { 'DELETE PORTABLE' } else { 'DELETE AGENTS' }
$confirm = Read-Host "Type $confirmWord to continue"
if ($confirm -ne $confirmWord) {
    Write-Host "Cancelled."
    exit 0
}

$configPath = Join-Path $ProjectRoot "MatrixConfig.json"
$baseNames = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
if (Test-Path $configPath) {
    try {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        foreach ($k in @('DefaultBaseModel','ActiveModel','Model')) {
            $v = [string]$cfg.$k
            if (-not [string]::IsNullOrWhiteSpace($v)) { [void]$baseNames.Add($v.Trim()) }
        }
    } catch {}
}

$rows = @(& ollama list 2>$null)
$names = @()
foreach ($row in $rows) {
    $line = ([string]$row).Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^NAME\s') { continue }
    $parts = $line -split '\s+'
    if ($parts.Count -ge 1) { $names += $parts[0] }
}

function Test-PortableBaseName {
    param([string]$Name)
    if ($baseNames.Contains($Name)) { return $true }
    if ($Name -match '/') { return $true }
    if ($Name -match '^(gemma|llama|mistral|qwen|phi|deepseek)') { return $true }
    return $false
}

$removed = 0
foreach ($name in $names) {
    $isBase = Test-PortableBaseName $name
    if ($Mode -eq 'Agents' -and $isBase) {
        Write-Host "[i] Keeping base: $name"
        continue
    }
    Write-Host "[*] Removing portable model: $name"
    & ollama rm $name
    $removed++
}

Write-Host ""
if ($Mode -eq 'Agents') {
    Write-Host "[+] Removed $removed agent model(s). Base weights kept."
} else {
    Write-Host "[+] Removed $removed model(s) from the portable store."
}
