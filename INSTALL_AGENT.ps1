param(
    [Parameter(Position=0)]
    [string]$AgentName
)

$ErrorActionPreference = "Stop"

# Cross-platform compatibility: $IsWindows exists on PowerShell 6+ (pwsh)
# but not on Windows PowerShell 5.1.
if (-not (Test-Path variable:IsWindows)) {
    $script:IsWindows = $true
}

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Store = Join-Path $ProjectRoot "OllamaModels"
$ModfileRoot = Join-Path $ProjectRoot "Modfiles"
$env:OLLAMA_MODELS = $Store
$env:OLLAMA_HOST = "127.0.0.1:11435"

if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    throw "ollama was not found in PATH. Install Ollama first (brew install ollama, or from https://ollama.com)."
}

New-Item -ItemType Directory -Path $Store -Force | Out-Null
New-Item -ItemType Directory -Path $ModfileRoot -Force | Out-Null

# Start only the CypraTeam Ollama endpoint if it is not already online.
try { Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:11435/" -TimeoutSec 2 | Out-Null }
catch {
    $spArgs = @{ FilePath = (Get-Command ollama).Source; ArgumentList = 'serve' }
    if ($IsWindows) { $spArgs['WindowStyle'] = 'Hidden' }
    Start-Process @spArgs
    $ready = $false
    for ($i=0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        try { Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:11435/" -TimeoutSec 2 | Out-Null; $ready = $true; break } catch {}
    }
    if (-not $ready) { throw "CypraTeam Ollama server did not become ready on 127.0.0.1:11435." }
}

if ([string]::IsNullOrWhiteSpace($AgentName)) { $AgentName = Read-Host "Agent to install/register (e.g. cypra)" }
$AgentName = $AgentName.Trim()
if ([string]::IsNullOrWhiteSpace($AgentName)) { Write-Host "[i] Nothing selected."; exit 0 }

$Modelfile = Join-Path $ModfileRoot ("Modelfile_{0}" -f $AgentName)
if (-not (Test-Path $Modelfile)) {
    Write-Host "[!] Missing $Modelfile" -ForegroundColor Red
    Write-Host "[i] Run INSTALL_MODELS.bat first to generate the local Modfiles." -ForegroundColor Yellow
    exit 2
}

Write-Host "[*] Checking base model required by $AgentName..." -ForegroundColor Cyan
$fromLine = Get-Content -LiteralPath $Modelfile -TotalCount 1
if ($fromLine -notmatch '^FROM\s+(.+)$') { throw "Invalid Modelfile: missing FROM line." }
$BaseModel = $Matches[1].Trim()
& ollama show $BaseModel *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[!] Required base model '$BaseModel' is not installed in the CypraTeam portable store." -ForegroundColor Red
    Write-Host "[i] Install that base model first with INSTALL_MODELS.bat." -ForegroundColor Yellow
    exit 3
}

Write-Host "[*] Explicitly registering '$AgentName' on the CypraTeam Ollama endpoint..." -ForegroundColor Yellow
& ollama create $AgentName -f $Modelfile
$rc = $LASTEXITCODE
if ($rc -ne 0) { throw "Registration failed with exit code $rc." }

& ollama show $AgentName *> $null
if ($LASTEXITCODE -ne 0) { throw "Ollama create reported success but '$AgentName' was not found afterward." }

Write-Host "[+] '$AgentName' is registered on CypraTeam Ollama (127.0.0.1:11435)." -ForegroundColor Green
Write-Host "[i] Portable store: $Store" -ForegroundColor DarkGray
exit 0
