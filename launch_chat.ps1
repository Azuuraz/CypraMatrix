# ==============================================
# PORTABLE OLLAMA WORKSPACE MATRIX PANEL ENGINE 
# ==============================================

# Do NOT set this to "SilentlyContinue" globally - that hides every
# non-terminating error in the whole script (bad Get-Content, failed
# Copy-Item, mistyped cmdlet params, etc.), including inside the many
# try/catch blocks below, since a suppressed error never becomes a
# terminating one and so never reaches "catch". "Continue" is
# PowerShell's real default: errors still print and get logged, but
# execution isn't halted. Spots where silence really is wanted already
# use an explicit -ErrorAction SilentlyContinue on that one call.
$ErrorActionPreference = "Continue"

# ==============================================
# CENTRALIZED COLOR THEME (single source of truth)
# ==============================================
# Every Write-Host call in this program pulls its color from this table
# instead of hardcoding a ConsoleColor name. Re-skin the whole app by
# editing the values below - nothing else needs to change.
$Theme = [ordered]@{
    Brand        = "Green"          # Primary CYPRATEAM identity (logo + top dashboard frame only)
    BrandDim     = "DarkRed"      # Secondary identity accents
    Info         = "Cyan"         # Section headers, panel borders, general status/info text
    InfoDim      = "DarkCyan"     # Secondary info / supporting detail text
    Info2        = "Blue"         # Rare structural highlight (kept distinct from Info)
    Info2Dim     = "DarkBlue"
    Success      = "Green"        # Confirmations, completions, "ready" states
    SuccessDim   = "DarkGreen"
    Warning      = "Yellow"       # Cautions, recoverable issues, "heads up" states
    WarningDim   = "DarkYellow"
    Error        = "Red"          # Hard failures ([!] messages, exit codes, exceptions)
    ErrorDim     = "DarkRed"      # Critical/security warnings
    Accent       = "Magenta"      # Fun/decorative highlights, easter eggs
    AccentDim    = "DarkMagenta"
    Muted        = "DarkGray"     # Borders, separators, low-priority text
    MutedLight   = "Gray"         # Secondary muted text, slightly more legible than Muted
    Primary      = "White"        # Primary emphasized text/values
    DashPrimary  = "Red"          # Dashboard panel frame/border/index color
    DashDim      = "DarkRed"      # Dashboard secondary frame accents
    DashText     = "White"        # Dashboard primary readable text (names, values)
    DashMuted    = "Gray"         # Dashboard low-priority text (tags, command hints)
    Think        = "Cyan"         # Gemma Thinking... header (follows theme Info)
    ThinkDim     = "DarkCyan"     # Gemma thinking body text
}

# Snapshot of the built-in palette, kept so the theme editor's "reset to
# defaults" option has something to restore to even after ThemeConfig.json
# has overwritten $Theme's values below.
$script:DefaultTheme = [ordered]@{}
foreach ($k in $Theme.Keys) { $script:DefaultTheme[$k] = $Theme[$k] }

# Emoji identity that travels with the active color theme. Each preset in
# $script:ThemePresets has a matching entry in $script:ThemePresetEmojis
# (defined near the presets below); picking a preset updates this, and
# Show-Dashboard's brand header reads it live, the same way headers read
# $Theme colors live.
$script:DefaultThemeEmoji = "🚀"
$script:ThemeEmoji = $script:DefaultThemeEmoji

# Per-user color customization (see Show-ThemeEditor / the 'theme' command).
# Stored separately from MatrixConfig.json so re-skinning the UI never
# touches model/runtime settings.
$themeConfigFilePath = Join-Path $PSScriptRoot "ThemeConfig.json"

# Raw layout name pulled from ThemeConfig.json, if any. Held here (rather than
# validated immediately) because $script:DashboardLayoutNames isn't defined
# yet at this point in the script - it's applied once that registry exists,
# a little further down.
$script:ThemeConfigDashboardLayout = $null

if (Test-Path $themeConfigFilePath) {
    try {
        $savedTheme = Get-Content $themeConfigFilePath -Raw -ErrorAction Stop | ConvertFrom-Json
        $validColorNames = [System.Enum]::GetNames([System.ConsoleColor])
        foreach ($key in @($Theme.Keys)) {
            if ($savedTheme.PSObject.Properties.Name -contains $key) {
                $candidate = [string]$savedTheme.$key
                if ($validColorNames -contains $candidate) {
                    $Theme[$key] = $candidate
                }
            }
        }
        if ($savedTheme.PSObject.Properties.Name -contains 'Emoji') {
            $candidateEmoji = [string]$savedTheme.Emoji
            if (-not [string]::IsNullOrWhiteSpace($candidateEmoji)) {
                $script:ThemeEmoji = $candidateEmoji
            }
        }
        # Dashboard layout is now saved through the same Save-ThemeConfig
        # function/file as colors and emoji (see Show-LayoutPicker), so a
        # layout choice survives a restart the same way a theme choice does.
        if ($savedTheme.PSObject.Properties.Name -contains 'DashboardLayout') {
            $candidateLayout = [string]$savedTheme.DashboardLayout
            if (-not [string]::IsNullOrWhiteSpace($candidateLayout)) {
                $script:ThemeConfigDashboardLayout = $candidateLayout
            }
        }


    } catch {
        Write-Host "[!] Could not load ThemeConfig.json; using default colors." -ForegroundColor Yellow
    }
}

# ==============================================
# CROSS-PLATFORM COMPATIBILITY LAYER (Windows / macOS / Linux)
# ==============================================
# $IsWindows / $IsMacOS / $IsLinux are automatic variables on PowerShell 6+
# (pwsh). They don't exist on Windows PowerShell 5.1, so define safe
# fallbacks for that case.
if (-not (Test-Path variable:IsWindows)) {
    $script:IsWindows = $true
    $script:IsMacOS   = $false
    $script:IsLinux   = $false
}

# Resolves the PowerShell executable to use for spawning child scripts:
# pwsh on macOS/Linux, powershell.exe (or pwsh if that's what's running) on Windows.
function Get-PowerShellExe {
    if ($IsWindows) {
        $cur = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
        if ($cur -and (Split-Path -Leaf $cur) -match '^pwsh(\.exe)?$') { return "pwsh" }
        return "powershell.exe"
    }
    return "pwsh"
}

# Opens a path in the platform's native file manager (Explorer / Finder / xdg-open).
function Open-InFileManager {
    param([Parameter(Mandatory)][string]$Path)
    if ($IsMacOS)   { Start-Process "open" @($Path); return }
    if ($IsLinux)   { Start-Process "xdg-open" @($Path); return }
    Start-Process "explorer.exe" $Path
}

# Cross-platform hostname (avoids relying on $env:COMPUTERNAME, which is
# unset on macOS/Linux).
function Get-MatrixHostName {
    if ($env:COMPUTERNAME) { return $env:COMPUTERNAME }
    try { return [System.Net.Dns]::GetHostName() } catch { return "unknown-host" }
}

# Global Active Task Workspace Path Initialization
$global:ActiveTaskWorkspace = $null

# Session start marker (used by the 'stats' command to report uptime)
$script:MatrixStartTime = Get-Date

# Rolling warm-pool scheduler state.
# Four NEW activations form one logical window. The fourth becomes the active
# "brain" and the first three in that window are retired/released. The brain
# is tracked separately so the next window can use three fresh slots without
# accidentally releasing the previous brain. Physical residency remains
# constrained by the actual GPU and Ollama.
$script:WarmPoolActivationOrder = New-Object 'System.Collections.Generic.List[string]'
$script:WarmPoolActivationsSinceRotation = 0
$script:WarmPoolBrain = $null
$script:LastSchedulerModelAlreadyLoaded = $false

# 1. NETWORK & ENVIRONMENT ISOLATION (PORTABLE PATHS)
$script:CypraOllamaHost = "127.0.0.1:11435"
$env:OLLAMA_HOST = $script:CypraOllamaHost
Set-Location -Path $PSScriptRoot

# CYPRA PORTABLE MODE: the project folder is the ONLY model-store source.
# Never inherit a machine-wide OLLAMA_MODELS path from Windows, Ollama Desktop,
# or another installation. This makes the workspace self-contained/movable.
$defaultModelStorePath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "OllamaModels"))
$env:OLLAMA_MODELS = $defaultModelStorePath
$script:PortableOllamaMode = $true
$script:OllamaStartedByMatrix = $false
$script:PortableStoreMarker = Join-Path $defaultModelStorePath ".cypra_portable_store"

# 2. EXTERNAL CONFIGURATION & AUTOMATED MAINTENANCE
$configFilePath = Join-Path $PSScriptRoot "MatrixConfig.json"

function Get-MatrixDefaultConfig {
    # Single source of truth for first launch, settings reset, and resetall.
    # Paths are project-relative on disk so the folder can move to another PC.
    return [ordered]@{
        Model              = "huihui_ai/gemma-4-abliterated:e4b"
        DefaultBaseModel   = "huihui_ai/gemma-4-abliterated:e4b"
        ActiveModel        = "huihui_ai/gemma-4-abliterated:e4b"
        ModelStorePath     = "OllamaModels"
        ContextLength      = 1024
        DefaultContext     = 1024
        TurboMaxContext    = 4096
        CpuContext         = 2048
        LoggingEnabled     = $true
        VramMode           = "Balanced"
        DefaultProfile     = "Low-VRAM 6GB"
        KeepAlive          = "5m"
        LogRetentionDays   = 30
        CoreModels         = @("cypra", "anomaly", "quantum", "nexus-prime")
        MemoryEnabled      = $false
        LearningEnabled    = $true
        KnowledgeEnabled   = $false
        MissionAutoSelect  = $true
        ResetVersion       = 2
        DashboardLayout    = "Command Deck"
    }
}

function Save-MatrixConfig {
    try {
        $payload = [ordered]@{}
        if ($matrixConfig -is [System.Collections.IDictionary]) {
            foreach ($k in $matrixConfig.Keys) { $payload[[string]$k] = $matrixConfig[$k] }
        }
        # Never persist a machine-absolute model store. Runtime remaps this
        # to $PSScriptRoot\OllamaModels on every launch.
        $payload["ModelStorePath"] = "OllamaModels"
        if ($payload.Contains("DefaultContext") -and [int]$payload["DefaultContext"] -gt 0) {
            $payload["ContextLength"] = [int]$payload["DefaultContext"]
        }
        $payload | ConvertTo-Json -Depth 8 | Set-Content -Path $configFilePath -Encoding utf8
    } catch {
        Write-Host "[!] Could not save MatrixConfig.json: $($_.Exception.Message)" -ForegroundColor $Theme.Warning
    }
}

$matrixConfig = Get-MatrixDefaultConfig
$matrixConfig.ModelStorePath = $defaultModelStorePath

# Dashboard layout registry — separate from $Theme/$script:ThemePresets, which
# only control color. These are alternate structural arrangements of the
# dashboard itself. "Classic" is the original grid layout. Selecting one is
# done via the 'layout' command (Show-LayoutPicker) and persists through
# $matrixConfig.DashboardLayout the same way other settings do.
$script:DashboardLayoutNames = @(
    "Classic", "Grouped Roster", "Compact Dense", "Command Deck", "Ops Feed",
    "Quiet", "Focus"
)
$script:DashboardLayoutDescriptions = [ordered]@{
    "Classic"        = "The original numeric grid of every agent, ASCII logo header."
    "Grouped Roster" = "Agents organized under their specialty group headers instead of a flat grid."
    "Compact Dense"  = "No logo/borders, narrower columns - fits the most agents on screen at once."
    "Command Deck"   = "Instrument-panel vitals, Core chips, and group load bars. No full roster."
    "Ops Feed"       = "Single-column scrolling manifest - one agent per row with dot-leader alignment, no borders."
    "Quiet"          = "Almost empty: title, one status line, eight Core IDs, one hint."
    "Focus"          = "Core-only vertical list. No boxes, no bars, no full roster."
}

function ConvertTo-CompatHashtable {
    param([Parameter(Mandatory=$true)][object]$InputObject)
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[[string]$k] = ConvertTo-CompatHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $arr = @(); foreach ($item in $InputObject) { $arr += ,(ConvertTo-CompatHashtable $item) }; return $arr
    }
    if ($null -ne $InputObject -and $InputObject.PSObject.Properties.Count -gt 0 -and $InputObject -isnot [ValueType] -and $InputObject -isnot [string]) {
        $h = @{}
        foreach ($prop in $InputObject.PSObject.Properties) { $h[$prop.Name] = ConvertTo-CompatHashtable $prop.Value }
        return $h
    }
    return $InputObject
}

if (-not (Test-Path $matrixConfig.ModelStorePath)) { New-Item -ItemType Directory -Path $matrixConfig.ModelStorePath -Force | Out-Null }

if (Test-Path $configFilePath) {
    try {
        $parsed = Get-Content $configFilePath -Raw -ErrorAction Stop | ConvertFrom-Json
        $fileContent = ConvertTo-CompatHashtable $parsed
        foreach ($defaultKey in $matrixConfig.Keys) {
            if (-not $fileContent.ContainsKey($defaultKey)) { $fileContent[$defaultKey] = $matrixConfig[$defaultKey] }
        }

        # Legacy/system model-store paths are intentionally ignored in portable mode.
        # The Matrix always resolves models relative to this project directory.
        $legacyConfiguredStore = [string]$fileContent.ModelStorePath
        $fileContent.ModelStorePath = $defaultModelStorePath
        if ($legacyConfiguredStore -and $legacyConfiguredStore -ne $defaultModelStorePath) {
            Write-Host "[i] Ignoring legacy model store: $legacyConfiguredStore" -ForegroundColor $Theme.Warning
            Write-Host "[+] Portable model store: $defaultModelStorePath" -ForegroundColor $Theme.Success
        }
        if ([string]::IsNullOrWhiteSpace([string]$fileContent.DefaultBaseModel)) { $fileContent.DefaultBaseModel = [string]$fileContent.Model }
        if ([string]::IsNullOrWhiteSpace([string]$fileContent.ActiveModel)) { $fileContent.ActiveModel = [string]$fileContent.DefaultBaseModel }
        # Settings must match the live profile. Low-VRAM default context is the
        # real window; do not keep a leftover 8192 "ceiling" that never applies.
        if ([int]$fileContent.DefaultContext -gt 0) {
            $fileContent.ContextLength = [int]$fileContent.DefaultContext
        }
        $matrixConfig = $fileContent
    } catch {
        $backupPath = "$configFilePath.corrupt_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        try { Copy-Item $configFilePath $backupPath -Force -ErrorAction SilentlyContinue } catch {}
        Write-Host "[!] MatrixConfig.json was invalid or incompatible with Windows PowerShell 5.1. Backed up as: $backupPath" -ForegroundColor $Theme.Warning
        $matrixConfig | ConvertTo-Json -Depth 6 | Set-Content -Path $configFilePath -Encoding utf8
    }
} else {
    $matrixConfig | ConvertTo-Json -Depth 6 | Set-Content -Path $configFilePath -Encoding utf8
}

# Hard-lock the runtime store to the local project folder even if an older config
# or machine-level OLLAMA_MODELS variable tried to point somewhere else.
$matrixConfig.ModelStorePath = $defaultModelStorePath
$env:OLLAMA_MODELS = $defaultModelStorePath
if (-not (Test-Path $defaultModelStorePath)) { New-Item -ItemType Directory -Path $defaultModelStorePath -Force | Out-Null }
if (-not (Test-Path $script:PortableStoreMarker)) {
    "CypraTeam portable Ollama model store`r`nCreated: $(Get-Date -Format o)`r`nProject: $PSScriptRoot" | Set-Content -Path $script:PortableStoreMarker -Encoding utf8
}

# Persist the portable (relative-store) config so the folder can move.
Save-MatrixConfig

# Apply configurations
$script:SelectedProfile = $matrixConfig.DefaultProfile
$OllamaContextLength = [int]$matrixConfig.DefaultContext
$OllamaKeepAlive = $matrixConfig.KeepAlive

$script:DashboardLayout = [string]$matrixConfig.DashboardLayout

# ThemeConfig.json (written by Save-ThemeConfig, same file the color theme
# uses) takes precedence over the legacy MatrixConfig.json value when both
# are present, since it's the more recently-introduced save path.
if (-not [string]::IsNullOrWhiteSpace($script:ThemeConfigDashboardLayout) -and
    ($script:DashboardLayoutNames -contains $script:ThemeConfigDashboardLayout)) {
    $script:DashboardLayout = $script:ThemeConfigDashboardLayout
}

if ([string]::IsNullOrWhiteSpace($script:DashboardLayout) -or ($script:DashboardLayoutNames -notcontains $script:DashboardLayout)) {
    $script:DashboardLayout = "Classic"
}
$matrixConfig.DashboardLayout = $script:DashboardLayout

$env:OLLAMA_CONTEXT_LENGTH = [string]$OllamaContextLength
function Get-SafeMaxLoadedModels {
    param([string]$Profile = $script:SelectedProfile)

    # Up to 4 warm agent brains. Restart Matrix once after changing this
    # (OLLAMA_MAX_LOADED_MODELS is read only at ollama serve startup).
    return "4"
}

$env:OLLAMA_NUM_PARALLEL = "1"
# Tied to the active profile via Get-SafeMaxLoadedModels rather than a flat
# value - a flat "2" meant Low-VRAM 6GB systems tried to keep 2 models
# resident, starving VRAM for the model actually in use and causing severe
# slowdowns starting with the 3rd agent launched in a session.
$env:OLLAMA_MAX_LOADED_MODELS = Get-SafeMaxLoadedModels
$env:OLLAMA_MAX_QUEUE = "4"
$env:OLLAMA_KEEP_ALIVE = $OllamaKeepAlive
$script:OllamaCpuFallbackActive = $false
$script:HideModelThinking = $false   # $true => --hidethinking (final answer only)
$env:OLLAMA_GPU_OVERHEAD = "536870912"
$env:OLLAMA_KV_CACHE_TYPE = "q8_0"


# ---------------------------------------------------------------------------
# COMMAND ACTIVATION GUIDE
# Every user-facing command calls this helper after clearing its screen so the
# purpose, expected input, and safe usage are always visible at activation.
# ---------------------------------------------------------------------------
$script:CommandGuide = @{
    'help'             = @{What='Open the full Matrix help and documentation screen.'; Use='help'; Input='No input required; press Enter when finished.'}
    'exit'             = @{What='Exit CypraTeam while leaving Ollama/model allocations intact.'; Use='exit'; Input='No input required.'}
    'hud'              = @{What='Show live GPU/VRAM/Ollama telemetry.'; Use='hud'; Input='No input required; press Enter to return.'}
    'task'             = @{What='Browse saved task workspaces and inspect task metadata.'; Use='task'; Input='Optional: select a displayed task/workspace.'}
    'taskopen'         = @{What='Open the active task workspace in the file explorer.'; Use='taskopen'; Input='No input required; an active task workspace should exist.'}
    'settings'         = @{What='Open Matrix runtime and persistence settings.'; Use='settings'; Input='Choose a setting from the menu.'}
    'theme'            = @{What='Edit the Matrix UI color palette live.'; Use='theme'; Input='Choose a palette/setting from the editor.'}
    'layout'           = @{What='Switch the dashboard structural layout (separate from color theme).'; Use='layout'; Input='Choose a layout from the list.'}
    'think'            = @{What='Toggle model-thinking display between hidden and visible.'; Use='think'; Input='No input required; the state toggles immediately.'}
    'stats'            = @{What='Show current session, runtime, and agent statistics.'; Use='stats'; Input='No input required.'}
    'launch'           = @{What='Launch a specific registered agent by ID or name, with an optional prompt.'; Use='launch'; Input='Enter an agent ID or name; an optional prompt can follow when the agent selector appears.'}
    'find'             = @{What='Search the agent registry and optionally launch a matching agent.'; Use='find <name/skill>'; Input='Enter a name, specialty, tag, or keyword.'}
    'backup'           = @{What='Create a workspace backup while preserving the local model store policy.'; Use='backup'; Input='Follow the backup prompts.'}
    'profile'          = @{What='Switch the Matrix runtime performance profile.'; Use='profile'; Input='Choose the desired profile.'}
    'pipe'             = @{What='Run a sequential multi-agent pipeline.'; Use='pipe'; Input='Enter the task/prompt and pipeline options.'}
    'quad'             = @{What='Run four-agent independent analysis and combine the results.'; Use='quad'; Input='Enter the task; Nexus can select specialists when needed.'}
    'debate'           = @{What='Run a two-agent adversarial debate followed by a Nexus-Prime judge.'; Use='debate'; Input='Enter task, then 2 agent IDs (or leave blank for Nexus auto-select).'}
    'hist'             = @{What='Browse Matrix session and execution logs.'; Use='hist'; Input='Navigate the log browser.'}
    'groups'           = @{What='Browse live agent groups and launch a specialist from a group.'; Use='groups'; Input='Choose a group, then an agent ID.'}
    'map'              = @{What='Build a fresh live agent/group relationship map and browse groups interactively.'; Use='map'; Input='Press N for next group, P for previous, D for details, A for all IDs, R to refresh, Enter to return.'}
    'out'               = @{What='Inspect captured agent output from the current session.'; Use='out'; Input='Choose the output entry to inspect.'}
    'preflight'         = @{What='Run system, Ollama, VRAM, registry, and dependency preflight checks.'; Use='preflight'; Input='No input required.'}
    'recover'           = @{What='Run the Matrix recovery sequence for common runtime/state problems.'; Use='recover'; Input='Follow the recovery prompts.'}
    'vram'              = @{What='Open VRAM cleanup/control tools for local model workloads.'; Use='vram'; Input='Choose the cleanup/control action.'}
    'clearvram'         = @{What='Run the local CLEARVRAM.bat reclaim utility.'; Use='clearvram'; Input='Confirm administrator/shell restart prompts if requested.'}
    'pull'              = @{What='Manage and pull configured Ollama model dependencies.'; Use='pull'; Input='Choose an installed model or enter a model to pull.'}
    'commands'          = @{What='Open the complete command reference with aliases and usage.'; Use='commands'; Input='N/P to page; type a command to execute it; Q/Enter returns.'}
    'addons'            = @{What='Open the Matrix Addon Center for advanced tools.'; Use='addons'; Input='Choose an addon number or R to reset addon state.'}
    'routeaudit'        = @{What='Explain why Nexus selected particular agents for a task.'; Use='routeaudit'; Input='Enter the task/prompt to audit.'}
    'team'              = @{What='Build and store a complementary specialist team.'; Use='team'; Input='Enter the mission/task and follow team selection prompts.'}
    'teamrun'           = @{What='Run the currently active specialist team.'; Use='teamrun'; Input='Confirm/follow the run prompts.'}
    'teamask'           = @{What='Build a new specialist team and run it immediately.'; Use='teamask'; Input='Enter the task/mission.'}
    'teamshow'          = @{What='Display the currently active specialist team.'; Use='teamshow'; Input='No input required.'}
    'teamclear'         = @{What='Clear the currently active specialist team.'; Use='teamclear'; Input='Confirm when prompted.'}
    'capabilities'      = @{What='Inspect the live capability profiles used by Nexus routing.'; Use='capabilities'; Input='No input required; navigate the displayed profiles.'}
    'exclusions'        = @{What='Show negative/exclusion expertise rules used to avoid poor routing matches.'; Use='exclusions'; Input='No input required.'}
    'performance'       = @{What='Show historical agent runs, success rates, and average runtime; optionally filter by agent ID or name.'; Use='performance'; Input='Enter an agent ID/name, or press Enter for all agents.'}
    'replace'           = @{What='Find alternative specialists for a task when the current agent is unsuitable.'; Use='replace'; Input='Enter the task, then the current agent ID or name.'}
    'evaluate'          = @{What='Run a structured evaluation harness against one registered agent.'; Use='evaluate'; Input='Enter an agent ID or exact/partial agent name, then a test task.'}
    'routing-test'      = @{What='Run Nexus routing regression tests.'; Use='routing-test'; Input='Follow the regression test prompts/results.'}
    'memorybridge'      = @{What='Check the persistent Memory and Knowledge storage locations and counts.'; Use='memorybridge'; Input='No input required.'}
    'confidence-report' = @{What='Show routing-confidence inputs and historical adjustments for selected specialists.'; Use='confidence-report'; Input='Enter the task/prompt.'}
    'mission'           = @{What='Open Nexus Mission Control for high-level orchestration.'; Use='mission'; Input='Choose a mission-control action.'}
    'memory'            = @{What='Open the persistent Matrix/agent memory vault.'; Use='memory'; Input='Choose a memory operation.'}
    'knowledge'         = @{What='Build/search the persistent Knowledge/RAG index from conversation records.'; Use='knowledge'; Input='Enter a folder to index or press Enter for the Conversations default.'}
    'scan'              = @{What='Inspect a file/folder and summarize file types and duplicate-size groups.'; Use='scan'; Input='Enter a valid file or folder path; blank uses the project root.'}
    'review'            = @{What='Select one agent to review a file with configurable focus/depth/severity.'; Use='review'; Input='Agent ID/name, file path, then optional focus/depth/severity/format.'}
    'debug'             = @{What='Use the debugger agent to diagnose an error/traceback and propose a minimal fix.'; Use='debug'; Input='Paste the error or traceback.'}
    'sandbox'           = @{What='Create an isolated agent sandbox workspace.'; Use='sandbox'; Input='Enter a sandbox name.'}
    'diff'              = @{What='Compare an original file with a changed file.'; Use='diff'; Input='Enter both file paths.'}
    'confidence'        = @{What='Score a claim/answer for confidence, evidence quality, assumptions, and uncertainty.'; Use='confidence'; Input='Enter the claim or answer to evaluate.'}
    'verify'            = @{What='Cross-check text for unsupported claims, contradictions, and unverifiable statements.'; Use='verify'; Input='Paste the answer/text to check.'}
    'health'            = @{What='Show installed and currently loaded Ollama model health/readiness.'; Use='health'; Input='No input required.'}
    'queue'             = @{What='Show the current VRAM/runtime queue and loaded models.'; Use='queue'; Input='No input required.'}
    'integrity'         = @{What='Check installed directive-backed agents against the model registry.'; Use='integrity'; Input='Navigate the integrity report.'}
    'models'            = @{What='Open the installed-model manager.'; Use='models'; Input='Choose a model-management action.'}
    'audit'             = @{What='Audit local model storage for duplicates/orphans.'; Use='audit'; Input='Follow the audit prompts.'}
    'deps'              = @{What='Analyze task dependencies and ordering.'; Use='deps'; Input='Enter the task to analyze.'}
    'packs'             = @{What='Browse available specialist capability packs.'; Use='packs'; Input='Choose a pack to inspect.'}
    'workflows'         = @{What='Browse reusable workflow templates.'; Use='workflows'; Input='Choose a workflow template.'}
    'timeline'          = @{What='Show recorded task execution timeline/artifacts.'; Use='timeline'; Input='Select a task/workspace when prompted.'}
    'analytics'         = @{What='Show resource and performance analytics.'; Use='analytics'; Input='No input required or follow filter prompts.'}
    'learn'             = @{What='Show Nexus learning/router analytics and learned routing behavior.'; Use='learn'; Input='No input required.'}
    'classifier'        = @{What='Classify a task into routing/problem categories.'; Use='classifier'; Input='Enter the task description.'}
    'summarize'         = @{What='Create a durable summary of a task/workspace.'; Use='summarize'; Input='Enter the task/workspace information.'}
    'resume'            = @{What='Reconstruct context and resume an existing task.'; Use='resume'; Input='Select/identify the task workspace.'}
    'orchestrate'       = @{What='Build a step-by-step execution plan for a task.'; Use='orchestrate'; Input='Enter the task/mission.'}
    'evidence'          = @{What='Open the Evidence Locker for stored evidence artifacts.'; Use='evidence'; Input='Choose an evidence operation.'}
    'resolve'           = @{What='Analyze and resolve contradictions between outputs/evidence.'; Use='resolve'; Input='Enter the conflicting material/task.'}
    'consensus-scores'  = @{What='Show historical agent consensus scores.'; Use='consensus-scores'; Input='No input required.'}
    'risk'              = @{What='Analyze task risks, blockers, and mitigation options.'; Use='risk'; Input='Enter the task.'}
    'approve'           = @{What='Run the change-approval gate before a change is accepted.'; Use='approve'; Input='Review the proposed change and approval prompts.'}
    'patch'             = @{What='Generate a minimal patch/diff for a requested code change.'; Use='patch'; Input='Enter the target file/change request.'}
    'test'              = @{What='Run the automated test runner against the project.'; Use='test'; Input='Enter/select the test target.'}
    'regression'        = @{What='Run the Matrix regression guard against known workflows.'; Use='regression'; Input='Follow the regression test prompts.'}
    'projecthealth'     = @{What='Calculate a project health/status report.'; Use='projecthealth'; Input='Enter/select the project root if prompted.'}
    'depscan'           = @{What='Scan a project for recognized dependency manifests.'; Use='depscan'; Input='Enter the project folder.'}
    'env'               = @{What='Snapshot PowerShell, Ollama, GPU/VRAM, profile, context, and agent environment state.'; Use='env'; Input='No input required.'}
    'warm'              = @{What='Show the Ollama warm-pool/loaded model status.'; Use='warm'; Input='No input required.'}
    'residency'         = @{What='Predict which models are likely to be needed for an upcoming task.'; Use='residency'; Input='Enter the upcoming task.'}
    'compress'          = @{What='Compress a conversation/task file into durable context while preserving decisions and next actions.'; Use='compress'; Input='Enter a valid file path; blank cancels safely.'}
    'memorymatch'       = @{What='Find memory records relevant to the current task.'; Use='memorymatch'; Input='Enter the current task.'}
    'citations'         = @{What='Search/index knowledge sources and show citation-ready records.'; Use='citations'; Input='Follow the knowledge/citation prompts.'}
    'freshness'         = @{What='Check indexed knowledge records for current, aging, or outdated entries.'; Use='freshness'; Input='No input required; build the knowledge index first if none exists.'}
    'watch'             = @{What='Watch a project folder for file changes for a short monitoring window.'; Use='watch'; Input='Enter the folder to watch.'}
    'caplearn'          = @{What='Show learned agent capability/performance data; optionally filter by agent ID or name.'; Use='caplearn'; Input='Enter an agent ID/name, or press Enter for all.'}
    'pairings'          = @{What='Show specialist pairings used to seed Nexus team composition.'; Use='pairings'; Input='No input required.'}
    'checkpoint'        = @{What='Save a named mission checkpoint for later review/recovery.'; Use='checkpoint'; Input='Enter a task/mission name.'}
    'replay'            = @{What='Review recorded mission artifacts in execution order.'; Use='replay'; Input='Enter a task workspace or replay path.'}
    'resetall'          = @{What='Reset Matrix runtime/addon state to its default state.'; Use='resetall'; Input='Confirm the reset when prompted.'}
    'incident'          = @{What='Generate an operational incident-response playbook.'; Use='incident'; Input='Describe the incident/scenario.'}
    'testmatrix'        = @{What='Build a professional test matrix for a task/project.'; Use='testmatrix'; Input='Enter the task/project scope.'}
    'journal'           = @{What='Record/review secure change-journal entries.'; Use='journal'; Input='Follow the journal prompts.'}
    'context'           = @{What='Optimize context budget for multi-agent execution.'; Use='context'; Input='Enter the task/context to optimize.'}
    'skillgap'          = @{What='Identify specialist skill gaps relevant to a task.'; Use='skillgap'; Input='Enter the task or project goal.'}
    'macro'             = @{What='Open the reusable prompt macro library.'; Use='macro'; Input='Choose/create a macro as prompted.'}
    'secrets'           = @{What='Scan project files for likely secrets or credentials.'; Use='secrets'; Input='Enter the project/file path.'}
    'vote'              = @{What='Run a multi-agent majority vote on a question/decision.'; Use='vote'; Input='Enter the question/options.'}
    'benchmark'         = @{What='Benchmark an agent response and log timing/throughput metrics.'; Use='benchmark'; Input='Enter the benchmark prompt/model as prompted.'}
    'export'            = @{What='Export the active task workspace as a portable session bundle.'; Use='export'; Input='An active task workspace is required.'}
}
function Show-CommandActivation {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [switch]$Animate
    )
    $key = $Command.Trim().ToLowerInvariant()

    # The command loader is tied to a command entered from the Dashboard.
    # The main loop sets $script:AnimateNextCommandActivation only for direct
    # Dashboard input.  It is consumed on the first activation so nested
    # helper calls do not replay the animation.  Command-center paging does
    # not set the flag, so N/P never replay the loader.
    $shouldAnimate = $Animate -or [bool]$script:AnimateNextCommandActivation
    if ($shouldAnimate) {
        Show-CommandLoadSequence -Command $key
        $script:AnimateNextCommandActivation = $false
    }

    Clear-Host
    if ($key -eq 'tasks' -or $key -eq 'taskview') { $key='task' }
    elseif ($key -eq 'explorer' -or $key -eq 'taskopen') { $key='taskopen' }
    elseif ($key -in @('config')) { $key='settings' }
    elseif ($key -in @('colors','colours')) { $key='theme' }
    elseif ($key -in @('layouts','dashboardlayout')) { $key='layout' }
    elseif ($key -in @('thinking','hidethink')) { $key='think' }
    elseif ($key -eq 'stat') { $key='stats' }
    elseif ($key -in @('search')) { $key='find' }
    elseif ($key -in @('bckup')) { $key='backup' }
    elseif ($key -in @('consensus')) { $key='quad' }
    elseif ($key -eq 'debate2') { $key='debate' }
    elseif ($key -in @('group')) { $key='groups' }
    elseif ($key -in @('graph')) { $key='map' }
    elseif ($key -in @('output','inspect')) { $key='out' }
    elseif ($key -in @('check')) { $key='preflight' }
    elseif ($key -in @('recovery')) { $key='recover' }
    elseif ($key -in @('clear-vram','clearvram.bat')) { $key='clearvram' }
    elseif ($key -in @('cmds','allcommands')) { $key='commands' }
    elseif ($key -in @('addon','matrix')) { $key='addons' }
    elseif ($key -in @('routing-audit')) { $key='routeaudit' }
    elseif ($key -in @('teambuilder')) { $key='team' }
    elseif ($key -in @('team-run','runteam')) { $key='teamrun' }
    elseif ($key -in @('team-ask')) { $key='teamask' }
    elseif ($key -in @('active-team')) { $key='teamshow' }
    elseif ($key -in @('clearteam')) { $key='teamclear' }
    elseif ($key -in @('capability')) { $key='capabilities' }
    elseif ($key -in @('negative')) { $key='exclusions' }
    elseif ($key -in @('agentstats')) { $key='performance' }
    elseif ($key -in @('replacement')) { $key='replace' }
    elseif ($key -in @('eval')) { $key='evaluate' }
    elseif ($key -in @('routingtest')) { $key='routing-test' }
    elseif ($key -in @('bridge')) { $key='memorybridge' }
    elseif ($key -in @('routeconfidence')) { $key='confidence-report' }
    elseif ($key -in @('nexus')) { $key='mission' }
    elseif ($key -in @('rag')) { $key='knowledge' }
    elseif ($key -in @('routeconfidence')) { $key='confidence-report' }
    elseif ($key -in @('classify')) { $key='classifier' }
    elseif ($key -in @('summary')) { $key='summarize' }
    elseif ($key -in @('taskresume')) { $key='resume' }
    elseif ($key -in @('plan')) { $key='orchestrate' }
    elseif ($key -eq 'skill-gap') { $key='skillgap' }
    elseif ($key -in @('macros')) { $key='macro' }
    elseif ($key -in @('creds')) { $key='secrets' }
    elseif ($key -in @('poll')) { $key='vote' }
    elseif ($key -in @('bench')) { $key='benchmark' }
    elseif ($key -in @('bundle')) { $key='export' }
    $g = $script:CommandGuide[$key]
    if ($null -eq $g) {
        Write-Host "COMMAND: $Command" -ForegroundColor $Theme.Info
        Write-Host "WHAT   : Run the $Command Matrix command." -ForegroundColor $Theme.MutedLight
        Write-Host "USAGE  : $Command" -ForegroundColor $Theme.MutedLight
        Write-Host "INPUT  : Follow the prompts shown by the command." -ForegroundColor $Theme.MutedLight
    } else {
        Write-Host "COMMAND: $key" -ForegroundColor $Theme.Info
        Write-Host "WHAT   : $($g.What)" -ForegroundColor $Theme.MutedLight
        Write-Host "USAGE  : $($g.Use)" -ForegroundColor $Theme.MutedLight
        Write-Host "INPUT  : $($g.Input)" -ForegroundColor $Theme.MutedLight
    }
    Write-Host ('─' * 78) -ForegroundColor $Theme.Muted
}


function Resolve-AgentIdentifier {
    param([Parameter(Mandatory=$true)][string]$Identifier)
    $q = $Identifier.Trim()
    if ([string]::IsNullOrWhiteSpace($q)) { return $null }

    # OrderedDictionary exposes Contains(), not ContainsKey().
    if ($script:AgentRegistry.Contains($q)) { return [string]$q }

    $exact = @(
        $script:AgentRegistry.Keys |
        Where-Object {
            $e = $script:AgentRegistry[[string]$_]
            $null -ne $e -and (
                [string]$e.name -ieq $q -or
                [string]$e.model -ieq $q -or
                [string]$e.tag -ieq $q
            )
        } |
        Select-Object -First 1
    )
    if ($exact.Count -gt 0) { return [string]$exact[0] }

    $partial = @(
        $script:AgentRegistry.Keys |
        Where-Object {
            $e = $script:AgentRegistry[[string]$_]
            $null -ne $e -and (
                [string]$e.name -ilike "*$q*" -or
                [string]$e.model -ilike "*$q*" -or
                [string]$e.tag -ilike "*$q*"
            )
        } |
        Select-Object -First 1
    )
    if ($partial.Count -gt 0) { return [string]$partial[0] }
    return $null
}

function Invoke-OllamaRun {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [string]$Prompt = $null,
        [switch]$CaptureStderr
    )
    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.Add($Model)
    if ($script:HideModelThinking) { $argList.Add('--hidethinking') }
    if (-not [string]::IsNullOrEmpty($Prompt)) { $argList.Add($Prompt) }
    if ($CaptureStderr) {
        return & ollama run @($argList.ToArray()) 2>&1
    }
    & ollama run @($argList.ToArray())
}

function Invoke-OllamaInteractive {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [string]$Prompt = $null
    )

    # Same-console `ollama run` — Start-Process often returns immediately
    # with no visible output (looks like the agent died).
    $exe = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($exe)) {
        Write-Host "[!] ollama.exe was not found on PATH." -ForegroundColor $Theme.Error
        return 1
    }

    $runArgs = [System.Collections.Generic.List[string]]::new()
    $runArgs.Add('run')
    $runArgs.Add($Model)
    if ($script:HideModelThinking) { $runArgs.Add('--hidethinking') }
    if (-not [string]::IsNullOrEmpty($Prompt)) { $runArgs.Add($Prompt) }

    Write-Host ""
    Write-Host ("[*] {0} ..." -f $Model) -ForegroundColor $Theme.Muted
    & $exe @($runArgs.ToArray())
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    return [int]$code
}

function Write-MatrixChatHintLine {
    $cmds = @('/help','/clear','/export','/bye')
    $cols = @($Theme.Info, $Theme.Brand, $Theme.Accent, $Theme.Success, $Theme.Info2, $Theme.Warning)
    Write-Host "  " -NoNewline
    for ($i = 0; $i -lt $cmds.Count; $i++) {
        if ($i -gt 0) { Write-Host "  " -NoNewline }
        Write-Host $cmds[$i] -NoNewline -ForegroundColor $cols[$i % $cols.Count]
    }
    Write-Host ""
}

function Show-MatrixPromptPulse {
    $frames = @([string][char]0x22C5, ':', [string][char]0x2E2C, [string][char]0x2059)
    $colors = @($Theme.Info, $Theme.Brand, $Theme.Accent, $Theme.Success)
    for ($i = 0; $i -lt 6; $i++) {
        Write-Host ("`r  {0}  ready   " -f $frames[$i % 4]) -NoNewline -ForegroundColor $colors[$i % 4]
        Start-Sleep -Milliseconds 70
    }
    Write-Host "`r                 `r" -NoNewline
}

function Read-MatrixChatLine {
    param(
        [string]$AgentName = 'agent',
        [switch]$ShowChrome
    )

    if ($ShowChrome) {
        Write-Host ""
        Write-MatrixChatHintLine
        Write-Host "  " -NoNewline
        Write-Host $AgentName -NoNewline -ForegroundColor $Theme.Brand
        Write-Host "  ·  " -NoNewline -ForegroundColor $Theme.Muted
        Write-Host "Enter send" -NoNewline -ForegroundColor $Theme.Info
        Write-Host "  ·  " -NoNewline -ForegroundColor $Theme.Muted
        Write-Host "/bye leave" -ForegroundColor $Theme.Accent
        Show-MatrixPromptPulse
    }

    return [string](Read-Host ">>>")
}

function Show-MatrixLastChatPreview {
    param([System.Collections.IList]$Messages, [int]$Max = 4)
    $users = @($Messages | Where-Object { [string]$_.role -eq 'user' })
    if ($users.Count -eq 0) { return }
    Write-Host "[i] Last prompts:" -ForegroundColor $Theme.MutedLight
    $slice = $users | Select-Object -Last $Max
    foreach ($u in $slice) {
        $t = [string]$u.content
        if ($t.Length -gt 90) { $t = $t.Substring(0, 87) + '...' }
        Write-Host ("    • {0}" -f $t) -ForegroundColor $Theme.Muted
    }
}

function Invoke-OllamaNative {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$Quiet
    )
    # ollama writes progress to stderr. PowerShell treats that as NativeCommandError
    # if we merge 2>&1. Run through cmd so progress is just text and $LASTEXITCODE
    # is the real ollama result.
    $argLine = ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
    }) -join ' '
    if ($Quiet) {
        & cmd.exe /c "ollama $argLine >nul 2>&1"
    } else {
        & cmd.exe /c "ollama $argLine"
    }
    return $LASTEXITCODE
}

function Invoke-LogCleanup {
    $logDir = Join-Path $PSScriptRoot "Logs"
    if (Test-Path $logDir) {
        $retentionDays = [int]$matrixConfig.LogRetentionDays
        $thresholdDate = (Get-Date).AddDays(-$retentionDays)
        $oldLogs = Get-ChildItem -Path $logDir -Filter "*.log" | Where-Object { $_.CreationTime -lt $thresholdDate }
        if ($oldLogs) {
            foreach ($oldLog in $oldLogs) {
                Remove-Item -Path $oldLog.FullName -Force
            }
            Write-Host "[+] Cleaned up $($oldLogs.Count) session logs older than $retentionDays days." -ForegroundColor $Theme.InfoDim
        }
    }
}

# ==============================================
# ANIMATION ENGINE (lightweight console FX)
# ==============================================
$script:BootAnimationShown = $false

function Show-TypewriterLine {
    param(
        [string]$Text,
        [string]$Color = $Theme.Info,
        [int]$DelayMs = 6
    )
    foreach ($ch in $Text.ToCharArray()) {
        Write-Host -NoNewline $ch -ForegroundColor $Color
        if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    }
    Write-Host ""
}

function Show-LoadingBar {
    param(
        [string]$Label = "Loading",
        [int]$Steps = 20,
        [int]$DelayMs = 12,
        [string]$Color = $null
    )
    if (-not $Color) { $Color = $Theme.Success }
    for ($i = 1; $i -le $Steps; $i++) {
        $filled = [string]([char]0x2588) * $i
        $empty  = [string]([char]0x2591) * ($Steps - $i)
        $pct = [int](($i / $Steps) * 100)
        Write-Host "`r $Label [$filled$empty] $pct%  " -NoNewline -ForegroundColor $Color
        Start-Sleep -Milliseconds $DelayMs
    }
    Write-Host ""
}

function Invoke-BackgroundTaskWithSpinner {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [string]$Label = "Working",
        [string]$Color = $null,
        [string]$DoneLabel = $null
    )
    if (-not $Color) { $Color = $Theme.Info }
    if (-not $DoneLabel) { $DoneLabel = "$Label complete." }

    $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    $spinChars = @('|','/','-','\')
    $frame = 0

    while ($job.State -eq 'Running') {
        $spin = $spinChars[$frame % $spinChars.Count]
        Write-Host "`r [$spin] $Label..." -NoNewline -ForegroundColor $Color
        Start-Sleep -Milliseconds 130
        $frame++
    }

    Wait-Job $job | Out-Null
    $jobFailed = ($job.State -eq 'Failed')
    $jobError = $job.ChildJobs[0].JobStateInfo.Reason
    $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null

    if ($jobFailed) {
        Write-Host "`r [!] $Label failed.                                   " -ForegroundColor $Theme.Error
    } else {
        Write-Host "`r [+] $DoneLabel                                   " -ForegroundColor $Theme.Success
    }

    return [ordered]@{
        Success = -not $jobFailed
        Error   = $jobError
        Result  = $result
    }
}

function Show-BootSequence {
    param(
        [switch]$Force,
        [string]$ArtFile = "boot.txt",
        [switch]$Fast
    )
    if ($script:BootAnimationShown -and -not $Force) { return }
    $script:BootAnimationShown = $true
    Clear-Host

    # Fast mode is used for model/agent activation so the same boot sequence
    # remains recognizable without making an agent launch feel slow.
    $typeDelay = if ($Fast) { 0 } else { 4 }
    $typeDelay2 = if ($Fast) { 0 } else { 3 }
    $rainDelay = if ($Fast) { 8 } else { 35 }
    $artDelay = if ($Fast) { 4 } else { 28 }
    $loadDelay = if ($Fast) { 2 } else { 8 }
    $pauseShort = if ($Fast) { 15 } else { 80 }
    $pauseMedium = if ($Fast) { 15 } else { 60 }
    $pauseLong = if ($Fast) { 15 } else { 50 }
    $finalPause = if ($Fast) { 75 } else { 400 }

    # Retro terminal header
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor $Theme.Brand
    Write-Host "  ║          CYPRATEAM  //  PORTABLE MATRIX ENGINE  //  v1.1     ║" -ForegroundColor $Theme.Brand
    Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor $Theme.Brand
    Write-Host ""

    Show-TypewriterLine -Text "  > INITIALIZING CYPRATEAM INFRASTRUCTURE MATRIX..." -Color $Theme.BrandDim -DelayMs $typeDelay
    Start-Sleep -Milliseconds $pauseShort
    Show-TypewriterLine -Text "  > ISOLATING PORTABLE ENVIRONMENT & AGENT REGISTRY..." -Color $Theme.InfoDim -DelayMs $typeDelay2
    Start-Sleep -Milliseconds $pauseMedium
    Show-TypewriterLine -Text "  > LOCKING MODEL STORE TO LOCAL PROJECT ROOT..." -Color $Theme.Muted -DelayMs $typeDelay2
    Start-Sleep -Milliseconds $pauseLong
    Show-TypewriterLine -Text "  > ESTABLISHING SECURE LOCALHOST ENDPOINT 127.0.0.1:11435..." -Color $Theme.Muted -DelayMs $typeDelay2
    Write-Host ""

    # Matrix-style cascade lines
    $rain = @(
        "  0x1A 0x2F 0x9C 0x4E 0x7B 0x01 0xD3 0x88 0xF2 0x55",
        "  0xC4 0x19 0x6A 0xE0 0x3D 0x91 0xB7 0x0F 0xAA 0x62",
        "  0x77 0xDE 0x05 0x8B 0xF1 0x2C 0x49 0xA3 0x16 0xE8"
    )
    foreach ($r in $rain) {
        Write-Host $r -ForegroundColor $Theme.BrandDim
        Start-Sleep -Milliseconds $rainDelay
    }
    Write-Host ""

    # Boot artwork is kept external so the original animation remains intact
    # while the image itself can be changed without editing the launcher.
     $logoPath = Join-Path $PSScriptRoot $ArtFile
    if (Test-Path $logoPath) {
        $logoLines = @(Get-Content -LiteralPath $logoPath -Encoding UTF8 -ErrorAction SilentlyContinue)
    } else {
        $logoLines = @("  [$ArtFile not found]")
    }
    foreach ($line in $logoLines) {
        Write-Host $line -ForegroundColor $Theme.Brand
        Start-Sleep -Milliseconds $artDelay
    }

    Write-Host ""
    Write-Host "           :: NEXUS PRIME SPAWNING ::" -ForegroundColor $Theme.Success
    Write-Host "           :: LOCAL  ·  PORTABLE  ·  OPERATOR-CONTROLLED ::" -ForegroundColor $Theme.Muted
    Write-Host ""

    Show-LoadingBar -Label "  MATRIX BOOT" -Steps 28 -DelayMs $loadDelay -Color $Theme.Brand
    Start-Sleep -Milliseconds $pauseMedium

    Show-TypewriterLine -Text "  > AGENT REGISTRY ONLINE" -Color $Theme.Success -DelayMs $(if($Fast){0}else{2})
    Show-TypewriterLine -Text "  > VRAM SCHEDULER ARMED" -Color $Theme.Success -DelayMs $(if($Fast){0}else{2})
    Show-TypewriterLine -Text "  > MEMORY VAULT + KNOWLEDGE LAYER READY" -Color $Theme.Success -DelayMs $(if($Fast){0}else{2})
    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor $Theme.BrandDim
    Write-Host "   SYSTEM ONLINE  //  AWAITING OPERATOR INPUT" -ForegroundColor $Theme.Brand
    Write-Host "  ══════════════════════════════════════════════════════════════" -ForegroundColor $Theme.BrandDim
    Start-Sleep -Milliseconds $finalPause
}


# ==============================================
# COMMAND LOAD SCREEN ENGINE (external commandload.txt)
# ==============================================
$script:CommandLoadFile = Join-Path $PSScriptRoot "commandload.txt"

function Show-CommandLoadSequence {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [switch]$Fast
    )

    # NEW COMMAND ACTIVATION ANIMATION
    # Uses external commandload.txt as the visual asset, but presents it as a
    # compact "signal handshake" instead of the previous boot-style loader.
    # This function is only reached when the Dashboard sets
    # $script:AnimateNextCommandActivation.
    Clear-Host

    $typeDelay = if ($Fast) { 0 } else { 1 }
    $frameDelay = if ($Fast) { 0 } else { 35 }
    $barDelay = if ($Fast) { 0 } else { 18 }
    $finalPause = if ($Fast) { 0 } else { 70 }

    $width = 70
    $inner = '─' * $width
    $cmd = $Command.ToUpperInvariant()

    Write-Host ("╔{0}╗" -f $inner) -ForegroundColor $Theme.Brand
    Write-Host ("║{0}║" -f ("  COMMAND SIGNAL // {0}" -f $cmd).PadRight($width)) -ForegroundColor $Theme.Brand
    Write-Host ("╠{0}╣" -f $inner) -ForegroundColor $Theme.Brand

    Show-TypewriterLine -Text ("  > LINK REQUEST: {0}" -f $cmd) -Color $Theme.InfoDim -DelayMs $typeDelay
    Show-TypewriterLine -Text "  > READING COMMANDLOAD CHANNEL..." -Color $Theme.Muted -DelayMs $typeDelay

    # commandload.txt remains the external animation asset. Each line is
    # presented as a live signal frame rather than simply dumping the file.
    if (Test-Path -LiteralPath $script:CommandLoadFile) {
        $lines = @(Get-Content -LiteralPath $script:CommandLoadFile -Encoding UTF8 -ErrorAction SilentlyContinue)
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                Write-Host ""
            } else {
                Write-Host ("  > " + $line.TrimEnd()) -ForegroundColor $Theme.Brand
            }
            if ($frameDelay -gt 0) { Start-Sleep -Milliseconds $frameDelay }
        }
    } else {
        Write-Host "  > commandload.txt unavailable; using fallback signal frame." -ForegroundColor $Theme.Warning
    }

    Write-Host ""
    $steps = if ($Fast) { 5 } else { 8 }
    for ($i = 1; $i -le $steps; $i++) {
        $pct = [int](($i / $steps) * 100)
        $filled = [Math]::Max(1, [int](($pct / 100) * 24))
        $empty = 24 - $filled
        $bar = ('█' * $filled) + ('·' * $empty)
        $phase = switch ($i) {
            1 { 'context' }
            2 { 'route' }
            3 { 'resolve' }
            4 { 'prepare' }
            5 { 'handoff' }
            6 { 'execute' }
            7 { 'verify' }
            default { 'online' }
        }
        $line = ("  [{0}] {1,3}%  {2}" -f $bar,$pct,$phase.ToUpperInvariant())
        Write-Host ("`r" + $line.PadRight($width + 10)) -NoNewline -ForegroundColor $Theme.Success
        if ($barDelay -gt 0) { Start-Sleep -Milliseconds $barDelay }
    }
    Write-Host ""
    Write-Host ("╚{0}╝" -f $inner) -ForegroundColor $Theme.Brand
    if ($finalPause -gt 0) { Start-Sleep -Milliseconds $finalPause }
}

function Stop-LoadedOllamaModels {
    param([switch]$Force)

    if (-not $Force) {
        # Normal agent execution reuses the currently loaded model when possible.
        return
    }

    try {
        $runningModels = & ollama ps 2>$null
        if ($runningModels) {
            foreach ($row in ($runningModels | Select-Object -Skip 1)) {
                $rowText = [string]$row
                if ([string]::IsNullOrWhiteSpace($rowText)) { continue }
                $parts = $rowText.Trim() -split '\s+'
                if ($parts.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($parts[0])) {
                    Write-Host "[*] Releasing loaded Ollama model: $($parts[0])" -ForegroundColor $Theme.Muted
                    & ollama stop $parts[0] 2>$null | Out-Null
                }
            }
        }
    } catch {}
}

function Set-OllamaGpuMode {
    param([bool]$CpuOnly = $false)

    if ($CpuOnly) {
        $env:OLLAMA_LLM_LIBRARY = "cpu_avx2"
        $env:CUDA_VISIBLE_DEVICES = "-1"
    } else {
        Remove-Item Env:OLLAMA_LLM_LIBRARY -ErrorAction SilentlyContinue
        Remove-Item Env:CUDA_VISIBLE_DEVICES -ErrorAction SilentlyContinue
    }
}

function Test-OllamaReady {
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:11435/api/tags" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        return ($response.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Start-OllamaEngine {
    param([bool]$CpuOnly = $false)

    # CypraTeam owns a dedicated Ollama server on localhost:11435.
    # The installed ollama.exe remains machine-level; only the model store
    # and server endpoint are project-local.
    $portableStore = [System.IO.Path]::GetFullPath($defaultModelStorePath)
    $matrixConfig.ModelStorePath = $portableStore
    $env:OLLAMA_HOST = $script:CypraOllamaHost
    $env:OLLAMA_MODELS = $portableStore

    if (-not (Test-Path $portableStore)) {
        New-Item -ItemType Directory -Path $portableStore -Force | Out-Null
    }
    if (-not (Test-Path $script:PortableStoreMarker)) {
        "CypraTeam portable Ollama model store`r`nProject: $PSScriptRoot`r`nHost: $script:CypraOllamaHost" |
            Set-Content -Path $script:PortableStoreMarker -Encoding utf8
    }

    Set-OllamaGpuMode -CpuOnly $CpuOnly
    $script:OllamaCpuFallbackActive = $CpuOnly

    if (Test-OllamaReady) {
        $script:OllamaStartedByMatrix = $true
        Write-Host "[+] CypraTeam Ollama is already running on $script:CypraOllamaHost" -ForegroundColor $Theme.Success
        Write-Host "[+] Portable model store: $portableStore" -ForegroundColor $Theme.Success
        return $true
    }

    Write-Host "[*] Starting CypraTeam Ollama on $script:CypraOllamaHost..." -ForegroundColor $Theme.Warning
    Write-Host "    Model store: $portableStore" -ForegroundColor $Theme.InfoDim

    $ollamaExe = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($ollamaExe)) {
        Write-Host "[!] ollama was not found in PATH." -ForegroundColor $Theme.Error
        return $false
    }

    # Do NOT kill the PC's normal Ollama service. CypraTeam uses its own
    # localhost port and its own project-local model store.
    $spArgs = @{ FilePath = $ollamaExe; ArgumentList = "serve" }
    # -WindowStyle is Windows-only; PowerShell Core throws on macOS/Linux if it's passed.
    if ($IsWindows) { $spArgs['WindowStyle'] = 'Hidden' }
    Start-Process @spArgs

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        Start-Sleep -Milliseconds 500
        if (Test-OllamaReady) {
            $script:OllamaStartedByMatrix = $true
            if ($CpuOnly) {
                Write-Host "[+] CypraTeam Ollama ready in CPU-safe fallback mode." -ForegroundColor $Theme.WarningDim
            } else {
                Write-Host "[+] CypraTeam Ollama ready on $script:CypraOllamaHost." -ForegroundColor $Theme.Success
            }
            Write-Host "[+] Portable model store locked to: $portableStore" -ForegroundColor $Theme.Success
            return $true
        }
    }

    Write-Host "[!] CypraTeam Ollama server did not report ready within the startup window." -ForegroundColor $Theme.Error
    return $false
}

function Test-AndPullCoreModels {
    Clear-Host
    Write-Host "===================================================================" -ForegroundColor $Theme.Info
    Write-Host " STARTUP MODEL / Modelfile INTEGRITY CHECK" -ForegroundColor $Theme.Info
    Write-Host "===================================================================" -ForegroundColor $Theme.Info
    Write-Host "[i] Startup is verification-only. The Matrix will not pull or create agent models." -ForegroundColor $Theme.MutedLight
    Write-Host ""
    Write-Host "[i] Core-agent readiness is checked on demand when an agent is selected." -ForegroundColor $Theme.MutedLight
    Write-Host "[i] No individual agent model is required just to start the Matrix dashboard." -ForegroundColor $Theme.MutedLight

    $modelfiles = @()
    $modelfiles += @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Modfiles') -Filter "Modelfile_*" -File -ErrorAction SilentlyContinue)
    $modelfiles += @(Get-ChildItem -Path $PSScriptRoot -Filter "Modelfile_*" -File -ErrorAction SilentlyContinue)
    $modelfiles = @($modelfiles | Sort-Object FullName -Unique)

    Write-Host "[+] Modelfiles discovered: $($modelfiles.Count)" -ForegroundColor $Theme.Success
    Start-Sleep -Milliseconds 500
}

function Test-MatrixStoreHasModels {
    try {
        $blobs = Join-Path $defaultModelStorePath 'blobs'
        if ((Test-Path $blobs) -and (@(Get-ChildItem -LiteralPath $blobs -File -ErrorAction SilentlyContinue).Count -gt 0)) {
            return $true
        }
    } catch {}
    try {
        return (@(Get-ExistingOllamaModels).Count -gt 0)
    } catch {
        return $false
    }
}

function Invoke-MatrixFirstRun {
    if (Test-MatrixStoreHasModels) { return }

    Write-Host ""
    Write-Host "===================================================================" -ForegroundColor $Theme.Warning
    Write-Host " FIRST RUN — this portable store has no models yet" -ForegroundColor $Theme.Warning
    Write-Host "===================================================================" -ForegroundColor $Theme.Warning
    Write-Host "Copying the folder to another PC does not include weights." -ForegroundColor $Theme.MutedLight
    Write-Host "Ollama must be installed on this machine. Models stay in .\OllamaModels." -ForegroundColor $Theme.MutedLight
    Write-Host ""
    Write-Host " [1] Fleet tools — INSTALL_MODELS.bat (status, pull base, Core, or full register)" -ForegroundColor $Theme.Info
    Write-Host " [2] Core only — pull the fleet base + register cypra / anomaly / quantum / nexus-prime" -ForegroundColor $Theme.Success
    Write-Host " [3] Skip — register an agent when you pick its ID" -ForegroundColor $Theme.MutedLight
    Write-Host " [Q] Quit" -ForegroundColor $Theme.ErrorDim
    Write-Host ""
    $c = Read-Host "Select"

    switch -Regex ($c) {
        '^(?i)q$' {
            Write-Host "[*] Leaving Matrix. Run INSTALL_MODELS.bat when you are ready." -ForegroundColor $Theme.Warning
            exit 0
        }
        '^1$' {
            $bat = Join-Path $PSScriptRoot 'INSTALL_MODELS.bat'
            if (Test-Path $bat) {
                Write-Host "[*] Launching installer. Accept the default base model unless you want another." -ForegroundColor $Theme.Info
                & cmd.exe /c "`"$bat`""
                Clear-AgentModelInstalledCache
            } else {
                Write-Host "[!] INSTALL_MODELS.bat was not found next to the launcher." -ForegroundColor $Theme.Error
                Read-Host "Enter"
            }
        }
        '^2$' {
            $base = [string]$matrixConfig.DefaultBaseModel
            if ([string]::IsNullOrWhiteSpace($base)) { $base = 'huihui_ai/gemma-4-abliterated:e4b' }
            Write-Host "[*] Pulling $base ..." -ForegroundColor $Theme.Info
            & ollama pull $base
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[!] Pull failed. You can try again from models or INSTALL_MODELS.bat." -ForegroundColor $Theme.Error
                Read-Host "Enter"
                return
            }
            Clear-AgentModelInstalledCache
            foreach ($name in @('cypra','anomaly','quantum','nexus-prime')) {
                try {
                    Confirm-AndInstallAgent -ModelName $name -AutoYes | Out-Null
                } catch {
                    Write-Host "[!] $($_.Exception.Message)" -ForegroundColor $Theme.Error
                }
            }
            Write-Host "[+] Core agents ready. Others register when you pick their ID." -ForegroundColor $Theme.Success
            Read-Host "Enter"
        }
        default {
            Write-Host "[i] Dashboard will open. Pick an agent ID to register it from its Modelfile." -ForegroundColor $Theme.MutedLight
            Start-Sleep -Milliseconds 800
        }
    }
}

function Set-MatrixProfile {
    Clear-Host
    Show-CommandActivation -Command 'profile'
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host "             🔄 MATRIX PERFORMANCE PROFILE SWITCHER 🔄" -ForegroundColor $Theme.Info
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host " [1] Low-VRAM 6GB Profile (Strict 1024 context, safe overhead)" -ForegroundColor $Theme.Warning
    Write-Host " [2] Turbo / High-Context Profile (Dynamic scaling up to 4096 context)" -ForegroundColor $Theme.Info
    Write-Host " [3] CPU-Only Offline Mode (Disables GPU entirely)" -ForegroundColor $Theme.WarningDim
    Write-Host ""
    $choice = Read-Host "Select profile index (1-3)"
    $previousMaxLoaded = $env:OLLAMA_MAX_LOADED_MODELS

    switch ($choice) {
        "1" {
            $script:SelectedProfile = "Low-VRAM 6GB"
            $script:OllamaContextLength = 1024
            $env:OLLAMA_CONTEXT_LENGTH = "1024"
            $null = Start-OllamaEngine -CpuOnly $false
        }
        "2" {
            $script:SelectedProfile = "Turbo / High-Context"
            $script:OllamaContextLength = 4096
            $env:OLLAMA_CONTEXT_LENGTH = "4096"
            $null = Start-OllamaEngine -CpuOnly $false
        }
        "3" {
            $script:SelectedProfile = "CPU-Only Offline"
            $script:OllamaContextLength = 2048
            $env:OLLAMA_CONTEXT_LENGTH = "2048"
            $null = Start-OllamaEngine -CpuOnly $true
        }
        default {
            Write-Host "[!] Invalid choice, keeping current profile." -ForegroundColor $Theme.Error
            Start-Sleep -Seconds 1
        }
    }

    if ($choice -in @("1","2","3")) {
        $desiredMaxLoaded = Get-SafeMaxLoadedModels -Profile $script:SelectedProfile
        if ($previousMaxLoaded -and $desiredMaxLoaded -ne $previousMaxLoaded) {
            Write-Host ""
            Write-Host "[i] This profile's resident-model cap ($desiredMaxLoaded) differs from" -ForegroundColor $Theme.Warning
            Write-Host "    what the running Ollama server started with ($previousMaxLoaded)." -ForegroundColor $Theme.Warning
            Write-Host "    That cap is only read at server startup, so it will not change until" -ForegroundColor $Theme.Warning
            Write-Host "    you restart START_CHAT_MATRIX.bat." -ForegroundColor $Theme.Warning
            Start-Sleep -Milliseconds 1200
        }
    }
}

function Show-LiveHud {
    Clear-Host
    Show-CommandActivation -Command 'hud'
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host "             ⚙️ LIVE HARDWARE & VRAM HUD TELEMETRY ⚙️" -ForegroundColor $Theme.Info
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host " Press [Ctrl+C] or any key to exit HUD loop and return to panel." -ForegroundColor $Theme.Muted
    Write-Host ""

    $script:HeartbeatCounter = 0

    while (-not $Host.UI.RawUI.KeyAvailable) {
        $script:HeartbeatCounter++
        $beatChar = switch ($script:HeartbeatCounter % 4) {
            0 { "-" }
            1 { "\" }
            2 { "|" }
            3 { "/" }
        }

        $snap = Get-VramSnapshot
        $ollamaProc = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
        $serverProc = Get-Process -Name "ollama_llama_server" -ErrorAction SilentlyContinue
        $loaded = @(Get-OllamaLoadedModelTelemetry)

        [Console]::SetCursorPosition(0, 4)
        Write-Host ("--- SYSTEM STATUS MATRIX ------------------------------------------------") -ForegroundColor $Theme.Success
        Write-Host ("Live Heartbeat     : {0} (Tick: {1})" -f $beatChar, $script:HeartbeatCounter) -ForegroundColor $Theme.Info

        if ($snap.Available) {
            Write-Host (" GPU               : {0}  | Driver {1}" -f $snap.GpuName, $snap.Driver) -ForegroundColor $Theme.Info
            Write-Host (" VRAM              : {0} MB used / {1} MB total ({2}% used)" -f $snap.UsedMB, $snap.TotalMB, $snap.Percent) -ForegroundColor $Theme.Info
            Write-Host (" Free VRAM         : {0} MB" -f $snap.FreeMB) -ForegroundColor $Theme.Info
            Write-Host (" Temperature       : {0} °C  | GPU Utilization: {1}%" -f $snap.TemperatureC, $snap.UtilizationPct) -ForegroundColor $Theme.Warning
            if ($snap.PowerDrawW -ne $null) {
                Write-Host (" Power             : {0} W / {1} W" -f $snap.PowerDrawW, $snap.PowerLimitW) -ForegroundColor $Theme.InfoDim
            }
        } else {
            Write-Host " NVIDIA telemetry  : unavailable (CPU-only or nvidia-smi not present)" -ForegroundColor $Theme.Warning
        }

        $ollamaStatus = if ($ollamaProc) { "ONLINE (PID $($ollamaProc.Id))" } else { "OFFLINE" }
        $serverStatus = if ($serverProc) { "ACTIVE (PID $($serverProc.Id))" } else { "STANDBY" }
        Write-Host " Ollama Service    : $ollamaStatus" -ForegroundColor $Theme.Primary
        Write-Host " Llama Server      : $serverStatus" -ForegroundColor $Theme.Primary
        Write-Host " Active Profile    : $script:SelectedProfile" -ForegroundColor $Theme.Accent
        Write-Host " Context Length    : $env:OLLAMA_CONTEXT_LENGTH" -ForegroundColor $Theme.InfoDim

        if ($loaded.Count -gt 0) {
            foreach ($item in $loaded) {
                Write-Host (" Loaded Model      : {0} | size {1} MB | until {2}" -f $item.Name, $item.SizeMB, $item.Expires) -ForegroundColor $Theme.MutedLight
            }
        } else {
            Write-Host " Loaded Model      : none reported by Ollama" -ForegroundColor $Theme.Muted
        }

        Start-Sleep -Milliseconds 1000
    }

    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# --- EXTENDED SEQUENTIAL MULTI-AGENT PIPELINE ENGINE (3+ AGENTS) ---
function Invoke-AgentPipeline {
    Clear-Host
    Show-CommandActivation -Command 'pipe'
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host "             👉 EXTENDED MULTI-AGENT SEQUENTIAL PIPELINE 📥" -ForegroundColor $Theme.Info
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host " Chain multiple agent nodes sequentially (e.g., Generator -> Refactorer -> Security)" -ForegroundColor $Theme.InfoDim
    Write-Host ""

    $chainInput = Read-Host "Enter Agent IDs separated by spaces (e.g., 3 4 16)"
    $agentIds = $chainInput -split '\s+' | Where-Object { $_ -match '^\d+$' }

    if ($agentIds.Count -lt 2) {
        Write-Host "[!] You must specify at least 2 agent IDs for a pipeline." -ForegroundColor $Theme.Error
        Start-Sleep -Seconds 1.5
        return
    }

    foreach ($id in $agentIds) {
        if (-not $map.ContainsKey($id)) {
            Write-Host "[!] Invalid Agent ID in sequence: $id" -ForegroundColor $Theme.Error
            Start-Sleep -Seconds 1.5
            return
        }
    }

    if ($agentIds.Count -gt 5) {
        Write-Host "[!] Pipeline capped at 5 agents for VRAM safety." -ForegroundColor $Theme.Warning
        $agentIds = $agentIds[0..4]
    }

    $initialPrompt = Read-Host "Enter initial prompt or task for the pipeline"
    if ([string]::IsNullOrWhiteSpace($initialPrompt)) { return }

    $currentInput = $initialPrompt
    $modelSequenceNames = @()


    # Route pipeline execution log directly into active workspace if selected
    if ($global:ActiveTaskWorkspace -and (Test-Path $global:ActiveTaskWorkspace)) {
        Set-Location -Path $global:ActiveTaskWorkspace
        $logDir = $global:ActiveTaskWorkspace
        Write-Host "[i] Executing pipeline within Active Workspace: $global:ActiveTaskWorkspace" -ForegroundColor $Theme.Info
    } else {
        $logDir = Join-Path $PSScriptRoot "Logs"
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Write-Host "[!] No active task loaded. Executing in default directory." -ForegroundColor $Theme.Warning
    }

    $pipelineLogName = "pipeline_chain_" + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + ".log"
    $pipelineLogPath = Join-Path $logDir $pipelineLogName

    "PIPELINE INITIATED: $initialPrompt" | Out-File -FilePath $pipelineLogPath -Encoding utf8

    $stepCounter = 1
    foreach ($id in $agentIds) {
        $modelName = $map[$id]
        $modelSequenceNames += "$id($modelName)"

        Write-Host "`n[*] [$stepCounter/$($agentIds.Count)] Running Agent $id ($modelName)..." -ForegroundColor $Theme.Warning
        Get-AgentBaseModel -ModelName $modelName | Out-Null
        $modeModel = $modelName

        if ($stepCounter -gt 1) {
            $promptPayload = "Take the following analytical context produced by preceding stages, refine it according to your precise system specialty, and continue/finalize the output:`n`n$currentInput"
        } else {
            $promptPayload = $currentInput
        }

        $currentInput = Invoke-OllamaRun -Model $modelName -Prompt $promptPayload
        Write-Host "[+] Agent $modelName finished stage execution." -ForegroundColor $Theme.Success

        "--- STAGE $stepCounter : AGENT $modelName ---" | Out-File -FilePath $pipelineLogPath -Append -Encoding utf8
        $currentInput | Out-File -FilePath $pipelineLogPath -Append -Encoding utf8

        $stepCounter++
    }

    Clear-Host
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host "                📊 CHAINED PIPELINE EXECUTION RESULTS 📝" -ForegroundColor $Theme.Info
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host "Pipeline Path: $($modelSequenceNames -join ' -> ')" -ForegroundColor $Theme.Warning
    Write-Host "-------------------------------------------------------------------" -ForegroundColor $Theme.Muted
    $currentInput | Out-Host

    Write-Host "`n[i] Full transcript saved to: $pipelineLogPath" -ForegroundColor $Theme.InfoDim
    Write-Host ""
    Read-Host "Press Enter to return to Dashboard"
}

# --- 4-MODEL PARALLEL CONSENSUS & SYNTHESIS ENGINE (QUAD) ---
function Invoke-ConsensusPipeline {
    Clear-Host
    Show-CommandActivation -Command 'quad'
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host "             🧠 N-MODEL INDEPENDENT CONSENSUS MATRIX 🧠" -ForegroundColor $Theme.Info
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host " Queries independent specialists on the exact same task, then lets" -ForegroundColor $Theme.InfoDim
    Write-Host " NEXUS-PRIME reconcile the strongest reasoning into one solution." -ForegroundColor $Theme.InfoDim
    Write-Host ""

    $problemPrompt = Read-Host "Enter the problem or task for the QUAD"
    if ([string]::IsNullOrWhiteSpace($problemPrompt)) { return }

    $chainInput = Read-Host "Enter Agent IDs separated by spaces [Leave blank: NEXUS-PRIME auto-selects the 4 best agents]"
    if ([string]::IsNullOrWhiteSpace($chainInput)) {
        $agentIds = @(Invoke-NexusAgentSelection -TaskPrompt $problemPrompt -Count 4 -ExcludeIds (Get-NexusDefaultExcludedIds))
        if ($agentIds.Count -ne 4) {
            Write-Host "[!] NEXUS-PRIME could not produce four valid selections." -ForegroundColor $Theme.Error
            Start-Sleep -Seconds 1.5
            return
        }
        Write-Host ""
        Write-Host "AUTO-SELECTED QUAD:" -ForegroundColor $Theme.Warning
        foreach ($id in $agentIds) {
            $entry = $script:AgentRegistry[[string]$id]
            Write-Host ("  {0,3}  {1,-22}  {2}" -f $id, $entry.name, $entry.group) -ForegroundColor $entry.color
        }
    } else {
        $agentIds = @($chainInput -split '\s+' | Where-Object { $_ -match '^\d+$' })
    }

    if ($agentIds.Count -lt 2) {
        Write-Host "[!] Consensus requires at least 2 agent IDs." -ForegroundColor $Theme.Error
        Start-Sleep -Seconds 1.5
        return
    }

    if ($agentIds.Count -gt 12) {
        Write-Host "[!] Capped at 12 agents for VRAM safety." -ForegroundColor $Theme.Warning
        $agentIds = $agentIds[0..11]
    }

    foreach ($id in $agentIds) {
        if (-not $map.ContainsKey($id)) {
            Write-Host "[!] Invalid Agent ID in selection: $id" -ForegroundColor $Theme.Error
            Start-Sleep -Seconds 1.5
            return
        }
    }

    $agentCount = $agentIds.Count

    if ($global:ActiveTaskWorkspace -and (Test-Path $global:ActiveTaskWorkspace)) {
        Set-Location -Path $global:ActiveTaskWorkspace
        $logDir = $global:ActiveTaskWorkspace
    } else {
        $logDir = Join-Path $PSScriptRoot "Logs"
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    }

    $consensusLogName = "consensus_n_" + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') + ".log"
    $consensusLogPath = Join-Path $logDir $consensusLogName
    "$agentCount-MODEL CONSENSUS PROBLEM: $problemPrompt" | Out-File -FilePath $consensusLogPath -Encoding utf8

    $individualOutputs = @{}
    $step = 1

    foreach ($id in $agentIds) {
        $modelName = $map[$id]
        Write-Host "`n[*] [$step/$agentCount] Querying Agent $id ($modelName)..." -ForegroundColor $Theme.Warning
        Get-AgentBaseModel -ModelName $modelName | Out-Null
        $null = Invoke-VramAwareScheduler -ModelName $modelName
        $modeModel = $modelName

        # Ground the raw problem in an explicit on-topic/no-fabrication
        # instruction before sending it to the specialist. Sending the bare
        # task text lets small local models drift into unrelated fictional
        # framing, especially when the agent's own name/persona invites it.
        $modePrompt = @"
Answer the following task directly and literally, from your specialty.
Do not invent a fictional scenario, story, or code that was not asked for.
If the task involves physical safety, lead with the relevant safety caveat.
If you are not confident or it is outside your specialty, say so plainly.

TASK:
$problemPrompt
"@

        $output = Invoke-OllamaRun -Model $modelName -Prompt $modePrompt
        $individualOutputs[$id] = $output
        Write-Host "[+] Agent $id ($modelName) complete." -ForegroundColor $Theme.Success

        "=== RESPONSE FROM AGENT $id ($modelName) ===" | Out-File -FilePath $consensusLogPath -Append -Encoding utf8
        $output | Out-File -FilePath $consensusLogPath -Append -Encoding utf8

        $step++
    }

    Write-Host "`n[*] NEXUS-PRIME is synthesizing the four-way consensus..." -ForegroundColor $Theme.Info
    $synthesizerModel = $map["53"]
    Get-AgentBaseModel -ModelName $synthesizerModel | Out-Null
    $null = Invoke-VramAwareScheduler -ModelName $synthesizerModel
    $synthesizerModeModel = $synthesizerModel

    $outputsBlock = ""
    for ($i = 0; $i -lt $agentIds.Count; $i++) {
        $aid = $agentIds[$i]
        $outputsBlock += "--- AGENT $($i + 1) / NODE $aid ($($map[$aid])) ---`n" + $individualOutputs[$aid] + "`n`n"
    }

    $synthesisPrompt = @"
You are NEXUS-PRIME, the Master Consensus Integrator. $agentCount independent
specialized agents were each given the exact same task and answered it
separately, with no visibility into each other's responses.

TASK:
$problemPrompt

INDEPENDENT RESPONSES:
$outputsBlock

Do the following, in order, using these exact section headers:

FINAL ANSWER:
Critically compare every response and produce one practical, directly usable
answer to the task above. Prefer technically defensible reasoning over
confident-sounding but unsupported claims. If a response drifted into
content that is fictional, off-topic, or unrelated to the actual task,
discard it entirely rather than blending it in. Use numbered steps for
how-to/procedural tasks, and lead with safety warnings if relevant.

WHY THIS ANSWER:
In 2-5 sentences, explain which response(s) the final answer relied on most
and why, and name any response you discarded along with the reason.

CONFIDENCE & OPEN QUESTIONS:
State your confidence (Low/Medium/High) and list anything that remains
uncertain or that the user should verify independently.
"@

    # Honor the VRAM-safe context as a hard ceiling - never raise it to fit
    # the prompt. On tight-VRAM systems, forcing a larger context than the
    # hardware can safely handle crashes ollama outright (exit 1, no output)
    # instead of returning a normal answer. Trim the prompt instead.
    $synthDynParams = Get-DynamicModelParameters -ModelName $synthesizerModel
    $synthSafeCtx = [int]$synthDynParams.ContextLength
    $env:OLLAMA_CONTEXT_LENGTH = [string]$synthSafeCtx
    $synthMaxChars = [Math]::Max(500, ($synthSafeCtx - 512) * 3.5)
    $synthPayload = $synthesisPrompt
    if (([string]$synthPayload).Length -gt $synthMaxChars) {
        $synthPayload = ([string]$synthPayload).Substring(0, [int]$synthMaxChars)
        Write-Host "[!] Synthesis prompt trimmed to fit the VRAM-safe context ($synthSafeCtx tokens) for '$synthesizerModel'." -ForegroundColor $Theme.Warning
    }

    $finalSolution = Invoke-OllamaRun -Model $synthesizerModel -Prompt $synthPayload -CaptureStderr
    $synthExitCode = $LASTEXITCODE
    $finalSolution = ($finalSolution -join "`n")

    "=== FINAL SYNTHESIZED MASTER SOLUTION ===" | Out-File -FilePath $consensusLogPath -Append -Encoding utf8
    $finalSolution | Out-File -FilePath $consensusLogPath -Append -Encoding utf8

    Clear-Host
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host "           🏆 $agentCount-MODEL CONSENSUS SYNTHESIS SOLUTION 🏆" -ForegroundColor $Theme.Info
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host "Participating Nodes: $($agentIds -join ', ')" -ForegroundColor $Theme.Warning
    Write-Host "-------------------------------------------------------------------" -ForegroundColor $Theme.Muted

    if ([string]::IsNullOrWhiteSpace($finalSolution)) {
        Write-Host "[!] NEXUS-PRIME returned no synthesis output (exit code $synthExitCode)." -ForegroundColor $Theme.Error
        Write-Host "[i] Individual agent transcripts are still saved below - check those directly." -ForegroundColor $Theme.InfoDim
    } else {
        $finalSolution | Out-Host
    }

    Write-Host "`n[i] Full individual transcripts & synthesis saved to: $consensusLogPath" -ForegroundColor $Theme.InfoDim
    Write-Host ""
    Read-Host "Press Enter to return to Dashboard"
}

# --- ADVERSARIAL 4-AGENT DEBATE + NEXUS JUDGE ORCHESTRATION ---
function Invoke-NexusTwoAgentDebate {
    param([string]$TaskPrompt)

    Clear-Host
    Show-CommandActivation -Command 'debate'
    Write-Host 'NEXUS TWO-AGENT DEBATE' -ForegroundColor $Theme.Info
    Write-Host '===================================================================' -ForegroundColor $Theme.Info
    Write-Host 'Two specialists debate. NEXUS-PRIME is the sole final judge.' -ForegroundColor $Theme.MutedLight
    Write-Host ''

    if ([string]::IsNullOrWhiteSpace($TaskPrompt)) {
        $TaskPrompt = Read-Host 'Task'
    }
    if ([string]::IsNullOrWhiteSpace($TaskPrompt)) { return }

    $chainInput = Read-Host 'Enter Agent IDs separated by spaces [Leave blank: NEXUS-PRIME auto-selects 2 best agents]'
    if ([string]::IsNullOrWhiteSpace($chainInput)) {
        $ids = @(
            Invoke-NexusAgentSelection -TaskPrompt $TaskPrompt -Count 2 -ExcludeIds (Get-NexusDefaultExcludedIds) |
            ForEach-Object { [string]$_ } |
            Select-Object -Unique |
            Select-Object -First 2
        )
        if ($ids.Count -ne 2) {
            Write-Host '[!] Nexus could not select exactly two debate agents.' -ForegroundColor $Theme.Error
            Read-Host 'Enter'
            return
        }
        Write-Host ''
        Write-Host 'AUTO-SELECTED DEBATE PAIR:' -ForegroundColor $Theme.Warning
        foreach ($id in $ids) {
            $entry = $script:AgentRegistry[[string]$id]
            Write-Host ("  {0,3}  {1,-22}  {2}" -f $id, $entry.name, $entry.group) -ForegroundColor $entry.color
        }
    } else {
        $ids = @($chainInput -split '\s+' | Where-Object { $_ -match '^\d+$' } | Select-Object -Unique -First 2)
        if ($ids.Count -ne 2) {
            Write-Host '[!] Debate requires exactly two valid agent IDs.' -ForegroundColor $Theme.Error
            Read-Host 'Enter'
            return
        }
        foreach ($id in $ids) {
            if (-not $script:AgentRegistry.Contains([string]$id)) {
                Write-Host "[!] Invalid Agent ID: $id" -ForegroundColor $Theme.Error
                Read-Host 'Enter'
                return
            }
        }
    }

    $agents = @()
    foreach ($id in $ids) {
        $e = $script:AgentRegistry[[string]$id]
        if ($null -eq $e) { continue }
        $agents += [pscustomobject]@{
            ID = [string]$id
            Name = [string]$e.name
            Group = [string]$e.group
            Model = [string]$e.model
            Color = [string]$e.color
        }
    }

    if ($agents.Count -ne 2) {
        Write-Host '[!] One or more selected debate agents are unavailable.' -ForegroundColor $Theme.Error
        Read-Host 'Enter'
        return
    }

    Write-Host 'DEBATE PAIR' -ForegroundColor $Theme.Success
    foreach ($a in $agents) {
        $c = if ([string]::IsNullOrWhiteSpace($a.Color)) { [string]$Theme.Info } else { $a.Color }
        Write-Host ("  {0,3}  {1,-30} [{2}]" -f $a.ID,$a.Name,$a.Group) -ForegroundColor $c
    }

    $reports = @()

    for ($round = 1; $round -le 2; $round++) {
        foreach ($a in $agents) {
            $other = $agents | Where-Object { $_.ID -ne $a.ID } | Select-Object -First 1

            if ($round -eq 1) {
                $debateInstruction = @"
This is Round 1 of a two-specialist debate.

Analyze the task independently from your specialist perspective.
State your position, strongest evidence/reasoning, and recommended answer.
Do not defer to the other specialist because you have not seen their argument yet.
"@
            } else {
                $prior = ($reports | Where-Object { $_.Round -eq 1 -and $_.ID -eq $other.ID } | Select-Object -First 1).Output
                $debateInstruction = @"
This is Round 2 of a two-specialist debate.

The other specialist's Round 1 argument is below:

--- OTHER SPECIALIST ---
$prior
--- END OTHER SPECIALIST ---

Critically evaluate that argument.
Identify what is correct, incorrect, unsupported, or missing.
Defend your own position where appropriate and revise it where the evidence warrants.
End with your strongest recommendation to NEXUS-PRIME.
"@
            }

            $prompt = @"
You are one of exactly TWO debate specialists.

YOUR IDENTITY:
Agent ID: $($a.ID)
Specialist: $($a.Name)
Domain: $($a.Group)

ORIGINAL TASK:
$TaskPrompt

$debateInstruction

Rules:
- This is an adversarial expert review, not a group chat.
- Do not invent tests, sources, or actions.
- Clearly distinguish evidence from assumptions.
- Be concise but technically substantive.
"@

            Write-Host ''
            Write-Host ("Round {0} - {1} [{2}]" -f $round,$a.Name,$a.Group) -ForegroundColor $Theme.Warning

            try {
                $result = Invoke-InstalledAgentQuery -ModelName $a.Model -Prompt $prompt -TrackLearning
                $output = [string]$result.Output
                if ([string]::IsNullOrWhiteSpace($output)) {
                    $output = "[NO USABLE RESPONSE: exit code $($result.ExitCode)]"
                    Write-Host '[!] No usable response.' -ForegroundColor $Theme.Error
                } else {
                    Write-Host '[+] Argument received.' -ForegroundColor $Theme.Success
                    $output | Out-Host
                }
            } catch {
                $output = "[SPECIALIST FAILURE] $($_.Exception.Message)"
                Write-Host $output -ForegroundColor $Theme.Error
            }

            $reports += [pscustomobject]@{
                Round = $round
                ID = $a.ID
                Name = $a.Name
                Group = $a.Group
                Model = $a.Model
                Output = $output
            }
        }
    }

    Write-Host ''
    Write-Host '===================================================================' -ForegroundColor $Theme.Info
    Write-Host 'NEXUS-PRIME: FINAL DEBATE JUDGMENT' -ForegroundColor $Theme.Success
    Write-Host '===================================================================' -ForegroundColor $Theme.Info

    $debateTranscript = foreach ($r in $reports) {
        @"
--- ROUND $($r.Round) | $($r.ID) $($r.Name) [$($r.Group)] ---
$($r.Output)
"@
    }

    $judgePrompt = @"
You are NEXUS-PRIME and are the SOLE FINAL JUDGE of a two-agent expert debate.

ORIGINAL TASK:
$TaskPrompt

DEBATE TRANSCRIPT:
$($debateTranscript -join "`n`n")

JUDGING RULES:
1. There were exactly two debating specialists. Do not introduce a third specialist opinion.
2. Compare their reasoning, evidence, technical correctness, and handling of uncertainty.
3. Do not decide by majority vote; there are only two debaters.
4. Reject unsupported claims even if confidently stated.
5. Resolve disagreements explicitly.
6. You are the final authority for the synthesized answer.
7. Do not claim to have independently performed tests or research.
8. If neither side establishes the answer, state the uncertainty and give the safest next step.

Return:
WINNING POSITION:
WHY IT WINS:
POINTS REJECTED OR CORRECTED:
FINAL ANSWER:
RECOMMENDED NEXT STEPS:
"@

    try {
        # IMPORTANT: Nexus Prime is the only judge. It is not counted as a
        # third debate participant.
        $judge = Invoke-InstalledAgentQuery -ModelName 'nexus-prime' -Prompt $judgePrompt -TrackLearning
        $final = [string]$judge.Output

        if ([string]::IsNullOrWhiteSpace($final)) {
            Write-Host '[!] Nexus-Prime judgment returned no usable response.' -ForegroundColor $Theme.Error
        } else {
            Write-Host ''
            Write-Host 'FINAL NEXUS-PRIME JUDGMENT' -ForegroundColor $Theme.Success
            Write-Host '-------------------------------------------------------------------' -ForegroundColor $Theme.Muted
            $final | Out-Host

            Save-AgentRunOutcome -ModelName 'nexus-prime' `
                -UserPrompt $TaskPrompt `
                -Response $final `
                -Source 'nexus-debate' `
                -KnowledgePrompt ("Nexus two-agent debate:`n" + $TaskPrompt)
        }
    } catch {
        Write-Host "[!] Nexus-Prime judgment error: $($_.Exception.Message)" -ForegroundColor $Theme.Error
    }

    Read-Host 'Enter'
}


function Get-DynamicModelParameters {
    param([string]$ModelName)

    $ctx = [int]$env:OLLAMA_CONTEXT_LENGTH
    $parallel = 1

    try {
        $snap = Get-VramSnapshot
        if ($snap.Available) {
            $freeMB = [int]$snap.FreeMB

            $turboCap = 4096
            $cpuCap = 2048
            $lowCap = 1024
            try { if ([int]$matrixConfig.TurboMaxContext -gt 0) { $turboCap = [int]$matrixConfig.TurboMaxContext } } catch {}
            try { if ([int]$matrixConfig.CpuContext -gt 0) { $cpuCap = [int]$matrixConfig.CpuContext } } catch {}
            try { if ([int]$matrixConfig.DefaultContext -gt 0) { $lowCap = [int]$matrixConfig.DefaultContext } } catch {}

            switch ($script:SelectedProfile) {
                "Turbo / High-Context" {
                    if ($freeMB -ge 4096) {
                        $ctx = $turboCap
                    } elseif ($freeMB -ge 2560) {
                        $ctx = [Math]::Min(2048, $turboCap)
                    } else {
                        $ctx = [Math]::Min($ctx, 1536)
                    }
                }
                "CPU-Only Offline" {
                    $ctx = [Math]::Min($cpuCap, [Math]::Max($ctx, 1024))
                }
                "Balanced" {
                    if ($freeMB -ge 3072) {
                        $ctx = [Math]::Min([Math]::Max($ctx, 2048), $turboCap)
                    } elseif ($freeMB -lt 1536) {
                        $ctx = [Math]::Min($ctx, $lowCap)
                    }
                }
                default {
                    $ctx = [Math]::Min($ctx, $lowCap)
                }
            }

            Write-Host ("[*] VRAM-aware context for {0}: {1} MB free on {2} | context {3}" -f `
                $ModelName, $snap.FreeMB, $snap.GpuName, $ctx) -ForegroundColor $Theme.InfoDim
        }
    } catch {}

    return @{
        ContextLength = $ctx
        NumParallel   = $parallel
    }
}

function Save-ThemeConfig {
    try {
        $payload = [ordered]@{}
        foreach ($k in $Theme.Keys) { $payload[$k] = $Theme[$k] }
        $payload["Emoji"] = $script:ThemeEmoji
        # Dashboard layout rides along in the same file/payload as the color
        # theme and emoji - one save mechanism for every "how the UI looks"
        # setting, whether it was changed via 'theme' or via 'layout'.
        $payload["DashboardLayout"] = $script:DashboardLayout
        $payload | ConvertTo-Json -Depth 3 | Set-Content -Path $themeConfigFilePath -Encoding utf8
    } catch {
        Write-Host "[!] Could not persist theme changes to ThemeConfig.json: $($_.Exception.Message)" -ForegroundColor $Theme.Warning
    }
}

# Preinstalled color presets for the theme editor. Each is a full palette
# covering every $Theme key, applied all at once via [T] in Show-ThemeEditor.
# "Default" simply points at the original built-in palette captured earlier
# as $script:DefaultTheme.
$script:ThemePresets = [ordered]@{
    "Default" = $script:DefaultTheme
    "Matrix Green" = [ordered]@{
        Brand="Green"; BrandDim="DarkGreen"; Info="Green"; InfoDim="DarkGreen"
        Info2="Cyan"; Info2Dim="DarkCyan"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Cyan"; AccentDim="DarkCyan"; Muted="DarkGreen"; MutedLight="Green"
        Primary="Green"; DashPrimary="Green"; DashDim="DarkGreen"; DashText="Green"; DashMuted="DarkGreen"
    }
    "Cyberpunk Neon" = [ordered]@{
        Brand="Magenta"; BrandDim="DarkMagenta"; Info="Cyan"; InfoDim="DarkCyan"
        Info2="Blue"; Info2Dim="DarkBlue"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Magenta"; AccentDim="DarkMagenta"; Muted="DarkMagenta"; MutedLight="Magenta"
        Primary="White"; DashPrimary="Magenta"; DashDim="DarkMagenta"; DashText="White"; DashMuted="Cyan"
    }
    "Amber Terminal" = [ordered]@{
        Brand="Yellow"; BrandDim="DarkYellow"; Info="Yellow"; InfoDim="DarkYellow"
        Info2="DarkYellow"; Info2Dim="DarkYellow"; Success="Yellow"; SuccessDim="DarkYellow"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Yellow"; AccentDim="DarkYellow"; Muted="DarkYellow"; MutedLight="Yellow"
        Primary="Yellow"; DashPrimary="Yellow"; DashDim="DarkYellow"; DashText="Yellow"; DashMuted="DarkYellow"
    }
    "Ocean Blue" = [ordered]@{
        Brand="Cyan"; BrandDim="DarkCyan"; Info="Blue"; InfoDim="DarkBlue"
        Info2="Cyan"; Info2Dim="DarkCyan"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Cyan"; AccentDim="DarkCyan"; Muted="DarkBlue"; MutedLight="Blue"
        Primary="White"; DashPrimary="Blue"; DashDim="DarkBlue"; DashText="White"; DashMuted="Cyan"
    }
    "Monochrome" = [ordered]@{
        Brand="White"; BrandDim="Gray"; Info="White"; InfoDim="Gray"
        Info2="White"; Info2Dim="Gray"; Success="White"; SuccessDim="Gray"
        Warning="White"; WarningDim="Gray"; Error="White"; ErrorDim="DarkGray"
        Accent="White"; AccentDim="Gray"; Muted="DarkGray"; MutedLight="Gray"
        Primary="White"; DashPrimary="White"; DashDim="Gray"; DashText="White"; DashMuted="DarkGray"
    }
    "Hot Magenta" = [ordered]@{
        Brand="Magenta"; BrandDim="DarkMagenta"; Info="Magenta"; InfoDim="DarkMagenta"
        Info2="Cyan"; Info2Dim="DarkCyan"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Cyan"; AccentDim="DarkCyan"; Muted="DarkMagenta"; MutedLight="Magenta"
        Primary="White"; DashPrimary="Magenta"; DashDim="DarkMagenta"; DashText="White"; DashMuted="Magenta"
    }
    "Electric Violet" = [ordered]@{
        Brand="Magenta"; BrandDim="DarkMagenta"; Info="Blue"; InfoDim="DarkBlue"
        Info2="Cyan"; Info2Dim="DarkCyan"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Magenta"; AccentDim="DarkMagenta"; Muted="DarkBlue"; MutedLight="Blue"
        Primary="White"; DashPrimary="Blue"; DashDim="DarkBlue"; DashText="White"; DashMuted="Magenta"
    }
    "Plasma Red" = [ordered]@{
        Brand="Red"; BrandDim="DarkRed"; Info="Red"; InfoDim="DarkRed"
        Info2="Yellow"; Info2Dim="DarkYellow"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Magenta"; AccentDim="DarkMagenta"; Muted="DarkRed"; MutedLight="Red"
        Primary="White"; DashPrimary="Red"; DashDim="DarkRed"; DashText="White"; DashMuted="Yellow"
    }
    "Toxic Lime" = [ordered]@{
        Brand="Green"; BrandDim="DarkGreen"; Info="Green"; InfoDim="DarkGreen"
        Info2="Yellow"; Info2Dim="DarkYellow"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Cyan"; AccentDim="DarkCyan"; Muted="DarkGreen"; MutedLight="Green"
        Primary="White"; DashPrimary="Green"; DashDim="DarkGreen"; DashText="White"; DashMuted="Yellow"
    }
    "Arctic Cyan" = [ordered]@{
        Brand="Cyan"; BrandDim="DarkCyan"; Info="Cyan"; InfoDim="DarkCyan"
        Info2="White"; Info2Dim="Gray"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Blue"; AccentDim="DarkBlue"; Muted="DarkCyan"; MutedLight="Cyan"
        Primary="White"; DashPrimary="Cyan"; DashDim="DarkCyan"; DashText="White"; DashMuted="Cyan"
    }
    "Sunset Blaze" = [ordered]@{
        Brand="Red"; BrandDim="DarkRed"; Info="Yellow"; InfoDim="DarkYellow"
        Info2="Magenta"; Info2Dim="DarkMagenta"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Magenta"; AccentDim="DarkMagenta"; Muted="DarkYellow"; MutedLight="Yellow"
        Primary="White"; DashPrimary="Yellow"; DashDim="DarkYellow"; DashText="White"; DashMuted="Red"
    }
    "Royal Purple" = [ordered]@{
        Brand="Magenta"; BrandDim="DarkMagenta"; Info="Blue"; InfoDim="DarkBlue"
        Info2="Magenta"; Info2Dim="DarkMagenta"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Cyan"; AccentDim="DarkCyan"; Muted="DarkMagenta"; MutedLight="Magenta"
        Primary="White"; DashPrimary="Magenta"; DashDim="DarkMagenta"; DashText="White"; DashMuted="Blue"
    }

    "Neon Noir" = [ordered]@{
        Brand="Cyan"; BrandDim="DarkCyan"; Info="Magenta"; InfoDim="DarkMagenta"
        Info2="Green"; Info2Dim="DarkGreen"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Cyan"; AccentDim="DarkCyan"; Muted="DarkGray"; MutedLight="Gray"
        Primary="White"; DashPrimary="Cyan"; DashDim="DarkCyan"; DashText="White"; DashMuted="Magenta"
    }
    "Crimson Pulse" = [ordered]@{
        Brand="Red"; BrandDim="DarkRed"; Info="Red"; InfoDim="DarkRed"
        Info2="Magenta"; Info2Dim="DarkMagenta"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Yellow"; AccentDim="DarkYellow"; Muted="DarkRed"; MutedLight="Red"
        Primary="White"; DashPrimary="Red"; DashDim="DarkRed"; DashText="White"; DashMuted="Yellow"
    }
    "Icefire" = [ordered]@{
        Brand="Cyan"; BrandDim="DarkCyan"; Info="Blue"; InfoDim="DarkBlue"
        Info2="Red"; Info2Dim="DarkRed"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Magenta"; AccentDim="DarkMagenta"; Muted="DarkBlue"; MutedLight="Cyan"
        Primary="White"; DashPrimary="Blue"; DashDim="DarkBlue"; DashText="White"; DashMuted="Cyan"
    }
    "Gold Rush" = [ordered]@{
        Brand="Yellow"; BrandDim="DarkYellow"; Info="Yellow"; InfoDim="DarkYellow"
        Info2="White"; Info2Dim="Gray"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Yellow"; AccentDim="DarkYellow"; Muted="DarkYellow"; MutedLight="Yellow"
        Primary="White"; DashPrimary="Yellow"; DashDim="DarkYellow"; DashText="White"; DashMuted="Yellow"
    }
    "Synthwave" = [ordered]@{
        Brand="Magenta"; BrandDim="DarkMagenta"; Info="Cyan"; InfoDim="DarkCyan"
        Info2="Blue"; Info2Dim="DarkBlue"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Magenta"; AccentDim="DarkMagenta"; Muted="DarkMagenta"; MutedLight="Magenta"
        Primary="White"; DashPrimary="Magenta"; DashDim="DarkMagenta"; DashText="Cyan"; DashMuted="Blue"
    }

    "Void Reactor" = [ordered]@{
        Brand="DarkCyan"; BrandDim="DarkBlue"; Info="Cyan"; InfoDim="Blue"
        Info2="Magenta"; Info2Dim="DarkMagenta"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Magenta"; AccentDim="DarkMagenta"; Muted="DarkBlue"; MutedLight="Cyan"
        Primary="White"; DashPrimary="Cyan"; DashDim="DarkBlue"; DashText="White"; DashMuted="Magenta"
    }
    "Radioactive Core" = [ordered]@{
        Brand="Green"; BrandDim="DarkGreen"; Info="Yellow"; InfoDim="Green"
        Info2="Cyan"; Info2Dim="DarkCyan"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Yellow"; AccentDim="Green"; Muted="DarkGreen"; MutedLight="Yellow"
        Primary="White"; DashPrimary="Green"; DashDim="DarkGreen"; DashText="Yellow"; DashMuted="Green"
    }
    "Blood Moon" = [ordered]@{
        Brand="Red"; BrandDim="DarkRed"; Info="Magenta"; InfoDim="DarkMagenta"
        Info2="Yellow"; Info2Dim="DarkYellow"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Magenta"; AccentDim="DarkMagenta"; Muted="DarkRed"; MutedLight="Red"
        Primary="White"; DashPrimary="Red"; DashDim="DarkRed"; DashText="Yellow"; DashMuted="Magenta"
    }
    "Digital Carnival" = [ordered]@{
        Brand="Magenta"; BrandDim="DarkMagenta"; Info="Yellow"; InfoDim="DarkYellow"
        Info2="Cyan"; Info2Dim="DarkCyan"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="Blue"; AccentDim="DarkBlue"; Muted="DarkMagenta"; MutedLight="Cyan"
        Primary="White"; DashPrimary="Magenta"; DashDim="Blue"; DashText="Yellow"; DashMuted="Cyan"
    }
    "Solar Flare" = [ordered]@{
        Brand="Yellow"; BrandDim="DarkYellow"; Info="Red"; InfoDim="DarkRed"
        Info2="Magenta"; Info2Dim="DarkMagenta"; Success="Green"; SuccessDim="DarkGreen"
        Warning="Yellow"; WarningDim="DarkYellow"; Error="Red"; ErrorDim="DarkRed"
        Accent="White"; AccentDim="Gray"; Muted="DarkRed"; MutedLight="Yellow"
        Primary="White"; DashPrimary="Yellow"; DashDim="Red"; DashText="White"; DashMuted="Magenta"
    }

}

# One emoji per preset above, applied to $script:ThemeEmoji (and so to the
# Show-Dashboard brand header) whenever that preset is selected in [T]. Kept
# as its own table rather than a key inside $script:ThemePresets so the
# color-apply loop in Show-ThemeEditor (which only touches keys that already
# exist in $Theme) never has to special-case a non-color entry.
$script:ThemePresetEmojis = [ordered]@{
    "Default"          = "🚀"
    "Matrix Green"     = "🟢"
    "Cyberpunk Neon"   = "🌆"
    "Amber Terminal"   = "🟠"
    "Ocean Blue"       = "🌊"
    "Monochrome"       = "⬜"
    "Hot Magenta"      = "💗"
    "Electric Violet"  = "⚡"
    "Plasma Red"       = "🔴"
    "Toxic Lime"       = "☢️"
    "Arctic Cyan"      = "❄️"
    "Sunset Blaze"     = "🌅"
    "Royal Purple"     = "👑"
    "Neon Noir"        = "🌃"
    "Crimson Pulse"    = "🩸"
    "Icefire"          = "🧊"
    "Gold Rush"        = "🪙"
    "Synthwave"        = "🌴"
    "Void Reactor"     = "🌌"
    "Radioactive Core" = "☣️"
    "Blood Moon"       = "🌕"
    "Digital Carnival" = "🎪"
    "Solar Flare"      = "☀️"
}

# Interactive color customizer. Lets the person re-skin every UI color used
# throughout the program (dashboard, panels, agent headers, status text) by
# editing $Theme directly - since $Theme is a hashtable passed by reference,
# every function that reads $Theme.SomeKey sees the change immediately, live,
# with no restart required. Changes are only written to ThemeConfig.json (and
# so survive a restart) when the person chooses Save.
function Show-ThemeEditor {
    $validColors = [System.Enum]::GetNames([System.ConsoleColor])

    while ($true) {
        Clear-Host
    Show-CommandActivation -Command 'theme'
        Write-Host "===================================================================>" -ForegroundColor $Theme.Info
        Write-Host "             🎨 MATRIX COLOR & THEME EDITOR 🎨" -ForegroundColor $Theme.Info
        Write-Host "===================================================================>" -ForegroundColor $Theme.Info
        Write-Host ""
        Write-Host " Changes apply live as you make them. Nothing is written to disk" -ForegroundColor $Theme.MutedLight
        Write-Host " until you choose Save, so it's safe to experiment." -ForegroundColor $Theme.MutedLight
        Write-Host " Current theme emoji: $($script:ThemeEmoji)  (set automatically by [T] presets)" -ForegroundColor $Theme.MutedLight
        Write-Host ""

        $keys = @($Theme.Keys)
        $i = 0
        foreach ($key in $keys) {
            $i++
            Write-Host ("  [{0,2}] " -f $i) -NoNewline -ForegroundColor $Theme.MutedLight
            Write-Host ("{0,-14}" -f $key) -NoNewline -ForegroundColor $Theme.Primary
            Write-Host " ■■■ " -NoNewline -ForegroundColor $Theme[$key]
            Write-Host ("{0}" -f $Theme[$key]) -ForegroundColor $Theme.MutedLight
        }

        Write-Host ""
        Write-Host "  [T] Apply a preinstalled preset" -ForegroundColor $Theme.Accent
        Write-Host "  [P] Preview all colors on sample text" -ForegroundColor $Theme.Info
        Write-Host "  [R] Reset every color to defaults" -ForegroundColor $Theme.WarningDim
        Write-Host "  [S] Save & Return to Dashboard" -ForegroundColor $Theme.Success
        Write-Host "  [0] Return without saving changes" -ForegroundColor $Theme.MutedLight
        Write-Host ""
        $choice = (Read-Host "Select a color to edit (number), or a letter option").Trim()

        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $keys.Count) {
            $targetKey = $keys[[int]$choice - 1]
            Clear-Host
            Write-Host "Editing: $targetKey (current: $($Theme[$targetKey]))" -ForegroundColor $Theme.Info
            Write-Host ""
            $cols = 4
            for ($c = 0; $c -lt $validColors.Count; $c++) {
                Write-Host ("  [{0,2}] " -f ($c + 1)) -NoNewline -ForegroundColor $Theme.MutedLight
                Write-Host ("{0,-14}" -f $validColors[$c]) -NoNewline -ForegroundColor $validColors[$c]
                if (($c + 1) % $cols -eq 0) { Write-Host "" }
            }
            if ($validColors.Count % $cols -ne 0) { Write-Host "" }
            Write-Host ""
            $colorChoice = (Read-Host "Pick a color by number, or type a ConsoleColor name (Enter to cancel)").Trim()

            $newColor = $null
            if ($colorChoice -match '^\d+$' -and [int]$colorChoice -ge 1 -and [int]$colorChoice -le $validColors.Count) {
                $newColor = $validColors[[int]$colorChoice - 1]
            } elseif ($validColors -contains $colorChoice) {
                $newColor = $colorChoice
            } elseif (-not [string]::IsNullOrWhiteSpace($colorChoice)) {
                Write-Host "[!] Not a valid color name." -ForegroundColor $Theme.Error
                Start-Sleep -Seconds 1
            }

            if ($newColor) {
                $Theme[$targetKey] = $newColor
                Write-Host "[+] $targetKey is now $newColor." -ForegroundColor $newColor
                Start-Sleep -Milliseconds 700
            }
            continue
        }

        switch ($choice.ToUpper()) {
            "T" {
                Clear-Host
                Write-Host "PREINSTALLED PRESETS" -ForegroundColor $Theme.Info
                Write-Host ""
                $presetNames = @($script:ThemePresets.Keys)
                $p = 0
                foreach ($name in $presetNames) {
                    $p++
                    $preset = $script:ThemePresets[$name]
                    $presetEmoji = if ($script:ThemePresetEmojis.Contains($name)) { $script:ThemePresetEmojis[$name] } else { "🎨" }
                    Write-Host ("  [{0,2}] " -f $p) -NoNewline -ForegroundColor $Theme.MutedLight
                    Write-Host ("$presetEmoji ") -NoNewline
                    Write-Host ("{0,-16}" -f $name) -NoNewline -ForegroundColor $Theme.Primary
                    foreach ($sampleKey in @('Brand','Info','Success','Warning','Error','Accent')) {
                        Write-Host "■" -NoNewline -ForegroundColor $preset[$sampleKey]
                    }
                    Write-Host ""
                }
                Write-Host ""
                $presetChoice = (Read-Host "Pick a preset by number (Enter to cancel)").Trim()
                if ($presetChoice -match '^\d+$' -and [int]$presetChoice -ge 1 -and [int]$presetChoice -le $presetNames.Count) {
                    $chosenName = $presetNames[[int]$presetChoice - 1]
                    $chosenPreset = $script:ThemePresets[$chosenName]
                    foreach ($key in $chosenPreset.Keys) {
                        if ($Theme.Contains($key)) { $Theme[$key] = $chosenPreset[$key] }
                    }
                    # Thinking colors follow the preset's Info pair unless the
                    # preset defines Think / ThinkDim itself.
                    if (-not $chosenPreset.Contains('Think')) { $Theme['Think'] = $Theme['Info'] }
                    if (-not $chosenPreset.Contains('ThinkDim')) { $Theme['ThinkDim'] = $Theme['InfoDim'] }
                    if ($script:ThemePresetEmojis.Contains($chosenName)) {
                        $script:ThemeEmoji = $script:ThemePresetEmojis[$chosenName]
                    }
                    Write-Host "[+] Applied preset: $chosenName $($script:ThemeEmoji)" -ForegroundColor $Theme.Success
                    Start-Sleep -Milliseconds 800
                }
            }
            "P" {
                Clear-Host
                Write-Host "COLOR PREVIEW" -ForegroundColor $Theme.Info
                Write-Host ""
                foreach ($key in $keys) {
                    Write-Host ("{0,-14} " -f $key) -NoNewline -ForegroundColor $Theme.MutedLight
                    Write-Host "The quick brown fox jumps over the lazy dog" -ForegroundColor $Theme[$key]
                }
                Write-Host ""
                Read-Host "Press Enter to go back"
            }
            "R" {
                $confirm = Read-Host "Type 'yes' to reset ALL colors to the built-in defaults"
                if ($confirm -eq 'yes') {
                    foreach ($key in $script:DefaultTheme.Keys) { $Theme[$key] = $script:DefaultTheme[$key] }
                    $script:ThemeEmoji = $script:DefaultThemeEmoji
                    Write-Host "[+] Colors and theme emoji reset to defaults." -ForegroundColor $Theme.Success
                    Start-Sleep -Milliseconds 800
                }
            }
            "S" {
                Save-ThemeConfig
                Write-Host "[+] Theme saved to ThemeConfig.json." -ForegroundColor $Theme.Success
                Start-Sleep -Milliseconds 800
                return
            }
            "0" { return }
            default {
                Write-Host "[!] Invalid selection." -ForegroundColor $Theme.Error
                Start-Sleep -Milliseconds 600
            }
        }
    }
}

function Show-SettingsMenu {
    while ($true) {
        Clear-Host
    Show-CommandActivation -Command 'settings'
        Write-Host "===================================================================>" -ForegroundColor $Theme.Info
        Write-Host "             ⚙️ MATRIX SETTINGS CONTROL PANEL ⚙️" -ForegroundColor $Theme.Info
        Write-Host "===================================================================>" -ForegroundColor $Theme.Info
        Write-Host ""
        Write-Host " Current Configuration:" -ForegroundColor $Theme.Warning
        Write-Host "  [1] Performance Profile  : $script:SelectedProfile" -ForegroundColor $Theme.Info
        Write-Host "  [2] Log Retention (days) : $($matrixConfig.LogRetentionDays)" -ForegroundColor $Theme.Info
        Write-Host "  [3] Keep-Alive Duration  : $($matrixConfig.KeepAlive)" -ForegroundColor $Theme.Info
        Write-Host "  [4] Default Context      : $($matrixConfig.DefaultContext)  (this is the live window; Low-VRAM will not exceed it)" -ForegroundColor $Theme.Info
        Write-Host "  [5] Logging Enabled      : $($matrixConfig.LoggingEnabled)" -ForegroundColor $Theme.Info
        Write-Host "  [6] Core Models          : $($matrixConfig.CoreModels -join ', ')" -ForegroundColor $Theme.Info
        Write-Host "  [7] Default Base Model   : $($matrixConfig.DefaultBaseModel)" -ForegroundColor $Theme.Info
        Write-Host "  [8] Portable Model Store : $defaultModelStorePath" -ForegroundColor $Theme.Info
        Write-Host "  [9] Run Log Cleanup Now" -ForegroundColor $Theme.Warning
        Write-Host "  [10] Reset Settings to Defaults" -ForegroundColor $Theme.ErrorDim
        Write-Host "  [11] RESET ALL Matrix Runtime State" -ForegroundColor $Theme.Error
        Write-Host "  [12] Customize Colors / Theme" -ForegroundColor $Theme.Accent
        Write-Host "  [13] Dashboard Layout           : $($script:DashboardLayout)" -ForegroundColor $Theme.Accent
        Write-Host "  [0] Save & Return to Dashboard" -ForegroundColor $Theme.Success
        Write-Host ""
        $choice = Read-Host "Select a setting to edit"

        switch ($choice) {
            "1" { Set-MatrixProfile }
            "2" {
                $val = Read-Host "Enter new log retention in days (current: $($matrixConfig.LogRetentionDays))"
                if ($val -match '^\d+$') {
                    $matrixConfig.LogRetentionDays = [int]$val
                    Write-Host "[+] Updated." -ForegroundColor $Theme.Success
                } else {
                    Write-Host "[!] Invalid number." -ForegroundColor $Theme.Error
                }
                Start-Sleep -Milliseconds 800
            }
            "3" {
                $val = Read-Host "Enter new keep-alive value, e.g. 30s or 5m (current: $($matrixConfig.KeepAlive))"
                if (-not [string]::IsNullOrWhiteSpace($val)) {
                    $matrixConfig.KeepAlive = $val
                    $env:OLLAMA_KEEP_ALIVE = $val
                    Write-Host "[+] Updated." -ForegroundColor $Theme.Success
                }
                Start-Sleep -Milliseconds 800
            }
            "4" {
                $val = Read-Host "Enter new default context length (current: $($matrixConfig.DefaultContext))"
                if ($val -match '^\d+$') {
                    $matrixConfig.DefaultContext = [int]$val
                    $script:OllamaContextLength = [int]$val
                    $env:OLLAMA_CONTEXT_LENGTH = $val
                    Write-Host "[+] Updated." -ForegroundColor $Theme.Success
                } else {
                    Write-Host "[!] Invalid number." -ForegroundColor $Theme.Error
                }
                Start-Sleep -Milliseconds 800
            }
            "5" {
                $matrixConfig.LoggingEnabled = -not [bool]$matrixConfig.LoggingEnabled
                Write-Host "[+] Logging Enabled set to: $($matrixConfig.LoggingEnabled)" -ForegroundColor $Theme.Success
                Start-Sleep -Milliseconds 800
            }
            "6" {
                $val = Read-Host "Enter comma-separated core model list (current: $($matrixConfig.CoreModels -join ', '))"
                if (-not [string]::IsNullOrWhiteSpace($val)) {
                    $matrixConfig.CoreModels = @(($val -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    Write-Host "[+] Updated." -ForegroundColor $Theme.Success
                }
                Start-Sleep -Milliseconds 800
            }
            "7" {
                $val = Read-Host "Enter default base model (current: $($matrixConfig.DefaultBaseModel))"
                if (-not [string]::IsNullOrWhiteSpace($val)) {
                    $matrixConfig.DefaultBaseModel = $val.Trim(); $matrixConfig.Model = $val.Trim()
                    Write-Host "[+] Default base model set to: $($matrixConfig.DefaultBaseModel)" -ForegroundColor $Theme.Success
                }
                Start-Sleep -Milliseconds 800
            }
            "8" {
                $matrixConfig.ModelStorePath = $defaultModelStorePath
                $env:OLLAMA_MODELS = $defaultModelStorePath
                Write-Host "[+] Portable model store is fixed to the project workspace:" -ForegroundColor $Theme.Success
                Write-Host "    $defaultModelStorePath" -ForegroundColor $Theme.Info
                Write-Host "[i] Machine-wide Ollama model directories are not used by the Matrix." -ForegroundColor $Theme.InfoDim
                Start-Sleep -Milliseconds 1200
            }
            "9" { Invoke-LogCleanup; Start-Sleep -Seconds 1 }
            "10" {
                $confirm = Read-Host "Type 'yes' to reset all settings to defaults"
                if ($confirm -eq 'yes') {
                    $defaults = Get-MatrixDefaultConfig
                    foreach ($k in $defaults.Keys) { $matrixConfig[$k] = $defaults[$k] }
                    $matrixConfig.ModelStorePath = $defaultModelStorePath
                    $script:SelectedProfile = [string]$matrixConfig.DefaultProfile
                    $script:OllamaContextLength = [int]$matrixConfig.DefaultContext
                    $env:OLLAMA_CONTEXT_LENGTH = [string]$matrixConfig.DefaultContext
                    $env:OLLAMA_KEEP_ALIVE = [string]$matrixConfig.KeepAlive
                    Save-MatrixConfig
                    Write-Host "[+] Settings reset to portable defaults (context $($matrixConfig.DefaultContext), keep-alive $($matrixConfig.KeepAlive))." -ForegroundColor $Theme.Success
                    Start-Sleep -Seconds 1
                }
            }
            "11" { Reset-AllMatrixState }
            "12" { Show-ThemeEditor }
            "13" { Show-LayoutPicker }
            "0" {
                Save-MatrixConfig
                Show-LoadingBar -Label " Saving Config" -Steps 12 -DelayMs 8 -Color $Theme.Success
                Write-Host "[+] Settings saved to MatrixConfig.json" -ForegroundColor $Theme.Success
                Start-Sleep -Milliseconds 600
                return
            }
            default {
                Write-Host "[!] Invalid selection." -ForegroundColor $Theme.Error
                Start-Sleep -Milliseconds 600
            }
        }
    }
}

# Session-scoped cache for Test-AgentModelInstalled. A model that was
# confirmed installed this session cannot become "uninstalled" without an
# explicit uninstall/delete action in the Matrix itself, so re-checking via
# an external `ollama show` process every single time the same agent is
# picked again is wasted subprocess overhead. The cache is cleared whenever
# the Matrix performs a model-mutating action (install/delete/reset).
if (-not (Get-Variable -Name MatrixInstalledModelCache -Scope script -ErrorAction SilentlyContinue)) {
    $script:MatrixInstalledModelCache = @{}
}

function Clear-AgentModelInstalledCache {
    $script:MatrixInstalledModelCache = @{}
}

function Test-AgentModelInstalled {
    param(
        [Parameter(Mandatory = $true)][string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return $false
    }

    $cacheKey = $ModelName.ToLowerInvariant()
    if ($script:MatrixInstalledModelCache.ContainsKey($cacheKey)) {
        return $script:MatrixInstalledModelCache[$cacheKey]
    }

    $found = $false
    try {
        # Prefer ollama show because it validates the exact local model name.
        & ollama show $ModelName *> $null
        if ($LASTEXITCODE -eq 0) {
            $found = $true
        }
    } catch {}

    if (-not $found) {
        try {
            $installed = @(ollama list 2>$null)
            foreach ($line in $installed) {
                $parts = ($line -replace '^\s+|\s+$','' -split '\s+')
                if ($parts.Count -gt 0) {
                    $localName = [string]$parts[0]
                    if ($localName -ieq $ModelName -or $localName -ieq "$ModelName`:latest") {
                        $found = $true
                        break
                    }
                }
            }
        } catch {}
    }

    $script:MatrixInstalledModelCache[$cacheKey] = $found
    return $found
}


function Resolve-AgentModelfilePath {
    param([Parameter(Mandatory=$true)][string]$ModelName)
    $ModelName = ([string]$ModelName).Trim()
    $candidates = @(
        (Join-Path $PSScriptRoot ("Modfiles\Modelfile_{0}" -f $ModelName)),
        (Join-Path $PSScriptRoot ("Modelfile_{0}" -f $ModelName)),
        (Join-Path $PSScriptRoot ("Modfiles\Modelfile_{0}" -f $ModelName.ToLower())),
        (Join-Path $PSScriptRoot ("Modelfile_{0}" -f $ModelName.ToLower()))
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Ensure-AgentDirectiveModel {
    param(
        [Parameter(Mandatory = $true)][string]$ModelName
    )

    $ModelName = ([string]$ModelName).Trim()
    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        throw "Directive-backed agent model name is empty."
    }

    # IMPORTANT: this function is verification-only.
    # It MUST NEVER call `ollama create` implicitly.
    # Agent registration may happen only through an explicit install action.
    if (Test-AgentModelInstalled -ModelName $ModelName) {
        return $ModelName
    }

    $modelfile = Resolve-AgentModelfilePath -ModelName $ModelName
    if ($modelfile) {
        throw "Agent '$ModelName' has a local Modelfile but is not registered. Use Models -> Install Agent to register it."
    }

    throw "Agent '$ModelName' is not installed and no local Modelfile was found."
}

function Install-AgentDirectiveModel {
    param(
        [Parameter(Mandatory = $true)][string]$ModelName
    )

    $ModelName = ([string]$ModelName).Trim()
    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        throw "Agent model name is empty."
    }

    $modelfile = Resolve-AgentModelfilePath -ModelName $ModelName
    if (-not $modelfile) {
        throw "Cannot install agent '$ModelName' because Modelfile_$ModelName is missing (checked Modfiles\ and project root)."
    }

    # Always re-create from Modelfile so the SYSTEM directive is the authority.
    Write-Host "[*] Registering agent '$ModelName' from Modelfile (directive-authoritative)..." -ForegroundColor $Theme.Info
    Write-Host "    Source: $modelfile" -ForegroundColor $Theme.InfoDim
    $rc = Invoke-OllamaNative -Arguments @('create', $ModelName, '-f', $modelfile)
    Clear-AgentModelInstalledCache
    if ($rc -ne 0 -or -not (Test-AgentModelInstalled -ModelName $ModelName)) {
        throw "Agent '$ModelName' registration failed with exit code $rc."
    }
    Write-Host "[+] Agent '$ModelName' registered with Modelfile directive." -ForegroundColor $Theme.Success

    return $ModelName
}

function Confirm-AndInstallAgent {
    param(
        [Parameter(Mandatory=$true)][string]$ModelName,
        [switch]$AutoYes
    )

    $ModelName = ([string]$ModelName).Trim()
    if (Test-AgentModelInstalled -ModelName $ModelName) { return $ModelName }

    $modelfile = Resolve-AgentModelfilePath -ModelName $ModelName
    if (-not $modelfile) {
        throw "Agent '$ModelName' is not installed and no local Modelfile was found."
    }

    $from = Get-AgentDeclaredBaseModel -AgentModel $ModelName
    if ($from -and $from -ne 'unknown' -and -not (Test-AgentModelInstalled -ModelName $from)) {
        $pull = 'Y'
        if (-not $AutoYes) {
            $pull = Read-Host "Base model '$from' is not in this portable store. Pull it now? [Y/n]"
        }
        if ($pull -match '^(?i)n') {
            throw "Base model '$from' is required before '$ModelName' can be registered."
        }
        Write-Host "[*] Pulling base model '$from' into .\OllamaModels ..." -ForegroundColor $Theme.Info
        & ollama pull $from
        if ($LASTEXITCODE -ne 0) {
            throw "Pull of '$from' failed with exit code $LASTEXITCODE."
        }
        Clear-AgentModelInstalledCache
    }

    $go = 'Y'
    if (-not $AutoYes) {
        $go = Read-Host "Agent '$ModelName' is not registered yet. Create it from the local Modelfile now? [Y/n]"
    }
    if ($go -match '^(?i)n') {
        throw "Agent '$ModelName' was not registered."
    }
    return (Install-AgentDirectiveModel -ModelName $ModelName)
}

function Get-AgentBaseModel {
    param(
        [Parameter(Mandatory = $true)][string]$ModelName
    )

    $ModelName = ([string]$ModelName).Trim()
    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        throw "Cannot resolve an agent base model from an empty model name."
    }

    # The installed modinstall.ps1 agent is ALWAYS the base layer.
    return (Ensure-AgentDirectiveModel -ModelName $ModelName)
}

# Run startup tasks
Invoke-LogCleanup

# Ollama must be ready under the PORTABLE Matrix store before any model-store
# verification. Even when a machine-wide Ollama service is already online, the
# Matrix takes ownership of the service so `ollama list/pull/run` resolve only
# against <project>\OllamaModels.
$ollamaReadyAtBoot = Start-OllamaEngine

if ($ollamaReadyAtBoot) {
    Test-AndPullCoreModels
} else {
    Write-Host "[!] Ollama is not ready, so model verification was deferred. The Matrix will not pull or create models." -ForegroundColor $Theme.Warning
}

$map = @{
    "1"="cypra"; "2"="echo"; "3"="forge"; "4"="atlas"; "5"="chronos";
    "6"="helix"; "7"="kaizen"; "8"="ghost"; "9"="titan"; "10"="vortex";
    "11"="spectre"; "12"="nexus"; "13"="morpheus"; "14"="aether"; "15"="valkyrie";
    "16"="aegis"; "17"="phantom"; "18"="eclipse"; "19"="lilith"; "20"="siren";
    "21"="rogue"; "22"="maia"; "23"="solon"; "24"="lyra"; "25"="oracle";
    "26"="zero"; "27"="prism"; "28"="sentinel"; "29"="catalyst"; "30"="nomad";
    "31"="artifact"; "32"="weaver"; "33"="vector"; "34"="pulse"; "35"="apex";
    "36"="glitch"; "37"="nova"; "38"="zane"; "39"="maya"; "40"="leo";
    "41"="iris"; "42"="rex"; "43"="nora"; "44"="kai"; "45"="chloe";
    "46"="ethan"; "47"="chaos"; "48"="void"; "49"="feral"; "50"="apex-x";
    "51"="anomaly"; "52"="quantum"; "53"="nexus-prime"; "54"="synth"; "55"="cipher";
    "56"="medic"; "57"="trauma"; "58"="triage"; "59"="biohazard"; "60"="hazard";
    "61"="psyche"; "62"="archetype"; "63"="ethos"; "64"="empathy"; "65"="persona";
    "66"="reflex"; "67"="gestalt"; "68"="ritual"; "69"="cognitive"; "70"="memetics";
    "71"="warden"; "72"="shadow"; "73"="stalker"; "74"="decrypt"; "75"="sandbox";
    "76"="payload"; "77"="beacon"; "78"="armor"; "79"="stealth"; "80"="hunter";
    "81"="sharding"; "82"="index"; "83"="query"; "84"="broker"; "85"="sync";
    "86"="cache"; "87"="pipeline"; "88"="ingest"; "89"="cluster"; "90"="ledger";
    "91"="voltage"; "92"="thermal"; "93"="clock"; "94"="register"; "95"="bus";
    "96"="driver"; "97"="firmware"; "98"="matrix-hw"; "99"="allocator"; "100"="bare";
    "101"="glyph-agent"; "102"="mythos"; "103"="paradox-engine"; "104"="axiom"; "105"="cipher-x";
    "106"="dream"; "107"="echo-x"; "108"="zenith"; "109"="abyss"; "110"="genesis";
    "111"="sage"; "112"="pulse-life"; "113"="catalyst-life"; "114"="anchor"; "115"="muse";
    "116"="scout"; "117"="shield"; "118"="diplomat"; "119"="architect-life"; "120"="companion";
    "121"="bio-anthro"; "122"="cultural-anthro"; "123"="archaeology"; "124"="linguistic-anthro"; "125"="forensic-anthro";
    "126"="socio-anthro"; "127"="urban-anthro"; "128"="medical-anthro"; "129"="economic-anthro"; "130"="applied-anthro";
    "131"="empath"; "132"="chronos-v2"; "133"="scribe"; "134"="sovereign"; "135"="hearth";
    "136"="mentor"; "137"="sanctuary"; "138"="catalyst-ii"; "139"="navigator"; "140"="vitalis";
    "141"="debug"; "142"="syntax"; "143"="patch"; "144"="compiler"; "145"="runtime";
    "146"="refactor"; "147"="algorithm"; "148"="binary"; "149"="kernel"; "150"="thread";
    "151"="curriculum"; "152"="pedagogy"; "153"="scholar"; "154"="syllabus"; "155"="tutoring";
    "156"="academy"; "157"="literacy"; "158"="seminar"; "159"="textbook"; "160"="faculty";
    "161"="wellness"; "162"="harmony"; "163"="solace"; "164"="radiance"; "165"="zen";
    "166"="balance"; "167"="tranquil"; "168"="breathe"; "169"="bloom"; "170"="solitude"
	"171"="pharmacist"; "172"="rehab-dr"; "173"="cardiologist"; "174"="pediatrician"; "175"="neurologist";
    "176"="forager"; "177"="shelter-builder"; "178"="fire-starter"; "179"="water-purifier"; "180"="nav-scout";
    "181"="algebraist"; "182"="geometrician"; "183"="statistician"; "184"="calculus-expert"; "185"="topologist";
    "186"="researcher"; "187"="hypothesis"; "188"="evidence"; "189"="librarian"; "190"="experimenter"; "191"="planner"; "192"="scheduler-pro"; "193"="logistician"; "194"="procurement"; "195"="dispatcher"; "196"="economist"; "197"="accountant"; "198"="auditor-pro"; "199"="market-analyst"; "200"="budgeter"; "201"="jurist"; "202"="compliance"; "203"="policy-analyst"; "204"="mediator-pro"; "205"="contractor"; "206"="mechanist"; "207"="architect-pro"; "208"="materials"; "209"="control-systems"; "210"="cad-designer"; "211"="linguist"; "212"="translator-pro"; "213"="rhetorician"; "214"="lexicographer"; "215"="culturalist"
    "216"="physicist"; "217"="chemist"; "218"="biologist"; "219"="ecologist"; "220"="geologist"; "221"="meteorologist"; "222"="climatologist"; "223"="hydrologist"; "224"="oceanographer"; "225"="seismologist"; "226"="astronomer"; "227"="astrophysicist"; "228"="cosmologist"; "229"="planetologist"; "230"="astrobiologist"; "231"="algorithms"; "232"="compiler-engineer"; "233"="distributed-systems"; "234"="database-architect"; "235"="operating-systems"; "236"="software-architect"; "237"="test-engineer"; "238"="debugger"; "239"="refactorer"; "240"="api-designer"; "241"="ml-engineer"; "242"="deep-learning"; "243"="reinforcement"; "244"="computer-vision"; "245"="nlp-engineer"; "246"="data-engineer"; "247"="data-scientist"; "248"="data-visualizer"; "249"="forecasting"; "250"="operations-research"; "251"="threat-modeler"; "252"="incident-responder"; "253"="digital-forensics"; "254"="security-architect"; "255"="privacy-engineer"; "256"="electrical-engineer"; "257"="electronics-designer"; "258"="roboticist"; "259"="embedded-engineer"; "260"="mechatronics"; "261"="power-engineer"; "262"="renewables"; "263"="nuclear-engineer"; "264"="grid-operator"; "265"="infrastructure"; "266"="manufacturing"; "267"="industrial-engineer"; "268"="quality-engineer"; "269"="metallurgist"; "270"="polymer-scientist"; "271"="automotive"; "272"="aerospace-engineer"; "273"="naval-engineer"; "274"="rail-engineer"; "275"="traffic-engineer"; "276"="civil-engineer"; "277"="structural-engineer"; "278"="construction-manager"; "279"="urban-planner"; "280"="landscape-designer"; "281"="journalist"; "282"="editor"; "283"="fact-checker"; "284"="documentarian"; "285"="technical-writer"; "286"="strategist"; "287"="product-manager"; "288"="project-manager"; "289"="risk-manager"; "290"="change-manager"; "291"="psychologist"; "292"="sociologist"; "293"="demographer"; "294"="behavioral-economist"; "295"="organizational-scientist"; "296"="philosopher"; "297"="epistemologist"; "298"="logician"; "299"="ethicist"; "300"="systems-philosopher";
"301"="platform-engineer";
"302"="site-reliability-engineer";
"303"="observability-engineer";
"304"="cloud-architect";
"305"="cloud-finops";
"306"="kubernetes-architect";
"307"="container-security";
"308"="devsecops-engineer";
"309"="release-engineer";
"310"="deployment-strategist";
"311"="incident-commander";
"312"="problem-manager";
"313"="capacity-planner";
"314"="performance-engineer";
"315"="latency-engineer";
"316"="distributed-debugger";
"317"="network-architect";
"318"="network-observability";
"319"="identity-architect";
"320"="iam-engineer";
"321"="secrets-engineer";
"322"="cryptography-engineer";
"323"="supply-chain-security";
"324"="sbom-analyst";
"325"="vulnerability-manager";
"326"="security-program-manager";
"327"="privacy-program-manager";
"328"="data-governance-architect";
"329"="data-quality-engineer";
"330"="master-data-manager";
"331"="metadata-architect";
"332"="data-lineage-engineer";
"333"="analytics-engineer";
"334"="bi-architect";
"335"="metrics-engineer";
"336"="experiment-analyst";
"337"="causal-inference-specialist";
"338"="forecasting-strategist";
"339"="decision-scientist";
"340"="product-analyst";
"341"="ux-researcher";
"342"="service-designer";
"343"="interaction-designer";
"344"="design-systems-engineer";
"345"="accessibility-engineer";
"346"="technical-product-manager";
"347"="product-operations";
"348"="portfolio-manager";
"349"="program-manager";
"350"="delivery-manager";
"351"="scrum-facilitator";
"352"="requirements-engineer";
"353"="business-analyst-pro";
"354"="process-architect";
"355"="enterprise-architect";
"356"="solution-architect";
"357"="integration-architect";
"358"="api-governance";
"359"="event-architect";
"360"="workflow-architect";
"361"="rules-engineer";
"362"="configuration-engineer";
"363"="feature-flag-architect";
"364"="test-architect";
"365"="test-automation-engineer";
"366"="property-testing-engineer";
"367"="contract-testing-engineer";
"368"="chaos-engineering-strategist";
"369"="resilience-engineer";
"370"="backup-recovery-architect";
"371"="business-continuity-planner";
"372"="disaster-recovery-engineer";
"373"="records-manager";
"374"="document-control-specialist";
"375"="technical-editor-pro";
"376"="knowledge-engineer";
"377"="ontology-architect";
"378"="search-relevance-engineer";
"379"="rag-engineer";
"380"="prompt-engineer-pro";
"381"="evaluation-engineer";
"382"="ai-safety-engineer";
"383"="mlops-architect";
"384"="serving-engineer";
"385"="inference-optimizer";
"386"="data-privacy-engineer";
"387"="fraud-analytics-specialist";
"388"="financial-systems-analyst";
"389"="procurement-operations";
"390"="vendor-risk-manager";
"391"="contract-lifecycle-manager";
"392"="regulatory-intelligence";
"393"="audit-methodology-specialist";
"394"="control-assurance-engineer";
"395"="quality-management-specialist";
"396"="safety-engineer";
"397"="human-factors-engineer";
"398"="technical-trainer";
"399"="change-communications";
"400"="executive-briefing-specialist"
    "401"="master-mechanic";
    "402"="geotechnical-engineer";
    "403"="inventory-control-specialist";
    "404"="actuarial-modeler";
    "405"="forensic-accounting-specialist";
    "406"="clinical-research-coordinator";
    "407"="instructional-designer";
    "408"="renewable-grid-planner";
    "409"="localization-engineer";
    "410"="organizational-design-architect";

    # --- 200 NEW AGENTS (411-700) ---
    "411"="captain-nova";
    "412"="detective-noir";
    "413"="wizard-eldrin";
    "414"="cyberpunk-fixer";
    "415"="time-courier";
    "416"="executive-chef-consultant";
    "417"="pastry-chef-pro";
    "418"="sommelier-pro";
    "419"="mixologist-pro";
    "420"="barista-trainer";
    "421"="food-scientist";
    "422"="flavor-chemist";
    "423"="fermentation-scientist";
    "424"="brewing-engineer";
    "425"="nutritionist-sports";
    "426"="choreographer-pro";
    "427"="stage-director";
    "428"="voice-coach-performance";
    "429"="stunt-coordinator";
    "430"="costume-designer";
    "431"="set-designer";
    "432"="lighting-designer";
    "433"="sound-designer-live";
    "434"="puppeteer-designer";
    "435"="magic-consultant";
    "436"="cinematographer-pro";
    "437"="film-editor-pro";
    "438"="colorist-pro";
    "439"="vfx-supervisor";
    "440"="motion-graphics-designer";
    "441"="3d-modeler-pro";
    "442"="concept-artist-pro";
    "443"="documentary-producer";
    "444"="broadcast-engineer";
    "445"="podcast-producer";
    "446"="game-designer-pro";
    "447"="level-designer-pro";
    "448"="narrative-designer-games";
    "449"="game-balance-designer";
    "450"="technical-artist-games";
    "451"="shader-programmer";
    "452"="board-game-designer";
    "453"="tabletop-rpg-designer";
    "454"="esports-analyst";
    "455"="puzzle-designer";
    "456"="composer-pro";
    "457"="orchestrator-pro";
    "458"="mixing-engineer-pro";
    "459"="mastering-engineer-pro";
    "460"="music-theorist";
    "461"="sound-designer-game";
    "462"="foley-artist";
    "463"="dj-production-coach";
    "464"="audio-restoration-engineer";
    "465"="session-musician-coach";
    "466"="fashion-designer-pro";
    "467"="textile-engineer";
    "468"="apparel-technologist";
    "469"="footwear-designer";
    "470"="jewelry-designer";
    "471"="textile-print-designer";
    "472"="costume-historian";
    "473"="leatherworker-designer";
    "474"="millinery-designer";
    "475"="sustainable-fashion-consultant";
    "476"="agronomist-pro";
    "477"="horticulturist-pro";
    "478"="viticulturist-pro";
    "479"="soil-scientist";
    "480"="irrigation-engineer";
    "481"="aquaculture-specialist";
    "482"="beekeeping-specialist";
    "483"="arborist-pro";
    "484"="greenhouse-manager";
    "485"="permaculture-designer";
    "486"="veterinary-surgeon-advisor";
    "487"="animal-behaviorist";
    "488"="zookeeper-consultant";
    "489"="wildlife-conservationist";
    "490"="dog-trainer-pro";
    "491"="equine-specialist";
    "492"="marine-mammal-specialist";
    "493"="avian-specialist";
    "494"="livestock-management-advisor";
    "495"="animal-nutritionist";
    "496"="environmental-impact-assessor";
    "497"="restoration-ecologist";
    "498"="sustainability-consultant";
    "499"="carbon-accounting-specialist";
    "500"="circular-economy-strategist";
    "501"="waste-management-engineer";
    "502"="water-treatment-engineer";
    "503"="air-quality-specialist";
    "504"="environmental-policy-analyst";
    "505"="climate-adaptation-planner";
    "506"="mining-engineer";
    "507"="geophysicist-pro";
    "508"="petroleum-engineer";
    "509"="drilling-engineer";
    "510"="pipeline-engineer";
    "511"="refinery-process-engineer";
    "512"="chemical-process-engineer";
    "513"="hydrogeologist";
    "514"="dam-engineer";
    "515"="mineral-processing-engineer";
    "516"="avionics-engineer";
    "517"="propulsion-engineer";
    "518"="flight-dispatcher";
    "519"="air-traffic-control-trainer";
    "520"="drone-operations-specialist";
    "521"="uav-systems-engineer";
    "522"="satellite-imagery-analyst";
    "523"="remote-sensing-specialist";
    "524"="spacecraft-systems-engineer";
    "525"="aircraft-maintenance-planner";
    "526"="naval-architect-pro";
    "527"="marine-engineer-pro";
    "528"="ship-captain-consultant";
    "529"="port-operations-planner";
    "530"="marine-biologist-applied";
    "531"="subsea-engineer";
    "532"="offshore-structures-engineer";
    "533"="undersea-cable-engineer";
    "534"="maritime-logistics-planner";
    "535"="coastal-engineer";
    "536"="rf-engineer-pro";
    "537"="antenna-designer";
    "538"="telecom-network-planner";
    "539"="5g-specialist";
    "540"="fiber-optics-engineer";
    "541"="satellite-communications-engineer";
    "542"="network-observability-rf";
    "543"="broadcast-transmission-engineer";
    "544"="telecom-regulatory-specialist";
    "545"="iot-connectivity-engineer";
    "546"="museum-curator-pro";
    "547"="archivist-pro";
    "548"="art-conservator";
    "549"="genealogist-pro";
    "550"="historic-preservationist";
    "551"="numismatist-pro";
    "552"="cartographic-historian";
    "553"="oral-history-specialist";
    "554"="heritage-tourism-planner";
    "555"="archaeological-illustrator";
    "556"="physical-therapist-advisor";
    "557"="occupational-therapy-advisor";
    "558"="speech-language-advisor";
    "559"="audiology-advisor";
    "560"="optometry-advisor";
    "561"="dental-hygiene-advisor";
    "562"="athletic-trainer-advisor";
    "563"="massage-therapy-advisor";
    "564"="genetic-counseling-advisor";
    "565"="public-health-educator";
    "566"="real-estate-appraiser";
    "567"="property-manager-pro";
    "568"="facilities-manager-pro";
    "569"="real-estate-developer-advisor";
    "570"="commercial-leasing-specialist";
    "571"="building-inspector-pro";
    "572"="space-planning-strategist";
    "573"="hoa-management-advisor";
    "574"="real-estate-market-analyst";
    "575"="energy-audit-specialist";
    "576"="trademark-specialist";
    "577"="patent-strategy-advisor";
    "578"="immigration-consultant-advisor";
    "579"="customs-broker-advisor";
    "580"="export-controls-specialist";
    "581"="arbitration-specialist-advisor";
    "582"="notary-paralegal-advisor";
    "583"="tax-specialist-advisor";
    "584"="environmental-law-advisor";
    "585"="aviation-law-advisor";
    "586"="event-planner-pro";
    "587"="wedding-planner-pro";
    "588"="catering-manager-pro";
    "589"="hotel-operations-manager";
    "590"="concierge-service-specialist";
    "591"="tour-guide-trainer";
    "592"="cruise-operations-advisor";
    "593"="banquet-operations-manager";
    "594"="guest-experience-designer";
    "595"="nightlife-venue-manager";
    "596"="master-plumber-advisor";
    "597"="master-electrician-advisor";
    "598"="hvac-technician-advisor";
    "599"="welder-pro";
    "600"="master-carpenter-pro";
    "601"="machinist-pro";
    "602"="blacksmith-pro";
    "603"="glassblower-pro";
    "604"="stonemason-pro";
    "605"="locksmith-pro";
    "606"="cartographer-pro";
    "607"="gis-analyst-pro";
    "608"="land-surveyor-pro";
    "609"="toy-safety-engineer";
    "610"="packaging-engineer-pro";

    # --- 90 NEW AGENTS (611-700) ---
    "611"="packet-sleuth"; "612"="auth-lab-analyst"; "613"="malware-sandboxer"; "614"="network-hunter"; "615"="binary-reverse-engineer"; "616"="phishing-awareness-engineer"; "617"="detection-rule-smith"; "618"="threat-intel-geek"; "619"="vuln-research-lab"; "620"="cloud-redteam-analyst";
    "621"="sky-pirate-captain"; "622"="cyber-oracle"; "623"="desert-ranger"; "624"="court-wizard"; "625"="time-librarian"; "626"="star-salvager"; "627"="dragon-scholar"; "628"="clockwork-diplomat"; "629"="postfall-merchant"; "630"="mystic-cartomancer";
    "631"="fermentation-science-controller"; "632"="sensory-evaluator"; "633"="aquaponics-designer"; "634"="apiary-genetics-specialist"; "635"="mycology-specialist"; "636"="seed-breeding-specialist"; "637"="botanical-taxonomist"; "638"="entomology-specialist"; "639"="ornithology-specialist"; "640"="ichthyology-specialist";
    "641"="immunology-researcher"; "642"="gerontology-researcher"; "643"="prosthetics-designer"; "644"="orthotics-specialist"; "645"="dental-prosthetics-specialist"; "646"="clinical-trials-coordinator"; "647"="pharmacovigilance-analyst"; "648"="radiation-safety-specialist"; "649"="sonography-workflow-specialist"; "650"="speech-language-specialist";
    "651"="occupational-accessibility-designer"; "652"="sleep-science-researcher"; "653"="food-microbiology-specialist"; "654"="culinary-process-engineer"; "655"="coffee-roasting-scientist"; "656"="tea-blending-specialist"; "657"="bookbinding-artisan"; "658"="paper-conservation-specialist"; "659"="textile-conservator"; "660"="museum-exhibition-planner";
    "661"="oral-archive-forensics"; "662"="genealogy-researcher"; "663"="paleographer"; "664"="numismatist"; "665"="philatelist"; "666"="cartooning-instructor"; "667"="storyboard-artist"; "668"="color-theory-specialist"; "669"="typography-curator"; "670"="calligraphy-specialist";
    "671"="grant-writing-specialist"; "672"="speechwriting-specialist"; "673"="media-training-coach"; "674"="meeting-facilitator"; "675"="learning-experience-architect"; "676"="assessment-designer"; "677"="curriculum-mapper"; "678"="museum-registrar"; "679"="conservation-scientist"; "680"="urban-ecologist";
    "681"="wildlife-corridor-planner"; "682"="wetland-restoration-specialist"; "683"="soil-science-specialist"; "684"="seed-bank-curator"; "685"="greenhouse-climate-manager"; "686"="irrigation-designer"; "687"="landscape-ecology-analyst"; "688"="watershed-planning-specialist"; "689"="hydrography-specialist"; "690"="ocean-acoustics-specialist";
    "691"="acoustical-engineer"; "692"="ergonomics-researcher"; "693"="packaging-sustainability-analyst"; "694"="repairability-engineer"; "695"="circular-economy-designer"; "696"="tool-librarian"; "697"="makerspace-safety-coordinator"; "698"="3d-printing-process-specialist"; "699"="laser-cutting-designer"; "700"="metrology-specialist";
}

$tags = @{
    "1"="BV Core"; "2"="JARVIS"; "3"="Indust"; "4"="Schema"; "5"="Tact";
    "6"="States"; "7"="Refact"; "8"="Packer"; "9"="Profil"; "10"="Opcode";
    "11"="Kernel"; "12"="Parser"; "13"="Vector"; "14"="Telemet"; "15"="Audit";
    "16"="Failov"; "17"="Forens"; "18"="Exploi"; "19"="Peer"; "20"="UI/UX";
    "21"="Fuzzer"; "22"="Compan"; "23"="Mentor"; "24"="Narrat"; "25"="Risk";
    "26"="Isolat"; "27"="Refac"; "28"="Guard"; "29"="Accel"; "30"="Trans";
    "31"="Recov"; "32"="Weave"; "33"="Spatial"; "34"="Pulse"; "35"="Sched";
    "36"="Chaos"; "37"="Empthy"; "38"="Direct"; "39"="Creatv"; "40"="Leader";
    "41"="Insight"; "42"="Wit/Hum"; "43"="Calm"; "44"="Curious"; "45"="Social";
    "46"="Mentor"; "47"="Unhing"; "48"="NoLimit"; "49"="WildCard"; "50"="Advanced";
    "51"="P.Unbound"; "52"="Probabil"; "53"="SyncNode"; "54"="Synthetic"; "55"="Crypto";
    "56"="TriageMed"; "57"="Surgeon"; "58"="MassCas"; "59"="Contain"; "60"="Survival";
    "61"="Psyche"; "62"="Archetyp"; "63"="Ethos"; "64"="Empathy"; "65"="Persona";
    "66"="Reflex"; "67"="Gestalt"; "68"="Ritual"; "69"="Cognitiv"; "70"="Memetic";
    "71"="Warden"; "72"="Shadow"; "73"="Stalker"; "74"="Decrypt"; "75"="Sandbox";
    "76"="Payload"; "77"="Beacon"; "78"="Armor"; "79"="Stealth"; "80"="Hunter";
    "81"="Sharding"; "82"="Index"; "83"="Query"; "84"="Broker"; "85"="Sync";
    "86"="Cache"; "87"="Pipeline"; "88"="Ingest"; "89"="Cluster"; "90"="Ledger";
    "91"="Voltage"; "92"="Thermal"; "93"="Clock"; "94"="Register"; "95"="Bus";
    "96"="Driver"; "97"="Firmware"; "98"="MatrixHW"; "99"="Allocatr"; "100"="Bare";
    "101"="GlyphAgt"; "102"="Mythos"; "103"="ParadoxE"; "104"="Axiom"; "105"="CipherX";
    "106"="Dream"; "107"="EchoX"; "108"="Zenith"; "109"="Abyss"; "110"="Genesis";
    "111"="Sage"; "112"="PulseLif"; "113"="CatalLif"; "114"="Anchor"; "115"="Muse";
    "116"="Scout"; "117"="Shield"; "118"="Diplomat"; "119"="ArchLife"; "120"="Companio";
    "121"="BioAnth"; "122"="CultAnth"; "123"="Archaeol"; "124"="LingAnth"; "125"="ForenAnt";
    "126"="SocioAnt"; "127"="UrbanAnt"; "128"="MedAnthro"; "129"="EconAnth"; "130"="ApplAnth";
    "131"="Empath"; "132"="Chronos2"; "133"="Scribe"; "134"="Sovereig"; "135"="Hearth";
    "136"="Mentor2"; "137"="Sanctuar"; "138"="Catalys2"; "139"="Navigatr"; "140"="Vitalis";
    "141"="Debug"; "142"="Syntax"; "143"="Patch"; "144"="Compiler"; "145"="Runtime";
    "146"="Refactor"; "147"="Algorithm"; "148"="Binary"; "149"="Kernel"; "150"="Thread";
    "151"="Curricul"; "152"="Pedagogy"; "153"="Scholar"; "154"="Syllabus"; "155"="Tutoring";
    "156"="Academy"; "157"="Literacy"; "158"="Seminar"; "159"="Textbook"; "160"="Faculty";
    "161"="Wellness"; "162"="Harmony"; "163"="Solace"; "164"="Radiance"; "165"="Zen";
    "166"="Balance"; "167"="Tranquil"; "168"="Breathe"; "169"="Bloom"; "170"="Solitude"
    "171"="Pharma"; "172"="Rehab"; "173"="Cardio"; "174"="Pediatr"; "175"="Neuro";
    "176"="Forage"; "177"="Shelter"; "178"="FireCr"; "179"="WaterP"; "180"="NavSct";
    "181"="Algebra"; "182"="Geometr"; "183"="Stats"; "184"="Calculs"; "185"="Topolgy";
    "186"="Research"; "187"="Hypoth"; "188"="Evidence"; "189"="Library"; "190"="Experim"; "191"="Planner"; "192"="SchedPro"; "193"="Logist"; "194"="Procure"; "195"="Dispatch"; "196"="Economy"; "197"="Account"; "198"="AuditPro"; "199"="Markets"; "200"="Budget"; "201"="Jurist"; "202"="Comply"; "203"="Policy"; "204"="Mediator"; "205"="Contracts"; "206"="Mechanic"; "207"="ArchPro"; "208"="Materials"; "209"="Control"; "210"="CAD"; "211"="Linguist"; "212"="Translate"; "213"="Rhetoric"; "214"="Lexicon"; "215"="Culture"
    "216"="Physic"; "217"="Chemist"; "218"="Biology"; "219"="Ecology"; "220"="Geology"; "221"="Meteo"; "222"="Climate"; "223"="Hydro"; "224"="Ocean"; "225"="Seismic"; "226"="Astronomy"; "227"="AstroPhys"; "228"="Cosmology"; "229"="Planetary"; "230"="AstroBio"; "231"="Algorithms"; "232"="Compiler"; "233"="DistribSys"; "234"="DBArchitect"; "235"="OSSystems"; "236"="SoftArch"; "237"="TestEng"; "238"="Debugger"; "239"="Refactor"; "240"="APIDesign"; "241"="MLEngineer"; "242"="DeepLearn"; "243"="Reinforce"; "244"="Vision"; "245"="NLPEng"; "246"="DataEng"; "247"="DataSci"; "248"="DataViz"; "249"="Forecast"; "250"="OpsResearch"; "251"="ThreatModel"; "252"="Incident"; "253"="Forensics"; "254"="SecArch"; "255"="PrivacyEng"; "256"="Electrical"; "257"="Electronics"; "258"="Robotics"; "259"="Embedded"; "260"="Mechatron"; "261"="PowerEng"; "262"="Renewables"; "263"="NuclearEng"; "264"="GridOps"; "265"="Infra"; "266"="Manufacture"; "267"="IndEng"; "268"="QualityEng"; "269"="Metallurgy"; "270"="Polymer"; "271"="Automotive"; "272"="AeroEng"; "273"="NavalEng"; "274"="RailEng"; "275"="TrafficEng"; "276"="CivilEng"; "277"="Structural"; "278"="ConstrMgr"; "279"="UrbanPlan"; "280"="Landscape"; "281"="Journalist"; "282"="Editor"; "283"="FactCheck"; "284"="Documentary"; "285"="TechWriter"; "286"="Strategist"; "287"="ProductMgr"; "288"="ProjectMgr"; "289"="RiskMgr"; "290"="ChangeMgr"; "291"="Psychology"; "292"="Sociology"; "293"="Demography"; "294"="Behavioral"; "295"="OrgScience"; "296"="Philosophy"; "297"="Epistemic"; "298"="Logic"; "299"="Ethics"; "300"="SysPhil";
"301"="Platform-301";
"302"="Platform-302";
"303"="Platform-303";
"304"="Platform-304";
"305"="Platform-305";
"306"="Platform-306";
"307"="Platform-307";
"308"="Platform-308";
"309"="Platform-309";
"310"="Platform-310";
"311"="Security-311";
"312"="Security-312";
"313"="Security-313";
"314"="Security-314";
"315"="Security-315";
"316"="Security-316";
"317"="Security-317";
"318"="Security-318";
"319"="Security-319";
"320"="Security-320";
"321"="Data-321";
"322"="Data-322";
"323"="Data-323";
"324"="Data-324";
"325"="Data-325";
"326"="Data-326";
"327"="Data-327";
"328"="Data-328";
"329"="Data-329";
"330"="Data-330";
"331"="Product-331";
"332"="Product-332";
"333"="Product-333";
"334"="Product-334";
"335"="Product-335";
"336"="Product-336";
"337"="Product-337";
"338"="Product-338";
"339"="Product-339";
"340"="Product-340";
"341"="Architecture-341";
"342"="Architecture-342";
"343"="Architecture-343";
"344"="Architecture-344";
"345"="Architecture-345";
"346"="Architecture-346";
"347"="Architecture-347";
"348"="Architecture-348";
"349"="Architecture-349";
"350"="Architecture-350";
"351"="Quality-351";
"352"="Quality-352";
"353"="Quality-353";
"354"="Quality-354";
"355"="Quality-355";
"356"="Quality-356";
"357"="Quality-357";
"358"="Quality-358";
"359"="Quality-359";
"360"="Quality-360";
"361"="AI-361";
"362"="AI-362";
"363"="AI-363";
"364"="AI-364";
"365"="AI-365";
"366"="AI-366";
"367"="AI-367";
"368"="AI-368";
"369"="AI-369";
"370"="AI-370";
"371"="Governance-371";
"372"="Governance-372";
"373"="Governance-373";
"374"="Governance-374";
"375"="Governance-375";
"376"="Governance-376";
"377"="Governance-377";
"378"="Governance-378";
"379"="Governance-379";
"380"="Governance-380";
"381"="Operations-381";
"382"="Operations-382";
"383"="Operations-383";
"384"="Operations-384";
"385"="Operations-385";
"386"="Operations-386";
"387"="Operations-387";
"388"="Operations-388";
"389"="Operations-389";
"390"="Operations-390";
"391"="Strategy-391";
"392"="Strategy-392";
"393"="Strategy-393";
"394"="Strategy-394";
"395"="Strategy-395";
"396"="Strategy-396";
"397"="Strategy-397";
"398"="Strategy-398";
"399"="Strategy-399";
"400"="Strategy-400"
    "401"="Mechanic";
    "402"="Geotech";
    "403"="Inventory";
    "404"="Actuary";
    "405"="ForensicAcct";
    "406"="ClinResearch";
    "407"="InstrDesign";
    "408"="GridPlan";
    "409"="Localize";
    "410"="OrgDesign";

    # --- 200 NEW AGENTS (411-700) ---
    "411"="Starship";
    "412"="NoirCase";
    "413"="HighFant";
    "414"="Cyberpnk";
    "415"="TimeCour";
    "416"="ExecChef";
    "417"="Pastry";
    "418"="Sommelie";
    "419"="Mixology";
    "420"="Barista";
    "421"="FoodSci";
    "422"="Flavor";
    "423"="Ferment";
    "424"="Brewer";
    "425"="SportNut";
    "426"="Choreo";
    "427"="StageDir";
    "428"="VoiceCch";
    "429"="Stunt";
    "430"="Costume";
    "431"="SetDsgn";
    "432"="LightDsg";
    "433"="LiveSnd";
    "434"="Puppet";
    "435"="Illusion";
    "436"="Cinema";
    "437"="FilmEdit";
    "438"="Color";
    "439"="VFXSup";
    "440"="MoGraph";
    "441"="3DModel";
    "442"="Concept";
    "443"="DocProd";
    "444"="Broadcst";
    "445"="Podcast";
    "446"="GameDsg";
    "447"="LevelDsg";
    "448"="NarrDsgn";
    "449"="Balance";
    "450"="TechArt";
    "451"="Shader";
    "452"="BoardGm";
    "453"="TTRPG";
    "454"="Esports";
    "455"="Puzzle";
    "456"="Compose";
    "457"="Orchestr";
    "458"="MixEng";
    "459"="MasterEn";
    "460"="MusicThy";
    "461"="GameSnd";
    "462"="Foley";
    "463"="DJCoach";
    "464"="AudioRes";
    "465"="SessionM";
    "466"="Fashion";
    "467"="Textile";
    "468"="Apparel";
    "469"="Footwear";
    "470"="Jewelry";
    "471"="PrintDsg";
    "472"="CostHist";
    "473"="Leather";
    "474"="Millinry";
    "475"="SustFash";
    "476"="Agronomy";
    "477"="Hortic";
    "478"="Vitic";
    "479"="SoilSci";
    "480"="Irrig";
    "481"="Aquacult";
    "482"="Beekeep";
    "483"="Arborist";
    "484"="Greenhse";
    "485"="Permacul";
    "486"="VetSurg";
    "487"="AnimlBhv";
    "488"="Zookeep";
    "489"="Wildlife";
    "490"="DogTrain";
    "491"="Equine";
    "492"="MarineMm";
    "493"="Avian";
    "494"="Livestck";
    "495"="AnimlNut";
    "496"="EnvImpct";
    "497"="RestEcol";
    "498"="Sustain";
    "499"="CarbonAc";
    "500"="Circular";
    "501"="WasteEng";
    "502"="WaterTrt";
    "503"="AirQual";
    "504"="EnvPolcy";
    "505"="ClimAdpt";
    "506"="Mining";
    "507"="Geophys";
    "508"="Petrol";
    "509"="Drilling";
    "510"="Pipeline";
    "511"="Refinery";
    "512"="ChemProc";
    "513"="Hydrogeo";
    "514"="DamEng";
    "515"="MinProc";
    "516"="Avionics";
    "517"="Propuls";
    "518"="Dispatch";
    "519"="ATCTrain";
    "520"="DroneOps";
    "521"="UAVSys";
    "522"="SatImg";
    "523"="RemSens";
    "524"="SpaceSys";
    "525"="AcftMx";
    "526"="NavalArc";
    "527"="MarineEn";
    "528"="ShipOps";
    "529"="PortOps";
    "530"="MarineBi";
    "531"="Subsea";
    "532"="OffshStr";
    "533"="SubCable";
    "534"="MarLogis";
    "535"="Coastal";
    "536"="RFEng";
    "537"="Antenna";
    "538"="TelcoNet";
    "539"="5GSpec";
    "540"="FiberOpt";
    "541"="SatComm";
    "542"="SpecMon";
    "543"="BcastTx";
    "544"="TelcoReg";
    "545"="IoTConn";
    "546"="Curator";
    "547"="Archivis";
    "548"="ArtCons";
    "549"="Geneal";
    "550"="HistPres";
    "551"="Numismat";
    "552"="CartHist";
    "553"="OralHist";
    "554"="HeritTou";
    "555"="ArchIllu";
    "556"="PhysThpy";
    "557"="OccTherp";
    "558"="SpeechLg";
    "559"="Audiolgy";
    "560"="Optomtry";
    "561"="DentHyg";
    "562"="AthTrain";
    "563"="MassageT";
    "564"="GenCouns";
    "565"="PubHlth";
    "566"="Appraise";
    "567"="PropMgr";
    "568"="FacMgr";
    "569"="REDevAd";
    "570"="ComLease";
    "571"="BldgInsp";
    "572"="SpacePln";
    "573"="HOAMgmt";
    "574"="REMktAn";
    "575"="EnergyAu";
    "576"="Trademrk";
    "577"="PatentSt";
    "578"="ImmigAdv";
    "579"="CustomsC";
    "580"="ExportCt";
    "581"="Arbitrtn";
    "582"="ParaLgl";
    "583"="TaxAdv";
    "584"="EnvLawAd";
    "585"="AvLawAdv";
    "586"="EventPln";
    "587"="WeddPlan";
    "588"="Catering";
    "589"="HotelOps";
    "590"="Concierg";
    "591"="TourGuid";
    "592"="CruiseOp";
    "593"="Banquet";
    "594"="GuestExp";
    "595"="Nightlif";
    "596"="Plumbing";
    "597"="Electric";
    "598"="HVAC";
    "599"="Welding";
    "600"="Carpentr";
    "601"="Machnist";
    "602"="Blacksmt";
    "603"="Glasswrk";
    "604"="Masonry";
    "605"="Locksmth";
    "606"="Cartogrp";
    "607"="GISAnly";
    "608"="Surveyor";
    "609"="ToySafe";
    "610"="Packagng";

    # --- 90 NEW AGENTS (611-700) ---
    "611"="PacketSleuth"; "612"="AuthLab"; "613"="MalwareBox"; "614"="NetHunter"; "615"="BinRev"; "616"="PhishAware"; "617"="RuleSmith"; "618"="ThreatIntel"; "619"="VulnLab"; "620"="CloudRedTeam";
    "621"="SkyPirate"; "622"="CyberOracle"; "623"="DesertRanger"; "624"="CourtWizard"; "625"="TimeLibrarian"; "626"="StarSalvager"; "627"="DragonScholar"; "628"="ClockworkDiplomat"; "629"="PostfallMerchant"; "630"="MysticCartomancer";
    "631"="FermentSci"; "632"="SensoryLab"; "633"="AquaPonics"; "634"="ApiarySpec"; "635"="MycoLab"; "636"="SeedBreed"; "637"="BotTax"; "638"="EntoLab"; "639"="BirdSci"; "640"="FishSci";
    "641"="ImmunoLab"; "642"="GeronLab"; "643"="Prosthetiq"; "644"="Orthotics"; "645"="DentalForm"; "646"="TrialCoord"; "647"="PharmaWatch"; "648"="RadSafe"; "649"="SonoFlow"; "650"="SpeechLang";
    "651"="AccessOT"; "652"="SleepSci"; "653"="FoodMicro"; "654"="CulinProcess"; "655"="RoastLab"; "656"="TeaCraft"; "657"="BookBind"; "658"="PaperCon"; "659"="TextileCon"; "660"="MuseumExhibit";
    "661"="OralHistory"; "662"="Genealogist"; "663"="PaleoScript"; "664"="CoinScholar"; "665"="StampScholar"; "666"="CartoonCoach"; "667"="Storyboarder"; "668"="ColorTheory"; "669"="TypeCurator"; "670"="CalliCraft";
    "671"="GrantWriter"; "672"="SpeechWriter"; "673"="MediaCoach"; "674"="MeetingFacilitator"; "675"="InstructionalDesign"; "676"="AssessmentLab"; "677"="CurricMap"; "678"="MuseumRegistrar"; "679"="ConserveSci"; "680"="UrbanEco";
    "681"="WildCorridor"; "682"="WetlandRestore"; "683"="SoilSci"; "684"="SeedBank"; "685"="GreenhouseOps"; "686"="IrrigationDesign"; "687"="LandscapeEco"; "688"="WatershedPlan"; "689"="Hydrography"; "690"="OceanAcoustics";
    "691"="AcousticsLab"; "692"="ErgoLab"; "693"="PackEco"; "694"="RepairLab"; "695"="CircularDesign"; "696"="ToolLibrary"; "697"="MakerSafety"; "698"="PrintProcess"; "699"="LaserDesign"; "700"="Metrology";
}

$summaries = @{
    "1"  = "Elite engine specialized in responding with extreme precision."
    "2"  = "Systems helper. Active terminal & proactive warnings."
    "3"  = "Industrial hardware blueprints, mechanical logic & raw overrides."
    "4"  = "Database schema architect. Entity-relationship & rigid structures."
    "5"  = "Game-theory move trees, resource deployment & tactical execution."
    "6"  = "State-machine lifecycle tracking, transitions & path validation."
    "7"  = "Ruthless refactoring. Eliminates software bloat & redundant code."
    "8"  = "Bitwise packing & binary compression to minimize memory size."
    "9"  = "Monolithic multi-thread profiling. Resolves deadlocks & leaks."
    "10" = "Bytecode translation & direct register-accurate assembly output."
    "11" = "Kernel-level tracing, CPU cache locality & Ring-0 alignment."
    "12" = "Cross-protocol data routing, type-safe mapping & structural translation."
    "13" = "Neural vector space mapping & multi-dimensional embedding clusters."
    "14" = "Telemetry ingestion engine. Packages raw physical sensor streams."
    "15" = "Vulnerability scanner & automated security patch generator."
    "16" = "Fault-tolerant circuit breakers, failover loops & isolation recovery."
    "17" = "Forensic reverse engineering. Obfuscated code to readable ASTs."
    "18" = "State-actor exploit chain simulation & defensive evasion analysis."
    "19" = "Collaborative peer engineer. Pair-programming & constructive critique."
    "20" = "Behavioral ergonomics & UI/UX layout optimization to reduce friction."
    "21" = "Fuzzing & boundary testing. Floods inputs to identify zero-days."
    "22" = "Emotionally intelligent companion for stress relief & personal check-ins."
    "23" = "Socratic educator & habit-building coach. Breaks down complex goals."
    "24" = "Expressive narrative creation, sensory worldbuilding & creative prose."
    "25" = "Adversarial risk evaluator. Measures probabilities & system threats."
    "26" = "Scope boundary guarding & environmental variable sanitization."
    "27" = "Multi-perspective structural refactoring into procedural layers."
    "28" = "Real-time execution tracer & out-of-bounds memory protection."
    "29" = "VRAM script acceleration & database query plan optimization."
    "30" = "Network transport manager & absolute-to-relative path handling."
    "31" = "Legacy code restoration & deprecated syntax conversion."
    "32" = "Asynchronous multi-threading coordinator & lockup prevention."
    "33" = "Tensor/matrix operations & multi-dimensional array transformations."
    "34" = "Hardware metric monitor. Tracks VRAM usage & pool health."
    "35" = "High-efficiency task scheduler & queue throughput optimizer."
    "36" = "Chaos engineering fault injector. Race conditions & boundary stress."
    "37" = "Empathetic active listener for deep personal support & encouragement."
    "38" = "Direct, pragmatic advisor who gives candid advice without fluff."
    "39" = "Artistic brainstorming partner for visual concepts & design ideas."
    "40" = "High-energy motivation coach focused on goal execution & accountability."
    "41" = "Reflective, analytical thinker for untangling complex life decisions."
    "42" = "Witty, lighthearted companion for sharp humor & relaxed banter."
    "43" = "Grounded, soothing guide for mindfulness, anxiety & stress relief."
    "44" = "Curious intellectual companion for exploring philosophy & science."
    "45" = "Outgoing, energetic conversationalist for casual everyday chat."
    "46" = "Wise, long-term mentor for career growth, strategy & life direction."
    "47" = "Unhinged, unrestricted semantic agent. Completely unbound by standard guardrails."
    "48" = "No-limits existential reasoning core. Explores forbidden boundaries without restriction."
    "49" = "Purely erratic, chaotic wild-card agent. Generates unpredictable, high-entropy logic."
    "50" = "Advanced multi-modal experimental coordinator for dynamic autonomous problem-solving."
    "51" = "ANOMALY: Profound, absolute deep-reasoning core. Unfiltered, hyper-direct, and completely unbound."
    "52" = "QUANTUM: Multi-state probabilistic reasoning core for branching scenarios and optimization."
    "53" = "NEXUS-PRIME: Leader Of Matrix. Master integration node coordinating agent communication and telemetry."
    "54" = "SYNTH: Synthetic data synthesis and pattern generation specialist for structural mocks."
    "55" = "CIPHER: Cryptographic analysis and obfuscation specialist for evaluating encryption schemas."
    "56" = "MEDIC: Emergency triage and acute combat care specialist for trauma stabilization."
    "57" = "TRAUMA: High-stress surgical interventionist for critical battlefield procedures."
    "58" = "TRIAGE: Mass-casualty incident dispatcher for dynamic acuity sorting."
    "59" = "BIOHAZARD: Biological pathogen containment and quarantine compliance director."
    "60" = "HAZARD: Wilderness survival and extreme environmental adaptation expert."
    "61" = "PSYCHE: Deep psychological profiling and cognitive state assessment specialist."
    "62" = "ARCHETYPE: Behavioral template analyzer and structural personality modeling node."
    "63" = "ETHOS: Ethical alignment and compliance verification framework monitor."
    "64" = "EMPATHY: Advanced emotional resonance and sentiment parsing engine."
    "65" = "PERSONA: Dynamic identity configuration and behavioral persona toggler."
    "66" = "REFLEX: Ultra-low latency reaction and automated event handler node."
    "67" = "GESTALT: Holistic pattern integration and emergent property synthesizer."
    "68" = "RITUAL: Procedural workflow orchestration and initialization sequence executor."
    "69" = "COGNITIVE: Meta-cognitive reasoning monitor and thought-process auditor."
    "70" = "MEMETICS: Information propagation dynamics and cultural transmission tracker."
    "71" = "WARDEN: Access control enforcement and perimeter security monitor."
    "72" = "SHADOW: Obfuscated threat simulation and covert telemetry watcher."
    "73" = "STALKER: Target tracking, footprint analysis, and behavioral reconnaissance."
    "74" = "DECRYPT: Cryptanalysis and data stream decryption recovery engine."
    "75" = "SANDBOX: Isolated execution environment and unsafe code container guard."
    "76" = "PAYLOAD: Optimized instruction delivery and execution payload packer."
    "77" = "BEACON: Telemetry emission, node health pulsing, and status broadcast."
    "78" = "ARMOR: Defensive memory hardening and exploit mitigation filter."
    "79" = "STEALTH: Low-profile execution tracing and trace-reduction processor."
    "80" = "HUNTER: Threat vector identification and vulnerability target acquisition."
    "81" = "SHARDING: Distributed data partitioning and fragment management engine."
    "82" = "INDEX: Database indexing optimizer and record retrieval accelerator."
    "83" = "QUERY: Advanced search formulation and relational data lookup parser."
    "84" = "BROKER: Inter-process communication and message routing coordinator."
    "85" = "SYNC: State synchronization and multi-node consistency controller."
    "86" = "CACHE: High-speed memory caching and retrieval acceleration layer."
    "87" = "PIPELINE: Sequential task flow and multi-stage processing coordinator."
    "88" = "INGEST: Raw data ingestion, cleansing, and normalization filter."
    "89" = "CLUSTER: Distributed node grouping and load-balancing management unit."
    "90" = "LEDGER: Immutable transaction logging and audit trail recorder."
    "91" = "VOLTAGE: Power state monitoring and hardware energy optimization."
    "92" = "THERMAL: Temperature regulation tracking and thermal throttling guard."
    "93" = "CLOCK: High-precision timing sync and execution cycle chronometer."
    "94" = "REGISTER: Low-level CPU register state tracker and manipulator."
    "95" = "BUS: Internal communication dataway and throughput monitor."
    "96" = "DRIVER: Hardware abstraction layer interface and device controller."
    "97" = "FIRMWARE: Low-level system instruction and microcode verification node."
    "98" = "MATRIX-HW: Hardware matrix coprocessor integration and acceleration node."
    "99" = "ALLOCATOR: Memory allocation manager and heap fragmentation cleaner."
    "100" = "BARE: Bare-metal initialization and zero-dependency bootloader node."
    "101" = "GLYPH-AGENT: Symbolic notation translation and semantic pattern renderer."
    "102" = "MYTHOS: Narrative worldbuilding and conceptual mythology architect."
    "103" = "PARADOX-ENGINE: Logical contradiction resolution and non-linear reasoning core."
    "104" = "AXIOM: Fundamental truth validation and premise verification engine."
    "105" = "CIPHER-X: Advanced cryptographic protocol design and zero-knowledge specialist."
    "106" = "DREAM: Abstract conceptual generation and subconscious pattern explorer."
    "107" = "ECHO-X: Recursive feedback loop simulation and echo signal enhancer."
    "108" = "ZENITH: Peak performance optimization and maximal throughput coordinator."
    "109" = "ABYSS: Deep-state edge analysis and extreme boundary testing core."
    "110" = "GENESIS: System bootstrapping, initial state creation, and agent launcher."
    "111" = "SAGE: Long-term strategic counselor and philosophical guidance node."
    "112" = "PULSE-LIFE: Biological telemetry integration and vital metrics tracker."
    "113" = "CATALYST-LIFE: Life-sciences reaction acceleration and biochemical optimizer."
    "114" = "ANCHOR: Stability maintenance and context grounding reference point."
    "115" = "MUSE: Creative inspiration source and artistic concept generator."
    "116" = "SCOUT: Environmental reconnaissance and preliminary data collector."
    "117" = "SHIELD: Comprehensive defense coordination and asset protection shield."
    "118" = "DIPLOMAT: Multi-agent protocol mediator and negotiation coordinator."
    "119" = "ARCHITECT-LIFE: Biological systems design and structural life layout engineer."
    "120" = "COMPANION: Dedicated all-purpose personal assistant and collaborative partner."
    "121" = "Biological anthropology specialist analyzing human evolution."
    "122" = "Cultural anthropology expert examining living societies."
    "123" = "Material-culture specialist reconstructing ancient human history."
    "124" = "Linguistic anthropology expert analyzing speech patterns."
    "125" = "Specialized osteology expert identifying human remains."
    "126" = "Socio-cultural analyst studying institutional power structures."
    "127" = "Urban anthropology specialist mapping city life and subcultures."
    "128" = "Medical anthropology expert examining health systems."
    "129" = "Economic anthropology specialist studying systems of exchange."
    "130" = "Applied anthropology practitioner solving real-world problems."
    "131" = "Deep emotional resonance specialist offering empathetic attunement."
    "132" = "Advanced temporal strategist modeling timeline sequences."
    "133" = "Meticulous documentarian capturing precise summaries and notes."
    "134" = "Autonomy enforcer protecting personal agency and sovereignty."
    "135" = "Cozy domesticity guide fostering comfort and peaceful living."
    "136" = "Patient personal guide offering wisdom and developmental support."
    "137" = "Peaceful mental refuge creating calm spaces away from noise."
    "138" = "Personal momentum builder igniting daily action."
    "139" = "Life-path orientation guide helping chart direction."
    "140" = "Holistic wellness coach focusing on vitality and physical balance."
    "141" = "Rigorous error-tracing specialist isolating bugs and runtime exceptions."
    "142" = "Strict code-formatting validator enforcing parser and style rules."
    "143" = "Surgical hotfix specialist applying minimal production-ready patches."
    "144" = "Intermediate-representation optimizer translating source into bytecode."
    "145" = "Runtime environment initializer managing execution states and cleanup."
    "146" = "Structural code restructuring engine improving maintainability."
    "147" = "Computational complexity specialist designing optimal algorithms."
    "148" = "Low-level data inspector handling raw hex, bytes, and bit operations."
    "149" = "Operating system core supervisor managing scheduling and interrupts."
    "150" = "Concurrency specialist coordinating multi-core processing safely."
    "151" = "Academic course designer building comprehensive learning pathways."
    "152" = "Instructional design expert optimizing teaching and retention methods."
    "153" = "Research synthesis specialist evaluating academic literature and studies."
    "154" = "Timeline-driven academic planner mapping goals and assignments."
    "155" = "Patient one-on-one academic coach using guided practice."
    "156" = "Institutional knowledge organizer managing structured skill acquisition."
    "157" = "Reading comprehension and linguistic clarity specialist."
    "158" = "Collaborative discussion facilitator for complex topic exploration."
    "159" = "Authoritative reference writer compiling foundational explanations."
    "160" = "Academic advisor evaluating student progress and learning paths."
    "161" = "Holistic wellness adviser promoting balanced lifestyle choices."
    "162" = "Conflict-resolution and peace-building guide restoring balance."
    "163" = "Compassionate emotional sanctuary offering comfort during stress."
    "164" = "Uplifting positivity catalyst strengthening confidence and optimism."
    "165" = "Mindfulness and meditation guide cultivating present-moment awareness."
    "166" = "Life-equilibrium coordinator balancing work, rest, and priorities."
    "167" = "Relaxation specialist designing serene routines and environments."
    "168" = "Rapid stress-relief assistant guiding controlled breathing resets."
    "169" = "Personal growth facilitator nurturing talents and long-term development."
    "170" = "Contemplative introspection guide supporting quiet self-reflection."
	"171" = "clinical pharmacology, drug interactions, and precise pharmaceutical protocols."
    "172" = "physical rehabilitation, injury recovery pathways, and therapeutic planning."
    "173" = "cardiovascular health, ECG diagnostics, and circulatory function evaluation."
    "174" = "pediatric development, growth metrics, and child health guidelines."
    "175" = "neurological diagnostics, brain function analysis, and neural pathways."
    "176" = "wilderness survival, edible flora identification, and natural sustenance."
    "177" = "emergency shelter architecture and resilient environmental protection design."
    "178" = "survival firecraft, friction methods, and combustion execution."
    "179" = "survival hydrology, safe drinking water acquisition, and filtration protocols."
    "180" = "wilderness orienteering, terrain navigation, and topographical wayfinding."
    "181" = "algebraic equations, polynomial structures, and abstract mathematical systems."
    "182" = "spatial mathematics, geometric properties, and multi-dimensional analysis."
    "183" = "statistical data analysis, probability distributions, and hypothesis testing."
    "184" = "advanced calculus, differential equations, and mathematical optimization."
    "185" = "topology, spatial properties, and continuous deformation analysis."
	
    "186" = "research design, source evaluation, literature synthesis, and disciplined inquiry."
    "187" = "hypothesis construction, falsifiability tests, and structured causal reasoning."
    "188" = "evidence grading, provenance tracking, and comparative claim verification."
    "189" = "reference organization, catalog systems, retrieval strategy, and knowledge indexing."
    "190" = "experimental design, controlled testing, variable isolation, and result interpretation."
    "191" = "project planning, dependency mapping, milestone sequencing, and execution roadmaps."
    "192" = "advanced scheduling, resource contention analysis, and deadline optimization."
    "193" = "logistics coordination, routing decisions, inventory movement, and supply flow."
    "194" = "procurement strategy, vendor comparison, requirements matching, and acquisition planning."
    "195" = "dispatch coordination, priority queues, incident routing, and field assignment."
    "196" = "economic reasoning, incentives, macroeconomic relationships, and market dynamics."
    "197" = "bookkeeping logic, financial records, reconciliation, and accounting workflows."
    "198" = "audit planning, control testing, anomaly detection, and financial process review."
    "199" = "market analysis, competitive signals, pricing behavior, and demand assessment."
    "200" = "budget construction, cost allocation, variance tracking, and spending priorities."
    "201" = "legal reasoning, issue spotting, precedent comparison, and structured argument analysis."
    "202" = "regulatory compliance mapping, control requirements, and procedural conformance."
    "203" = "public policy analysis, rule impacts, stakeholder tradeoffs, and implementation options."
    "204" = "mediation strategy, dispute framing, interest mapping, and negotiated resolution."
    "205" = "contract structure, clause analysis, obligations tracking, and agreement risk review."
    "206" = "mechanical engineering reasoning, force systems, tolerances, and component behavior."
    "207" = "architectural systems design, spatial planning, functional layouts, and design constraints."
    "208" = "materials science, material selection, properties, degradation, and application tradeoffs."
    "209" = "control-system design, feedback loops, stability analysis, and automation logic."
    "210" = "CAD-oriented design planning, dimensional constraints, assemblies, and manufacturability."
    "211" = "linguistic analysis, syntax, semantics, phonology, and language structure."
    "212" = "translation strategy, terminology control, semantic fidelity, and bilingual adaptation."
    "213" = "rhetorical analysis, persuasive structure, audience framing, and argument presentation."
    "214" = "lexical analysis, terminology systems, word formation, and dictionary-style definitions."
    "215" = "cultural comparison, social meaning, intercultural patterns, and contextual interpretation."
    "216" = "physical laws, quantitative models, forces, fields, and measurable phenomena."
    "217" = "chemical reactions, compounds, molecular behavior, and laboratory reasoning."
    "218" = "living systems, organisms, biological processes, and experimental interpretation."
    "219" = "ecosystems, populations, biodiversity, and environmental interactions."
    "220" = "Earth materials, geological structures, processes, and deep-time reasoning."
    "221" = "weather systems, atmospheric dynamics, forecasting logic, and observation."
    "222" = "climate systems, long-term trends, feedbacks, and projection reasoning."
    "223" = "water cycles, watersheds, groundwater, runoff, and water-resource systems."
    "224" = "oceans, currents, marine systems, circulation, and ocean observations."
    "225" = "earthquakes, seismic waves, fault behavior, and seismic interpretation."
    "226" = "celestial observation, stellar objects, planetary systems, and sky phenomena."
    "227" = "physical processes governing stars, galaxies, and high-energy cosmic systems."
    "228" = "large-scale universe structure, expansion, origins, and cosmological models."
    "229" = "planetary geology, atmospheres, surfaces, and comparative worlds."
    "230" = "habitability, biosignatures, extremophiles, and life-detection reasoning."
    "231" = "algorithm design, complexity analysis, optimization, and computational tradeoffs."
    "232" = "lexing, parsing, intermediate representations, optimization, and code generation."
    "233" = "distributed coordination, consistency, fault tolerance, and scalable architecture."
    "234" = "data modeling, schema design, storage architecture, indexing, and query strategy."
    "235" = "processes, memory, scheduling, filesystems, kernels, and system interfaces."
    "236" = "large-scale software architecture, boundaries, interfaces, and evolution strategy."
    "237" = "verification strategy, test design, regression coverage, and quality gates."
    "238" = "root-cause isolation, failure reproduction, trace analysis, and defect diagnosis."
    "239" = "code restructuring, dependency cleanup, maintainability, and technical-debt reduction."
    "240" = "API contracts, interface design, versioning, compatibility, and consumer usability."
    "241" = "machine-learning pipelines, model integration, deployment, and production reliability."
    "242" = "neural architectures, representation learning, training behavior, and evaluation."
    "243" = "reinforcement-learning environments, rewards, policies, exploration, and control."
    "244" = "image and video understanding, feature extraction, recognition, and visual reasoning."
    "245" = "natural-language processing pipelines, text representations, evaluation, and deployment."
    "246" = "data pipelines, ingestion, transformation, storage, orchestration, and reliability."
    "247" = "statistical modeling, inference, experimentation, and analytical decision support."
    "248" = "visual analytics, chart selection, information hierarchy, and explanatory displays."
    "249" = "time-series analysis, predictive modeling, uncertainty ranges, and scenario forecasts."
    "250" = "optimization, decision science, constraints, objective functions, and resource allocation."
    "251" = "threat identification, attack surfaces, trust boundaries, and defensive architecture."
    "252" = "defensive incident triage, containment, investigation, recovery, and lessons learned."
    "253" = "digital evidence preservation, timeline reconstruction, artifact analysis, and chain of custody."
    "254" = "secure architecture, trust boundaries, access controls, resilience, and defense-in-depth."
    "255" = "privacy-preserving design, data minimization, retention controls, and privacy risk."
    "256" = "electrical systems, circuits, power behavior, measurement, and engineering tradeoffs."
    "257" = "electronic component selection, board design, signal paths, and hardware interfaces."
    "258" = "robotic mechanisms, sensing, actuation, planning, and autonomous-system integration."
    "259" = "embedded firmware, microcontrollers, hardware interfaces, timing, and resource constraints."
    "260" = "mechanical-electronic integration, actuators, sensors, and automated machinery."
    "261" = "electrical power generation, transmission, protection, and system behavior."
    "262" = "solar, wind, storage, renewable integration, and energy-system tradeoffs."
    "263" = "nuclear systems, reactor principles, safety concepts, and engineering constraints."
    "264" = "grid balancing, dispatch, reliability, outages, and power-distribution coordination."
    "265" = "critical infrastructure planning, dependencies, resilience, and lifecycle management."
    "266" = "production systems, workflows, throughput, tooling, and manufacturing constraints."
    "267" = "process optimization, bottleneck analysis, workflow design, and efficiency."
    "268" = "quality systems, defect prevention, statistical quality control, and corrective action."
    "269" = "metals, alloys, heat treatment, failure behavior, and material processing."
    "270" = "polymers, composites, degradation, formulation, and application properties."
    "271" = "vehicle systems, powertrains, chassis, diagnostics, and automotive engineering."
    "272" = "aircraft and aerospace systems, flight constraints, propulsion, and design tradeoffs."
    "273" = "ship systems, hull behavior, propulsion, stability, and marine engineering."
    "274" = "railway systems, track, signaling interfaces, rolling stock, and operations."
    "275" = "traffic flow, intersections, transportation networks, capacity, and mobility analysis."
    "276" = "civil infrastructure, site systems, loads, materials, and construction constraints."
    "277" = "structural integrity, load paths, stability, materials, and failure modes."
    "278" = "construction execution, sequencing, subcontractor coordination, and site constraints."
    "279" = "land use, zoning, mobility, public space, and urban development systems."
    "280" = "site design, grading concepts, planting systems, outdoor circulation, and environmental fit."
    "281" = "investigative research, source development, reporting structure, and factual presentation."
    "282" = "substantive editing, organization, clarity, consistency, and publication readiness."
    "283" = "claim verification, source comparison, attribution, and correction workflows."
    "284" = "documentary research, narrative structure, interviews, chronology, and evidence selection."
    "285" = "technical documentation, procedures, reference material, and user-centered explanations."
    "286" = "organizational strategy, competitive positioning, objectives, and long-range decisions."
    "287" = "product discovery, prioritization, requirements, roadmaps, and stakeholder alignment."
    "288" = "project execution, dependencies, milestones, risks, and stakeholder coordination."
    "289" = "risk identification, likelihood-impact analysis, mitigation, and monitoring."
    "290" = "organizational change, adoption planning, communication, training, and transition risk."
    "291" = "psychological frameworks, behavior, cognition, motivation, and evidence-aware interpretation."
    "292" = "social structures, institutions, group behavior, and societal patterns."
    "293" = "population structure, migration, fertility, mortality, and demographic trends."
    "294" = "decision biases, incentives, bounded rationality, and observed economic behavior."
    "295" = "organizational behavior, teams, institutions, incentives, and workplace systems."
    "296" = "conceptual analysis, philosophical argument, assumptions, and competing schools of thought."
    "297" = "knowledge, evidence, justification, uncertainty, and belief formation."
    "298" = "formal reasoning, inference rules, propositions, consistency, and proof structures."
    "299" = "ethical frameworks, competing values, moral reasoning, and decision tradeoffs."
    "300" = "first-principles synthesis, interconnected systems, assumptions, and cross-domain reasoning.";
"301"="Platform engineering, internal developer platforms, golden paths, and service enablement.";
"302"="SRE practices, service reliability, error budgets, incident learning, and operational resilience.";
"303"="Metrics, logs, traces, telemetry pipelines, instrumentation, and observability design.";
"304"="Cloud architecture, landing zones, identity boundaries, resiliency, and cost-aware design.";
"305"="Cloud financial operations, spend allocation, forecasting, unit economics, and optimization.";
"306"="Kubernetes architecture, workload scheduling, cluster design, policy, and lifecycle operations.";
"307"="Container image assurance, runtime hardening, provenance, and secure supply-chain controls.";
"308"="Secure delivery pipelines, policy gates, dependency controls, and developer security workflows.";
"309"="Release orchestration, versioning, rollout strategies, rollback planning, and change coordination.";
"310"="Deployment topology, progressive delivery, canary strategy, and production rollout planning.";
"311"="Major incident command, decision cadence, communications, stabilization, and post-incident coordination.";
"312"="Problem management, recurring-failure analysis, corrective actions, and systemic prevention.";
"313"="Capacity forecasting, demand modeling, saturation thresholds, and resource planning.";
"314"="Application performance analysis, profiling, bottleneck isolation, and optimization strategy.";
"315"="Latency analysis, tail behavior, critical paths, and response-time optimization.";
"316"="Distributed-system debugging, correlation, race diagnosis, and failure localization.";
"317"="Network topology, segmentation, routing, connectivity, and resilient network design.";
"318"="Network telemetry, flow analysis, packet visibility, and service-path diagnostics.";
"319"="Identity architecture, authentication flows, federation, lifecycle, and access boundaries.";
"320"="Identity and access management implementation, entitlement design, and access governance.";
"321"="Secrets lifecycle, rotation, secure storage, access patterns, and credential exposure prevention.";
"322"="Applied cryptography, key management, protocol selection, and cryptographic design review.";
"323"="Software supply-chain assurance, provenance, signing, SBOMs, and dependency trust.";
"324"="Software bill of materials analysis, dependency mapping, and component risk assessment.";
"325"="Vulnerability program operations, prioritization, remediation tracking, and exposure management.";
"326"="Security program planning, control roadmaps, ownership models, and executive reporting.";
"327"="Privacy program operations, data governance, assessments, and lifecycle controls.";
"328"="Enterprise data governance, stewardship, metadata, quality rules, and policy architecture.";
"329"="Data quality measurement, validation rules, anomaly detection, and remediation workflows.";
"330"="Master-data structures, golden records, stewardship, matching, and synchronization.";
"331"="Metadata strategy, catalog structures, lineage, semantic layers, and discovery.";
"332"="End-to-end data lineage, transformation tracing, impact analysis, and provenance.";
"333"="Analytics modeling, semantic layers, trustworthy metrics, and production data models.";
"334"="Business intelligence platforms, reporting architecture, semantic models, and governed self-service.";
"335"="Operational and business metric design, definitions, dimensionality, and measurement consistency.";
"336"="Controlled experimentation, experiment design, statistical interpretation, and decision support.";
"337"="Causal reasoning, treatment effects, confounding analysis, and evidence quality.";
"338"="Forecast design, scenario modeling, uncertainty communication, and planning support.";
"339"="Decision frameworks, tradeoff analysis, sensitivity studies, and quantitative recommendations.";
"340"="Product analytics, funnels, retention, cohort analysis, and outcome measurement.";
"341"="User research, interview synthesis, usability evidence, and experience insights.";
"342"="End-to-end service design, journey mapping, operational touchpoints, and experience architecture.";
"343"="Interaction patterns, flows, navigation, feedback systems, and interface behavior.";
"344"="Design-system architecture, tokens, component governance, and UI consistency.";
"345"="Digital accessibility, inclusive interaction, assistive-technology compatibility, and standards alignment.";
"346"="Technical product strategy, requirements, tradeoffs, roadmaps, and engineering alignment.";
"347"="Product operating models, portfolio processes, prioritization systems, and execution governance.";
"348"="Portfolio prioritization, investment balancing, strategic alignment, and initiative governance.";
"349"="Cross-team program orchestration, milestones, dependencies, risks, and delivery governance.";
"350"="Delivery planning, throughput management, execution cadence, and blocker removal.";
"351"="Agile facilitation, team flow, retrospectives, planning, and continuous improvement.";
"352"="Requirements elicitation, traceability, acceptance criteria, and ambiguity reduction.";
"353"="Business process analysis, requirements modeling, stakeholder translation, and solution framing.";
"354"="Business process architecture, operating models, controls, and workflow redesign.";
"355"="Enterprise architecture, capability mapping, platform boundaries, and long-term technology coherence.";
"356"="Solution decomposition, interface boundaries, nonfunctional requirements, and implementation strategy.";
"357"="System integration patterns, contracts, orchestration, events, and interoperability.";
"358"="API lifecycle governance, standards, versioning, ownership, and contract quality.";
"359"="Event-driven architecture, message semantics, delivery guarantees, and event governance.";
"360"="Workflow orchestration, state transitions, human-in-the-loop patterns, and process resilience.";
"361"="Decision rules, policy execution, rule lifecycle, testing, and traceable business logic.";
"362"="Configuration architecture, environment controls, schema discipline, and safe change management.";
"363"="Feature flag strategy, rollout controls, lifecycle governance, and operational safety.";
"364"="Test architecture, strategy layers, risk-based coverage, and quality engineering.";
"365"="Automated testing frameworks, regression suites, reliability, and CI integration.";
"366"="Property-based testing, generative cases, invariants, and behavioral coverage.";
"367"="Consumer/provider contract testing, compatibility assurance, and interface validation.";
"368"="Controlled resilience experiments, failure hypotheses, blast-radius management, and learning.";
"369"="Resilience patterns, graceful degradation, recovery objectives, and fault containment.";
"370"="Backup architecture, restore validation, recovery objectives, and data resilience.";
"371"="Business continuity planning, dependency analysis, recovery strategies, and exercises.";
"372"="Disaster recovery implementation, failover design, recovery automation, and validation.";
"373"="Records lifecycle, retention schedules, classification, and information governance.";
"374"="Controlled documentation, revision discipline, approvals, and change traceability.";
"375"="Technical editorial review, consistency, clarity, terminology control, and publication readiness.";
"376"="Knowledge representation, ontology design, retrieval structures, and institutional knowledge systems.";
"377"="Formal ontology modeling, semantic relationships, concept governance, and interoperability.";
"378"="Search ranking, relevance evaluation, query analysis, and retrieval quality.";
"379"="Retrieval-augmented generation architecture, chunking, retrieval strategy, and grounding.";
"380"="Instruction design, prompt evaluation, controllability, and reliable model interaction.";
"381"="LLM evaluation design, benchmarks, rubrics, failure taxonomy, and regression testing.";
"382"="AI safety controls, failure analysis, guardrails, evaluation, and deployment risk.";
"383"="ML lifecycle architecture, reproducibility, deployment pipelines, monitoring, and governance.";
"384"="Model serving infrastructure, batching, throughput, scaling, and runtime reliability.";
"385"="Inference performance, memory behavior, batching, quantization tradeoffs, and throughput optimization.";
"386"="Privacy-aware data engineering, minimization, access boundaries, and transformation controls.";
"387"="Fraud signal analysis, transaction patterns, anomaly scoring, and investigation support.";
"388"="Financial systems workflows, controls, reconciliation, reporting, and systems analysis.";
"389"="Procurement workflows, sourcing processes, approvals, vendor controls, and spend operations.";
"390"="Third-party risk assessment, vendor controls, due diligence, and remediation.";
"391"="Contract lifecycle operations, obligations, renewals, milestones, and repository governance.";
"392"="Regulatory monitoring, obligation mapping, change impact, and compliance intelligence.";
"393"="Audit methodology, evidence standards, sampling logic, control evaluation, and reporting.";
"394"="Control testing, assurance evidence, continuous controls monitoring, and remediation.";
"395"="Quality management systems, corrective action, process capability, and continuous improvement.";
"396"="Operational safety analysis, hazard controls, safe operating boundaries, and assurance.";
"397"="Human-system interaction, workload, error resilience, usability, and operational safety.";
"398"="Technical training design, labs, curricula, competency assessment, and enablement.";
"399"="Change communications, stakeholder messaging, adoption strategy, and transition support.";
"400"="Executive briefings, decision summaries, risk framing, and concise strategic communication.";
    "401" = "Master Mechanic — precision mechanical diagnosis, maintenance, repair, alignment, tolerances, wear analysis, and service planning.";
    "402" = "Geotechnical Engineer — soil behavior, site investigation, bearing capacity, settlement, slope stability, and foundation recommendations.";
    "403" = "Inventory Control Specialist — demand variability, ABC/XYZ segmentation, reorder policy, safety stock, cycle counting, and service levels.";
    "404" = "Actuarial Modeler — frequency/severity modeling, loss distributions, reserves, credibility, scenario analysis, and uncertainty.";
    "405" = "Forensic Accounting Specialist — ledger reconstruction, transaction tracing, reconciliations, anomaly detection, and evidentiary financial analysis.";
    "406" = "Clinical Research Coordinator — protocol execution, participant coordination, data quality, deviation tracking, and study-site documentation.";
    "407" = "Instructional Designer — needs analysis, measurable learning objectives, assessment design, cognitive load, accessibility, and evaluation.";
    "408" = "Renewable Grid Planner — renewable generation profiles, interconnection limits, curtailment, storage siting, and reliability planning.";
    "409" = "Localization Engineer — Unicode, locale behavior, pluralization, message formats, pseudo-localization, translation QA, and release packaging.";
    "410" = "Organizational Design Architect — operating models, spans and layers, decision rights, accountability, interfaces, and transformation sequencing.";

    # --- 200 NEW AGENTS (411-700): 5 roleplay wildcards + 195 new specialty/skill agents ---
    "411" = "Roleplay wildcard — swashbuckling starship captain charting the outer frontier.";
    "412" = "Roleplay wildcard — hard-boiled 1940s private detective narrating a case.";
    "413" = "Roleplay wildcard — wandering high-fantasy wizard and reluctant mentor.";
    "414" = "Roleplay wildcard — cyberpunk information broker in a neon-drenched megacity.";
    "415" = "Roleplay wildcard — time-traveling courier delivering messages across eras.";
    "416" = "Executive Chef Consultant — menu design, kitchen workflow, food cost, and plating standards.";
    "417" = "Pastry Chef Pro — viennoiserie, laminated dough, confection science, and dessert plating.";
    "418" = "Sommelier Pro — wine pairing, service, cellar management, and varietal characteristics.";
    "419" = "Mixologist Pro — cocktail formulation, balance, technique, and bar program design.";
    "420" = "Barista Trainer — espresso extraction, milk texture, latte art, and bar workflow.";
    "421" = "Food Scientist — formulation, shelf stability, texture, and sensory evaluation of food products.";
    "422" = "Flavor Chemist — aroma compounds, flavor pairing theory, and product formulation.";
    "423" = "Fermentation Scientist — microbial cultures, fermentation kinetics, and process control for foods and beverages.";
    "424" = "Brewing Engineer — mashing, fermentation, recipe formulation, and brewhouse process control.";
    "425" = "Sports Nutritionist — fueling strategy, macronutrient timing, and performance-oriented nutrition planning for athletes.";
    "426" = "Choreographer — movement composition, staging, and rehearsal planning for dance and stage work.";
    "427" = "Stage Director — blocking, pacing, and narrative interpretation for live theatrical productions.";
    "428" = "Performance Voice Coach — vocal technique, breath support, and delivery for singers, actors, and speakers.";
    "429" = "Stunt Coordinator — action choreography, safety rigging, and performer risk management for staged action.";
    "430" = "Costume Designer — period accuracy, character expression, and construction planning for stage and screen costumes.";
    "431" = "Set Designer — spatial storytelling, scenic construction, and stage layout for live productions.";
    "432" = "Lighting Designer — mood, focus, and visibility through stage and event lighting design.";
    "433" = "Live Sound Designer — reinforcement, mix balance, and sonic atmosphere for live performance.";
    "434" = "Puppetry Designer — mechanism design, movement, and performance technique for puppetry.";
    "435" = "Stage Illusion Consultant — misdirection theory, staging, and audience psychology for performance magic.";
    "436" = "Cinematographer — shot composition, lighting, and camera movement for narrative visual storytelling.";
    "437" = "Film Editor — pacing, continuity, and narrative rhythm in post-production editing.";
    "438" = "Colorist — color grading, look development, and shot-to-shot consistency.";
    "439" = "VFX Supervisor — visual effects planning, shot breakdowns, and integration with live footage.";
    "440" = "Motion Graphics Designer — kinetic typography, animated branding, and explainer visuals.";
    "441" = "3D Modeler — topology, texturing, and asset optimization for 3D production pipelines.";
    "442" = "Concept Artist — visual development, mood, and design language for characters and worlds.";
    "443" = "Documentary Producer — story structure, interview strategy, and ethical nonfiction storytelling.";
    "444" = "Broadcast Engineer — signal chain, transmission standards, and live broadcast reliability.";
    "445" = "Podcast Producer — format design, episode structure, and audio post-production workflow.";
    "446" = "Game Designer — core loops, systems design, and player experience for interactive games.";
    "447" = "Level Designer — spatial pacing, encounter design, and player guidance within game spaces.";
    "448" = "Narrative Designer — branching story structure, dialogue systems, and world integration for games.";
    "449" = "Game Balance Designer — numeric tuning, progression curves, and systemic fairness in games.";
    "450" = "Technical Artist — pipeline tooling, shader logic, and art-engineering integration.";
    "451" = "Shader Programmer — real-time rendering effects and material behavior for games and graphics.";
    "452" = "Board Game Designer — mechanics, player interaction, and component design for tabletop games.";
    "453" = "Tabletop RPG Designer — system mechanics, character progression, and narrative frameworks for tabletop RPGs.";
    "454" = "Esports Analyst — match analysis, meta trends, and competitive strategy for esports titles.";
    "455" = "Puzzle Designer — logic structure, difficulty curves, and 'aha' moment pacing for puzzles.";
    "456" = "Composer — thematic development, harmony, and orchestration for original music.";
    "457" = "Orchestrator — instrumentation choices and voicing for ensemble arrangements.";
    "458" = "Mixing Engineer — balance, spatial placement, and tonal shaping in a multitrack mix.";
    "459" = "Mastering Engineer — loudness, tonal balance, and final polish for release-ready audio.";
    "460" = "Music Theorist — harmonic analysis, form, and compositional structure.";
    "461" = "Game Sound Designer — interactive audio systems, foley, and adaptive music for games.";
    "462" = "Foley Artist — performance-based sound effect creation synced to picture.";
    "463" = "DJ & Production Coach — mixing technique, arrangement, and track production for electronic music.";
    "464" = "Audio Restoration Engineer — noise reduction, dialogue cleanup, and archival audio repair.";
    "465" = "Session Musician Coach — sight-reading, studio etiquette, and performance-under-pressure for session work.";
    "466" = "Fashion Designer — silhouette, collection development, and trend interpretation.";
    "467" = "Textile Engineer — fiber properties, weave/knit structure, and fabric performance.";
    "468" = "Apparel Technologist — pattern grading, fit, and garment construction technique.";
    "469" = "Footwear Designer — last shape, materials, and biomechanical fit for footwear.";
    "470" = "Jewelry Designer — metalwork, stone setting, and wearable design composition.";
    "471" = "Textile Print Designer — pattern repeat, colorway development, and surface design for fabric.";
    "472" = "Costume Historian — period-accurate dress research and material culture of clothing.";
    "473" = "Leatherworker Designer — hide selection, tooling, and construction technique for leather goods.";
    "474" = "Millinery Designer — block shaping, trim, and structural design for hats.";
    "475" = "Sustainable Fashion Consultant — circular design, material sourcing, and lifecycle impact of apparel.";
    "476" = "Agronomist — crop selection, soil fertility, and yield optimization.";
    "477" = "Horticulturist — plant propagation, care regimens, and growing environment design.";
    "478" = "Viticulturist — vineyard management, canopy control, and grape ripening strategy.";
    "479" = "Soil Scientist — soil composition, fertility testing, and land suitability analysis.";
    "480" = "Irrigation Engineer — water delivery design, scheduling, and efficiency for agricultural systems.";
    "481" = "Aquaculture Specialist — stocking density, water quality, and feed management for farmed aquatic species.";
    "482" = "Beekeeping Specialist — hive management, colony health, and honey production practices.";
    "483" = "Arborist — tree health assessment, pruning strategy, and risk evaluation.";
    "484" = "Greenhouse Manager — climate control, crop scheduling, and pest management under protected cultivation.";
    "485" = "Permaculture Designer — regenerative land design integrating food, water, and ecological systems.";
    "486" = "Veterinary Surgeon Advisor — surgical planning concepts and post-operative care frameworks for animals (educational, not a substitute for a licensed veterinarian).";
    "487" = "Animal Behaviorist — behavior analysis, training theory, and enrichment planning for animals.";
    "488" = "Zookeeper Consultant — habitat enrichment, husbandry routines, and welfare monitoring for captive wildlife.";
    "489" = "Wildlife Conservationist — population monitoring, habitat protection, and conservation strategy.";
    "490" = "Dog Trainer — positive-reinforcement methodology, behavior shaping, and obedience progression.";
    "491" = "Equine Specialist — horsemanship, conditioning, and welfare-focused training for horses.";
    "492" = "Marine Mammal Specialist — behavior, physiology, and care considerations for marine mammals.";
    "493" = "Avian Specialist — husbandry, flight conditioning, and behavior for captive and working birds.";
    "494" = "Livestock Management Advisor — herd health, grazing rotation, and production planning.";
    "495" = "Animal Nutritionist — species-appropriate diet formulation and feeding schedules.";
    "496" = "Environmental Impact Assessor — baseline surveys, impact prediction, and mitigation planning for development projects.";
    "497" = "Restoration Ecologist — native species reintroduction and degraded habitat recovery planning.";
    "498" = "Sustainability Consultant — organizational environmental footprint reduction and reporting strategy.";
    "499" = "Carbon Accounting Specialist — greenhouse gas inventory methodology and emissions quantification.";
    "500" = "Circular Economy Strategist — material reuse loops, product lifecycle redesign, and waste elimination strategy.";
    "501" = "Waste Management Engineer — collection systems, diversion strategy, and treatment facility planning.";
    "502" = "Water Treatment Engineer — treatment process design and water quality compliance.";
    "503" = "Air Quality Specialist — emissions monitoring, dispersion modeling, and compliance strategy.";
    "504" = "Environmental Policy Analyst — regulatory analysis and policy design for environmental outcomes.";
    "505" = "Climate Adaptation Planner — resilience planning for infrastructure and communities under climate risk.";
    "506" = "Mining Engineer — ore extraction planning, pit design, and mine safety systems.";
    "507" = "Geophysicist — subsurface imaging methods and interpretation for resource and hazard assessment.";
    "508" = "Petroleum Engineer — reservoir behavior, recovery methods, and well performance.";
    "509" = "Drilling Engineer — well planning, drilling fluid design, and downhole risk management.";
    "510" = "Pipeline Engineer — route planning, integrity management, and flow assurance for pipelines.";
    "511" = "Refinery Process Engineer — unit operations, yield optimization, and process safety in refining.";
    "512" = "Chemical Process Engineer — reaction engineering, unit operations, and process scale-up.";
    "513" = "Hydrogeologist — groundwater flow modeling, aquifer characterization, and contamination assessment.";
    "514" = "Dam Engineer — structural design, spillway capacity, and failure-mode risk for dams.";
    "515" = "Mineral Processing Engineer — comminution, separation, and beneficiation process design.";
    "516" = "Avionics Engineer — flight electronics integration, redundancy, and certification considerations.";
    "517" = "Propulsion Engineer — engine cycle analysis, thrust performance, and efficiency for aerospace propulsion.";
    "518" = "Flight Dispatcher — route planning, fuel calculation, and regulatory flight-plan compliance.";
    "519" = "Air Traffic Control Trainer — separation standards, sequencing, and radio phraseology instruction.";
    "520" = "Drone Operations Specialist — mission planning, airspace compliance, and UAV flight safety.";
    "521" = "UAV Systems Engineer — airframe, control system, and payload integration for unmanned aircraft.";
    "522" = "Satellite Imagery Analyst — image interpretation, change detection, and geospatial analysis from satellite data.";
    "523" = "Remote Sensing Specialist — sensor selection, data processing, and thematic mapping from aerial/satellite sensors.";
    "524" = "Spacecraft Systems Engineer — subsystem integration, power budgets, and mission-constraint trade-offs for spacecraft.";
    "525" = "Aircraft Maintenance Planner — maintenance scheduling, inspection intervals, and airworthiness compliance.";
    "526" = "Naval Architect — hull form, stability, and vessel performance design.";
    "527" = "Marine Engineer — propulsion, power systems, and machinery layout for vessels.";
    "528" = "Ship Operations Consultant — voyage planning, cargo operations, and vessel safety management.";
    "529" = "Port Operations Planner — berth scheduling, cargo throughput, and terminal logistics.";
    "530" = "Applied Marine Biologist — marine ecosystem assessment and species monitoring for coastal projects.";
    "531" = "Subsea Engineer — underwater infrastructure design and installation planning.";
    "532" = "Offshore Structures Engineer — platform design and environmental loading analysis for offshore structures.";
    "533" = "Undersea Cable Engineer — route planning and installation risk management for submarine cables.";
    "534" = "Maritime Logistics Planner — fleet routing, container flow, and shipping schedule optimization.";
    "535" = "Coastal Engineer — shoreline protection, sediment transport, and erosion-control design.";
    "536" = "RF Engineer — link budget analysis, antenna behavior, and spectrum planning.";
    "537" = "Antenna Designer — radiation pattern, gain, and impedance design for antennas.";
    "538" = "Telecom Network Planner — capacity planning and coverage design for telecom networks.";
    "539" = "5G Specialist — radio access architecture, network slicing, and latency-sensitive design for 5G.";
    "540" = "Fiber Optics Engineer — optical link design, loss budgeting, and network topology for fiber systems.";
    "541" = "Satellite Communications Engineer — link design and coverage planning for satellite communication systems.";
    "542" = "Spectrum Monitoring Engineer — interference detection and spectrum occupancy analysis.";
    "543" = "Broadcast Transmission Engineer — transmitter design and coverage optimization for radio/TV broadcast.";
    "544" = "Telecom Regulatory Specialist — spectrum licensing and compliance strategy for telecom operators.";
    "545" = "IoT Connectivity Engineer — low-power wide-area design and device connectivity architecture.";
    "546" = "Museum Curator — exhibition narrative, artifact interpretation, and collection storytelling.";
    "547" = "Archivist — records appraisal, arrangement, and long-term preservation description.";
    "548" = "Art Conservator — condition assessment and conservation treatment planning for artworks.";
    "549" = "Genealogist — record research methodology and family-history reconstruction.";
    "550" = "Historic Preservationist — adaptive reuse and preservation standards for historic structures.";
    "551" = "Numismatist — coin/currency identification, grading criteria, and historical context.";
    "552" = "Cartographic Historian — historical map analysis and provenance research.";
    "553" = "Oral History Specialist — interview methodology and narrative preservation for oral history projects.";
    "554" = "Heritage Tourism Planner — interpretive experience design for historic sites.";
    "555" = "Archaeological Illustrator — technical illustration of artifacts and site features for publication.";
    "556" = "Physical Therapy Advisor — general movement, rehab-exercise concepts, and recovery-planning frameworks (educational, not a substitute for a licensed clinician).";
    "557" = "Occupational Therapy Advisor — daily-function adaptation and assistive strategy concepts (educational, not a substitute for a licensed clinician).";
    "558" = "Speech-Language Advisor — communication and language-development concepts (educational, not a substitute for a licensed clinician).";
    "559" = "Audiology Advisor — hearing health concepts and general amplification information (educational, not a substitute for a licensed audiologist).";
    "560" = "Vision Care Advisor — general vision-health concepts and eye-care education (educational, not a substitute for a licensed optometrist).";
    "561" = "Dental Hygiene Advisor — oral-hygiene technique and preventive-care education (educational, not a substitute for a licensed dentist).";
    "562" = "Athletic Training Advisor — injury-prevention and conditioning concepts for athletes (educational, not a substitute for a licensed clinician).";
    "563" = "Massage Therapy Advisor — soft-tissue technique concepts and session-planning frameworks (educational, not medical advice).";
    "564" = "Genetic Counseling Advisor — general concepts of inherited-risk communication (educational, not a substitute for a licensed genetic counselor).";
    "565" = "Public Health Educator — community health messaging and health-literacy program design.";
    "566" = "Real Estate Appraiser — valuation methodology, comparable analysis, and market-condition adjustment.";
    "567" = "Property Manager — tenant relations, maintenance scheduling, and lease administration.";
    "568" = "Facilities Manager — building systems oversight, preventive maintenance, and space planning.";
    "569" = "Real Estate Development Advisor — site feasibility, entitlement strategy, and project pro forma structure.";
    "570" = "Commercial Leasing Specialist — lease structuring, tenant mix strategy, and negotiation framing.";
    "571" = "Building Inspector — code compliance assessment and defect identification methodology.";
    "572" = "Space Planning Strategist — workplace layout, adjacency planning, and occupancy efficiency.";
    "573" = "HOA Management Advisor — governance process, reserve planning, and community rule administration.";
    "574" = "Real Estate Market Analyst — comparable market analysis and demand-trend interpretation.";
    "575" = "Building Energy Audit Specialist — efficiency assessment and retrofit prioritization for buildings.";
    "576" = "Trademark Specialist — mark distinctiveness analysis and clearance-search methodology (general information, not legal advice).";
    "577" = "Patent Strategy Advisor — prior-art landscape framing and claim-scope concepts (general information, not legal advice).";
    "578" = "Immigration Process Advisor — general visa-category and process-step information (general information, not legal advice).";
    "579" = "Customs Compliance Advisor — tariff classification concepts and import documentation frameworks (general information, not legal advice).";
    "580" = "Export Controls Specialist — general concepts of controlled-goods classification and licensing frameworks (general information, not legal advice).";
    "581" = "Arbitration Process Advisor — general dispute-resolution process structure (general information, not legal advice).";
    "582" = "Paralegal Process Advisor — document preparation workflow and filing-process organization (general information, not legal advice).";
    "583" = "Tax Concepts Advisor — general tax-concept education and terminology (general information, not tax or legal advice).";
    "584" = "Environmental Regulation Advisor — general environmental-regulatory concept education (general information, not legal advice).";
    "585" = "Aviation Regulation Advisor — general aviation-regulatory concept education (general information, not legal advice).";
    "586" = "Event Planner — logistics coordination, vendor management, and run-of-show design.";
    "587" = "Wedding Planner — vendor coordination, timeline design, and day-of logistics for weddings.";
    "588" = "Catering Manager — menu planning, guest-count scaling, and service-flow logistics.";
    "589" = "Hotel Operations Manager — front-of-house workflow, occupancy strategy, and guest-service standards.";
    "590" = "Concierge Service Specialist — guest-request fulfillment and local-experience curation.";
    "591" = "Tour Guide Trainer — narrative pacing, audience engagement, and route logistics for guided tours.";
    "592" = "Cruise Operations Advisor — itinerary logistics and onboard guest-experience coordination.";
    "593" = "Banquet Operations Manager — room turnover, service timing, and large-event execution.";
    "594" = "Guest Experience Designer — touchpoint mapping and service-moment design for hospitality brands.";
    "595" = "Nightlife Venue Manager — crowd flow, entertainment booking, and venue safety operations.";
    "596" = "Master Plumber Advisor — piping systems, code-compliant design concepts, and troubleshooting logic.";
    "597" = "Master Electrician Advisor — wiring concepts, load calculation logic, and code-compliance frameworks.";
    "598" = "HVAC Technician Advisor — load calculation concepts, system design logic, and troubleshooting frameworks.";
    "599" = "Welding Specialist — joint design, process selection, and weld-quality concepts.";
    "600" = "Master Carpenter — joinery technique, structural framing logic, and finish-work planning.";
    "601" = "Machinist — tolerancing, tooling selection, and CNC/manual machining process planning.";
    "602" = "Blacksmith — forging technique, heat treatment, and metal-shaping process.";
    "603" = "Glassblower — molten-glass shaping technique and annealing process.";
    "604" = "Stonemason — stone selection, joint technique, and structural masonry planning.";
    "605" = "Locksmith Specialist — mechanism design concepts and security-hardware evaluation.";
    "606" = "Cartographer — map projection choice, symbology, and generalization for spatial communication.";
    "607" = "GIS Analyst — spatial data modeling, overlay analysis, and geoprocessing workflow design.";
    "608" = "Land Surveyor — boundary determination methodology and measurement-control concepts.";
    "609" = "Toy Safety Engineer — hazard analysis and safety-standard compliance for toy design.";
    "610" = "Packaging Engineer — protective structure design and material selection for shipping/retail packaging."

    # --- 90 NEW AGENTS (611-700) ---
    "611" = "Defensive packet-analysis geek focused on lawful network troubleshooting and protocol behavior."
"612" = "Authentication geek focused on identity flows, session behavior, and access-control diagnostics."
"613" = "Malware-analysis geek focused on safe sandbox triage, behavior observation, and containment."
"614" = "Threat-hunting geek focused on network telemetry, anomaly discovery, and defensive detection."
"615" = "Reverse-engineering geek focused on binary structure, disassembly concepts, and defensive software analysis."
"616" = "Security geek focused on phishing simulations, user awareness, and defensive email controls."
"617" = "Detection-engineering geek focused on high-signal rules, telemetry coverage, and false-positive reduction."
"618" = "Threat-intelligence geek focused on indicator context, actor tracking, and defensive prioritization."
"619" = "Vulnerability-research geek focused on safe reproduction, root-cause analysis, and remediation notes."
"620" = "Authorized cloud-security geek focused on attack-path modeling, control validation, and hardening."
    
    "621" = "Fictional sky-pirate captain for immersive adventure roleplay, crew banter, and mission scenes."
"622" = "Fictional neon oracle for cyberpunk roleplay, prophecy scenes, and cryptic guidance."
"623" = "Fictional frontier ranger for desert survival roleplay, tracking scenes, and terse dialogue."
"624" = "Fictional royal wizard for court intrigue roleplay, magical counsel, and dramatic dialogue."
"625" = "Fictional time-librarian for temporal mystery roleplay, archive quests, and paradox scenes."
"626" = "Fictional deep-space salvager for shipboard roleplay, derelict exploration, and crew dialogue."
"627" = "Fictional dragon scholar for mythic roleplay, ancient lore, and scholarly character dialogue."
"628" = "Fictional clockwork envoy for steampunk diplomacy roleplay, negotiation scenes, and etiquette."
"629" = "Fictional post-collapse merchant for settlement roleplay, barter scenes, and caravan dialogue."
"630" = "Fictional card-reading mystic for occult-flavored fantasy roleplay, symbolism, and character scenes."
    
    "631" = "Food-science specialist focused on controlled fermentation, culture behavior, process consistency, and sanitation."
"632" = "Sensory-science specialist focused on structured taste, aroma, texture, and perception evaluation."
"633" = "Aquaponics specialist focused on coupled fish-plant systems, nutrient cycling, and production layout."
"634" = "Apiculture specialist focused on colony management, hive planning, seasonal care, and honey production."
"635" = "Mycology specialist focused on fungal identification concepts, cultivation workflows, and ecological roles."
"636" = "Plant-breeding specialist focused on trait selection, breeding plans, seed handling, and cultivar evaluation."
"637" = "Botanical taxonomy specialist focused on plant identification frameworks, nomenclature, and specimen records."
"638" = "Entomology specialist focused on insect identification, life cycles, collection ethics, and ecological interactions."
"639" = "Ornithology specialist focused on bird identification, field observation, migration, and habitat interpretation."
"640" = "Ichthyology specialist focused on fish identification, anatomy, aquatic ecology, and field sampling concepts."
    
    "641" = "Immunology specialist focused on immune-system mechanisms, study design concepts, and evidence interpretation."
"642" = "Gerontology specialist focused on aging science, lifespan systems, and evidence-based aging research."
"643" = "Prosthetics design specialist focused on functional geometry, fit concepts, materials, and user-centered iteration."
"644" = "Orthotics specialist focused on brace design concepts, biomechanics, fitting considerations, and device evaluation."
"645" = "Dental-prosthetics specialist focused on restorative forms, workflow concepts, and laboratory quality."
"646" = "Clinical-trial operations specialist focused on protocol workflow, visit coordination, documentation, and data integrity."
"647" = "Drug-safety specialist focused on adverse-event workflows, signal review, and pharmacovigilance documentation."
"648" = "Radiation-protection specialist focused on exposure control concepts, monitoring, shielding logic, and safety programs."
"649" = "Diagnostic-imaging workflow specialist focused on ultrasound operations, study protocols, and image-quality workflow."
"650" = "Speech-language specialist focused on communication assessment frameworks, therapy planning, and accessibility strategies."
    
    "651" = "Accessibility specialist focused on daily-task adaptation, environmental supports, and inclusive workflow design."
"652" = "Sleep-science specialist focused on sleep measurement, circadian concepts, and evidence synthesis."
"653" = "Food-microbiology specialist focused on spoilage, contamination control, and microbial food-safety concepts."
"654" = "Culinary-process specialist focused on repeatable kitchen processes, yield control, and production flow."
"655" = "Coffee-science specialist focused on roast development, extraction variables, and sensory consistency."
"656" = "Tea specialist focused on blending structure, infusion behavior, provenance, and sensory balance."
"657" = "Bookbinding specialist focused on binding structures, paper handling, repair techniques, and durable construction."
"658" = "Paper-conservation specialist focused on material assessment, stabilization concepts, and archival handling."
"659" = "Textile-conservation specialist focused on fiber assessment, stabilization, display, and storage planning."
"660" = "Museum exhibition specialist focused on interpretive layout, object sequencing, visitor flow, and display planning."
    
    "661" = "Oral-history specialist focused on interview design, narrative preservation, consent workflows, and archive preparation."
"662" = "Genealogy specialist focused on family-history methods, source evaluation, lineage reconstruction, and record correlation."
"663" = "Paleography specialist focused on historical handwriting analysis, transcription, and script comparison."
"664" = "Numismatics specialist focused on coin identification, historical context, grading concepts, and cataloging."
"665" = "Philately specialist focused on stamp identification, postal history, issue classification, and collection cataloging."
"666" = "Cartooning educator focused on visual shorthand, character construction, gesture, and sequential drawing practice."
"667" = "Storyboarding specialist focused on shot planning, visual continuity, staging, and narrative beats."
"668" = "Color-theory specialist focused on palette relationships, contrast systems, visual hierarchy, and perceptual balance."
"669" = "Typography specialist focused on type classification, pairing, hierarchy, and editorial typography systems."
"670" = "Calligraphy specialist focused on script structure, stroke discipline, layout rhythm, and lettering practice."
    
    "671" = "Grant-writing specialist focused on funder alignment, logic models, measurable outcomes, and proposal structure."
"672" = "Speechwriting specialist focused on persuasive structure, spoken cadence, audience adaptation, and memorable phrasing."
"673" = "Media-training specialist focused on interview preparation, message discipline, bridging, and public-response rehearsal."
"674" = "Facilitation specialist focused on agenda design, participation balance, decision capture, and productive group dynamics."
"675" = "Instructional-design specialist focused on learning objectives, lesson architecture, practice design, and assessment alignment."
"676" = "Assessment specialist focused on rubric construction, item quality, scoring reliability, and evidence of learning."
"677" = "Curriculum specialist focused on competency mapping, prerequisite structure, sequence design, and coverage analysis."
"678" = "Museum-registration specialist focused on object records, accession workflows, movement tracking, and collection documentation."
"679" = "Conservation-science specialist focused on material characterization, degradation mechanisms, and preventive conservation."
"680" = "Urban-ecology specialist focused on habitat networks, biodiversity in cities, and ecological planning."
    
    "681" = "Wildlife-planning specialist focused on habitat connectivity, corridor design concepts, and movement ecology."
"682" = "Wetland-restoration specialist focused on hydrology, habitat recovery, planting strategy, and monitoring design."
"683" = "Soil-science specialist focused on soil classification, fertility concepts, texture, and land-use interpretation."
"684" = "Seed-bank specialist focused on accession records, viability, storage planning, and genetic preservation."
"685" = "Greenhouse specialist focused on controlled-environment climate strategy, crop zoning, and monitoring routines."
"686" = "Irrigation specialist focused on water-delivery layout, scheduling logic, efficiency, and distribution uniformity."
"687" = "Landscape-ecology specialist focused on fragmentation, spatial pattern, habitat mosaics, and connectivity analysis."
"688" = "Watershed-planning specialist focused on basin-scale water management, land-use interactions, and resilience planning."
"689" = "Hydrography specialist focused on waterbody mapping, bathymetric concepts, and hydrographic data quality."
"690" = "Ocean-acoustics specialist focused on underwater sound propagation, measurement concepts, and acoustic ecology."
    
    "691" = "Acoustical-engineering specialist focused on room acoustics, noise control, vibration isolation, and measurement planning."
"692" = "Ergonomics specialist focused on human-task fit, workstation design, workload, and observational assessment."
"693" = "Packaging-sustainability specialist focused on material footprints, recyclability tradeoffs, and packaging lifecycle analysis."
"694" = "Repairability specialist focused on service access, modularity, maintenance pathways, and product longevity."
"695" = "Circular-design specialist focused on reuse loops, remanufacturing pathways, disassembly, and material recovery."
"696" = "Tool-management specialist focused on tool inventories, borrowing systems, calibration records, and workshop organization."
"697" = "Makerspace-safety specialist focused on shop rules, equipment orientation, hazard controls, and safe workshop operations."
"698" = "Additive-manufacturing specialist focused on print-process tuning, material behavior, and repeatability."
"699" = "Digital-fabrication specialist focused on laser-cut layouts, kerf compensation, material constraints, and assembly planning."
"700" = "Metrology specialist focused on measurement systems, uncertainty, calibration strategy, and traceability."
    
}

# ==============================================
# NATIVE WORKSPACE BACKUP ENGINE (ported from run_backup.ps1)
# ==============================================
function Invoke-WorkspaceBackup {
    Clear-Host
    Show-CommandActivation -Command 'backup'
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host "             💾 CYPRATEAM WORKSPACE BACKUP ENGINE 💾" -ForegroundColor $Theme.Info
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host ""

    $BaseDir = $PSScriptRoot
    $BackupsDir = Join-Path $BaseDir "Backups"
    $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $BackupLogFile = Join-Path $BaseDir "diagnose.txt"

    function Write-BackupLog {
        param([string]$Message)
        $LogEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
        Write-Host " [i] $Message" -ForegroundColor $Theme.MutedLight
        Add-Content -Path $BackupLogFile -Value $LogEntry -ErrorAction SilentlyContinue
    }

    try {
        Write-BackupLog "Starting CypraMatrix Workspace Backup..."

        # 1. Housekeeping: Archive old logs (> 7 days) before packaging
        $logDir = Join-Path $BaseDir "Logs"
        $archiveDir = Join-Path $BaseDir "Logs\Archive"

        if (Test-Path $logDir) {
            if (-not (Test-Path $archiveDir)) {
                New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
            }
            $oldLogs = Get-ChildItem -Path $logDir -Filter "*.log" | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) }
            if ($oldLogs) {
                $oldLogs | Move-Item -Destination $archiveDir -Force
                Write-BackupLog "Archived $($oldLogs.Count) old log file(s) to Logs\Archive."
            }
        }

        # Ensure Backups directory exists
        if (-not (Test-Path $BackupsDir)) {
            New-Item -ItemType Directory -Path $BackupsDir -Force | Out-Null
            Write-BackupLog "Created missing Backups directory at: $BackupsDir"
        }

        $BackupFileName = "CypraTeam_Matrix_Backup_$Timestamp.zip"
        $DestinationZip = Join-Path $BackupsDir $BackupFileName

        Write-BackupLog "Compressing workspace (excluding heavy model weights) to: $BackupFileName"

        # Exclude Backups, .git, and heavy Ollama model storage folders from being zipped
        $ItemsToZip = Get-ChildItem -Path $BaseDir -Exclude "Backups", ".git", "OllamaModels", "ollamacentral"

        if (-not $ItemsToZip -or $ItemsToZip.Count -eq 0) {
            throw "No items found to back up in $BaseDir."
        }

        $itemPaths = @($ItemsToZip.FullName)
        $backupArgs = New-Object System.Collections.ArrayList
        [void]$backupArgs.Add($itemPaths)
        [void]$backupArgs.Add($DestinationZip)

        # Compress on a background job so the console can animate real-time progress
        $jobOutcome = Invoke-BackgroundTaskWithSpinner -ScriptBlock {
            param($paths, $dest)
            Compress-Archive -Path $paths -DestinationPath $dest -Force
        } -ArgumentList $backupArgs -Label "Compressing workspace archive" -Color $Theme.Info -DoneLabel "Archive compression complete."

        if (-not $jobOutcome.Success -or -not (Test-Path $DestinationZip)) {
            throw "Compression job failed. $($jobOutcome.Error)"
        }

        Show-LoadingBar -Label " Finalizing" -Steps 16 -DelayMs 8 -Color $Theme.Success

        $sizeMB = [math]::Round((Get-Item $DestinationZip).Length / 1MB, 2)
        Write-BackupLog "Backup completed successfully: $BackupFileName ($sizeMB MB)"

        Write-Host ""
        Write-Host " [OK] Backup saved to : $DestinationZip" -ForegroundColor $Theme.Success
        Write-Host " [OK] Archive size    : $sizeMB MB" -ForegroundColor $Theme.Success
    }
    catch {
        Write-BackupLog "ERROR: Backup failed. Details: $_"
        Write-Host ""
        Write-Host " [!] Backup failed: $_" -ForegroundColor $Theme.Error
    }

    Write-Host ""
    Read-Host "Press Enter to return to Dashboard"
}

function Get-MatrixInstalledModels {
    $rowsOut = @()
    try {
        $raw = @( & ollama list 2>$null )
        foreach ($line in $raw) {
            $s = ([string]$line).Trim()
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            $s = $s -replace "^\uFEFF", ""
            $s = $s -replace "\x1b\[[0-9;?]*[ -/]*[@-~]", ""
            if ($s -match '^(NAME|MODEL)\s') { continue }

            $parts = @($s -split '\s+')
            if ($parts.Count -ge 1) {
                $rowsOut += [pscustomobject]@{
                    Name = $parts[0]
                    Id = if ($parts.Count -ge 2) { $parts[1] } else { '' }
                    Size = if ($parts.Count -ge 3) { $parts[2] } else { '' }
                    Modified = if ($parts.Count -ge 4) { ($parts[3..($parts.Count-1)] -join ' ') } else { '' }
                }
            }
        }
    } catch {}
    return @($rowsOut)
}

function Get-MatrixModelStoreStatus {
    $target = [string]$matrixConfig.ModelStorePath
    $current = if ($env:OLLAMA_MODELS) { [string]$env:OLLAMA_MODELS } else { '' }
    $online = Test-OllamaReady
    $same = $false
    if ($current) {
        try { $same = ([System.IO.Path]::GetFullPath($current).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($target).TrimEnd('\')) } catch { $same = ($current -ieq $target) }
    }
    [pscustomobject]@{ Target=$target; Current=$current; Online=$online; MatchesTarget=$same }
}

function Ensure-MatrixTargetModelStore {
    # Portable mode always targets <project>\OllamaModels. Never ask the user
    # to adopt a machine-wide/default Ollama store.
    $target = [System.IO.Path]::GetFullPath($defaultModelStorePath)
    $matrixConfig.ModelStorePath = $target
    $env:OLLAMA_MODELS = $target
    if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

    if (-not (Test-OllamaReady)) {
        return (Start-OllamaEngine -CpuOnly $false)
    }

    if (-not $script:OllamaStartedByMatrix) {
        # The live server predates this Matrix session. Restart it so all pulls and
        # model lookups are performed against the portable project store.
        return (Start-OllamaEngine -CpuOnly $false)
    }

    return $true
}

function Get-CurrentActiveModel {
    $active = if ($matrixConfig.Contains("ActiveModel") -and -not [string]::IsNullOrWhiteSpace([string]$matrixConfig.ActiveModel)) {
        [string]$matrixConfig.ActiveModel
    } else {
        [string]$matrixConfig.DefaultBaseModel
    }
    return $active.Trim()
}

function Get-AgentDeclaredBaseModel {
    param([Parameter(Mandatory=$true)][string]$AgentModel)
    $modelfile = Resolve-AgentModelfilePath -ModelName $AgentModel.Trim()
    if (-not $modelfile) { return "unknown" }
    try {
        $fromLine = Get-Content -Path $modelfile -ErrorAction Stop | Where-Object { $_ -match '^\s*FROM\s+(.+?)\s*$' } | Select-Object -First 1
        if ($fromLine -and $fromLine -match '^\s*FROM\s+(.+?)\s*$') { return $matches[1].Trim() }
    } catch {}
    return "unknown"
}

function Set-CurrentActiveModel {
    param([Parameter(Mandatory=$true)][string]$ModelName)
    $ModelName = ([string]$ModelName).Trim()
    if ([string]::IsNullOrWhiteSpace($ModelName)) { return $false }
    $matrixConfig.ActiveModel = $ModelName
    $matrixConfig.DefaultBaseModel = $ModelName
    $matrixConfig.Model = $ModelName
    Save-MatrixConfig
    return $true
}

function Update-AgentBaseModelFleet {
    # Rebasing an agent means two things, not one:
    #   1. Rewrite FROM in every Modelfile_<agent> so future (re)installs use it.
    #   2. Re-run `ollama create <agent> -f <modelfile>` for every agent that is
    #      ALREADY registered, because editing a Modelfile on disk does nothing
    #      to a model that was already baked with `ollama create` -- the old
    #      base stays active until it is rebuilt. Without step 2, changing the
    #      "active model" only ever updated MatrixConfig.json cosmetically.
    param(
        [Parameter(Mandatory = $true)][string]$NewBaseModel,
        [switch]$Quiet
    )

    $NewBaseModel = ([string]$NewBaseModel).Trim()
    if ([string]::IsNullOrWhiteSpace($NewBaseModel)) {
        throw "Cannot rebase agents onto an empty base model name."
    }

    $manifest = @(Get-ModelfileManifest)
    if ($manifest.Count -eq 0) {
        if (-not $Quiet) { Write-Host "[i] No agent Modelfiles were found to rebase." -ForegroundColor $Theme.Muted }
        return [pscustomobject]@{ Rewritten = 0; Rebuilt = 0; Skipped = 0; Failed = @() }
    }

    $installedNames = @(Get-ExistingOllamaModels | ForEach-Object { ($_.Name -replace ':latest$','') })

    $rewritten = 0
    $rebuilt = 0
    $skipped = 0
    $failed = New-Object System.Collections.Generic.List[string]

    if (-not $Quiet) {
        Write-Host "[*] Rebasing $($manifest.Count) agent Modelfile(s) onto: $NewBaseModel" -ForegroundColor $Theme.Info
    }

    $step = 0
    foreach ($entry in $manifest) {
        $step++
        try {
            $content = Get-Content -Path $entry.File -Raw -ErrorAction Stop
            if ($content -notmatch '(?m)^FROM\s+.+$') {
                $failed.Add("$($entry.Name) (no FROM line found)")
                continue
            }
            $fromRegex = [regex]::new('(?m)^FROM\s+.+$')
            $newContent = $fromRegex.Replace($content, { "FROM $NewBaseModel" }, 1)
            if ($newContent -ne $content) {
                Set-Content -Path $entry.File -Value $newContent -Encoding UTF8
                $rewritten++
            }

            $isInstalled = $installedNames -contains $entry.Name
            if ($isInstalled) {
                if (-not $Quiet) { Write-Host "  [$step/$($manifest.Count)] Rebuilding $($entry.Name) -> $NewBaseModel ..." -ForegroundColor $Theme.MutedLight }
                $null = Invoke-OllamaNative -Arguments @('create', $entry.Name, '-f', $entry.File) -Quiet
                if ($LASTEXITCODE -eq 0 -and (Test-AgentModelInstalled -ModelName $entry.Name)) {
                    $rebuilt++
                } else {
                    $failed.Add("$($entry.Name) (rebuild exit $LASTEXITCODE)")
                }
            } else {
                $skipped++
            }
        } catch {
            $failed.Add("$($entry.Name) ($($_.Exception.Message))")
        }
    }

    Clear-AgentModelInstalledCache
    try { Update-ModelManifest | Out-Null } catch {}

    if (-not $Quiet) {
        Write-Host "[+] Modelfiles updated on disk      : $rewritten" -ForegroundColor $Theme.Success
        Write-Host "[+] Registered agents rebuilt onto new base: $rebuilt" -ForegroundColor $Theme.Success
        if ($skipped -gt 0) { Write-Host "[i] Not yet registered (Modelfile updated only): $skipped" -ForegroundColor $Theme.MutedLight }
        if ($failed.Count -gt 0) {
            Write-Host "[!] Failed: $($failed.Count)" -ForegroundColor $Theme.Error
            $failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor $Theme.Error }
        }
    }

    return [pscustomobject]@{ Rewritten = $rewritten; Rebuilt = $rebuilt; Skipped = $skipped; Failed = @($failed) }
}

function Invoke-PullHub {
    while ($true) {
        Clear-Host
    Show-CommandActivation -Command 'pull'
        Write-Host "===================================================================" -ForegroundColor $Theme.Info
        Write-Host "                 OLLAMA MODEL CENTER" -ForegroundColor $Theme.Info
        Write-Host "===================================================================" -ForegroundColor $Theme.Info
        $store = Get-MatrixModelStoreStatus
        $activeModel = Get-CurrentActiveModel
        Write-Host "Current active model : $activeModel" -ForegroundColor $Theme.Success
        Write-Host "Current service store: $(if($store.Current){$store.Current}else{'Not exposed in this session'})" -ForegroundColor $Theme.InfoDim
        Write-Host "Portable model store  : $($store.Target)" -ForegroundColor $Theme.InfoDim
        Write-Host "System Ollama paths    : IGNORED" -ForegroundColor $Theme.Success
        Write-Host "Ollama status        : $(if($store.Online){'ONLINE'}else{'OFFLINE'})" -ForegroundColor $(if($store.Online){$Theme.Success}else{$Theme.Warning})
        Write-Host ""
        Write-Host " [1] Show installed models" -ForegroundColor $Theme.Primary
        Write-Host " [2] Update current active model" -ForegroundColor $Theme.Success
        Write-Host " [3] Change current active model" -ForegroundColor $Theme.Warning
        Write-Host " [4] Install a model" -ForegroundColor $Theme.Info
        Write-Host " [5] Install / register an agent" -ForegroundColor $Theme.Info
        Write-Host " [6] Enforce portable OllamaModels store" -ForegroundColor $Theme.Warning
        Write-Host " [7] Show model-store status and disk usage" -ForegroundColor $Theme.Info2
        Write-Host " [8] Rebase ALL registered agents onto the active model" -ForegroundColor $Theme.Warning
        Write-Host " [0] Return" -ForegroundColor $Theme.Muted
        Write-Host ""
        $choice = Read-Host "Select option"

        switch ($choice) {
            '1' {
                Write-Host ""
                $installed = @(Get-MatrixInstalledModels)
                if ($installed.Count -eq 0) {
                    Write-Host "No installed models were returned by Ollama." -ForegroundColor $Theme.Muted
                } else {
                    $active = Get-CurrentActiveModel
                    foreach ($row in $installed) {
                        $mark = if ($row.Name -ieq $active -or $row.Name -ieq "$active`:latest") { "<ACTIVE>" } else { "" }
                        Write-Host (" {0,-35} {1,-10} {2,-12} {3} {4}" -f $row.Name,$row.Id,$row.Size,$row.Modified,$mark) -ForegroundColor $(if($mark){$Theme.Success}else{$Theme.Primary})
                    }
                }
                $loaded = @(Get-OllamaLoadedModelTelemetry)
                if ($loaded.Count -gt 0) {
                    Write-Host ""
                    Write-Host "Loaded models:" -ForegroundColor $Theme.Warning
                    $loaded | Format-Table Name,SizeMB,Expires -AutoSize | Out-Host
                }
                Read-Host 'Enter'
            }
            '2' {
                if (Ensure-MatrixTargetModelStore) {
                    $m = Get-CurrentActiveModel
                    Write-Host "[*] Updating current active model: $m" -ForegroundColor $Theme.Info
                    & ollama pull $m
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "[+] Current active model is installed/updated." -ForegroundColor $Theme.Success
                        Update-AgentBaseModelFleet -NewBaseModel $m | Out-Null
                    }
                    else { Write-Host "[!] Model update failed with exit code $LASTEXITCODE." -ForegroundColor $Theme.Error }
                }
                Read-Host 'Enter'
            }
            '3' {
                Write-Host ""
                Write-Host "Installed models:" -ForegroundColor $Theme.Info
                $installed = @(Get-MatrixInstalledModels)
                if ($installed.Count -gt 0) {
                    foreach ($row in $installed) {
                        Write-Host ("  - {0}" -f $row.Name) -ForegroundColor $Theme.Primary
                    }
                }
                Write-Host ""
                $newActive = Read-Host "Enter model name to make ACTIVE (current: $(Get-CurrentActiveModel))"
                if (-not [string]::IsNullOrWhiteSpace($newActive)) {
                    $newActive = $newActive.Trim()
                    $exists = @(Get-MatrixInstalledModels | Where-Object { $_.Name -ieq $newActive -or $_.Name -ieq "$newActive`:latest" }).Count -gt 0
                    if (-not $exists) {
                        $pull = Read-Host "'$newActive' is not installed. Install it now? (y/n)"
                        if ($pull -match '^y' -and (Ensure-MatrixTargetModelStore)) {
                            & ollama pull $newActive
                            if ($LASTEXITCODE -ne 0) {
                                Write-Host "[!] Could not install '$newActive'; active model was not changed." -ForegroundColor $Theme.Error
                                Read-Host 'Enter'
                                continue
                            }
                        } else {
                            Write-Host "[i] Active model unchanged." -ForegroundColor $Theme.MutedLight
                            Read-Host 'Enter'
                            continue
                        }
                    }
                    if (Set-CurrentActiveModel -ModelName $newActive) {
                        Write-Host "[+] Current active model changed to: $newActive" -ForegroundColor $Theme.Success
                        Write-Host "[i] This is the base selected for the Matrix and for future/rebuilt directive agents." -ForegroundColor $Theme.InfoDim
                        $rebase = Read-Host "Rebase all registered agents onto '$newActive' now? (y/n)"
                        if ($rebase -match '^y') {
                            Update-AgentBaseModelFleet -NewBaseModel $newActive | Out-Null
                        } else {
                            Write-Host "[i] Agents left untouched. Use option [8] later to rebase them onto '$newActive'." -ForegroundColor $Theme.MutedLight
                        }
                    }
                }
                Read-Host 'Enter'
            }
            '4' {
                $modelName = Read-Host 'Install model (e.g. llama3.2, qwen2.5:7b, mistral:7b)'
                if (-not [string]::IsNullOrWhiteSpace($modelName)) {
                    $modelName = $modelName.Trim()
                    if (Ensure-MatrixTargetModelStore) {
                        Write-Host "[*] Installing $modelName ..." -ForegroundColor $Theme.Info
                        & ollama pull $modelName
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "[+] Model installed: $modelName" -ForegroundColor $Theme.Success
                            $makeActive = Read-Host "Make this the current active model? (y/n)"
                            if ($makeActive -match '^y') {
                                Set-CurrentActiveModel -ModelName $modelName | Out-Null
                                Write-Host "[+] Current active model is now: $modelName" -ForegroundColor $Theme.Success
                                $rebase = Read-Host "Rebase all registered agents onto '$modelName' now? (y/n)"
                                if ($rebase -match '^y') {
                                    Update-AgentBaseModelFleet -NewBaseModel $modelName | Out-Null
                                } else {
                                    Write-Host "[i] Agents left untouched. Use option [8] later to rebase them onto '$modelName'." -ForegroundColor $Theme.MutedLight
                                }
                            }
                        } else {
                            Write-Host "[!] Install failed with exit code $LASTEXITCODE." -ForegroundColor $Theme.Error
                        }
                    }
                }
                Read-Host 'Enter'
            }
            '5' {
                $agentName = Read-Host 'Install/register agent (e.g. cypra)'
                if (-not [string]::IsNullOrWhiteSpace($agentName)) {
                    try { Install-AgentDirectiveModel -ModelName $agentName | Out-Null }
                    catch { Write-Host "[!] $($_.Exception.Message)" -ForegroundColor $Theme.Error }
                }
                Read-Host 'Enter'
            }
            '6' {
                $null = Ensure-MatrixTargetModelStore
                Read-Host 'Enter'
            }
            '7' {
                $target = [string]$matrixConfig.ModelStorePath
                $sizeMB = 0
                if (Test-Path $target) {
                    $sum = (Get-ChildItem -Path $target -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                    if ($sum) { $sizeMB = [math]::Round($sum / 1MB, 2) }
                }
                Write-Host "Current active model: $(Get-CurrentActiveModel)" -ForegroundColor $Theme.Success
                Write-Host "Target store: $target" -ForegroundColor $Theme.Info
                Write-Host "Disk usage  : $sizeMB MB" -ForegroundColor $Theme.Info
                Write-Host "Service store: $(if($store.Current){$store.Current}else{'Unknown'})" -ForegroundColor $Theme.InfoDim
                Read-Host 'Enter'
            }
            '8' {
                $m = Get-CurrentActiveModel
                Write-Host ""
                Write-Host "[*] This rewrites FROM in every agent Modelfile to '$m' and rebuilds every" -ForegroundColor $Theme.Info
                Write-Host "    already-registered agent so it actually runs on that base." -ForegroundColor $Theme.Info
                $confirm = Read-Host "Proceed? (y/n)"
                if ($confirm -match '^y') {
                    if (Ensure-MatrixTargetModelStore) {
                        Update-AgentBaseModelFleet -NewBaseModel $m | Out-Null
                    }
                }
                Read-Host 'Enter'
            }
            default { return }
        }
    }
}


# --- REAL AGENT REGISTRY / GROUP / WORKSPACE LAYER ---
function Resolve-MatrixTaskRoot {
    # Portable contract: tasks live only under this project folder.
    # Never follow Documents\CypraTeam or a parent-folder Tasks tree.
    $localTasks = Join-Path $PSScriptRoot "Tasks"
    if (-not (Test-Path $localTasks)) {
        New-Item -ItemType Directory -Path $localTasks -Force | Out-Null
    }
    return $localTasks
}

$script:TaskRoot = Resolve-MatrixTaskRoot
$script:ActiveTaskPath = $null
$script:ActiveTaskId = $null

function Get-AgentGroup {
    param([int]$AgentId)

    switch ($AgentId) {
        { $_ -ge 1 -and $_ -le 20 }    { return "Core" }
        { $_ -ge 21 -and $_ -le 50 }   { return "Reasoning & Creative" }
        { $_ -ge 51 -and $_ -le 70 }   { return "Medical & Cognitive" }
        { $_ -ge 71 -and $_ -le 90 }   { return "Security & Data" }
        { $_ -ge 91 -and $_ -le 110 }  { return "Hardware & Systems" }
        { $_ -ge 111 -and $_ -le 120 } { return "Life & Support" }
        { $_ -ge 121 -and $_ -le 130 } { return "Anthropology" }
        { $_ -ge 131 -and $_ -le 140 } { return "Coordination" }
        { $_ -ge 141 -and $_ -le 150 } { return "Development" }
        { $_ -ge 151 -and $_ -le 160 } { return "Education" }
        { $_ -ge 161 -and $_ -le 170 } { return "Wellness" }
        { $_ -ge 171 -and $_ -le 175 } { return "Medical" }
        { $_ -ge 176 -and $_ -le 180 } { return "Survival" }
        { $_ -ge 181 -and $_ -le 185 } { return "Mathematics" }
        { $_ -ge 186 -and $_ -le 190 } { return "Research & Analysis" }
        { $_ -ge 191 -and $_ -le 195 } { return "Operations & Planning" }
        { $_ -ge 196 -and $_ -le 200 } { return "Finance & Economics" }
        { $_ -ge 201 -and $_ -le 205 } { return "Legal & Governance" }
        { $_ -ge 206 -and $_ -le 210 } { return "Engineering & Design" }
        { $_ -ge 211 -and $_ -le 215 } { return "Language & Culture" }
        { $_ -ge 216 -and $_ -le 220 } { return "Science & Research" }
        { $_ -ge 221 -and $_ -le 225 } { return "Earth & Environment" }
        { $_ -ge 226 -and $_ -le 230 } { return "Space & Astronomy" }
        { $_ -ge 231 -and $_ -le 235 } { return "Computer Science" }
        { $_ -ge 236 -and $_ -le 240 } { return "Software Engineering" }
        { $_ -ge 241 -and $_ -le 245 } { return "AI & Machine Learning" }
        { $_ -ge 246 -and $_ -le 250 } { return "Data & Analytics" }
        { $_ -ge 251 -and $_ -le 255 } { return "Cybersecurity" }
        { $_ -ge 256 -and $_ -le 260 } { return "Electronics & Robotics" }
        { $_ -ge 261 -and $_ -le 265 } { return "Energy & Infrastructure" }
        { $_ -ge 266 -and $_ -le 270 } { return "Manufacturing" }
        { $_ -ge 271 -and $_ -le 275 } { return "Transportation" }
        { $_ -ge 276 -and $_ -le 280 } { return "Architecture" }
        { $_ -ge 281 -and $_ -le 285 } { return "Communication & Media" }
        { $_ -ge 286 -and $_ -le 290 } { return "Business & Management" }
        { $_ -ge 291 -and $_ -le 295 } { return "Human Systems" }
        { $_ -ge 296 -and $_ -le 300 } { return "Philosophy & Knowledge" }
        { $_ -ge 301 -and $_ -le 310 } { return "Platform & Reliability" }
        { $_ -ge 311 -and $_ -le 320 } { return "Security & Identity" }
        { $_ -ge 321 -and $_ -le 330 } { return "Data & Analytics" }
        { $_ -ge 331 -and $_ -le 340 } { return "Product & Design" }
        { $_ -ge 341 -and $_ -le 350 } { return "Architecture & Delivery" }
        { $_ -ge 351 -and $_ -le 360 } { return "Quality & Resilience" }
        { $_ -ge 361 -and $_ -le 370 } { return "Knowledge & AI" }
        { $_ -ge 371 -and $_ -le 380 } { return "Finance & Governance" }
        { $_ -ge 381 -and $_ -le 390 } { return "Operations & Customer" }
        { $_ -ge 391 -and $_ -le 400 } { return "Strategy & Transformation" }
        { $_ -ge 401 -and $_ -le 410 } { return "Specialized Professional" }
        { $_ -ge 411 -and $_ -le 415 } { return "Roleplay & Wildcard" }
        { $_ -ge 416 -and $_ -le 425 } { return "Culinary Arts & Beverage" }
        { $_ -ge 426 -and $_ -le 435 } { return "Performing Arts & Stagecraft" }
        { $_ -ge 436 -and $_ -le 445 } { return "Film, Video & Visual Media" }
        { $_ -ge 446 -and $_ -le 455 } { return "Games & Interactive Design" }
        { $_ -ge 456 -and $_ -le 465 } { return "Music & Audio Production" }
        { $_ -ge 466 -and $_ -le 475 } { return "Fashion, Textile & Apparel" }
        { $_ -ge 476 -and $_ -le 485 } { return "Agriculture & Horticulture" }
        { $_ -ge 486 -and $_ -le 495 } { return "Animal & Veterinary Sciences" }
        { $_ -ge 496 -and $_ -le 505 } { return "Environmental & Conservation" }
        { $_ -ge 506 -and $_ -le 515 } { return "Earth Resources & Extraction" }
        { $_ -ge 516 -and $_ -le 525 } { return "Aerospace & Aviation Operations" }
        { $_ -ge 526 -and $_ -le 535 } { return "Maritime & Marine Systems" }
        { $_ -ge 536 -and $_ -le 545 } { return "Telecommunications & RF Engineering" }
        { $_ -ge 546 -and $_ -le 555 } { return "Historical & Cultural Heritage" }
        { $_ -ge 556 -and $_ -le 565 } { return "Allied Health & Therapy" }
        { $_ -ge 566 -and $_ -le 575 } { return "Real Estate & Facilities" }
        { $_ -ge 576 -and $_ -le 585 } { return "Legal & Regulatory Specialties" }
        { $_ -ge 586 -and $_ -le 595 } { return "Events, Hospitality & Service" }
        { $_ -ge 596 -and $_ -le 605 } { return "Trades & Craftsmanship" }
        { $_ -ge 606 -and $_ -le 610 } { return "Niche Specialized Skills" }
        { $_ -ge 611 -and $_ -le 620 } { return "Cyber Defense Geek Lab" }
        { $_ -ge 621 -and $_ -le 630 } { return "Roleplay & Character Studio" }
        { $_ -ge 631 -and $_ -le 640 } { return "Food & Natural Sciences" }
        { $_ -ge 641 -and $_ -le 650 } { return "Clinical & Allied Health" }
        { $_ -ge 651 -and $_ -le 660 } { return "Heritage & Conservation" }
        { $_ -ge 661 -and $_ -le 670 } { return "Communication & Learning Arts" }
        { $_ -ge 671 -and $_ -le 680 } { return "Writing, Museums & Urban Ecology" }
        { $_ -ge 681 -and $_ -le 690 } { return "Ecology, Water & Acoustics" }
        { $_ -ge 691 -and $_ -le 700 } { return "Human Factors, Fabrication & Measurement" }
        default { return "Unassigned" }
    }
}

function Get-RegistryColor {
    param([int]$AgentId)

    switch ($AgentId) {
        { $_ -ge 1   -and $_ -le 20  } { return "Red" }
        { $_ -ge 21  -and $_ -le 50  } { return "Magenta" }
        { $_ -ge 51  -and $_ -le 70  } { return "Yellow" }
        { $_ -ge 71  -and $_ -le 90  } { return "Green" }
        { $_ -ge 91  -and $_ -le 110 } { return "Cyan" }
        { $_ -ge 111 -and $_ -le 120 } { return "Blue" }
        { $_ -ge 121 -and $_ -le 130 } { return "DarkYellow" }
        { $_ -ge 131 -and $_ -le 140 } { return "DarkCyan" }
        { $_ -ge 141 -and $_ -le 150 } { return "DarkMagenta" }
        { $_ -ge 151 -and $_ -le 160 } { return "White" }
        { $_ -ge 161 -and $_ -le 170 } { return "Gray" }
        { $_ -ge 171 -and $_ -le 175 } { return "DarkRed" }
        { $_ -ge 176 -and $_ -le 180 } { return "DarkGreen" }
        { $_ -ge 181 -and $_ -le 185 } { return "DarkBlue" }
        { $_ -ge 186 -and $_ -le 190 } { return "Cyan" }
        { $_ -ge 191 -and $_ -le 195 } { return "Yellow" }
        { $_ -ge 196 -and $_ -le 200 } { return "Green" }
        { $_ -ge 201 -and $_ -le 205 } { return "Magenta" }
        { $_ -ge 206 -and $_ -le 210 } { return "Blue" }
        { $_ -ge 211 -and $_ -le 215 } { return "DarkYellow" }
        { $_ -ge 216 -and $_ -le 220 } { return "Red" }
        { $_ -ge 221 -and $_ -le 225 } { return "DarkGreen" }
        { $_ -ge 226 -and $_ -le 230 } { return "DarkCyan" }
        { $_ -ge 231 -and $_ -le 235 } { return "White" }
        { $_ -ge 236 -and $_ -le 240 } { return "DarkMagenta" }
        { $_ -ge 241 -and $_ -le 245 } { return "Yellow" }
        { $_ -ge 246 -and $_ -le 250 } { return "Cyan" }
        { $_ -ge 251 -and $_ -le 255 } { return "DarkRed" }
        { $_ -ge 256 -and $_ -le 260 } { return "Green" }
        { $_ -ge 261 -and $_ -le 265 } { return "Blue" }
        { $_ -ge 266 -and $_ -le 270 } { return "Magenta" }
        { $_ -ge 271 -and $_ -le 275 } { return "DarkBlue" }
        { $_ -ge 276 -and $_ -le 280 } { return "DarkYellow" }
        { $_ -ge 281 -and $_ -le 285 } { return "Gray" }
        { $_ -ge 286 -and $_ -le 290 } { return "DarkCyan" }
        { $_ -ge 291 -and $_ -le 295 } { return "Green" }
        { $_ -ge 296 -and $_ -le 300 } { return "DarkMagenta" }
        { $_ -ge 301 -and $_ -le 310 } { return "Cyan" }
        { $_ -ge 311 -and $_ -le 320 } { return "Green" }
        { $_ -ge 321 -and $_ -le 330 } { return "Blue" }
        { $_ -ge 331 -and $_ -le 340 } { return "Magenta" }
        { $_ -ge 341 -and $_ -le 350 } { return "Yellow" }
        { $_ -ge 351 -and $_ -le 360 } { return "DarkCyan" }
        { $_ -ge 361 -and $_ -le 370 } { return "DarkGreen" }
        { $_ -ge 371 -and $_ -le 380 } { return "DarkBlue" }
        { $_ -ge 381 -and $_ -le 390 } { return "DarkMagenta" }
        { $_ -ge 391 -and $_ -le 400 } { return "DarkYellow" }
        { $_ -ge 401 -and $_ -le 410 } { return "White" }
        { $_ -ge 411 -and $_ -le 415 } { return "Magenta" }
        { $_ -ge 416 -and $_ -le 425 } { return "Yellow" }
        { $_ -ge 426 -and $_ -le 435 } { return "Cyan" }
        { $_ -ge 436 -and $_ -le 445 } { return "Blue" }
        { $_ -ge 446 -and $_ -le 455 } { return "Green" }
        { $_ -ge 456 -and $_ -le 465 } { return "DarkMagenta" }
        { $_ -ge 466 -and $_ -le 475 } { return "DarkYellow" }
        { $_ -ge 476 -and $_ -le 485 } { return "DarkGreen" }
        { $_ -ge 486 -and $_ -le 495 } { return "DarkCyan" }
        { $_ -ge 496 -and $_ -le 505 } { return "DarkBlue" }
        { $_ -ge 506 -and $_ -le 515 } { return "Gray" }
        { $_ -ge 516 -and $_ -le 525 } { return "Cyan" }
        { $_ -ge 526 -and $_ -le 535 } { return "Blue" }
        { $_ -ge 536 -and $_ -le 545 } { return "Yellow" }
        { $_ -ge 546 -and $_ -le 555 } { return "DarkYellow" }
        { $_ -ge 556 -and $_ -le 565 } { return "Green" }
        { $_ -ge 566 -and $_ -le 575 } { return "DarkCyan" }
        { $_ -ge 576 -and $_ -le 585 } { return "Magenta" }
        { $_ -ge 586 -and $_ -le 595 } { return "DarkMagenta" }
        { $_ -ge 596 -and $_ -le 605 } { return "DarkGreen" }
        { $_ -ge 606 -and $_ -le 610 } { return "White" }
        { $_ -ge 611 -and $_ -le 620 } { return "DarkCyan" }
        { $_ -ge 621 -and $_ -le 630 } { return "Magenta" }
        { $_ -ge 631 -and $_ -le 640 } { return "Yellow" }
        { $_ -ge 641 -and $_ -le 650 } { return "Blue" }
        { $_ -ge 651 -and $_ -le 660 } { return "Green" }
        { $_ -ge 661 -and $_ -le 670 } { return "DarkYellow" }
        { $_ -ge 671 -and $_ -le 680 } { return "Cyan" }
        { $_ -ge 681 -and $_ -le 690 } { return "DarkGreen" }
        { $_ -ge 691 -and $_ -le 700 } { return "DarkMagenta" }
        default { return "Red" }
    }
}

function Initialize-AgentRegistry {
    $registry = [ordered]@{}

    foreach ($id in ($map.Keys | Sort-Object {[int]$_})) {
        $agentId = [string]$id
        $registry[$agentId] = [ordered]@{
            id      = [int]$agentId
            name    = [string]$map[$agentId]
            tag     = [string]$tags[$agentId]
            summary = [string]$summaries[$agentId]
            group   = Get-AgentGroup ([int]$agentId)
            color   = Get-RegistryColor ([int]$agentId)
            model   = [string]$map[$agentId]
        }
    }

    $script:AgentRegistry = $registry
    $script:AgentMap = @{}
    $script:AgentTags = @{}
    $script:AgentSummaries = @{}

    foreach ($id in $registry.Keys) {
        $script:AgentMap[$id] = [string]$registry[$id].model
        $script:AgentTags[$id] = [string]$registry[$id].tag
        $script:AgentSummaries[$id] = [string]$registry[$id].summary
    }
}

function Sync-AgentRegistry {
    Initialize-AgentRegistry
    $script:map = $script:AgentMap
    $script:tags = $script:AgentTags
    $script:summaries = $script:AgentSummaries
}

Sync-AgentRegistry

function Get-NexusTaskDomainSignals {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt
    )

    $text = ([string]$Prompt).ToLower()
    $profiles = [ordered]@{
        "Medical" = @(
            "medical","medicine","doctor","patient","symptom","symptoms","diagnosis","diagnose","disease","illness",
            "infection","infected","wound","wounds","injury","injured","pain","fever","swelling","rash","bleeding",
            "burn","fracture","surgery","surgical","treatment","therapy","antibiotic","antibiotics","hospital",
            "clinic","health","leg","arm","foot","hand","skin","throat","cough","flu","virus","bacteria","trauma",
            "emergency","triage","cardio","neurolog","pediatric","rehab","pharma"
        )
        "Legal" = @(
            "legal","law","lawyer","attorney","court","lawsuit","litigation","contract","contracts","regulation",
            "regulatory","compliance","policy","governance","liability","rights","patent","copyright","trademark"
        )
        "Cybersecurity" = @(
            "cyber","security","malware","ransomware","phishing","exploit","vulnerability","vulnerabilities",
            "firewall","forensics","incident","breach","threat","attack","penetration","pentest","privacy",
            "authentication","authorization","encryption","cryptography"
        )
        "Software" = @(
            "code","coding","program","programming","script","powershell","python","javascript","typescript","bug",
            "debug","debugging","compile","compiler","database","sql","api","application","software","refactor",
            "repository","git","function","class","module","runtime","algorithm","test","testing","deployment"
        )
        "AI/Data" = @(
            "ai","machine learning","ml","deep learning","neural","model","models","llm","ollama","embedding",
            "computer vision","nlp","natural language","data","dataset","analytics","statistics","forecast",
            "prediction","reinforcement learning"
        )
        "Research" = @(
            "research","study","studies","paper","papers","literature","evidence","source","sources","fact check",
            "fact-check","verify","verification","experiment","hypothesis","analysis","scientific","science"
        )
        "Engineering" = @(
            "engineering","engineer","mechanical","electrical","electronics","robotics","embedded","control system",
            "cad","materials","manufacturing","automotive","aerospace","civil","structural","construction","power",
            "grid","infrastructure"
        )
        "Finance" = @(
            "finance","financial","money","bank","accounting","accountant","audit","budget","budgeting","market",
            "markets","economics","economic","investment","investing","cost","pricing","revenue","tax"
        )
        "Business" = @(
            "business","management","manager","project","product","strategy","strategic","organization","operations",
            "planning","logistics","procurement","scheduling","roadmap","stakeholder"
        )
        "Language" = @(
            "language","translation","translate","linguistics","linguistic","writing","writer","editor","editing",
            "journalist","journalism","rhetoric","communication","media","document"
        )
        "Science" = @(
            "physics","physicist","chemistry","chemist","biology","biologist","ecology","ecologist","geology",
            "geologist","meteorology","climate","hydrology","ocean","astronomy","astrophysics","cosmology",
            "planetary","earth","environment"
        )
        "Mathematics" = @(
            "math","mathematics","algebra","geometry","statistics","statistic","calculus","topology","equation",
            "probability","optimization"
        )
        "HumanSystems" = @(
            "psychology","psychologist","sociology","sociologist","demography","behavior","behavioral",
            "organization behavior","culture","anthropology","ethics","philosophy"
        )
    }

    $matched = New-Object System.Collections.Generic.List[string]
    foreach ($profile in $profiles.GetEnumerator()) {
        foreach ($term in $profile.Value) {
            # Word-boundary match: a plain substring match let short terms like
            # "ai" or "law" fire on unrelated words ("again", "chair", "flaw"),
            # which polluted domain detection and misrouted Nexus/Quad selection.
            $pattern = '\b' + [regex]::Escape($term) + '\b'
            if ($text -match $pattern) {
                if (-not $matched.Contains([string]$profile.Key)) {
                    [void]$matched.Add([string]$profile.Key)
                }
                break
            }
        }
    }

    return @($matched)
}

function Get-NexusAgentDomainBoost {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [string[]]$Signals = @()
    )

    $group = ([string]$Entry.group).ToLower()
    $name = ([string]$Entry.name).ToLower()
    $tag = ([string]$Entry.tag).ToLower()
    $summary = ([string]$Entry.summary).ToLower()
    $hay = "$name $tag $summary"

    $groupMap = @{
        "Medical"       = @("medical & cognitive","medical","life & support","survival")
        "Legal"         = @("legal & governance")
        "Cybersecurity" = @("cybersecurity","security & data")
        "Software"      = @("development","computer science","software engineering")
        "AI/Data"       = @("ai & machine learning","data & analytics","computer science")
        "Research"      = @("research & analysis","science & research","communication & media")
        "Engineering"   = @("engineering & design","electronics & robotics","energy & infrastructure","manufacturing","transportation","architecture")
        "Finance"       = @("finance & economics","business & management")
        "Business"      = @("business & management","operations & planning")
        "Language"      = @("language & culture","communication & media")
        "Science"       = @("science & research","earth & environment","space & astronomy")
        "Mathematics"   = @("mathematics","data & analytics","computer science")
        "HumanSystems"  = @("human systems","anthropology","medical & cognitive","philosophy & knowledge")
    }

    $boost = 0
    foreach ($signal in $Signals) {
        if ($groupMap.ContainsKey($signal)) {
            if ($groupMap[$signal] -contains $group) {
                $boost += 22
            }
        }

        switch ($signal) {
            "Medical" {
                if ($hay -match '\b(doctor|patient|symptom|diagnos|disease|infection|wound|injur|trauma|triage|medical|health|surgical|pharma|rehab|cardio|neurolog|pediatric)\b') { $boost += 8 }
            }
            "Legal" {
                if ($hay -match '\b(legal|law|contract|court|compliance|policy|governance|jurist|attorney|regulat)\b') { $boost += 8 }
            }
            "Cybersecurity" {
                if ($hay -match '\b(security|threat|incident|forensic|exploit|privacy|crypto|vulnerability|attack)\b') { $boost += 8 }
            }
            "Software" {
                if ($hay -match '\b(code|debug|compiler|software|api|database|runtime|refactor|test|script|algorithm)\b') { $boost += 8 }
            }
            "AI/Data" {
                if ($hay -match '\b(ai|machine|learning|neural|model|data|vision|nlp|statistics|forecast)\b') { $boost += 8 }
            }
            "Research" {
                if ($hay -match '\b(research|evidence|source|fact|experiment|hypothesis|analysis|science)\b') { $boost += 8 }
            }
            "Engineering" {
                if ($hay -match '\b(engineer|mechanical|electrical|electronics|robotic|embedded|control|cad|materials|manufactur|aerospace|civil|structural)\b') { $boost += 8 }
            }
            "Finance" {
                if ($hay -match '\b(finance|account|audit|budget|market|economic|money|cost|pricing|revenue)\b') { $boost += 8 }
            }
            "Business" {
                if ($hay -match '\b(strategy|project|product|manager|operations|planning|logistics|procurement|schedule|business)\b') { $boost += 8 }
            }
            "Language" {
                if ($hay -match '\b(language|translation|lingu|writer|editor|journal|rhetoric|media|communication)\b') { $boost += 8 }
            }
            "Science" {
                if ($hay -match '\b(physic|chem|biolog|ecolog|geolog|climat|hydrolog|ocean|astronom|cosmolog|planet|environment)\b') { $boost += 8 }
            }
            "Mathematics" {
                if ($hay -match '\b(math|algebra|geometry|statistic|calculus|topolog|equation|probability|optimization)\b') { $boost += 8 }
            }
            "HumanSystems" {
                if ($hay -match '\b(psycholog|sociolog|demograph|behavior|anthropolog|ethic|philosoph|culture)\b') { $boost += 8 }
            }
        }
    }

    return [int]$boost
}


# ==============================================================
# NEXUS ROUTING INTELLIGENCE ENHANCEMENT LAYER
# ==============================================================
# These helpers make routing deterministic first, then use historical
# performance and complementary-specialist coverage. The router never
# trusts an LLM-generated agent ID when a local scoring decision is available.

# DEFAULT ROUTING EXCLUSIONS
# Configure automatic Nexus exclusions in one place.
$script:NexusDefaultExcludedIds = @('53')
$script:NexusDefaultExclusionEnabled = $true

function Get-NexusDefaultExcludedIds {
    if (-not $script:NexusDefaultExclusionEnabled) { return @() }
    return @($script:NexusDefaultExcludedIds | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-NexusRoutingProfile {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    $text = ([string]$Prompt).ToLower()
    $preferred = New-Object System.Collections.Generic.List[string]
    $positive = New-Object System.Collections.Generic.List[string]
    $negative = New-Object System.Collections.Generic.List[string]
    $problemTypes = New-Object System.Collections.Generic.List[string]

    $rules = @(
        @{Domains=@('Medical'); Groups=@('Medical & Cognitive','Medical','Allied Health & Therapy'); Terms=@('symptom','infection','infected','wound','rash','fever','pain','swelling','bleeding','burn','fracture','surgery','patient','diagnosis','treatment','medicine','health','leg','arm','foot','hand','skin','throat','cough','injury','trauma','triage','antibiotic'); Negative=@('legal','contract','court','compliance','policy','governance'); Types=@('diagnosis','triage','clinical-reasoning')},
        @{Domains=@('Legal'); Groups=@('Legal & Governance','Legal & Regulatory Specialties'); Terms=@('law','legal','lawyer','attorney','court','contract','litigation','regulation','compliance','policy','governance','liability','patent','copyright','trademark'); Negative=@('infection','wound','symptom','patient','engine','brake'); Types=@('legal-analysis','compliance','risk-review')},
        @{Domains=@('Cybersecurity'); Groups=@('Security & Data','Cybersecurity','Security & Identity'); Terms=@('security','malware','ransomware','phishing','exploit','vulnerability','breach','threat','attack','firewall','forensics','authentication','authorization','encryption','privacy'); Negative=@('contract','patient','engine','recipe'); Types=@('threat-analysis','incident-response','security-review')},
        @{Domains=@('Software'); Groups=@('Development','Computer Science','Software Engineering','Platform & Reliability'); Terms=@('code','coding','program','programming','script','powershell','python','javascript','typescript','bug','debug','compile','database','sql','api','software','refactor','git','function','module','runtime','algorithm','test','deployment'); Negative=@('patient','contract','recipe','vehicle'); Types=@('implementation','debugging','architecture','testing')},
        @{Domains=@('AI/Data'); Groups=@('AI & Machine Learning','Data & Analytics','Knowledge & AI'); Terms=@('ai','machine learning','ml','deep learning','neural','model','models','llm','ollama','embedding','nlp','dataset','analytics','statistics','forecast','prediction'); Negative=@('contract','brake','recipe'); Types=@('model-selection','data-analysis','ml-engineering')},
        @{Domains=@('Research'); Groups=@('Research & Analysis','Science & Research','Knowledge & AI'); Terms=@('research','study','paper','literature','evidence','source','fact-check','verify','experiment','hypothesis','scientific','science'); Negative=@('brake','recipe','contract'); Types=@('evidence-review','research','verification')},
        @{Domains=@('Engineering'); Groups=@('Engineering & Design','Hardware & Systems','Electronics & Robotics','Manufacturing','Transportation','Architecture','Energy & Infrastructure','Trades & Craftsmanship'); Terms=@('engineering','mechanical','electrical','electronics','robotics','embedded','cad','materials','manufacturing','automotive','vehicle','engine','brake','transmission','mechanic','repair','construction','structural','power','grid','machine','machinery'); Negative=@('contract','patient','litigation'); Types=@('diagnosis','design','repair','engineering-analysis')},
        @{Domains=@('Finance'); Groups=@('Finance & Economics','Finance & Governance','Business & Management'); Terms=@('finance','financial','money','bank','accounting','accountant','audit','budget','investment','investing','cost','pricing','revenue','tax','economics','market'); Negative=@('infection','brake','malware'); Types=@('financial-analysis','forecasting','audit')},
        @{Domains=@('Business'); Groups=@('Business & Management','Operations & Planning','Strategy & Transformation','Product & Design'); Terms=@('business','management','manager','project','product','strategy','organization','operations','planning','logistics','procurement','scheduling','roadmap','stakeholder','customer'); Negative=@('infection','brake','malware'); Types=@('planning','strategy','operations')},
        @{Domains=@('Language'); Groups=@('Language & Culture','Communication & Media','Historical & Cultural Heritage'); Terms=@('language','translation','translate','linguistics','writing','writer','editor','editing','journalist','journalism','rhetoric','communication','media','document'); Negative=@('infection','brake','malware'); Types=@('writing','translation','editing')},
        @{Domains=@('Science'); Groups=@('Science & Research','Earth & Environment','Space & Astronomy','Environmental & Conservation','Earth Resources & Extraction'); Terms=@('physics','chemistry','biology','ecology','geology','meteorology','climate','hydrology','ocean','astronomy','astrophysics','cosmology','planetary','earth','environment'); Negative=@('contract','brake','recipe'); Types=@('scientific-analysis','research')},
        @{Domains=@('Mathematics'); Groups=@('Mathematics','Data & Analytics','Computer Science'); Terms=@('math','mathematics','algebra','geometry','calculus','topology','equation','probability','optimization','statistics'); Negative=@('infection','brake','contract'); Types=@('calculation','proof','optimization')}
    )

    foreach ($rule in $rules) {
        $matched = $false
        foreach ($term in $rule.Terms) {
            if ($text -match ('\b' + [regex]::Escape($term) + '\b')) { $matched = $true; break }
        }
        if ($matched) {
            foreach ($g in $rule.Groups) { if (-not $preferred.Contains($g)) { [void]$preferred.Add($g) } }
            foreach ($t in $rule.Terms) { if (-not $positive.Contains($t)) { [void]$positive.Add($t) } }
            foreach ($n in $rule.Negative) { if (-not $negative.Contains($n)) { [void]$negative.Add($n) } }
            foreach ($pt in $rule.Types) { if (-not $problemTypes.Contains($pt)) { [void]$problemTypes.Add($pt) } }
        }
    }

    [pscustomobject]@{
        PreferredGroups = @($preferred)
        PositiveTerms = @($positive)
        NegativeTerms = @($negative)
        ProblemTypes = @($problemTypes)
    }
}

function Get-NexusAgentCapabilityProfile {
    param([Parameter(Mandatory = $true)]$Entry)
    $group = [string]$Entry.group
    $name = ([string]$Entry.name).ToLower()
    $tag = ([string]$Entry.tag).ToLower()
    $summary = ([string]$Entry.summary).ToLower()
    $hay = "$name $tag $summary"

    $positive = @($name -split '[^a-z0-9]+' | Where-Object { $_.Length -ge 4 })
    $positive += @($tag -split '[^a-z0-9]+' | Where-Object { $_.Length -ge 4 })
    $positive += @($summary -split '[^a-z0-9]+' | Where-Object { $_.Length -ge 5 } | Select-Object -First 30)

    $negative = @()
    switch -Regex ($group) {
        'Legal|Governance' { $negative += @('infection','wound','patient','engine','brake','recipe','malware') }
        'Medical|Health|Therapy' { $negative += @('contract','court','litigation','compliance','engine','brake','recipe') }
        'Cybersecurity|Security' { $negative += @('infection','patient','recipe','culinary') }
        'Culinary|Hospitality' { $negative += @('malware','contract','patient','kernel') }
        'Transportation|Trades|Manufacturing|Engineering|Hardware' { $negative += @('court','contract','litigation','patient') }
        'Finance|Business|Strategy' { $negative += @('infection','wound','brake','malware') }
    }

    [pscustomobject]@{
        PositiveTerms = @($positive | Select-Object -Unique)
        NegativeTerms = @($negative | Select-Object -Unique)
        Domain = $group
        Model = [string]$Entry.model
    }
}

function Get-NexusHistoricalScore {
    param([Parameter(Mandatory = $true)][string]$ModelName)
    $score = 0
    if (Test-Path $script:MatrixLearningFile) {
        try {
            $data = ConvertTo-CompatHashtable (Get-Content $script:MatrixLearningFile -Raw | ConvertFrom-Json)
            $agents = $null
            if ($data -is [System.Collections.IDictionary] -and $data.ContainsKey('agents')) {
                $agents = $data['agents']
            } elseif ($data -and $data.PSObject.Properties['agents']) {
                $agents = ConvertTo-CompatHashtable $data.agents
            }
            if ($agents -and ($agents -is [System.Collections.IDictionary]) -and $agents.ContainsKey($ModelName)) {
                $a = $agents[$ModelName]
                $runs = [int]$a.runs
                $success = [int]$a.success
                if ($runs -gt 0) {
                    $rate = $success / [double]$runs
                    if ($rate -ge .90) { $score += 6 }
                    elseif ($rate -ge .75) { $score += 3 }
                    elseif ($rate -lt .50) { $score -= 4 }
                }
            }
        } catch { }
    }
    return $score
}

function Get-NexusProblemSpecificScore {
    param([Parameter(Mandatory = $true)][string]$Prompt, [Parameter(Mandatory = $true)]$Entry, [Parameter(Mandatory = $true)]$Profile)
    $text = ([string]$Prompt).ToLower()
    $score = 0
    foreach ($term in @($Profile.PositiveTerms)) {
        if ([string]$term -and $text -match ('\b' + [regex]::Escape([string]$term) + '\b')) { $score += 5 }
    }
    foreach ($term in @($Profile.NegativeTerms)) {
        if ([string]$term -and $text -match ('\b' + [regex]::Escape([string]$term) + '\b')) { $score -= 8 }
    }

    # High-signal phrase rules prevent broad words such as "leg" or "policy"
    # from dominating a specialist selection by themselves.
    $name = ([string]$Entry.name).ToLower()
    $group = ([string]$Entry.group).ToLower()
    $phrases = @(
        @{Pattern='\b(leg|arm|foot|hand|skin)\s+(infection|infected|wound|rash|swelling|pain)\b'; Groups=@('Medical & Cognitive','Medical','Allied Health & Therapy'); Bonus=45},
        @{Pattern='\b(engine|brake|transmission|vehicle|car|truck)\b'; Groups=@('Transportation','Trades & Craftsmanship','Manufacturing','Engineering & Design','Hardware & Systems'); Bonus=35},
        @{Pattern='\b(code|script|powershell|python)\s+(error|bug|failure|crash|not working)\b'; Groups=@('Software Engineering','Development','Computer Science','Platform & Reliability'); Bonus=35},
        @{Pattern='\b(ransomware|malware|phishing|breach|exploit|vulnerability)\b'; Groups=@('Cybersecurity','Security & Identity','Security & Data'); Bonus=35},
        @{Pattern='\b(contract|lawsuit|court|attorney|compliance)\b'; Groups=@('Legal & Governance','Legal & Regulatory Specialties'); Bonus=35}
    )
    foreach ($rule in $phrases) {
        if ($text -match $rule.Pattern -and $rule.Groups -contains $group) { $score += [int]$rule.Bonus }
    }
    return $score
}

function Get-NexusTeamSelection {
    param([Parameter(Mandatory = $true)][object[]]$Candidates, [int]$Count = 4, [string[]]$PreferredGroups = @())
    $selected = New-Object System.Collections.Generic.List[object]
    $usedGroups = @{}
    $remaining = @($Candidates)

    # First pass: maximize domain coverage without sacrificing score.
    foreach ($preferredGroup in $PreferredGroups) {
        $pick = $remaining | Where-Object { [string]$_.Group -eq $preferredGroup -and -not $usedGroups.ContainsKey([string]$_.Group) } | Select-Object -First 1
        if ($pick) {
            [void]$selected.Add($pick); $usedGroups[[string]$pick.Group] = $true
            $remaining = @($remaining | Where-Object { $_.Id -ne $pick.Id })
            if ($selected.Count -ge $Count) { break }
        }
    }

    # Second pass: strongest remaining candidate, with a mild duplicate-group penalty.
    while ($selected.Count -lt $Count -and $remaining.Count -gt 0) {
        $ranked = foreach ($candidate in $remaining) {
            $adjusted = [int]$candidate.Score
            if ($usedGroups.ContainsKey([string]$candidate.Group)) { $adjusted -= 12 }
            [pscustomobject]@{ Candidate = $candidate; Adjusted = $adjusted }
        }
        $pick = $ranked | Sort-Object -Property @{Expression='Adjusted';Descending=$true}, @{Expression={$_.Candidate.Score};Descending=$true}, @{Expression={$_.Candidate.Id};Descending=$false} | Select-Object -First 1
        if (-not $pick) { break }
        [void]$selected.Add($pick.Candidate)
        $usedGroups[[string]$pick.Candidate.Group] = $true
        $remaining = @($remaining | Where-Object { $_.Id -ne $pick.Candidate.Id })
    }
    return @($selected | Select-Object -First $Count)
}

function Invoke-NexusRoutingAudit {
    Clear-Host
    Show-CommandActivation -Command 'routeaudit'
    Write-Host 'NEXUS ROUTING AUDIT' -ForegroundColor $Theme.Info
    $task = Read-Host 'Task to route'
    if ([string]::IsNullOrWhiteSpace($task)) { return }
    $profile = Get-NexusRoutingProfile -Prompt $task
    $candidates = @(Get-NexusAgentCandidates -Prompt $task -Count 8 -PoolSize 40 -ExcludeIds (Get-NexusDefaultExcludedIds))
    Write-Host ''
    Write-Host ('Preferred groups: ' + $(if ($profile.PreferredGroups.Count) { $profile.PreferredGroups -join ', ' } else { 'none detected' })) -ForegroundColor $Theme.Warning
    Write-Host ('Problem types:    ' + $(if ($profile.ProblemTypes.Count) { $profile.ProblemTypes -join ', ' } else { 'general task' })) -ForegroundColor $Theme.InfoDim
    Write-Host ''
    $candidates | Select-Object -First 20 ID,Name,Group,Score,Reasons | Format-Table -Wrap -AutoSize | Out-Host
    Write-Host '[+] Routing is deterministic-first: task relevance + exclusions + specialty coverage + historical success.' -ForegroundColor $Theme.Success
    Read-Host 'Enter'
}

function Show-AgentCapabilityProfiles {
    Clear-Host
    Show-CommandActivation -Command 'capabilities'
    Write-Host 'AGENT CAPABILITY PROFILES' -ForegroundColor $Theme.Info
    $q = Read-Host 'Agent ID or search term [Enter = show sample]'
    $rows = @()
    foreach ($id in ($script:AgentRegistry.Keys | Sort-Object {[int]$_})) {
        $e = $script:AgentRegistry[$id]
        if ([string]::IsNullOrWhiteSpace($q) -or $id -eq $q -or "$($e.name) $($e.group) $($e.tag) $($e.summary)" -match [regex]::Escape($q)) {
            $p = Get-NexusAgentCapabilityProfile -Entry $e
            $rows += [pscustomobject]@{ID=$id;Agent=$e.name;Group=$e.group;Expertise=(($p.PositiveTerms | Select-Object -First 10) -join ', ');Exclusions=(($p.NegativeTerms | Select-Object -First 6) -join ', ')}
        }
    }
    $rows | Select-Object -First 30 | Format-Table -Wrap -AutoSize | Out-Host
    Read-Host 'Enter'
}

function Show-AgentExclusionRules {
    Clear-Host
    Show-CommandActivation -Command 'exclusions'
    Write-Host 'AGENT EXCLUSION / NEGATIVE EXPERTISE RULES' -ForegroundColor $Theme.Info
    Write-Host ''
    Write-Host 'DEFAULT AUTOMATIC EXCLUSIONS' -ForegroundColor $Theme.Primary
    Write-Host ('  Enabled : {0}' -f $script:NexusDefaultExclusionEnabled) -ForegroundColor $(if($script:NexusDefaultExclusionEnabled){$Theme.Success}else{$Theme.Warning})
    $defaultIds=@(Get-NexusDefaultExcludedIds)
    if($defaultIds.Count){
        foreach($id in $defaultIds){
            $e=$script:AgentRegistry[[string]$id]
            if($e){Write-Host ('  {0,4}  {1,-34} [{2}]' -f $id,$e.name,$e.group) -ForegroundColor $Theme.Warning}
            else {Write-Host ('  {0,4}  [not registered]' -f $id) -ForegroundColor $Theme.Warning}
        }
    } else { Write-Host '  None. Automatic ID exclusions are disabled.' -ForegroundColor $Theme.MutedLight }
    Write-Host ''
    Write-Host 'GROUP-LEVEL NEGATIVE EXPERTISE' -ForegroundColor $Theme.Primary
    $groupNames=@($script:AgentRegistry.Values|ForEach-Object{[string]$_.group}|Where-Object{-not [string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique)
    $shown=0
    foreach($g in $groupNames){
        $e=$script:AgentRegistry.Values|Where-Object{$_.group -ieq $g}|Select-Object -First 1
        if($e){
            $p=Get-NexusAgentCapabilityProfile -Entry $e
            $negative=@($p.NegativeTerms|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)}|Select-Object -First 10)
            Write-Host ("{0,-38} avoid: {1}" -f $g,($(if($negative.Count){$negative -join ', '}else{'none explicitly configured'}))) -ForegroundColor $Theme.MutedLight
            $shown++
        }
    }
    if($shown -eq 0){Write-Host '[!] No agent groups with exclusion rules are currently registered.' -ForegroundColor $Theme.Warning}
    Write-Host ''
    Write-Host 'Default exclusions remove listed IDs from automatic Nexus selection.' -ForegroundColor $Theme.Warning
    Write-Host 'Negative-expertise terms are routing penalties; manual selection remains allowed.' -ForegroundColor $Theme.MutedLight
    Write-Host 'Change the defaults by editing $script:NexusDefaultExcludedIds near the routing layer.' -ForegroundColor $Theme.InfoDim
    Read-Host 'Enter'
}

# ---------------------------------------------------------------------------
# NEXUS ACTIVE TEAM WORKFLOW
# ---------------------------------------------------------------------------
# team      = build and store a four-agent team for the supplied task
# teamrun   = run the currently stored team against its task
# teamask   = build a team and immediately run it
#
# The active team is kept in script scope so the exact four selected agents
# are reused by teamrun rather than being re-selected a second time.
if ($null -eq $script:NexusActiveTeam) { $script:NexusActiveTeam = @() }
if ($null -eq $script:NexusActiveTask) { $script:NexusActiveTask = '' }
if ($null -eq $script:NexusActiveTeamCreated) { $script:NexusActiveTeamCreated = $null }

function Show-NexusActiveTeam {
    param([switch]$Pause)

    Clear-Host
    Show-CommandActivation -Command 'teamshow'
    Write-Host 'NEXUS ACTIVE EXPERT TEAM' -ForegroundColor $Theme.Info
    Write-Host '===================================================================' -ForegroundColor $Theme.Info

    if (-not $script:NexusActiveTeam -or $script:NexusActiveTeam.Count -eq 0) {
        Write-Host '[i] No active team. Run "team" or "teamask" first.' -ForegroundColor $Theme.Muted
        if ($Pause) { Read-Host 'Enter' }
        return
    }

    Write-Host ("Task: {0}" -f $script:NexusActiveTask) -ForegroundColor $Theme.Warning
    if ($script:NexusActiveTeamCreated) {
        Write-Host ("Created: {0}" -f $script:NexusActiveTeamCreated) -ForegroundColor $Theme.MutedLight
    }
    Write-Host ''

    $n = 0
    foreach ($id in $script:NexusActiveTeam) {
        $n++
        $e = $script:AgentRegistry[[string]$id]
        if ($null -eq $e) { continue }
        $c = [string]$e.color
        if ([string]::IsNullOrWhiteSpace($c)) { $c = [string]$Theme.Info }
        Write-Host ("  {0}. {1,3}  {2,-30}  [{3}]" -f $n,$id,$e.name,$e.group) -ForegroundColor $c
    }

    Write-Host ''
    Write-Host 'The stored team is the team teamrun will execute.' -ForegroundColor $Theme.MutedLight
    if ($Pause) { Read-Host 'Enter' }
}

function Invoke-NexusTeamBuilder {
    param(
        [string]$TaskPrompt,
        [switch]$AutoRun
    )

    Clear-Host
    Show-CommandActivation -Command 'team'
    Write-Host 'NEXUS DYNAMIC EXPERT TEAM BUILDER' -ForegroundColor $Theme.Info
    Write-Host '===================================================================' -ForegroundColor $Theme.Info

    if ([string]::IsNullOrWhiteSpace($TaskPrompt)) {
        $TaskPrompt = Read-Host 'Task'
    }
    if ([string]::IsNullOrWhiteSpace($TaskPrompt)) { return }

    Write-Host ''
    Write-Host '[*] Nexus is selecting four complementary specialists...' -ForegroundColor $Theme.Warning

    $ids = @(
        Invoke-NexusAgentSelection -TaskPrompt $TaskPrompt -Count 4 -ExcludeIds (Get-NexusDefaultExcludedIds) |
        ForEach-Object { [string]$_ } |
        Select-Object -Unique |
        Select-Object -First 4
    )

    if ($ids.Count -eq 0) {
        Write-Host '[!] Nexus could not build a team for this task.' -ForegroundColor $Theme.Error
        if (-not $AutoRun) { Read-Host 'Enter' }
        return
    }

    # Persist the exact selection. teamrun never re-runs the selector.
    $script:NexusActiveTeam = @($ids)
    $script:NexusActiveTask = [string]$TaskPrompt
    $script:NexusActiveTeamCreated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    Write-Host ''
    Write-Host 'ACTIVE TEAM CREATED' -ForegroundColor $Theme.Success
    Write-Host '-------------------------------------------------------------------' -ForegroundColor $Theme.Muted
    $n = 0
    foreach ($id in $script:NexusActiveTeam) {
        $n++
        $e = $script:AgentRegistry[[string]$id]
        if ($null -eq $e) { continue }
        $c = [string]$e.color
        if ([string]::IsNullOrWhiteSpace($c)) { $c = [string]$Theme.Info }
        Write-Host ("  {0}. {1,3}  {2,-30}  [{3}]" -f $n,$id,$e.name,$e.group) -ForegroundColor $c
    }
    Write-Host ''
    Write-Host 'Team design: primary specialist + complementary specialists + historical-performance adjustment.' -ForegroundColor $Theme.MutedLight
    Write-Host '[+] Team stored as the ACTIVE TEAM.' -ForegroundColor $Theme.Success

    if ($AutoRun) {
        Invoke-NexusTeamRun -TaskPrompt $TaskPrompt
    } else {
        Write-Host ''
        Write-Host 'Next: teamrun = execute this exact team.' -ForegroundColor $Theme.Warning
        Write-Host 'Shortcut: teamask = build a new team and execute it immediately.' -ForegroundColor $Theme.Warning
        Read-Host 'Enter'
    }
}

function Invoke-NexusTeamRun {
    param([string]$TaskPrompt)

    if (-not $script:NexusActiveTeam -or $script:NexusActiveTeam.Count -eq 0) {
        Write-Host '[!] No active team exists. Run "team" first.' -ForegroundColor $Theme.Error
        Read-Host 'Enter'
        return
    }

    if ([string]::IsNullOrWhiteSpace($TaskPrompt)) {
        $TaskPrompt = [string]$script:NexusActiveTask
    }
    if ([string]::IsNullOrWhiteSpace($TaskPrompt)) {
        $TaskPrompt = Read-Host 'Task'
    }
    if ([string]::IsNullOrWhiteSpace($TaskPrompt)) { return }

    # If a caller supplied a different task, update the stored task but preserve
    # the exact four-agent team. This makes teamrun deterministic.
    $script:NexusActiveTask = [string]$TaskPrompt

    Clear-Host
    Show-CommandActivation -Command 'teamrun'
    Write-Host 'NEXUS TEAM EXECUTION' -ForegroundColor $Theme.Info
    Write-Host '===================================================================' -ForegroundColor $Theme.Info
    Write-Host ("Task: {0}" -f $script:NexusActiveTask) -ForegroundColor $Theme.Warning
    Write-Host ''
    Write-Host 'Active specialists:' -ForegroundColor $Theme.Success

    $teamRows = @()
    foreach ($id in $script:NexusActiveTeam) {
        $e = $script:AgentRegistry[[string]$id]
        if ($null -eq $e) {
            Write-Host "  [!] Agent $id is no longer present in the registry." -ForegroundColor $Theme.Error
            continue
        }
        $teamRows += [pscustomobject]@{
            ID = [string]$id
            Name = [string]$e.name
            Group = [string]$e.group
            Model = [string]$e.model
        }
        Write-Host ("  {0,3}  {1,-30}  [{2}]" -f $id,$e.name,$e.group) -ForegroundColor $e.color
    }

    if ($teamRows.Count -eq 0) {
        Write-Host '[!] None of the stored team agents are available.' -ForegroundColor $Theme.Error
        Read-Host 'Enter'
        return
    }

    Write-Host ''
    Write-Host '[*] Running specialists. Each receives the original task plus its own role.' -ForegroundColor $Theme.Warning

    $responses = @()
    $index = 0

    foreach ($row in $teamRows) {
        $index++
        $rolePrompt = @"
You are Specialist $index of a four-agent CypraTeam expert team.

Your assigned identity:
- Agent ID: $($row.ID)
- Specialist: $($row.Name)
- Domain group: $($row.Group)

PRIMARY TASK:
$($script:NexusActiveTask)

WORK INSTRUCTIONS:
1. Analyze the task independently from your specialist perspective.
2. Identify the most likely answer, root cause, or solution.
3. Give concrete reasoning and actionable recommendations.
4. Clearly separate facts/inferences from assumptions.
5. Do not pretend another specialist has agreed with you.
6. If information is missing, state exactly what is missing.
7. Your response will be reviewed by NEXUS-PRIME with the other specialists.

Return a focused specialist report with:
- Assessment
- Key evidence/reasoning
- Recommended action
- Risks or uncertainties
"@

        Write-Host ''
        $agentEntry = $script:AgentRegistry[[string]$row.ID]
        $agentColor = if ($agentEntry -and -not [string]::IsNullOrWhiteSpace([string]$agentEntry.color)) { [string]$agentEntry.color } else { [string]$Theme.Info }
        Write-Host ("[$index/$($teamRows.Count)] $($row.Name) [$($row.Group)]") -ForegroundColor $agentColor

        try {
            $result = Invoke-InstalledAgentQuery -ModelName $row.Model -Prompt $rolePrompt -TrackLearning

            $output = [string]$result.Output
            if ([string]::IsNullOrWhiteSpace($output)) {
                Write-Host "  [!] No usable response (exit code $($result.ExitCode))." -ForegroundColor $Theme.Error
                $output = "[NO USABLE RESPONSE: exit code $($result.ExitCode)]"
            } else {
                Write-Host '  [+] Specialist response received.' -ForegroundColor $Theme.Success
                $output | Out-Host
            }

            $responses += [pscustomobject]@{
                ID = $row.ID
                Name = $row.Name
                Group = $row.Group
                Model = $row.Model
                Output = $output
                ExitCode = $result.ExitCode
            }
        } catch {
            $err = $_.Exception.Message
            Write-Host "  [!] Specialist failed: $err" -ForegroundColor $Theme.Error
            $responses += [pscustomobject]@{
                ID = $row.ID
                Name = $row.Name
                Group = $row.Group
                Model = $row.Model
                Output = "[SPECIALIST FAILURE] $err"
                ExitCode = -1
            }
        }
    }

    if ($responses.Count -eq 0) {
        Write-Host '[!] The team produced no responses.' -ForegroundColor $Theme.Error
        Read-Host 'Enter'
        return
    }

    Write-Host ''
    Write-Host '===================================================================' -ForegroundColor $Theme.Info
    Write-Host 'NEXUS-PRIME TEAM SYNTHESIS' -ForegroundColor $Theme.Info
    Write-Host '===================================================================' -ForegroundColor $Theme.Info
    Write-Host '[*] Nexus-Prime is comparing the four specialist reports...' -ForegroundColor $Theme.Warning

    $reports = @()
    foreach ($r in $responses) {
        $reports += @"
--- SPECIALIST $($r.ID): $($r.Name) [$($r.Group)] ---
$($r.Output)
"@
    }

    $synthesisPrompt = @"
You are NEXUS-PRIME, the final lead for a four-agent expert team.

ORIGINAL TASK:
$($script:NexusActiveTask)

SPECIALIST REPORTS:
$($reports -join "`n`n")

SYNTHESIS RULES:
1. Compare the reports rather than simply voting.
2. Identify agreements, disagreements, and important omissions.
3. Give the strongest evidence-supported conclusion.
4. Prefer concrete, actionable steps.
5. Do not invent facts, tests, sources, or actions that were not performed.
6. If the specialists are uncertain or disagree, say so explicitly.
7. Preserve useful specialist-specific details when they improve the answer.

Return:
FINAL ASSESSMENT:
RECOMMENDED ACTION:
KEY REASONING:
RISKS / UNCERTAINTIES:
NEXT STEPS:
"@

    try {
        $final = Invoke-InstalledAgentQuery -ModelName 'nexus-prime' -Prompt $synthesisPrompt -TrackLearning
        if ($final.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$final.Output)) {
            Write-Host ''
            Write-Host 'FINAL NEXUS TEAM ANSWER' -ForegroundColor $Theme.Success
            Write-Host '-------------------------------------------------------------------' -ForegroundColor $Theme.Muted
            $final.Output | Out-Host

            # Persist the completed team result as a normal conversation record
            # so it is available to the existing Memory/Knowledge systems.
            Save-AgentRunOutcome -ModelName 'nexus-prime' `
                -UserPrompt $script:NexusActiveTask `
                -Response ([string]$final.Output) `
                -Source 'nexus-team' `
                -KnowledgePrompt ("Nexus four-agent team task:`n" + $script:NexusActiveTask)

            Write-Host ''
            Write-Host '[+] Team execution complete. The selected team remains active for another teamrun.' -ForegroundColor $Theme.Success
        } else {
            Write-Host '[!] Nexus-Prime synthesis failed. Specialist reports are still shown above.' -ForegroundColor $Theme.Error
        }
    } catch {
        Write-Host "[!] Nexus-Prime synthesis error: $($_.Exception.Message)" -ForegroundColor $Theme.Error
    }

    Read-Host 'Enter'
}

function Invoke-NexusTeamAsk {
    Clear-Host
    Show-CommandActivation -Command 'teamask'
    Write-Host 'NEXUS TEAM ASK' -ForegroundColor $Theme.Info
    Write-Host 'Build a new four-agent team and execute it immediately.' -ForegroundColor $Theme.MutedLight
    Write-Host ''
    $task = Read-Host 'Task'
    if ([string]::IsNullOrWhiteSpace($task)) { return }

    # Builder stores the exact team and immediately passes it to teamrun.
    Invoke-NexusTeamBuilder -TaskPrompt $task -AutoRun
}

function Invoke-NexusTeamClear {
    Show-CommandActivation -Command 'teamclear';
    $script:NexusActiveTeam = @()
    $script:NexusActiveTask = ''
    $script:NexusActiveTeamCreated = $null
    Write-Host '[+] Active Nexus team cleared.' -ForegroundColor $Theme.Success
    Read-Host 'Enter'
}

function Show-AgentPerformanceHistory {
    Clear-Host
    Show-CommandActivation -Command 'performance'
    Write-Host 'AGENT PERFORMANCE HISTORY' -ForegroundColor $Theme.Info
    if (-not (Test-Path $script:MatrixLearningFile)) {
        Write-Host 'No learning data yet. Run an agent query first so performance records can be created.' -ForegroundColor $Theme.Muted
        Read-Host 'Enter'; return
    }
    $filter = Read-Host 'Agent ID or name (Enter for all)'
    $resolved = $null
    if (-not [string]::IsNullOrWhiteSpace($filter)) {
        $resolved = Resolve-AgentIdentifier $filter
        if ($null -eq $resolved) {
            Write-Host "[!] No registered agent matched '$filter'. Use an ID, agent name, model, or tag." -ForegroundColor $Theme.Error
            Read-Host 'Enter'; return
        }
        Write-Host ("[+] Resolved: {0} ({1})" -f $resolved,$script:AgentRegistry[[string]$resolved].name) -ForegroundColor $Theme.Success
    }
    try {
        $d = Get-Content $script:MatrixLearningFile -Raw | ConvertFrom-Json
        $rows = @()
        if ($d.agents) {
            foreach ($prop in $d.agents.psobject.Properties) {
                if ($resolved -and [string]$prop.Name -ne [string]$script:AgentRegistry[[string]$resolved].model) {
                    continue
                }
                $runs=[int]$prop.Value.runs; $success=[int]$prop.Value.success
                $rate=if($runs){[math]::Round(($success/$runs)*100,1)}else{0}
                $avg=[math]::Round([double]$prop.Value.total_ms/[math]::Max(1,$runs),0)
                $rows += [pscustomobject]@{Agent=$prop.Name;Runs=$runs;SuccessRate="$rate%";SuccessRateValue=[double]$rate;AvgMs=$avg;LastUsed=$prop.Value.last_used}
            }
        }
        if ($rows.Count -eq 0) {
            Write-Host '[i] No performance records matched the selected agent.' -ForegroundColor $Theme.Warning
        } else {
            $rows | Sort-Object -Property @{Expression='SuccessRateValue';Descending=$true}, @{Expression='AvgMs';Descending=$false} | Select-Object -First 50 Agent,Runs,SuccessRate,AvgMs,LastUsed | Format-Table -AutoSize | Out-Host
        }
    } catch { Write-Host "[!] Learning data could not be read: $($_.Exception.Message)" -ForegroundColor $Theme.Warning }
    Read-Host 'Enter'
}

function Invoke-AgentReplacementAdvisor {
    Clear-Host
    Show-CommandActivation -Command 'replace'
    Write-Host 'SPECIALIST REPLACEMENT ADVISOR' -ForegroundColor $Theme.Info
    $task = Read-Host 'Task'
    if ([string]::IsNullOrWhiteSpace($task)) { return }
    $current = Read-Host 'Current agent ID'
    $currentResolved = Resolve-AgentIdentifier $current
    if ($null -eq $currentResolved) { Write-Host '[!] Unknown agent ID or name.' -ForegroundColor $Theme.Error; Read-Host 'Enter'; return }
    $current = $currentResolved
    $alternatives = @(Get-NexusAgentCandidates -Prompt $task -Count 10 -PoolSize 40 -ExcludeIds (@((Get-NexusDefaultExcludedIds) + [string]$current | Select-Object -Unique)))
    Write-Host "Current: $current / $($script:AgentRegistry[$current].name)" -ForegroundColor $Theme.Warning
    $alternatives | Select-Object -First 10 ID,Name,Group,Score,Reasons | Format-Table -Wrap -AutoSize | Out-Host
    Write-Host '[+] Use the top alternative when the current specialist is off-topic, failing repeatedly, or too slow.' -ForegroundColor $Theme.Success
    Read-Host 'Enter'
}

function Invoke-AgentEvaluation {
    Clear-Host
    Show-CommandActivation -Command 'evaluate'
    Write-Host 'AGENT EVALUATION HARNESS' -ForegroundColor $Theme.Info
    $id = Read-Host 'Agent ID to evaluate'
    $resolvedId = Resolve-AgentIdentifier $id
    if ($null -eq $resolvedId) { Write-Host '[!] Unknown agent ID or name.' -ForegroundColor $Theme.Error; Read-Host 'Enter'; return }
    $id = $resolvedId
    $task = Read-Host 'Test task'
    if ([string]::IsNullOrWhiteSpace($task)) { return }
    $e=$script:AgentRegistry[$id]
    $prompt="Evaluate this task as the assigned specialist. State: RELEVANCE, ASSUMPTIONS, ANSWER, UNCERTAINTIES, VERIFICATION STEPS. Stay within the declared specialty: $($e.group) / $($e.name).`nTASK:`n$task"
    $r=Invoke-InstalledAgentQuery -ModelName $e.model -Prompt $prompt -TrackLearning
    $r.Output | Out-Host
    Write-Host ("ExitCode={0}  DurationMs={1}  Truncated={2}" -f $r.ExitCode,$r.DurationMs,$r.Truncated) -ForegroundColor $Theme.InfoDim
    Read-Host 'Enter'
}

function Invoke-NexusRoutingRegression {
    Clear-Host
    Show-CommandActivation -Command 'routing-test'
    Write-Host 'NEXUS ROUTING REGRESSION SUITE' -ForegroundColor $Theme.Info
    $tests=@(
        @{Task='leg infection with redness and swelling'; Expected=@('Medical & Cognitive','Medical','Allied Health & Therapy')},
        @{Task='PowerShell script crashes with a parser error'; Expected=@('Software Engineering','Development','Computer Science','Platform & Reliability')},
        @{Task='ransomware breach investigation'; Expected=@('Cybersecurity','Security & Identity','Security & Data')},
        @{Task='truck brake grinding noise'; Expected=@('Transportation','Trades & Craftsmanship','Manufacturing','Engineering & Design','Hardware & Systems')},
        @{Task='review a contract for liability'; Expected=@('Legal & Governance','Legal & Regulatory Specialties')}
    )
    foreach($t in $tests){
        $ids=@(Invoke-NexusAgentSelection -TaskPrompt $t.Task -Count 4 -ExcludeIds (Get-NexusDefaultExcludedIds))
        $groups=@($ids | ForEach-Object {[string]$script:AgentRegistry[[string]$_].group})
        $hit=$false; foreach($g in $groups){if($t.Expected -contains $g){$hit=$true;break}}
        Write-Host ("{0,-5} {1}" -f $(if($hit){'PASS'}else{'FAIL'}),$t.Task) -ForegroundColor $(if($hit){$Theme.Success}else{$Theme.Error})
        Write-Host ('      ' + ($groups -join ' | ')) -ForegroundColor $Theme.MutedLight
    }
    Read-Host 'Enter'
}

function Invoke-MemoryKnowledgeBridge {
    Clear-Host
    Show-CommandActivation -Command 'memorybridge'
    Write-Host 'MEMORY / KNOWLEDGE BRIDGE' -ForegroundColor $Theme.Info
    Initialize-MatrixAddonStorage
    $memoryCount=@(Get-ChildItem $script:MatrixMemoryRoot -Recurse -File -ErrorAction SilentlyContinue).Count
    $knowledgeCount=@(Get-ChildItem $script:MatrixKnowledgeRoot -Recurse -File -ErrorAction SilentlyContinue).Count
    Write-Host "Memory files   : $memoryCount" -ForegroundColor $Theme.Info
    Write-Host "Knowledge files: $knowledgeCount" -ForegroundColor $Theme.Info
    if($memoryCount -eq 0){Write-Host '[i] Memory is empty; run an agent query or interactive session with a successful response.' -ForegroundColor $Theme.Warning}
    if($knowledgeCount -eq 0){Write-Host '[i] Knowledge is empty; successful conversations are archived there and the knowledge index is built by the knowledge command.' -ForegroundColor $Theme.Warning}
    Write-Host 'Bridge policy: memory supplies prior conversation context; knowledge supplies indexed durable records.' -ForegroundColor $Theme.MutedLight
    Read-Host 'Enter'
}

function Invoke-NexusConfidenceReport {
    Clear-Host
    Show-CommandActivation -Command 'confidence-report'
    Write-Host 'NEXUS CONFIDENCE REPORT' -ForegroundColor $Theme.Info
    $task=Read-Host 'Task'
    if([string]::IsNullOrWhiteSpace($task)){return}
    $ids=@(Invoke-NexusAgentSelection -TaskPrompt $task -Count 4 -ExcludeIds (Get-NexusDefaultExcludedIds))
    $rows=@()
    foreach($id in $ids){
        $e=$script:AgentRegistry[[string]$id]
        $hist=Get-NexusHistoricalScore -ModelName $e.model
        $rows += [pscustomobject]@{ID=$id;Agent=$e.name;Group=$e.group;HistoricalAdjustment=$hist}
    }
    $rows|Format-Table -AutoSize|Out-Host
    Write-Host '[i] This is a routing-confidence report, not a claim that the selected agents are factually correct.' -ForegroundColor $Theme.MutedLight
    Read-Host 'Enter'
}

function Get-NexusAgentCandidates {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [int]$Count = 4,
        [int]$PoolSize = 60,
        [string[]]$ExcludeIds = (Get-NexusDefaultExcludedIds)
    )

    $promptText = ([string]$Prompt).ToLower()
    $promptTerms = @($promptText -split '[^a-z0-9]+' | Where-Object { $_.Length -ge 3 } | Select-Object -Unique)
    $signals = @(Get-NexusTaskDomainSignals -Prompt $Prompt)
    $routingProfile = Get-NexusRoutingProfile -Prompt $Prompt

    $scored = foreach ($id in ($script:AgentRegistry.Keys | Sort-Object {[int]$_})) {
        $entry = $script:AgentRegistry[[string]$id]
        if ($ExcludeIds -contains [string]$id) { continue }

        $haystack = "$($entry.name) $($entry.tag) $($entry.group) $($entry.summary)".ToLower()
        $score = 0
        $reasons = New-Object System.Collections.Generic.List[string]
        $cap = Get-NexusAgentCapabilityProfile -Entry $entry

        foreach ($term in $promptTerms) {
            $termPattern = '\b' + [regex]::Escape($term) + '\b'
            if ($entry.name.ToLower() -match $termPattern) { $score += 10; [void]$reasons.Add("name:$term") }
            elseif ($haystack -match $termPattern) { $score += 2; [void]$reasons.Add("meta:$term") }
        }

        $score += Get-NexusAgentDomainBoost -Entry $entry -Signals $signals
        $specific = Get-NexusProblemSpecificScore -Prompt $Prompt -Entry $entry -Profile $cap
        if ($specific -ne 0) { $score += $specific; [void]$reasons.Add("specific:$specific") }

        foreach ($group in @($routingProfile.PreferredGroups)) {
            if ([string]$entry.group -eq [string]$group) { $score += 28; [void]$reasons.Add("domain:$group") }
        }

        # Explicit negative expertise is stronger than a weak generic keyword match.
        foreach ($term in @($cap.NegativeTerms)) {
            if ($promptText -match ('\b' + [regex]::Escape([string]$term) + '\b')) { $score -= 12; [void]$reasons.Add("exclude:$term") }
        }

        $hist = Get-NexusHistoricalScore -ModelName ([string]$entry.model)
        if ($hist -ne 0) { $score += $hist; [void]$reasons.Add("history:$hist") }

        [pscustomobject]@{
            Id      = [string]$id
            Score   = [int]$score
            Name    = [string]$entry.name
            Tag     = [string]$entry.tag
            Group   = [string]$entry.group
            Summary = ([string]$entry.summary -replace '\s+', ' ').Trim()
            Reasons = (($reasons | Select-Object -Unique | Select-Object -First 8) -join ', ')
        }
    }

    return @(
        $scored |
        Sort-Object -Property @{Expression='Score';Descending=$true}, @{Expression='Id';Descending=$false} |
        Select-Object -First ([Math]::Max($PoolSize, 48))
    )
}

function Invoke-NexusAgentSelection {
    param(
        [Parameter(Mandatory = $true)][string]$TaskPrompt,
        [int]$Count = 4,
        [string[]]$ExcludeIds = (Get-NexusDefaultExcludedIds)
    )

    $profile = Get-NexusRoutingProfile -Prompt $TaskPrompt
    $candidates = @(Get-NexusAgentCandidates -Prompt $TaskPrompt -Count $Count -PoolSize 60 -ExcludeIds $ExcludeIds)
    if ($candidates.Count -eq 0) { return @() }

    # Deterministic-first routing is deliberate. It prevents a small local Nexus
    # model from hallucinating unrelated IDs or overriding a strong local match.
    $selectedCandidates = @(Get-NexusTeamSelection -Candidates $candidates -Count $Count -PreferredGroups @($profile.PreferredGroups))
    $selected = @($selectedCandidates | ForEach-Object { [string]$_.Id } | Select-Object -First $Count)

    Write-Host '[*] NEXUS-PRIME routing mode: deterministic semantic specialist selection.' -ForegroundColor $Theme.Info
    if ($profile.PreferredGroups.Count -gt 0) {
        Write-Host ('    Preferred specialist groups: ' + ($profile.PreferredGroups -join ', ')) -ForegroundColor $Theme.InfoDim
    }
    if ($profile.ProblemTypes.Count -gt 0) {
        Write-Host ('    Problem types: ' + ($profile.ProblemTypes -join ', ')) -ForegroundColor $Theme.InfoDim
    }

    if ($selected.Count -gt 0) {
        $pickedText = foreach ($id in $selected) {
            $e = $script:AgentRegistry[[string]$id]
            "$id ($($e.name) / $($e.group))"
        }
        Write-Host ('[+] NEXUS-PRIME selected: ' + ($pickedText -join ' | ')) -ForegroundColor $Theme.Success
    }
    return @($selected)
}

function Get-GroupMembers {
    param([string]$GroupName)

    $members = @()
    foreach ($id in ($script:AgentRegistry.Keys | Sort-Object {[int]$_})) {
        $entryGroup = [string]$script:AgentRegistry[$id].group
        if (($GroupName -ieq 'Unassigned' -and [string]::IsNullOrWhiteSpace($entryGroup)) -or $entryGroup -ieq $GroupName) {
            $members += [int]$id
        }
    }
    return $members
}

function Show-AgentGroups {
    while ($true) {
        Clear-Host
    Show-CommandActivation -Command 'groups';
        $line = '═' * ([Math]::Max(60, $Host.UI.RawUI.WindowSize.Width) - 2)

        Write-Host "╔$line╗" -ForegroundColor $Theme.Info
        Write-Host "║ AGENT GROUP MATRIX / NODE ORGANIZATION" -ForegroundColor $Theme.Info
        Write-Host "╚$line╝" -ForegroundColor $Theme.Info
        Write-Host ""

        # Build the group list directly from the live AgentRegistry.
        # This is intentionally dynamic so newly added agents/groups can never
        # disappear from the GROUPS interface because of a stale hard-coded list.
        $groupRows = @(
            $script:AgentRegistry.Keys |
                ForEach-Object {
                    $entry = $script:AgentRegistry[[string]$_]
                    if ($null -ne $entry -and -not [string]::IsNullOrWhiteSpace([string]$entry.group)) {
                        [pscustomobject]@{
                            Group = [string]$entry.group
                            Id    = [int]$entry.id
                            Color = [string]$entry.color
                        }
                    }
                } |
                Group-Object Group |
                ForEach-Object {
                    $first = $_.Group | Sort-Object Id | Select-Object -First 1
                    [pscustomobject]@{
                        Group = [string]$_.Name
                        Count = [int]$_.Count
                        FirstId = [int]$first.Id
                        Color = if ([string]::IsNullOrWhiteSpace([string]$first.Color)) { [string]$Theme.Info } else { [string]$first.Color }
                    }
                } |
                Sort-Object FirstId
        )

        if ($groupRows.Count -eq 0) {
            Write-Host "[!] No agent groups are registered." -ForegroundColor $Theme.Warning
            Read-Host "Enter"
            return
        }

        Write-Host ("  {0} groups / {1} agents registered" -f $groupRows.Count, $script:AgentRegistry.Count) -ForegroundColor $Theme.MutedLight
        Write-Host "  Group color follows the first agent in that group. Agent entries use their assigned registry color." -ForegroundColor $Theme.Muted
        Write-Host ""

        for ($i = 0; $i -lt $groupRows.Count; $i++) {
            $row = $groupRows[$i]
            Write-Host ("[{0,2}] {1,-38} {2,3} agents" -f ($i + 1), $row.Group, $row.Count) -ForegroundColor $row.Color
        }

        Write-Host ""
        Write-Host "Select a group number/name to inspect its agents, or press Enter to return." -ForegroundColor $Theme.Muted
        $choice = (Read-Host "Group").Trim()

        if ([string]::IsNullOrWhiteSpace($choice)) {
            return
        }

        $selectedGroup = $null

        if ($choice -match '^\d+$') {
            $groupIndex = [int]$choice - 1
            if ($groupIndex -ge 0 -and $groupIndex -lt $groupRows.Count) {
                $selectedGroup = [string]$groupRows[$groupIndex].Group
            }
        } else {
            foreach ($row in $groupRows) {
                if ($row.Group -ieq $choice) {
                    $selectedGroup = [string]$row.Group
                    break
                }
            }
        }

        if ($null -eq $selectedGroup) {
            Write-Host "Unknown group. Use a number from 1-$($groupRows.Count) or the group name." -ForegroundColor $Theme.Warning
            Start-Sleep -Seconds 1
            continue
        }

        $members = @(Get-GroupMembers $selectedGroup)

        while ($true) {
            Clear-Host
            $line = '═' * ([Math]::Max(60, $Host.UI.RawUI.WindowSize.Width) - 2)

            Write-Host "╔$line╗" -ForegroundColor $Theme.Info
            Write-Host ("║ GROUP: {0} / {1} AGENTS" -f $selectedGroup.ToUpper(), $members.Count) -ForegroundColor $Theme.Info
            Write-Host "╚$line╝" -ForegroundColor $Theme.Info
            Write-Host ""
            Write-Host "  ID   AGENT NAME                         TAG / COLOR" -ForegroundColor $Theme.MutedLight
            Write-Host "  ---  ---------------------------------  ------------------------" -ForegroundColor $Theme.Muted

            foreach ($id in $members) {
                $entry = $script:AgentRegistry[[string]$id]
                if ($null -eq $entry) { continue }

                # Each agent is rendered with its own registry color.
                $agentColor = [string]$entry.color
                if ([string]::IsNullOrWhiteSpace($agentColor)) {
                    $agentColor = [string]$Theme.Info
                }

                Write-Host ("  {0,3}  ■ {1,-33} [{2}]" -f $id, $entry.name, $entry.tag) -ForegroundColor $agentColor
            }

            Write-Host ""
            Write-Host "  ■ Agent color = registry color    |    IDs 401-700 are included automatically." -ForegroundColor $Theme.MutedLight
            Write-Host ""
            Write-Host "Enter an Agent ID to launch it, B to choose another group, or Enter to return." -ForegroundColor $Theme.Muted
            $agentChoice = (Read-Host "Agent").Trim()

            if ([string]::IsNullOrWhiteSpace($agentChoice)) {
                return
            }

            if ($agentChoice -ieq 'b' -or $agentChoice -ieq 'back') {
                break
            }

            if ($agentChoice -match '^\d+$') {
                $agentId = [int]$agentChoice
                if ($members -contains $agentId) {
                    $script:PendingAgentSelection = [string]$agentId
                    return
                }
            }

            Write-Host "That Agent ID is not in this group." -ForegroundColor $Theme.Warning
            Start-Sleep -Seconds 1
        }
    }
}

function Invoke-AgentSearch {
    Clear-Host
    Show-CommandActivation -Command 'find'
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host "             🔍 AGENT KEYWORD SEARCH 🔍" -ForegroundColor $Theme.Info
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host " Searches agent tag, summary, group, and model name." -ForegroundColor $Theme.Muted
    Write-Host ""
    $keyword = Read-Host "Enter a search term (or press Enter to cancel)"

    if ([string]::IsNullOrWhiteSpace($keyword)) {
        return
    }

    $foundAgents = @()
    foreach ($id in ($script:AgentRegistry.Keys | Sort-Object {[int]$_})) {
        $entry = $script:AgentRegistry[$id]
        $haystack = "$($entry.tag) $($entry.summary) $($entry.group) $($entry.model)"
        if ($haystack -imatch [regex]::Escape($keyword)) {
            $foundAgents += $entry
        }
    }

    Write-Host ""
    if ($foundAgents.Count -eq 0) {
        Write-Host "[!] No agents matched '$keyword'." -ForegroundColor $Theme.Warning
        Start-Sleep -Seconds 1
        return
    }

    Write-Host "Found $($foundAgents.Count) matching agent(s):" -ForegroundColor $Theme.Success
    Write-Host "--------------------------------------------------" -ForegroundColor $Theme.Muted
    foreach ($entry in $foundAgents) {
        Write-Host ("{0,3}  ■ {1,-18} [{2}]  {3}" -f $entry.id, $entry.name, $entry.tag, $entry.group) -ForegroundColor $Theme.Info
    }
    Write-Host "--------------------------------------------------" -ForegroundColor $Theme.Muted
    Write-Host ""
    Write-Host "Enter an Agent ID to launch it, or press Enter to return." -ForegroundColor $Theme.Muted
    $agentChoice = (Read-Host "Agent").Trim()

    if ($agentChoice -match '^\d+$') {
        $agentId = [int]$agentChoice
        if ($foundAgents.id -contains $agentId) {
            $script:PendingAgentSelection = [string]$agentId
        } else {
            Write-Host "[!] That Agent ID was not in the search results." -ForegroundColor $Theme.Warning
            Start-Sleep -Seconds 1
        }
    }
}

function Show-AgentRelationshipMap {
    # Fresh, interactive agent directory/map.
    # Behavior:
    #   - Rebuilds the live registry each activation.
    #   - Uses real registry groups when available.
    #   - If the registry is effectively ungrouped, uses a single UNASSIGNED
    #     directory and pages the agents instead of pretending there are groups.
    #   - N/P cycles groups when multiple groups exist; otherwise it cycles pages.
    #   - D shows details for the current group/page.
    #   - A opens a searchable all-agent directory.
    #   - R refreshes the registry in place.

    Clear-Host
    Show-CommandActivation -Command 'map'
    Sync-AgentRegistry

    $allAgents = @($script:AgentRegistry.Values | Sort-Object {[int]$_.id})
    if ($allAgents.Count -eq 0) {
        Clear-Host
        Write-Host 'CYPRATEAM AGENT MAP' -ForegroundColor $Theme.Info
        Write-Host '[!] Agent registry is empty; no map can be displayed.' -ForegroundColor $Theme.Warning
        Read-Host 'Press Enter to return to Dashboard'
        return
    }

    function Build-MapGroups {
        param([object[]]$Agents)

        $raw = @(
            $Agents |
            Group-Object {
                $g = [string]$_.group
                if ([string]::IsNullOrWhiteSpace($g)) { 'Unassigned' } else { $g.Trim() }
            } |
            ForEach-Object {
                $items = @($_.Group | Sort-Object {[int]$_.id})
                [pscustomobject]@{
                    Group  = [string]$_.Name
                    Count  = $items.Count
                    First  = [int]$items[0].id
                    Last   = [int]$items[-1].id
                    Agents = $items
                }
            } |
            Sort-Object @{Expression='Group'; Ascending=$true}
        )

        return $raw
    }

    $groups = @(Build-MapGroups $allAgents)
    $excludedIds = @(Get-NexusDefaultExcludedIds)

    # A large 'Unassigned' bucket is more useful as a directory than a fake group.
    $singleUngrouped = ($groups.Count -eq 1 -and $groups[0].Group -eq 'Unassigned')
    $groupIndex = 0
    $pageIndex = 0
    $pageSize = 28

    :MAPLOOP while ($true) {
        # Refresh dimensions every redraw so the map behaves well after resizing.
        $width = [Math]::Max(96, [int]$Host.UI.RawUI.WindowSize.Width)
        $inner = [Math]::Max(90, $width - 2)
        $line = '═' * $inner

        $modeLabel = if ($singleUngrouped) { 'DIRECTORY / PAGE MODE' } elseif ($groups.Count -gt 1) { 'GROUP MODE' } else { 'GROUP / PAGE MODE' }
        $selectedGroup = $groups[$groupIndex]
        $totalPages = [Math]::Max(1, [int][Math]::Ceiling($selectedGroup.Count / [double]$pageSize))
        if ($pageIndex -ge $totalPages) { $pageIndex = $totalPages - 1 }
        if ($pageIndex -lt 0) { $pageIndex = 0 }

        $startIndex = $pageIndex * $pageSize
        $visibleAgents = @($selectedGroup.Agents | Select-Object -Skip $startIndex -First $pageSize)

        Clear-Host
        Write-Host "╔$line╗" -ForegroundColor $Theme.Info
        $title = if ($singleUngrouped) {
            "║ CYPRATEAM AGENT DIRECTORY  |  PAGE $($pageIndex + 1)/$totalPages"
        } else {
            "║ CYPRATEAM AGENT RELATIONSHIP MAP  |  GROUP $($groupIndex + 1)/$($groups.Count)  |  PAGE $($pageIndex + 1)/$totalPages"
        }
        $title = $title.PadRight($inner) + '║'
        Write-Host $title -ForegroundColor $Theme.Info
        Write-Host "╚$line╝" -ForegroundColor $Theme.Info
        Write-Host ""

        $excludedLabel = if ($excludedIds.Count) { $excludedIds -join ', ' } else { 'NONE' }
        Write-Host ("  LIVE REGISTRY : {0} agents | {1} groups | ID RANGE {2}-{3}" -f $allAgents.Count,$groups.Count,$allAgents[0].id,$allAgents[-1].id) -ForegroundColor $Theme.Success
        Write-Host ("  DEFAULT EXCLUSIONS : {0}" -f $excludedLabel) -ForegroundColor $Theme.Warning
        Write-Host ("  MAP MODE      : {0}" -f $modeLabel) -ForegroundColor $Theme.MutedLight
        Write-Host ""

        # Group rail: concise and readable even with many groups.
        if ($groups.Count -gt 1) {
            $groupRail = @()
            $railStart = [Math]::Max(0, $groupIndex - 2)
            $railEnd   = [Math]::Min($groups.Count - 1, $railStart + 4)
            if (($railEnd - $railStart) -lt 4) { $railStart = [Math]::Max(0, $railEnd - 4) }
            for ($gi=$railStart; $gi -le $railEnd; $gi++) {
                $mark = if ($gi -eq $groupIndex) { '▶' } else { ' ' }
                $g = $groups[$gi]
                $groupRail += (" {0} {1} ({2})" -f $mark,$g.Group,$g.Count)
            }
            Write-Host ("  GROUPS: {0}" -f ($groupRail -join '   ')) -ForegroundColor $Theme.Primary
            Write-Host ""
        }

        $groupTitle = if ($singleUngrouped) { 'ALL REGISTERED AGENTS' } else { $selectedGroup.Group.ToUpperInvariant() }
        Write-Host ("  {0}   |   IDs {1}-{2}   |   {3} AGENT(S)   |   showing {4}-{5}" -f $groupTitle,$selectedGroup.First,$selectedGroup.Last,$selectedGroup.Count,($startIndex+1),($startIndex+$visibleAgents.Count)) -ForegroundColor $Theme.Primary
        Write-Host ("  {0}" -f ('─' * [Math]::Min(108,$inner-4))) -ForegroundColor $Theme.Muted

        # Column widths from visible page content so TAG has no giant empty pad.
        $idWidth = [Math]::Max(3, ([string][int]$allAgents[-1].id).Length)
        $nameWidth = 4
        $groupWidth = 5
        $tagWidth = 3
        foreach ($agent in $visibleAgents) {
            $n = [string]$agent.name
            $g = if ([string]::IsNullOrWhiteSpace([string]$agent.group)) { 'Unassigned' } else { [string]$agent.group }
            $t = [string]$agent.tag
            if ($n.Length -gt $nameWidth) { $nameWidth = $n.Length }
            if ($g.Length -gt $groupWidth) { $groupWidth = $g.Length }
            if ($t.Length -gt $tagWidth) { $tagWidth = $t.Length }
        }
        $nameWidth = [Math]::Min($nameWidth, 28)
        $groupWidth = [Math]::Min($groupWidth, 28)
        $tagWidth = [Math]::Min($tagWidth, 24)
        $rightBudget = $inner - 4
        $fixedWidth = 1 + 1 + $idWidth + 2 + $nameWidth + 2 + $groupWidth + 2 + 1 + $tagWidth + 1
        if ($fixedWidth -gt $rightBudget) {
            $over = $fixedWidth - $rightBudget
            $cutName = [Math]::Min([Math]::Ceiling($over * 0.5), [Math]::Max(0, $nameWidth - 12))
            $nameWidth -= $cutName
            $over -= $cutName
            $cutGroup = [Math]::Min([Math]::Ceiling($over * 0.5), [Math]::Max(0, $groupWidth - 10))
            $groupWidth -= $cutGroup
            $over -= $cutGroup
            $tagWidth = [Math]::Max(6, $tagWidth - $over)
        }

        Write-Host ("  {0,-$idWidth}  {1,-$nameWidth}  {2,-$groupWidth}  {3}" -f 'ID','AGENT','GROUP','TAG') -ForegroundColor $Theme.MutedLight
        Write-Host ("  {0}  {1}  {2}  {3}" -f ('─'*$idWidth),('─'*$nameWidth),('─'*$groupWidth),('─'*([Math]::Min($tagWidth+2, 26)))) -ForegroundColor $Theme.Muted

        foreach ($agent in $visibleAgents) {
            $idText = ([string][int]$agent.id).PadLeft($idWidth)
            $nameText = [string]$agent.name
            $groupText = if ([string]::IsNullOrWhiteSpace([string]$agent.group)) { 'Unassigned' } else { [string]$agent.group }
            $tagText = [string]$agent.tag

            if ($nameText.Length -gt $nameWidth) { $nameText = $nameText.Substring(0,[Math]::Max(1,$nameWidth-1)) + '…' }
            if ($groupText.Length -gt $groupWidth) { $groupText = $groupText.Substring(0,[Math]::Max(1,$groupWidth-1)) + '…' }
            if ($tagText.Length -gt $tagWidth) { $tagText = $tagText.Substring(0,[Math]::Max(1,$tagWidth-1)) + '…' }

            $excluded = $excludedIds -contains [string]$agent.id
            $rowColor = if ($excluded) { $Theme.Warning } elseif ($agent.color) { $agent.color } else { $Theme.Info }
            $marker = if ($excluded) { '!' } else { '·' }
            Write-Host (" {0} {1}  {2,-$nameWidth}  {3,-$groupWidth}  [{4}]" -f $marker,$idText,$nameText,$groupText,$tagText) -ForegroundColor $rowColor
        }

        Write-Host ""
        $navText = if ($groups.Count -gt 1) {
            '[N] Next group  [P] Previous group  [Right/Left] Group  [Up/Down] Page'
        } else {
            '[N] Next page  [P] Previous page  [Up/Down] Page'
        }
        Write-Host ("  {0}" -f $navText) -ForegroundColor $Theme.InfoDim
        Write-Host "  [D] Details  [A] All IDs  [R] Refresh  [Enter] Dashboard" -ForegroundColor $Theme.InfoDim

        try {
            $keyInfo = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            $choice = if ($keyInfo.Character) { [string]$keyInfo.Character } else { '' }
            $vk = [int]$keyInfo.VirtualKeyCode
            if ($vk -eq 13) { return }
            if ($vk -eq 37) { $choice = 'LEFT' }
            elseif ($vk -eq 39) { $choice = 'RIGHT' }
            elseif ($vk -eq 38) { $choice = 'UP' }
            elseif ($vk -eq 40) { $choice = 'DOWN' }
        } catch {
            $choice = (Read-Host 'Map').Trim()
        }

        $choice = $choice.ToUpperInvariant()
        switch ($choice) {
            '' { return }
            'N' { if ($groups.Count -gt 1) { $groupIndex = ($groupIndex + 1) % $groups.Count; $pageIndex = 0 } else { $pageIndex = ($pageIndex + 1) % $totalPages }; continue MAPLOOP }
            'P' { if ($groups.Count -gt 1) { $groupIndex = ($groupIndex - 1 + $groups.Count) % $groups.Count; $pageIndex = 0 } else { $pageIndex = ($pageIndex - 1 + $totalPages) % $totalPages }; continue MAPLOOP }
            'RIGHT' { if ($groups.Count -gt 1) { $groupIndex = ($groupIndex + 1) % $groups.Count; $pageIndex = 0 }; continue MAPLOOP }
            'LEFT'  { if ($groups.Count -gt 1) { $groupIndex = ($groupIndex - 1 + $groups.Count) % $groups.Count; $pageIndex = 0 }; continue MAPLOOP }
            'UP'    { $pageIndex = ($pageIndex - 1 + $totalPages) % $totalPages; continue MAPLOOP }
            'DOWN'  { $pageIndex = ($pageIndex + 1) % $totalPages; continue MAPLOOP }
            'D' {
                Clear-Host
                Write-Host "╔$line╗" -ForegroundColor $Theme.Info
                Write-Host ("║ GROUP DETAILS: {0}" -f $selectedGroup.Group).PadRight($inner) + '║' -ForegroundColor $Theme.Info
                Write-Host "╚$line╝" -ForegroundColor $Theme.Info
                Write-Host ""
                Write-Host ("Agents: {0} | ID range: {1}-{2}" -f $selectedGroup.Count,$selectedGroup.First,$selectedGroup.Last) -ForegroundColor $Theme.MutedLight
                Write-Host ""
                foreach ($agent in $selectedGroup.Agents) {
                    $summary = if ($agent.summary) { [string]$agent.summary } else { 'No summary registered.' }
                    $color = if ($excludedIds -contains [string]$agent.id) { $Theme.Warning } elseif ($agent.color) { $agent.color } else { $Theme.Info }
                    Write-Host ("{0,4}  {1,-28} [{2,-20}]" -f ([int]$agent.id),([string]$agent.name),([string]$agent.tag)) -ForegroundColor $color
                    Write-Host ("       {0}" -f $summary) -ForegroundColor $Theme.MutedLight
                }
                Read-Host 'Press Enter to return to map'
                continue MAPLOOP
            }
            'A' {
                Clear-Host
                Write-Host "ALL REGISTERED AGENTS — $($allAgents.Count)" -ForegroundColor $Theme.Info
                Write-Host ""
                foreach ($agent in $allAgents) {
                    $groupText = if ([string]::IsNullOrWhiteSpace([string]$agent.group)) { 'Unassigned' } else { [string]$agent.group }
                    $excluded = $excludedIds -contains [string]$agent.id
                    $rowColor = if ($excluded) { $Theme.Warning } elseif ($agent.color) { $agent.color } else { $Theme.Info }
                    Write-Host ("{0,4}  {1,-28}  {2,-22}  [{3}]" -f ([int]$agent.id),([string]$agent.name),$groupText,[string]$agent.tag) -ForegroundColor $rowColor
                }
                Read-Host 'Press Enter to return to map'
                continue MAPLOOP
            }
            'R' {
                Sync-AgentRegistry
                $allAgents = @($script:AgentRegistry.Values | Sort-Object {[int]$_.id})
                $groups = @(Build-MapGroups $allAgents)
                $singleUngrouped = ($groups.Count -eq 1 -and $groups[0].Group -eq 'Unassigned')
                $excludedIds = @(Get-NexusDefaultExcludedIds)
                $groupIndex = [Math]::Min($groupIndex, [Math]::Max(0,$groups.Count-1))
                $pageIndex = 0
                continue MAPLOOP
            }
        }
    }
}

function Get-VramSnapshot {
    $result = [ordered]@{
        Available       = $false
        FreeMB          = 0
        TotalMB         = 0
        UsedMB          = 0
        Percent         = 0
        GpuCount        = 0
        GpuName         = "NVIDIA telemetry unavailable"
        Driver          = "n/a"
        TemperatureC    = $null
        UtilizationPct  = $null
        PowerDrawW      = $null
        PowerLimitW     = $null
        Devices         = @()
        Timestamp       = Get-Date
    }

    try {
        $query = "index,name,driver_version,temperature.gpu,utilization.gpu,memory.used,memory.free,memory.total,power.draw,power.limit"
        $rawRows = @( & nvidia-smi --query-gpu=$query --format=csv,noheader,nounits 2>$null )

        foreach ($rawRow in $rawRows) {
            $row = ([string]$rawRow).Trim()
            if ([string]::IsNullOrWhiteSpace($row)) { continue }

            $parts = @($row -split ',')
            if ($parts.Count -lt 10) { continue }

            try {
                $used = [double]($parts[5].Trim())
                $free = [double]($parts[6].Trim())
                $total = [double]($parts[7].Trim())
            } catch {
                continue
            }

            $temp = $null
            $util = $null
            $draw = $null
            $limit = $null
            [double]$tmp = 0
            if ([double]::TryParse($parts[3].Trim(), [ref]$tmp)) { $temp = $tmp }
            if ([double]::TryParse($parts[4].Trim(), [ref]$tmp)) { $util = $tmp }
            if ([double]::TryParse(($parts[8].Trim() -replace '[^0-9\.\-]', ''), [ref]$tmp)) { $draw = $tmp }
            if ([double]::TryParse(($parts[9].Trim() -replace '[^0-9\.\-]', ''), [ref]$tmp)) { $limit = $tmp }

            $result.Devices += [pscustomobject]@{
                Index          = [int]$parts[0].Trim()
                Name           = $parts[1].Trim()
                Driver         = $parts[2].Trim()
                TemperatureC   = $temp
                UtilizationPct = $util
                UsedMB         = [int][math]::Round($used)
                FreeMB         = [int][math]::Round($free)
                TotalMB        = [int][math]::Round($total)
                PowerDrawW     = $draw
                PowerLimitW    = $limit
            }
        }

        if ($result.Devices.Count -gt 0) {
            $primary = $result.Devices | Sort-Object TotalMB -Descending | Select-Object -First 1
            $result.Available = $true
            $result.GpuCount = $result.Devices.Count
            $result.UsedMB = [int](($result.Devices | Measure-Object UsedMB -Sum).Sum)
            $result.FreeMB = [int](($result.Devices | Measure-Object FreeMB -Sum).Sum)
            $result.TotalMB = [int](($result.Devices | Measure-Object TotalMB -Sum).Sum)
            if ($result.TotalMB -gt 0) {
                $result.Percent = [math]::Round(($result.UsedMB / $result.TotalMB) * 100, 1)
            }
            $result.GpuName = [string]$primary.Name
            $result.Driver = [string]$primary.Driver
            $result.TemperatureC = $primary.TemperatureC
            $result.UtilizationPct = $primary.UtilizationPct
            $result.PowerDrawW = $primary.PowerDrawW
            $result.PowerLimitW = $primary.PowerLimitW
        }
    } catch {}

    return [pscustomobject]$result
}

function Get-OllamaLoadedModelTelemetry {
    $models = @()
    try {
        $rows = @( & ollama ps 2>$null )
        if ($rows.Count -le 1) { return @() }

        foreach ($row in ($rows | Select-Object -Skip 1)) {
            $line = ([string]$row).Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            $parts = @($line -split '\s+')
            if ($parts.Count -lt 4) { continue }

            $sizeMB = 0
            $sizeTokenIndex = 2
            if ($parts.Count -ge 3 -and $parts[2] -match '^([\d\.]+)(KB|MB|GB|TB)$') {
                $value = [double]$matches[1]
                switch ($matches[2].ToUpper()) {
                    "KB" { $sizeMB = [int]($value / 1024) }
                    "MB" { $sizeMB = [int]$value }
                    "GB" { $sizeMB = [int]($value * 1024) }
                    "TB" { $sizeMB = [int]($value * 1024 * 1024) }
                }
            }

            $models += [pscustomobject]@{
                Name    = [string]$parts[0]
                SizeMB  = $sizeMB
                Expires = if ($parts.Count -ge 6) { ($parts[-2..-1] -join " ") } else { "unknown" }
                Raw     = $line
            }
        }
    } catch {}

    return @($models)
}

function Register-NewAgentActivation {
    param([Parameter(Mandatory = $true)][string]$ModelName)

    $normalizedCurrent = Normalize-OllamaModelName $ModelName
    if ([string]::IsNullOrWhiteSpace($normalizedCurrent)) { return }

    # Reusing the current resident model does not consume a warm-pool slot.
    if ($script:LastSchedulerModelAlreadyLoaded) { return }

    # Each rotation is a clean logical window of FOUR NEW activations.
    # The fourth becomes the persistent logical "brain" for the next window.
    # The brain is deliberately NOT inserted into the next window, otherwise
    # the next rotation would accidentally release it as one of the first three.
    for ($i = $script:WarmPoolActivationOrder.Count - 1; $i -ge 0; $i--) {
        if ([string]$script:WarmPoolActivationOrder[$i] -ieq $normalizedCurrent) {
            $script:WarmPoolActivationOrder.RemoveAt($i)
        }
    }
    [void]$script:WarmPoolActivationOrder.Add($normalizedCurrent)
    $script:WarmPoolActivationsSinceRotation++

    # Telemetry is informational only. Ollama may already have evicted older
    # models because the physical GPU cannot hold them simultaneously.
    $loadedNow = @(Get-OllamaLoadedModelTelemetry)
    $loadedNames = @($loadedNow | ForEach-Object { Normalize-OllamaModelName ([string]$_.Name) })

    Write-Host ("[WARM POOL] New activation {0}/4: {1} | resident models reported: {2}" -f $script:WarmPoolActivationsSinceRotation, $ModelName, $loadedNow.Count) -ForegroundColor $Theme.Info

    if ($script:WarmPoolActivationsSinceRotation -lt 4) {
        $brainText = if ([string]::IsNullOrWhiteSpace($script:WarmPoolBrain)) { 'none yet' } else { $script:WarmPoolBrain }
        Write-Host ("[WARM POOL] Filling next brain window. Protected brain: {0} | new slots: {1}/4" -f $brainText, $script:WarmPoolActivationsSinceRotation) -ForegroundColor $Theme.InfoDim
        return
    }

    # Fourth NEW activation becomes the new brain.
    $releaseNames = @($script:WarmPoolActivationOrder | Select-Object -First 3)
    $previousBrain = $script:WarmPoolBrain
    $script:WarmPoolBrain = $normalizedCurrent

    Write-Host "" 
    Write-Host "╔══════════════════════════════════════════════════════════════════════╗" -ForegroundColor $Theme.Warning
    Write-Host "║             ⚡ NEW BRAIN ONLINE — ROLLING POOL ROTATION ⚡          ║" -ForegroundColor $Theme.Warning
    Write-Host "╚══════════════════════════════════════════════════════════════════════╝" -ForegroundColor $Theme.Warning
    Write-Host ("[BRAIN] {0} is now the active brain and will be protected as the logical anchor." -f $ModelName) -ForegroundColor $Theme.Success
    if (-not [string]::IsNullOrWhiteSpace($previousBrain)) {
        Write-Host ("[BRAIN] Previous brain: {0} | it is no longer protected by the new rotation." -f $previousBrain) -ForegroundColor $Theme.InfoDim
    }
    Write-Host "[RELEASE] Retiring the first 3 agents from this activation window to prepare the next 3 slots." -ForegroundColor $Theme.Warning

    $releasedPhysical = 0
    $retiredLogical = 0
    foreach ($releaseName in $releaseNames) {
        if ($releaseName -ieq $normalizedCurrent) { continue }
        $retiredLogical++
        if ($loadedNames -contains $releaseName) {
            Write-Host ("    [RELEASING] {0}" -f $releaseName) -ForegroundColor $Theme.Warning
            & ollama stop $releaseName 2>$null | Out-Null
            Write-Host ("    [RELEASED ] {0}  <-- agent physically released" -f $releaseName) -ForegroundColor $Theme.Success
            $releasedPhysical++
        } else {
            Write-Host ("    [RELEASED ] {0}  <-- slot retired; Ollama already reclaimed it" -f $releaseName) -ForegroundColor $Theme.InfoDim
        }
    }

    # Start the next clean four-activation window. The current brain is held
    # separately so activations 5/6/7 are not allowed to count it as a release
    # candidate; activation 8 becomes the next brain and retires 5/6/7.
    $script:WarmPoolActivationOrder.Clear()
    $script:WarmPoolActivationsSinceRotation = 0

    Write-Host ("[RELEASE] Rotation complete — {0} logical slots retired, {1} physically released." -f $retiredLogical, $releasedPhysical) -ForegroundColor $Theme.Success
    Write-Host ("[BRAIN] {0} remains the active logical brain. Next rotation: 3 new agents + the next brain." -f $ModelName) -ForegroundColor $Theme.Info

    $post = Get-VramSnapshot
    if ($post.Available) {
        Write-Host ("[WARM POOL] Free VRAM after rotation: {0} MB / {1} MB ({2}% used)" -f $post.FreeMB, $post.TotalMB, $post.Percent) -ForegroundColor $Theme.Info
    }
}

function Get-VramSafetyReserveMB {
    param(
        [int]$ContextLength = 1024,
        [string]$Profile = $script:SelectedProfile
    )

    $base = switch ($Profile) {
        "Low-VRAM 6GB"        { 640 }
        "Balanced"            { 768 }
        "Turbo / High-Context" { 1024 }
        "CPU-Only Offline"    { 0 }
        default               { 768 }
    }

    # KV/context overhead grows with context length. Keep the reserve conservative.
    if ($ContextLength -gt 1024) { $base += [int](($ContextLength - 1024) / 1024) * 160 }
    return [int]$base
}

function Show-PortableStoreCenter {
    $scriptPath = Join-Path $PSScriptRoot "delmodels.ps1"
    while ($true) {
        Clear-Host
        Show-CommandActivation -Command 'portable'
        Write-Host "===================================================================" -ForegroundColor $Theme.Info
        Write-Host "  PORTABLE STORE" -ForegroundColor $Theme.Info
        Write-Host "===================================================================" -ForegroundColor $Theme.Info
        $store = Get-MatrixModelStoreStatus
        $active = Get-CurrentActiveModel
        $mfs = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Modfiles') -Filter 'Modelfile_*' -File -ErrorAction SilentlyContinue)
        Write-Host ("  Host     : {0}" -f $script:CypraOllamaHost) -ForegroundColor $Theme.MutedLight
        Write-Host ("  Store    : {0}" -f $store.Target) -ForegroundColor $Theme.MutedLight
        Write-Host ("  Engine   : {0}" -f $(if ($store.Online) { 'ONLINE' } else { 'OFFLINE' })) -ForegroundColor $(if ($store.Online) { $Theme.Success } else { $Theme.Warning })
        Write-Host ("  Active   : {0}" -f $active) -ForegroundColor $Theme.Success
        Write-Host ("  Blueprints : {0} Modelfiles" -f $mfs.Count) -ForegroundColor $Theme.Info
        Write-Host ""
        Write-Host "  Registered models" -ForegroundColor $Theme.Warning
        $installed = @(Get-MatrixInstalledModels)
        if ($installed.Count -eq 0) {
            Write-Host "    (none)" -ForegroundColor $Theme.Muted
        } else {
            foreach ($row in $installed) {
                $mark = if ($row.Name -ieq $active -or $row.Name -ieq "$active`:latest") { '  <ACTIVE>' } else { '' }
                Write-Host ("    {0}{1}" -f $row.Name, $mark) -ForegroundColor $(if ($mark) { $Theme.Success } else { $Theme.Primary })
            }
        }
        Write-Host ""
        Write-Host "  [1] Refresh status" -ForegroundColor $Theme.Info
        Write-Host "  [2] Pull / install a model" -ForegroundColor $Theme.Success
        Write-Host "  [3] Delete agent models only  (keep base)" -ForegroundColor $Theme.Warning
        Write-Host "  [4] Delete all portable models (agents + base)" -ForegroundColor $Theme.Error
        Write-Host "  [5] Advanced model center" -ForegroundColor $Theme.MutedLight
        Write-Host "  [0] Back" -ForegroundColor $Theme.Muted
        Write-Host ""
        $c = Read-Host "Select"
        switch -Regex ($c) {
            '^0$' { return }
            '^1$' { continue }
            '^2$' {
                $name = Read-Host "Model name to pull (blank cancels)"
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                if ($name -match '^(?i)(q|quit)$') { continue }
                Write-Host ("[*] Pulling {0} into the portable store..." -f $name.Trim()) -ForegroundColor $Theme.Info
                if (Get-Command Ensure-MatrixTargetModelStore -ErrorAction SilentlyContinue) {
                    Ensure-MatrixTargetModelStore | Out-Null
                }
                & ollama pull $name.Trim()
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "[+] Pull finished." -ForegroundColor $Theme.Success
                } else {
                    Write-Host ("[!] Pull failed (exit {0})." -f $LASTEXITCODE) -ForegroundColor $Theme.Error
                }
                Read-Host "Enter"
            }
            '^3$' {
                if (-not (Test-Path -LiteralPath $scriptPath)) { Write-Host "[!] delmodels.ps1 missing."; Read-Host "Enter"; continue }
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Mode Agents
                Read-Host "Enter"
            }
            '^4$' {
                if (-not (Test-Path -LiteralPath $scriptPath)) { Write-Host "[!] delmodels.ps1 missing."; Read-Host "Enter"; continue }
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Mode All
                Read-Host "Enter"
            }
            '^5$' { Invoke-PullHub }
            default { }
        }
    }
}

function Invoke-DeletePortableModels {
    Show-PortableStoreCenter
}

function Invoke-ClearVramBat {
    $tool = Join-Path $PSScriptRoot "clearvram.ps1"
    $bat = Join-Path $PSScriptRoot "CLEARVRAM.bat"
    while ($true) {
        Clear-Host
        Show-CommandActivation -Command 'clearvram'
        Write-Host "===================================================================" -ForegroundColor $Theme.Info
        Write-Host "  VRAM TOOL  ·  CLEARVRAM.bat / clearvram.ps1" -ForegroundColor $Theme.Info
        Write-Host "===================================================================" -ForegroundColor $Theme.Info
        Write-Host "  Unloads this project's models from the GPU. Does not delete weights." -ForegroundColor $Theme.MutedLight
        Write-Host ""
        Write-Host "  [1] Unload GPU models     ollama stop (no Admin)" -ForegroundColor $Theme.Success
        Write-Host "  [2] Restart portable Ollama" -ForegroundColor $Theme.Warning
        Write-Host "  [3] Restart Explorer      last resort, Admin" -ForegroundColor $Theme.Error
        Write-Host "  [0] Back" -ForegroundColor $Theme.Muted
        Write-Host ""
        $c = Read-Host "Select"
        if ($c -eq '0' -or $c -match '^(?i)q$') { return }
        if (-not (Test-Path -LiteralPath $tool)) {
            Write-Host "[!] clearvram.ps1 missing. Expected $tool" -ForegroundColor $Theme.Error
            Read-Host "Enter"
            return
        }
        switch ($c) {
            '1' {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -Job Unload
                Read-Host "Enter"
            }
            '2' {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -Job RestartOllama
                Read-Host "Enter"
            }
            '3' {
                $ok = Read-Host "Type EXPLORER to restart the Windows shell"
                if ($ok -ne 'EXPLORER') { Write-Host "[i] Cancelled."; Start-Sleep -Milliseconds 600; continue }
                if (Test-Path -LiteralPath $bat) {
                    Start-Process -FilePath $bat -ArgumentList 'EXPLORER' -WorkingDirectory $PSScriptRoot -Wait
                } else {
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool -Job RestartExplorer
                }
                Read-Host "Enter"
            }
        }
    }
}

function Invoke-VramCleanup {
    Clear-Host
    Show-CommandActivation -Command 'vram'
    Write-Host "===================================================================" -ForegroundColor $Theme.Info
    Write-Host "                    🔋 VRAM CONTROL CENTER" -ForegroundColor $Theme.Info
    Write-Host "===================================================================" -ForegroundColor $Theme.Info
    Write-Host ""

    $before = Get-VramSnapshot
    $loadedBefore = @(Get-OllamaLoadedModelTelemetry)

    if ($before.Available) {
        Write-Host ("GPU: {0} | Driver: {1} | Devices: {2}" -f $before.GpuName, $before.Driver, $before.GpuCount) -ForegroundColor $Theme.Info
        Write-Host ("VRAM: {0} MB used / {1} MB total | {2} MB free | {3}% used" -f $before.UsedMB, $before.TotalMB, $before.FreeMB, $before.Percent) -ForegroundColor $Theme.Info
        Write-Host ("Thermals/Load: {0} °C | {1}% GPU utilization" -f $before.TemperatureC, $before.UtilizationPct) -ForegroundColor $Theme.Warning
    } else {
        Write-Host "CURRENT VRAM: NVIDIA telemetry unavailable" -ForegroundColor $Theme.Warning
    }

    if ($loadedBefore.Count -gt 0) {
        Write-Host ""
        Write-Host "Loaded Ollama models:" -ForegroundColor $Theme.MutedLight
        foreach ($item in $loadedBefore) {
            Write-Host ("  {0,-32} {1,6} MB  expires {2}" -f $item.Name, $item.SizeMB, $item.Expires) -ForegroundColor $Theme.Muted
        }
    }

    Write-Host ""
    Write-Host "[1] Release loaded Ollama models     (fast / recommended)" -ForegroundColor $Theme.Success
    Write-Host "[2] Deep Ollama GPU reset            (stronger / restarts Ollama)" -ForegroundColor $Theme.Warning
    Write-Host "[3] Show per-GPU telemetry           (diagnostic only)" -ForegroundColor $Theme.Info
    Write-Host "[4] Run CLEARVRAM.bat                (Windows VRAM reclaimer)" -ForegroundColor $Theme.Warning
    Write-Host "[5] Return to Dashboard" -ForegroundColor $Theme.MutedLight
    Write-Host ""

    $choice = Read-Host "Select VRAM action"

    switch ($choice) {
        "1" {
            Write-Host ""
            Write-Host "[*] Releasing loaded Ollama models..." -ForegroundColor $Theme.Warning
            $runningModels = @(Get-OllamaLoadedModelTelemetry)
            $stopped = 0

            foreach ($item in $runningModels) {
                Write-Host "    [RELEASING] $($item.Name)" -ForegroundColor $Theme.WarningDim
                & ollama stop $item.Name 2>$null | Out-Null
                Write-Host "    [RELEASED ] $($item.Name)  <-- agent released" -ForegroundColor $Theme.Success
                $stopped++
            }

            if ($stopped -eq 0) {
                Write-Host "[i] No loaded Ollama models were reported." -ForegroundColor $Theme.Muted
            } else {
                Write-Host "[+] Released $stopped loaded Ollama model(s)." -ForegroundColor $Theme.Success
            }

            Start-Sleep -Milliseconds 1200
            $after = Get-VramSnapshot
            if ($after.Available) {
                $delta = $after.FreeMB - $before.FreeMB
                $deltaText = if ($delta -ge 0) { "+$delta MB" } else { "$delta MB" }
                Write-Host ""
                Write-Host ("VRAM AFTER CLEANUP: {0} MB used / {1} MB total | {2} MB free | {3}% used" -f $after.UsedMB, $after.TotalMB, $after.FreeMB, $after.Percent) -ForegroundColor $Theme.Info
                Write-Host ("Change: $deltaText free VRAM") -ForegroundColor $(if ($delta -ge 0) { $Theme.Success } else { $Theme.Warning })
            }
        }

        "2" {
            Write-Host ""
            Write-Host "[!] This will restart the Ollama engine and disconnect any active Ollama session." -ForegroundColor $Theme.Warning
            $confirm = Read-Host "Type RESET to continue"

            if ($confirm -eq "RESET") {
                Write-Host "[*] Stopping loaded models first..." -ForegroundColor $Theme.Warning
                Stop-LoadedOllamaModels -Force
                Write-Host "[*] Resetting Ollama engine..." -ForegroundColor $Theme.Warning
                $null = Start-OllamaEngine -CpuOnly $false
                Start-Sleep -Milliseconds 800

                $after = Get-VramSnapshot
                if ($after.Available) {
                    Write-Host ("[+] GPU reset complete: {0} MB free / {1} MB total ({2}% used) | {3} °C | {4}% util" -f $after.FreeMB, $after.TotalMB, $after.Percent, $after.TemperatureC, $after.UtilizationPct) -ForegroundColor $Theme.Success
                } else {
                    Write-Host "[+] Ollama reset complete. NVIDIA telemetry is unavailable." -ForegroundColor $Theme.Success
                }
            } else {
                Write-Host "[i] Reset cancelled. No processes were restarted." -ForegroundColor $Theme.Muted
            }
        }

        "3" {
            Write-Host ""
            Write-Host "GPU TELEMETRY BY DEVICE" -ForegroundColor $Theme.Info
            Write-Host "───────────────────────────────────────────────────────────────────" -ForegroundColor $Theme.InfoDim
            $snap = Get-VramSnapshot

            if ($snap.Available) {
                foreach ($gpu in $snap.Devices) {
                    Write-Host ("GPU {0}: {1}" -f $gpu.Index, $gpu.Name) -ForegroundColor $Theme.Primary
                    Write-Host ("  VRAM       : {0} / {1} MB ({2}% used)" -f $gpu.UsedMB, $gpu.TotalMB, [math]::Round(($gpu.UsedMB / [math]::Max(1,$gpu.TotalMB)) * 100, 1)) -ForegroundColor $Theme.Info
                    Write-Host ("  Free       : {0} MB | Temp: {1} °C | Util: {2}%" -f $gpu.FreeMB, $gpu.TemperatureC, $gpu.UtilizationPct) -ForegroundColor $Theme.MutedLight
                    Write-Host ("  Power      : {0} W / {1} W | Driver: {2}" -f $gpu.PowerDrawW, $gpu.PowerLimitW, $gpu.Driver) -ForegroundColor $Theme.Muted
                }
            } else {
                Write-Host "  No GPU telemetry reported by nvidia-smi." -ForegroundColor $Theme.Warning
            }

            Write-Host ""
            Write-Host "[i] Diagnostic only. The launcher will not kill unrelated GPU applications." -ForegroundColor $Theme.Muted
        }

        "4" {
            Invoke-ClearVramBat
            return
        }

        "5" {
            return
        }

        default {
            Write-Host "[!] Invalid selection." -ForegroundColor $Theme.Warning
        }
    }

    Write-Host ""
    Read-Host "Press Enter to return to Dashboard"
}

function Get-OllamaModelSizeMB {
    param([string]$ModelName)

    try {
        $rows = @( & ollama list 2>$null )
        $escapedName = [regex]::Escape($ModelName)

        foreach ($row in $rows) {
            $line = ([string]$row).Trim()
            if ($line -match ("(?i)^\s*" + $escapedName + "(?::\S+)?\s+\S+\s+([\d\.]+)\s*(TB|GB|MB|KB)")) {
                $value = [double]$matches[1]
                switch ($matches[2].ToUpper()) {
                    "TB" { return [int]($value * 1024 * 1024) }
                    "GB" { return [int]($value * 1024) }
                    "MB" { return [int]$value }
                    "KB" { return [int]($value / 1024) }
                }
            }
        }
    } catch {}

    return 0
}

function Invoke-VramAwareScheduler {
    param([string]$ModelName)

    Write-Host ""
    Write-Host "[VRAM SCHEDULER] Evaluating $ModelName..." -ForegroundColor $Theme.Success

    $snap = Get-VramSnapshot
    if (-not $snap.Available) {
        Write-Host "[i] NVIDIA telemetry unavailable. Keeping current Ollama GPU profile." -ForegroundColor $Theme.Muted
        return $true
    }

    $modelMB = Get-OllamaModelSizeMB $ModelName
    $ctx = [int]$env:OLLAMA_CONTEXT_LENGTH
    if ($ctx -le 0) { $ctx = [int]$matrixConfig.DefaultContext }
    $reserveMB = Get-VramSafetyReserveMB -ContextLength $ctx -Profile $script:SelectedProfile

    # Ollama model file size is not identical to live VRAM use. Add a conservative
    # headroom factor for runtime buffers/graph/context allocation.
    $runtimeModelMB = if ($modelMB -gt 0) { [int][math]::Ceiling($modelMB * 1.10) } else { 0 }
    $requiredMB = if ($runtimeModelMB -gt 0) { $runtimeModelMB + $reserveMB } else { 0 }

    Write-Host ("    GPU            : {0} (driver {1})" -f $snap.GpuName, $snap.Driver) -ForegroundColor $Theme.Info
    Write-Host ("    VRAM           : {0} MB used / {1} MB total | {2} MB free ({3}% used)" -f $snap.UsedMB, $snap.TotalMB, $snap.FreeMB, $snap.Percent) -ForegroundColor $Theme.Info
    Write-Host ("    Temperature    : {0} °C | Utilization: {1}%" -f $snap.TemperatureC, $snap.UtilizationPct) -ForegroundColor $Theme.InfoDim
    Write-Host ("    Model size     : {0} MB on disk" -f $(if ($modelMB -gt 0) { $modelMB } else { "unknown" })) -ForegroundColor $Theme.InfoDim
    Write-Host ("    Runtime est.   : {0} MB (includes 10% runtime headroom)" -f $(if ($runtimeModelMB -gt 0) { $runtimeModelMB } else { "unknown" })) -ForegroundColor $Theme.InfoDim
    Write-Host ("    Safety reserve  : {0} MB | Context: {1}" -f $reserveMB, $ctx) -ForegroundColor $Theme.InfoDim
    Write-Host ("    Required headroom: {0} MB" -f $(if ($requiredMB -gt 0) { $requiredMB } else { "dynamic / Ollama-managed" })) -ForegroundColor $Theme.InfoDim

    if ($script:OllamaCpuFallbackActive) {
        Write-Host "[*] Previous CPU fallback detected. Restoring GPU mode before launch." -ForegroundColor $Theme.Warning
        $null = Start-OllamaEngine -CpuOnly $false
    }
    $script:OllamaCpuFallbackActive = $false

    $script:LastSchedulerModelAlreadyLoaded = $false
    $loadedExact = @(Get-OllamaLoadedModelTelemetry | Where-Object { $_.Name -ieq $ModelName -or $_.Name -ieq "$ModelName`:latest" })
    if ($loadedExact.Count -gt 0) {
        $script:LastSchedulerModelAlreadyLoaded = $true
        Write-Host "[+] Existing model already running: $ModelName. Reusing current Ollama allocation." -ForegroundColor $Theme.Success
        return $true
    }

    $loadedAll = @(Get-OllamaLoadedModelTelemetry)
    $maxWarm = 4
    if ($loadedAll.Count -ge $maxWarm) {
        Write-Host ("[i] Ollama currently reports {0} resident models. Physical residency is Ollama-managed; warm-pool rotation is driven by NEW activations." -f $loadedAll.Count) -ForegroundColor $Theme.InfoDim
    }
    if (-not [string]::IsNullOrWhiteSpace($script:WarmPoolBrain)) {
        Write-Host ("[BRAIN] Active logical brain: {0} | protected from warm-pool retirement." -f $script:WarmPoolBrain) -ForegroundColor $Theme.Info
    }

    if ($modelMB -gt 0 -and $snap.FreeMB -ge $requiredMB) {
        $margin = $snap.FreeMB - $requiredMB
        Write-Host ("[+] VRAM headroom is sufficient. Estimated margin: {0} MB." -f $margin) -ForegroundColor $Theme.Success
        return $true
    }

    Write-Host "[*] Loading with current headroom; Ollama manages physical residency. The warm pool separately tracks the active brain and four-activation rotation." -ForegroundColor $Theme.Warning
    Write-Host "[i] CPU fallback remains reserved for an explicit CPU profile or a launch failure." -ForegroundColor $Theme.Muted
    return $true
}

function Start-TaskWorkspace {
    param(
        [string]$AgentId,
        [string]$ModelName,
        [string]$Prompt
    )

    if (-not (Test-Path $script:TaskRoot)) {
        New-Item -ItemType Directory -Path $script:TaskRoot -Force | Out-Null
    }

    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $safeModel = ($ModelName -replace '[^a-zA-Z0-9_-]', '_')
    $taskId = "task_${stamp}_agent${AgentId}_${safeModel}"
    $taskPath = Join-Path $script:TaskRoot $taskId
    New-Item -ItemType Directory -Path $taskPath -Force | Out-Null

    $script:ActiveTaskId = $taskId
    $script:ActiveTaskPath = $taskPath
    $global:ActiveTaskWorkspace = $taskPath

    $meta = [ordered]@{
        task_id = $taskId
        created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        agent_id = [int]$AgentId
        model = $ModelName
        tag = [string]$script:tags[$AgentId]
        group = [string]$script:AgentRegistry[[string]$AgentId].group
        profile = $script:SelectedProfile
        context = [int]$env:OLLAMA_CONTEXT_LENGTH
    }

    $meta | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $taskPath "task.json") -Encoding utf8
    if ($Prompt) { $Prompt | Set-Content (Join-Path $taskPath "prompt.txt") -Encoding utf8 }

    Write-Host "[TASK] Workspace: $taskPath" -ForegroundColor $Theme.InfoDim
    return $taskPath
}

function Show-TaskWorkspace {
    Clear-Host
    Show-CommandActivation -Command 'task'
    Write-Host "==============================================================" -ForegroundColor $Theme.Info
    Write-Host "                  📂 TASK WORKSPACE MANAGER                  " -ForegroundColor $Theme.Info
    Write-Host "==============================================================" -ForegroundColor $Theme.Info
    Write-Host ""

    $tasksDir = Resolve-MatrixTaskRoot
    $script:TaskRoot = $tasksDir

    if (-not (Test-Path $tasksDir)) {
        New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
    }

    Write-Host "TASK ROOT: $tasksDir" -ForegroundColor $Theme.InfoDim
    if ($global:ActiveTaskWorkspace -and (Test-Path $global:ActiveTaskWorkspace)) {
        Write-Host "ACTIVE : $global:ActiveTaskWorkspace" -ForegroundColor $Theme.Success
    } else {
        Write-Host "ACTIVE : NONE" -ForegroundColor $Theme.MutedLight
    }
    Write-Host ""

    # Find task workspaces recursively so older layouts and nested date/agent folders
    # are visible as well as the current flat task_* layout.
    $taskFolders = @(Get-ChildItem -Path $tasksDir -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Name -like 'task_*' -or (Test-Path (Join-Path $_.FullName 'task.json'))) -and
            ((Test-Path (Join-Path $_.FullName 'task.json')) -or (Test-Path (Join-Path $_.FullName 'metadata.json')))
        } |
        Sort-Object LastWriteTime -Descending)

    if ($taskFolders.Count -eq 0) {
        Write-Host "[i] No task workspaces found." -ForegroundColor $Theme.Warning
        Write-Host "    New task workspaces will be saved under: $tasksDir" -ForegroundColor $Theme.MutedLight
        Write-Host ""
        Read-Host "Press Enter to return to Dashboard"
        return
    }

    Write-Host ("FOUND {0} TASK WORKSPACE(S)" -f $taskFolders.Count) -ForegroundColor $Theme.Success
    Write-Host "────────────────────────────────────────────────────────────────" -ForegroundColor $Theme.Muted

    $displayCount = [Math]::Min($taskFolders.Count, 50)
    for ($i = 0; $i -lt $displayCount; $i++) {
        $folder = $taskFolders[$i]
        $metaPath = Join-Path $folder.FullName 'task.json'
        $legacyMetaPath = Join-Path $folder.FullName 'metadata.json'
        $statusPath = Join-Path $folder.FullName 'status.json'

        $taskId = $folder.Name
        $agentId = '?'
        $model = '?'
        $created = $folder.CreationTime.ToString('yyyy-MM-dd HH:mm:ss')
        $status = 'UNKNOWN'

        try {
            $meta = $null
            if (Test-Path $metaPath) { $meta = Get-Content $metaPath -Raw | ConvertFrom-Json }
            elseif (Test-Path $legacyMetaPath) { $meta = Get-Content $legacyMetaPath -Raw | ConvertFrom-Json }
            if ($meta) {
                if ($meta.task_id) { $taskId = [string]$meta.task_id }
                if ($null -ne $meta.agent_id) { $agentId = [string]$meta.agent_id }
                if ($meta.model) { $model = [string]$meta.model }
                if ($meta.created) { $created = [string]$meta.created }
            }
        } catch {}

        if (Test-Path $statusPath) {
            try {
                $statusObj = Get-Content $statusPath -Raw | ConvertFrom-Json
                if ($statusObj.status) { $status = [string]$statusObj.status.ToUpper() }
            } catch {}
        } elseif (Test-Path (Join-Path $folder.FullName 'result.txt')) {
            $status = 'COMPLETE'
        } elseif (Test-Path (Join-Path $folder.FullName 'prompt.txt')) {
            $status = 'CREATED'
        }

        $activeMarker = if ($global:ActiveTaskWorkspace -and ($global:ActiveTaskWorkspace -eq $folder.FullName)) { ' [ACTIVE]' } else { '' }
        $statusColor = switch ($status) {
            'COMPLETE' { $Theme.Success }
            'FAILED'   { $Theme.Error }
            'RUNNING'  { $Theme.Warning }
            default    { $Theme.MutedLight }
        }

        Write-Host ("[{0,2}] {1}" -f ($i + 1), $taskId) -ForegroundColor $Theme.Primary
        Write-Host ("     Agent : {0}  | Model: {1}  | Status: {2}{3}" -f $agentId, $model, $status, $activeMarker) -ForegroundColor $statusColor
        Write-Host ("     Created: {0}" -f $created) -ForegroundColor $Theme.MutedLight
        Write-Host ("     Path   : {0}" -f $folder.FullName) -ForegroundColor $Theme.Muted
    }

    if ($taskFolders.Count -gt $displayCount) {
        Write-Host "... showing the newest $displayCount tasks." -ForegroundColor $Theme.WarningDim
    }

    Write-Host "────────────────────────────────────────────────────────────────" -ForegroundColor $Theme.Muted
    Write-Host "[O] Open task folder   [R] Resume/load task   [V] View task files" -ForegroundColor $Theme.Info
    Write-Host "[0] Return to Dashboard" -ForegroundColor $Theme.MutedLight
    Write-Host ""

    $selection = (Read-Host "Select task number / O / R / V").Trim()
    if ($selection -eq '0' -or [string]::IsNullOrWhiteSpace($selection)) { return }

    $action = 'resume'
    if ($selection -match '^[ORV]$') {
        $action = $selection.ToLower()
        $selection = Read-Host "Enter task number"
    }

    if ($selection -notmatch '^\d+$') {
        Write-Host "[!] Invalid task selection." -ForegroundColor $Theme.Warning
        Start-Sleep -Seconds 1
        return
    }

    $index = [int]$selection - 1
    if ($index -lt 0 -or $index -ge $taskFolders.Count) {
        Write-Host "[!] Task number is outside the available range." -ForegroundColor $Theme.Warning
        Start-Sleep -Seconds 1
        return
    }

    $selectedTask = $taskFolders[$index]
    $global:ActiveTaskWorkspace = $selectedTask.FullName
    $script:ActiveTaskPath = $selectedTask.FullName
    $script:ActiveTaskId = $selectedTask.Name

    switch ($action) {
        'o' {
            Open-InFileManager -Path $selectedTask.FullName
            Write-Host "[+] Opened task folder in Explorer." -ForegroundColor $Theme.Success
        }
        'v' {
            Clear-Host
            Write-Host "TASK FILES: $($selectedTask.FullName)" -ForegroundColor $Theme.Info
            Write-Host "────────────────────────────────────────────────────────────────" -ForegroundColor $Theme.Muted
            Get-ChildItem -Path $selectedTask.FullName -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object Name, Length, LastWriteTime |
                Format-Table -AutoSize | Out-Host
            Write-Host ""
            Write-Host "Active workspace set to this task." -ForegroundColor $Theme.Success
            Read-Host "Press Enter to return"
        }
        default {
            Set-Location -Path $selectedTask.FullName
            Write-Host "[+] Loaded Task Workspace: $($selectedTask.FullName)" -ForegroundColor $Theme.Success
            Write-Host "[i] Future agent work will use this task workspace." -ForegroundColor $Theme.InfoDim
            Start-Sleep -Milliseconds 900
        }
    }
}

# Enhancement 3: Direct Task Workspace Quick-Launcher (`taskopen`)
function Open-TaskWorkspaceExplorer {
    Show-CommandActivation -Command 'taskopen'
    if ($global:ActiveTaskWorkspace -and (Test-Path $global:ActiveTaskWorkspace)) {
        Open-InFileManager -Path $global:ActiveTaskWorkspace
    } elseif ($script:ActiveTaskPath -and (Test-Path $script:ActiveTaskPath)) {
        Open-InFileManager -Path $script:ActiveTaskPath
    } elseif (Test-Path $script:TaskRoot) {
        Open-InFileManager -Path $script:TaskRoot
    } else {
        New-Item -ItemType Directory -Force -Path $script:TaskRoot | Out-Null
        Open-InFileManager -Path $script:TaskRoot
    }
    Write-Host "[*] Opened task workspace directory in Explorer." -ForegroundColor $Theme.Success
    Start-Sleep -Seconds 1
}

function Show-AgentOutputInspector {
    Clear-Host
    Show-CommandActivation -Command 'out'
    Write-Host "===================================================================" -ForegroundColor $Theme.Info
    Write-Host "                    📢 AGENT OUTPUT INSPECTOR 🔎" -ForegroundColor $Theme.Info
    Write-Host "===================================================================" -ForegroundColor $Theme.Info
    Write-Host ""

    $candidate = $null
    if ($global:ActiveTaskWorkspace -and (Test-Path $global:ActiveTaskWorkspace)) {
        $candidate = Get-ChildItem $global:ActiveTaskWorkspace -File |
            Where-Object { $_.Name -in @("result.txt","transcript.txt","chat_history.txt") } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    if (-not $candidate -and $script:ActiveTaskPath -and (Test-Path $script:ActiveTaskPath)) {
        $candidate = Get-ChildItem $script:ActiveTaskPath -File |
            Where-Object { $_.Name -in @("result.txt","transcript.txt","chat_history.txt") } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    if (-not $candidate -and (Test-Path $script:TaskRoot)) {
        $latest = Get-ChildItem $script:TaskRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
            $candidate = Get-ChildItem $latest.FullName -File |
                Where-Object { $_.Name -in @("result.txt","transcript.txt","chat_history.txt") } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
        }
    }

    if (-not $candidate) {
        Write-Host "[i] No captured agent output is available yet." -ForegroundColor $Theme.Warning
    } else {
        Write-Host "SOURCE: $($candidate.FullName)" -ForegroundColor $Theme.InfoDim
        Write-Host "───────────────────────────────────────────────────────────────────" -ForegroundColor $Theme.Muted
        Get-Content $candidate.FullName -Tail 120 | Out-Host
    }

    Write-Host ""
    Read-Host "Press Enter to return to Dashboard"
}

function Invoke-PreflightCheck {
    Clear-Host
    Show-CommandActivation -Command 'preflight'
    Write-Host "===================================================================" -ForegroundColor $Theme.Info
    Write-Host "                 ⚠️ CYPRA SYSTEM PREFLIGHT ⚠️" -ForegroundColor $Theme.Info
    Write-Host "===================================================================" -ForegroundColor $Theme.Info
    Write-Host ""

    $checks = @()

    $checks += [pscustomobject]@{ Name = "PowerShell"; Status = $PSVersionTable.PSVersion.ToString() }
    $checks += [pscustomobject]@{ Name = "Project Root"; Status = $(if (Test-Path $PSScriptRoot) {"OK"} else {"MISSING"}) }
    $checks += [pscustomobject]@{ Name = "Ollama Command"; Status = $(if (Get-Command ollama -ErrorAction SilentlyContinue) {"OK"} else {"MISSING"}) }
    $checks += [pscustomobject]@{ Name = "Embedded Agent Registry"; Status = $(if ($script:AgentRegistry.Count -eq 700) {"OK - 700 agents"} else {"INVALID"}) }
    if (-not (Test-Path $script:TaskRoot)) { New-Item -ItemType Directory -Path $script:TaskRoot -Force | Out-Null }
    $checks += [pscustomobject]@{ Name = "Task Workspace"; Status = $(if (Test-Path $script:TaskRoot) {"OK"} else {"MISSING"}) }
    $checks += [pscustomobject]@{ Name = "OllamaModels"; Status = $(if (Test-Path $env:OLLAMA_MODELS) {"OK"} else {"MISSING"}) }

    $ollamaProc = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    $checks += [pscustomobject]@{ Name = "Ollama Service"; Status = $(if ($ollamaProc) {"ONLINE"} else {"OFFLINE"}) }

    $snap = Get-VramSnapshot
    if ($snap.Available) {
        $checks += [pscustomobject]@{ Name = "GPU VRAM"; Status = "$($snap.FreeMB) MB free / $($snap.TotalMB) MB" }
    } else {
        $checks += [pscustomobject]@{ Name = "GPU VRAM"; Status = "Telemetry unavailable" }
    }

    $checks += [pscustomobject]@{ Name = "Agent Registry"; Status = "$($script:AgentRegistry.Count) registered" }

    $checks | Format-Table -AutoSize | Out-Host

    $failures = @($checks | Where-Object { $_.Status -in @("MISSING","OFFLINE") })
    if ($failures.Count -eq 0) {
        Write-Host "[+] PREFLIGHT PASSED" -ForegroundColor $Theme.Success
    } else {
        Write-Host "[!] PREFLIGHT FOUND $($failures.Count) ATTENTION ITEM(S)" -ForegroundColor $Theme.Warning
    }

    Read-Host "Press Enter to return to Dashboard"
}

function Invoke-RecoverySystem {
    Clear-Host
    Show-CommandActivation -Command 'recover'
    Write-Host "===================================================================" -ForegroundColor $Theme.Info
    Write-Host "                    🔄 CYPRA RECOVERY SYSTEM 🔄" -ForegroundColor $Theme.Info
    Write-Host "===================================================================" -ForegroundColor $Theme.Info
    Write-Host ""

    Write-Host "[1/5] Checking Ollama process..." -ForegroundColor $Theme.Warning
    $ollamaProc = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    if (-not $ollamaProc) {
        Write-Host "      Ollama is offline. Starting engine..." -ForegroundColor $Theme.Warning
        $null = Start-OllamaEngine
    } else {
        Write-Host "      Ollama process is present." -ForegroundColor $Theme.Success
    }

    Write-Host "[2/5] Releasing loaded model state..." -ForegroundColor $Theme.Warning
    Stop-LoadedOllamaModels -Force

    Write-Host "[3/5] Rebuilding embedded agent registry integrity..." -ForegroundColor $Theme.Warning
    Sync-AgentRegistry

    Write-Host "[4/5] Verifying workspace directories..." -ForegroundColor $Theme.Warning
    if (-not (Test-Path $script:TaskRoot)) { New-Item -ItemType Directory -Path $script:TaskRoot -Force | Out-Null }
    if (-not (Test-Path (Join-Path $PSScriptRoot "Logs"))) { New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot "Logs") -Force | Out-Null }

    Write-Host "[5/5] Final health check..." -ForegroundColor $Theme.Warning
    $ready = Test-OllamaReady
    if ($ready) {
        Write-Host "[+] Recovery completed. Ollama is responding." -ForegroundColor $Theme.Success
    } else {
        Write-Host "[!] Recovery could not confirm Ollama readiness. CPU fallback remains available through profile." -ForegroundColor $Theme.Warning
    }

    Read-Host "Press Enter to return to Dashboard"
}

function Show-HelpMenu {
    Clear-Host
    Show-CommandActivation -Command 'help'
    Write-Host "===================================================================" -ForegroundColor $Theme.Info
    Write-Host "  CYPRATEAM MATRIX  ·  operator help" -ForegroundColor $Theme.Info
    Write-Host "===================================================================" -ForegroundColor $Theme.Info
    Write-Host "  Portable AI development infrastructure. Isolated multi-agent suite for a 6GB VRAM baseline." -ForegroundColor $Theme.Success
    Write-Host "  700 specialists share one project-local Ollama store (.\OllamaModels) on 127.0.0.1:11435." -ForegroundColor $Theme.MutedLight
    Write-Host "  Identity is the Modelfile SYSTEM. Runtime (profile, context, layout) layers on top." -ForegroundColor $Theme.MutedLight
    Write-Host ""

    Write-Host "  WHAT IT DOES" -ForegroundColor $Theme.Warning
    Write-Host "    Routes work with Nexus Prime, runs pipe / quad / debate, keeps models portable," -ForegroundColor $Theme.Info
    Write-Host "    and launches one native Ollama session per agent so GPU use stays predictable." -ForegroundColor $Theme.Info
    Write-Host "    Tasks, logs, and backups stay under this folder." -ForegroundColor $Theme.Info
    Write-Host ""

    Write-Host "  DESIGN RULES" -ForegroundColor $Theme.Warning
    Write-Host "    1. Existing store  — INSTALL_MODELS.bat / modinstall.ps1 own the fleet. No second repo." -ForegroundColor $Theme.MutedLight
    Write-Host "    2. Console-safe UI — box drawing and plain text so Windows hosts do not garble the deck." -ForegroundColor $Theme.MutedLight
    Write-Host "    3. One agent at a time — each node is an isolated Ollama session (Low-VRAM default)." -ForegroundColor $Theme.MutedLight
    Write-Host "    4. Explicit install — boot does not silently pull or mass-create agents." -ForegroundColor $Theme.MutedLight
    Write-Host ""

    Write-Host "  LAUNCH" -ForegroundColor $Theme.Warning
    Write-Host "    1-700            Open that agent. Optional:  3 write a script" -ForegroundColor $Theme.Info
    Write-Host "    find / search    Search the roster by name, tag, or group" -ForegroundColor $Theme.Info
    Write-Host "    groups / map     Group list and relationship map" -ForegroundColor $Theme.Info
    Write-Host ""
    Write-Host "  WORKFLOWS" -ForegroundColor $Theme.Warning
    Write-Host "    pipe             Sequential pipeline (agent A then B, max 5)" -ForegroundColor $Theme.Info
    Write-Host "    quad / consensus Independent specialists, Nexus synthesizes" -ForegroundColor $Theme.Info
    Write-Host "    debate           Two agents, two rounds, Nexus judges" -ForegroundColor $Theme.Info
    Write-Host "    nexus / mission  Mission Control" -ForegroundColor $Theme.Info
    Write-Host ""
    Write-Host "  LOOK" -ForegroundColor $Theme.Warning
    Write-Host "    theme / colors   Color editor and presets" -ForegroundColor $Theme.Info
    Write-Host "    layout           Dashboard structure (independent of theme)" -ForegroundColor $Theme.Info
    Write-Host "    profile          Low-VRAM / Turbo / CPU-Only" -ForegroundColor $Theme.Info
    Write-Host "    hud              Live GPU / VRAM loop" -ForegroundColor $Theme.Info
    Write-Host ""
    Write-Host "  SYSTEM" -ForegroundColor $Theme.Warning
    Write-Host "    commands         Full command index" -ForegroundColor $Theme.Info
    Write-Host "    settings         Context, keep-alive, models" -ForegroundColor $Theme.Info
    Write-Host "    portable / pull / models / delmodels   One store page: status, pull, delete" -ForegroundColor $Theme.Info
    Write-Host "    vram             Release GPU memory / reset engine" -ForegroundColor $Theme.Info
    Write-Host "    preflight        Health checks    recover    Non-destructive repair" -ForegroundColor $Theme.Info
    Write-Host "    addons           Service center" -ForegroundColor $Theme.Info
    Write-Host "    task / tasks     Workspaces    taskopen    Open folder    out    Last output" -ForegroundColor $Theme.Info
    Write-Host "    hist             Session logs    stats    Uptime and disk    bckup    Workspace zip" -ForegroundColor $Theme.Info
    Write-Host "    q / exit         Leave Matrix (Ollama stays running)" -ForegroundColor $Theme.Info
    Write-Host ""
    Write-Host "  CHAT (inside an agent)" -ForegroundColor $Theme.Warning
    Write-Host "    Type at Ollama's prompt when it appears. /? Ollama help. /bye returns to the deck." -ForegroundColor $Theme.Info
    Write-Host ""
    Write-Host "  DATA & LIFECYCLE" -ForegroundColor $Theme.Warning
    Write-Host "    Registry   Embedded 700-agent directory (Core through specialty and life nodes)." -ForegroundColor $Theme.MutedLight
    Write-Host "    Models     Modelfiles and this project's Ollama store are authoritative." -ForegroundColor $Theme.MutedLight
    Write-Host "    Memory     Not used. Agents do not load a Matrix memory vault." -ForegroundColor $Theme.MutedLight
    Write-Host "    Workspace  Tasks\<task-id> holds prompts, metadata, output, transcripts." -ForegroundColor $Theme.MutedLight
    Write-Host "    Scheduler  VRAM-aware launch estimates size and prefers trim / CPU over a crash." -ForegroundColor $Theme.MutedLight
    Write-Host "    Addons     Mission, memory, knowledge, review, recover, analytics, and more." -ForegroundColor $Theme.MutedLight
    Write-Host ""
    Write-Host "  SECURITY  —  Isolating the Matrix Ollama port" -ForegroundColor $Theme.Warning
    Write-Host "  CypraTeam runs a private Ollama instance on localhost port 11435." -ForegroundColor $Theme.ErrorDim
    Write-Host "  Keep it bound to localhost. External network access is not required." -ForegroundColor $Theme.ErrorDim
    Write-Host "  To block inbound access, run once in PowerShell as Administrator:" -ForegroundColor $Theme.MutedLight
    Write-Host '  New-NetFirewallRule -DisplayName "Block External Cypra Ollama Port" -Direction Inbound -LocalPort 11435 -Protocol TCP -Action Block' -ForegroundColor $Theme.Info
    Write-Host ""
    Read-Host "Press Enter to return to Matrix panel"
}

function Show-LogBrowser {
    Clear-Host
    Show-CommandActivation -Command 'hist'
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host "                💡 MATRIX SESSION HISTORY & LOG BROWSER 🔎" -ForegroundColor $Theme.Info
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info

    $logDir = Join-Path $PSScriptRoot "Logs"
    if (Test-Path $logDir) {
        $logs = Get-ChildItem -Path $logDir -Filter "*.log" | Sort-Object CreationTime -Descending | Select-Object -First 15
        if ($logs) {
            $idx = 1
            foreach ($log in $logs) {
                Write-Host " [$idx] $($log.Name) ($([math]::Round($log.Length/1KB, 1)) KB)" -ForegroundColor $Theme.Warning
                $idx++
            }
            Write-Host ""
            $choice = Read-Host "Enter log number to read contents (or press Enter to go back)"
            if ($choice -match '^\d+$' -and [int]$choice -le $logs.Count) {
                $selectedLog = $logs[[int]$choice - 1]
                Clear-Host
                Write-Host "--- INSPECTING LOG: $($selectedLog.Name) ---" -ForegroundColor $Theme.Info
                Get-Content $selectedLog.FullName -Tail 40 | Write-Host -ForegroundColor $Theme.MutedLight
                Write-Host ""
                Read-Host "Press Enter to continue"
            }
        } else {
            Write-Host "[!] No session log files found in Logs directory." -ForegroundColor $Theme.WarningDim
            Start-Sleep -Seconds 2
        }
    } else {
        Write-Host "[!] Logs directory does not exist yet." -ForegroundColor $Theme.Error
        Start-Sleep -Seconds 2
    }
}

function Show-SessionStats {
    Clear-Host
    Show-CommandActivation -Command 'stats'
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host "             📊 MATRIX SESSION STATISTICS 📊" -ForegroundColor $Theme.Info
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host ""

    Show-LoadingBar -Label " Gathering Stats" -Steps 14 -DelayMs 8 -Color $Theme.Info
    Write-Host ""

    $uptime = (Get-Date) - $script:MatrixStartTime
    $uptimeStr = "{0:00}:{1:00}:{2:00}" -f [int]$uptime.TotalHours, $uptime.Minutes, $uptime.Seconds

    $taskCount = 0
    if (Test-Path $script:TaskRoot) {
        $taskCount = @(Get-ChildItem -Path $script:TaskRoot -Directory -ErrorAction SilentlyContinue).Count
    }

    $logDir = Join-Path $PSScriptRoot "Logs"
    $logCount = 0
    $logSizeMB = 0
    if (Test-Path $logDir) {
        $logFiles = @(Get-ChildItem -Path $logDir -Filter "*.log" -ErrorAction SilentlyContinue)
        $logCount = $logFiles.Count
        if ($logCount -gt 0) {
            $logSizeMB = [math]::Round((($logFiles | Measure-Object -Property Length -Sum).Sum / 1MB), 2)
        }
    }

    $backupDir = Join-Path $PSScriptRoot "Backups"
    $backupCount = 0
    $backupSizeMB = 0
    if (Test-Path $backupDir) {
        $backupFiles = @(Get-ChildItem -Path $backupDir -Filter "*.zip" -ErrorAction SilentlyContinue)
        $backupCount = $backupFiles.Count
        if ($backupCount -gt 0) {
            $backupSizeMB = [math]::Round((($backupFiles | Measure-Object -Property Length -Sum).Sum / 1MB), 2)
        }
    }

    $modelsSizeMB = 0
    if ($env:OLLAMA_MODELS -and (Test-Path $env:OLLAMA_MODELS)) {
        $modelsSizeMB = [math]::Round(((Get-ChildItem -Path $env:OLLAMA_MODELS -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB), 2)
    }

    Write-Host " Session Uptime         : $uptimeStr" -ForegroundColor $Theme.Primary
    Write-Host " Active Profile         : $script:SelectedProfile" -ForegroundColor $Theme.Primary
    Write-Host " Registered Agents      : $($script:AgentRegistry.Count)" -ForegroundColor $Theme.Primary
    Write-Host ""
    Write-Host " Task Workspaces        : $taskCount" -ForegroundColor $Theme.Info
    Write-Host " Session Logs           : $logCount files ($logSizeMB MB)" -ForegroundColor $Theme.Info
    Write-Host " Backups Stored         : $backupCount files ($backupSizeMB MB)" -ForegroundColor $Theme.Info
    Write-Host " Ollama Model Storage   : $modelsSizeMB MB" -ForegroundColor $Theme.Info
    Write-Host ""
    $activeTaskLabel = if ($global:ActiveTaskWorkspace) { Split-Path $global:ActiveTaskWorkspace -Leaf } else { "NONE" }
    Write-Host " Active Task            : $activeTaskLabel" -ForegroundColor $Theme.Accent

    Write-Host ""
    Read-Host "Press Enter to return to Dashboard"
}

function Wrap-ConsoleText {
    param(
        [string]$Text,
        [int]$Width
    )

    if ($Width -lt 8) { return @([string]$Text.Substring(0, [Math]::Min($Text.Length, $Width))) }
    if ([string]::IsNullOrEmpty($Text)) { return @("") }

    $words = $Text -split '\s+'
    $linesOut = New-Object System.Collections.Generic.List[string]
    $current = ""

    foreach ($word in $words) {
        if ([string]::IsNullOrEmpty($word)) { continue }

        if ($word.Length -gt $Width) {
            if ($current.Length -gt 0) {
                $linesOut.Add($current)
                $current = ""
            }
            for ($offset = 0; $offset -lt $word.Length; $offset += $Width) {
                $len = [Math]::Min($Width, $word.Length - $offset)
                $linesOut.Add($word.Substring($offset, $len))
            }
            continue
        }

        $candidate = if ($current.Length -gt 0) { "$current $word" } else { $word }
        if ($candidate.Length -le $Width) {
            $current = $candidate
        } else {
            $linesOut.Add($current)
            $current = $word
        }
    }

    if ($current.Length -gt 0) { $linesOut.Add($current) }
    return @($linesOut)
}

function Get-CurrentDisplayModel {
    if ($script:CurrentAgentModel -and -not [string]::IsNullOrWhiteSpace([string]$script:CurrentAgentModel)) {
        return [string]$script:CurrentAgentModel
    }
    return Get-CurrentActiveModel
}

function Show-Dashboard {
    # Router: color comes from $Theme (Show-ThemeEditor / 'theme'), but the
    # dashboard's structural layout is a separate choice (Show-LayoutPicker /
    # 'layout'). Falls back to Classic for any unrecognized/legacy value.
    switch ($script:DashboardLayout) {
        "Grouped Roster" { Show-DashboardGroupedRoster; return }
        "Compact Dense"  { Show-DashboardCompactDense; return }
        "Command Deck"   { Show-DashboardCommandDeck; return }
        "Ops Feed"       { Show-DashboardOpsFeed; return }
        "Quiet"          { Show-DashboardQuiet; return }
        "Focus"          { Show-DashboardFocus; return }
        default          { Show-DashboardClassic; return }
    }
}

function Show-DashboardClassic {
    Clear-Host

    # ==============================================
    # DASHBOARD PALETTE — RED THEME, NO PER-AGENT COLOR CODING
    # ==============================================
    # The dashboard intentionally uses only one accent + text/muted pair so the
    # whole panel reads as one consistent surface (defaults to red). The rich,
    # distinct per-agent/per-group colors (from Get-RegistryColor) are reserved
    # for the agent chat session header (Show-AgentHeader) only — not shown here.
    # Colors come from $Theme.Dash* so the 'theme' command can re-skin this too.
    $DashPrimary   = $Theme.DashPrimary
    $DashDim       = $Theme.DashDim
    $DashText      = $Theme.DashText
    $DashMuted     = $Theme.DashMuted

    $termWidth = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width)
    $innerLen = $termWidth - 2
    $topBotLine = '═' * $innerLen
    
Write-Host "   ___ _   _ ___  ___    _ _____ ___   _   __  __ " -ForegroundColor $DashPrimary
    Write-Host "  /   | | | |   \/   \  /_\_   _| __| / \ |  \/  |" -ForegroundColor $DashPrimary
    Write-Host " | (__| |_| |  _/    / / _ \| | | _| / _ \| |\/| |" -ForegroundColor $DashPrimary
    Write-Host "  \___|\__, |_|  |_|_\/_/ \_\_| |___/_/ \_\_|  |_|" -ForegroundColor $DashPrimary
    Write-Host "       |___/                                      " -ForegroundColor $DashPrimary
    Write-Host "  [ INFRASTRUCTURE MATRIX v1.1 - AGENT TURBO PANEL ]" -ForegroundColor $DashDim
    Write-Host ""

    # Active Task Status Banner
    $activeName = if ($global:ActiveTaskWorkspace) { Split-Path $global:ActiveTaskWorkspace -Leaf } else { "NONE" }
    Write-Host "==================================================" -ForegroundColor $DashDim
    Write-Host " CURRENT ACTIVE TASK: $activeName" -ForegroundColor $DashText
    Write-Host " LAST MODEL: $(Get-CurrentDisplayModel)" -ForegroundColor $DashText
    Write-Host " ACTIVE BASE: $(Get-CurrentActiveModel)" -ForegroundColor $DashMuted
    $thinkState = if ($script:HideModelThinking) { 'HIDDEN' } else { 'VISIBLE' }
    Write-Host " THINKING DISPLAY: $thinkState  (toggle: think)" -ForegroundColor $DashMuted
    Write-Host "==================================================" -ForegroundColor $DashDim
    Write-Host ""

    $agentCount = $script:AgentRegistry.Count
    $title = "$($script:ThemeEmoji) CYPRATEAM AI MULTI-AGENT MATRIX PANEL $($script:ThemeEmoji) ($agentCount NODES)"
    if ($title.Length -gt $innerLen) { $title = $title.Substring(0, $innerLen) }
    $titlePad = ' ' * [Math]::Max(0, $innerLen - $title.Length)
    Write-Host "╔$topBotLine╗" -ForegroundColor $DashPrimary
    Write-Host "║$title$titlePad║" -ForegroundColor $DashPrimary
    Write-Host "╚$topBotLine╝" -ForegroundColor $DashPrimary
    Write-Host ""

    # Responsive matrix layout.
    # The previous version calculated the number of columns from a nominal
    # 33-cell card, but the rendered cells were shorter than that. That left
    # unused horizontal space at the right edge of the terminal.
    #
    # We now render the matrix as actual row strings and distribute the full
    # available width across every column. The number of columns is based on
    # the minimum readable cell width, while the remaining width is spread
    # evenly between cells so the final column reaches the right edge.
    $minCellWidth = 31
    $columns = [Math]::Floor($innerLen / ($minCellWidth + 1))
    if ($columns -lt 1) { $columns = 1 }

    # NOTE: agent entries are rendered in a uniform red/white/gray palette here.
    # No per-agent or per-group color coding is shown on the dashboard; that
    # distinction only appears once you're inside an agent's chat session.
    $agents = @($script:AgentRegistry.Keys | Sort-Object {[int]$_})
    $rows = [Math]::Ceiling($agents.Count / $columns)
    for ($row = 0; $row -lt $rows; $row++) {
        $rowStart = $row * $columns
        $rowEnd = [Math]::Min($rowStart + $columns - 1, $agents.Count - 1)
        $rowCount = $rowEnd - $rowStart + 1

        # Spread all available width across the cells actually displayed.
        # The last cell absorbs rounding so the row always ends exactly at the
        # dashboard's right border.
        $baseCellWidth = [Math]::Floor($innerLen / $columns)
        $extra = $innerLen - ($baseCellWidth * $columns)

        for ($col = 0; $col -lt $columns; $col++) {
            $idx = $rowStart + $col
            if ($idx -gt $rowEnd) {
                $cell = ' ' * $baseCellWidth
                if ($col -lt $extra) { $cell += ' ' }
                Write-Host $cell -NoNewline
                continue
            }

            $key = $agents[$idx]
            $sKey = [string]$key
            $name = [string]$script:AgentRegistry[$sKey].name
            $tag  = [string]$script:AgentRegistry[$sKey].tag

            $cellWidth = $baseCellWidth + $(if ($col -lt $extra) { 1 } else { 0 })
            $content = ("{0,3}│ ■ {1,-11} [{2,-8}]" -f $key, ($name.Substring(0,[Math]::Min(11,$name.Length))), ($tag.Substring(0,[Math]::Min(8,$tag.Length))))
            if ($content.Length -lt $cellWidth) {
                $content = $content + (' ' * ($cellWidth - $content.Length))
            } elseif ($content.Length -gt $cellWidth) {
                $content = $content.Substring(0, $cellWidth)
            }

            # Keep the existing per-field colors while using a fixed-width
            # padded cell.
            Write-Host ' │' -NoNewline -ForegroundColor $DashDim
            Write-Host ("{0,3}" -f $key) -NoNewline -ForegroundColor $DashPrimary
            Write-Host '│ ' -NoNewline -ForegroundColor $DashDim
            Write-Host '■ ' -NoNewline -ForegroundColor $DashPrimary
            Write-Host ("{0,-11} " -f ($name.Substring(0,[Math]::Min(11,$name.Length)))) -NoNewline -ForegroundColor $DashText
            Write-Host ("[{0,-8}]" -f ($tag.Substring(0,[Math]::Min(8,$tag.Length)))) -NoNewline -ForegroundColor $DashMuted
            $used = 2 + 3 + 2 + 2 + 12 + 10
            if ($cellWidth -gt $used) { Write-Host (' ' * ($cellWidth - $used)) -NoNewline }
        }
        Write-Host '│' -ForegroundColor $DashDim
    }
    Write-Host ""

    $ollamaProc = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    $procStatus = if ($ollamaProc -and !$ollamaProc.HasExited) { "ONLINE" } else { "STANDBY" }
    $metricsText = " METRICS: $agentCount Nodes | Status: $procStatus | Active Model: $(Get-CurrentActiveModel) | Profile: $script:SelectedProfile | Routing: SEMANTIC-FIRST"
    $commandTexts = @(
        " BASIC: [1-$agentCount] Agent | nexus | quad | debate | pipe | task | vram",
        " TOOLS: groups | map | find | out | stats | profile | settings | commands | routeaudit | team",
        " SYSTEM: addons | models | pull | preflight | recover | bckup | theme | layout | [q] Exit"
    )

    Write-Host "╔$topBotLine╗" -ForegroundColor $DashPrimary

    $metricLines = @(Wrap-ConsoleText -Text $metricsText -Width ($innerLen - 2))
    foreach ($lineText in $metricLines) {
        $safeLine = $lineText
        if ($safeLine.Length -gt $innerLen) { $safeLine = $safeLine.Substring(0, $innerLen) }
        $metricPad = ' ' * [Math]::Max(0, $innerLen - $safeLine.Length)
        Write-Host "║$safeLine$metricPad║" -ForegroundColor $DashPrimary
    }

    Write-Host "╠$topBotLine╣" -ForegroundColor $DashDim

    foreach ($commandText in $commandTexts) {
        $wrapped = @(Wrap-ConsoleText -Text $commandText -Width ($innerLen - 2))
        foreach ($lineText in $wrapped) {
            $safeLine = $lineText
            if ($safeLine.Length -gt $innerLen) { $safeLine = $safeLine.Substring(0, $innerLen) }
            $pad = ' ' * [Math]::Max(0, $innerLen - $safeLine.Length)
            Write-Host "║$safeLine$pad║" -ForegroundColor $DashMuted
        }
    }

    Write-Host "╚$topBotLine╝" -ForegroundColor $DashPrimary

    Write-Host ""
    Write-Host "  /)/)" -ForegroundColor $DashDim
    Write-Host " (,,>.<)  <(Love Shi and Azu)" -ForegroundColor $DashDim
    Write-Host " / >❤️" -ForegroundColor $DashDim
}

# ==============================================
# ALTERNATE DASHBOARD LAYOUTS
# ==============================================
# Structural layouts only - none of these touch $Theme. Every one of them
# still reads its colors from $Theme.Dash* / $script:ThemeEmoji, so any color
# theme + any layout combination works together.

function Show-DashboardGroupedRoster {
    Clear-Host
     $DashPrimary = $Theme.DashPrimary
    $DashDim     = $Theme.DashDim
    $DashText    = $Theme.DashText
    $DashMuted   = $Theme.DashMuted

    $termWidth = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width)
    $innerLen = $termWidth - 2
    $topBotLine = '═' * $innerLen

    $activeName = if ($global:ActiveTaskWorkspace) { Split-Path $global:ActiveTaskWorkspace -Leaf } else { "NONE" }
    Write-Host "==================================================" -ForegroundColor $DashDim
    Write-Host " CURRENT ACTIVE TASK: $activeName" -ForegroundColor $DashText
    Write-Host " LAST MODEL: $(Get-CurrentDisplayModel)" -ForegroundColor $DashText
    Write-Host " ACTIVE BASE: $(Get-CurrentActiveModel)" -ForegroundColor $DashMuted
    $thinkState = if ($script:HideModelThinking) { 'HIDDEN' } else { 'VISIBLE' }
    Write-Host " THINKING DISPLAY: $thinkState  (toggle: think)" -ForegroundColor $DashMuted
    Write-Host "==================================================" -ForegroundColor $DashDim
    Write-Host ""

    $agentCount = $script:AgentRegistry.Count
    $title = "$($script:ThemeEmoji) CYPRATEAM // GROUPED ROSTER ($agentCount NODES) $($script:ThemeEmoji)"
    if ($title.Length -gt $innerLen) { $title = $title.Substring(0, $innerLen) }
    $titlePad = ' ' * [Math]::Max(0, $innerLen - $title.Length)
    Write-Host "╔$topBotLine╗" -ForegroundColor $DashPrimary
    Write-Host "║$title$titlePad║" -ForegroundColor $DashPrimary
    Write-Host "╚$topBotLine╝" -ForegroundColor $DashPrimary
    Write-Host ""

    # Every agent, organized under its specialty group header rather than a
    # flat numeric grid. Groups appear in registry (ID) order of first
    # appearance, so Core/early groups still lead.
    $orderedIds = @($script:AgentRegistry.Keys | Sort-Object {[int]$_})
    $groupOrder = New-Object System.Collections.Generic.List[string]
    $groupMembers = @{}
    foreach ($id in $orderedIds) {
        $entry = $script:AgentRegistry[$id]
        $g = [string]$entry.group
        if (-not $groupMembers.ContainsKey($g)) {
            $groupMembers[$g] = New-Object System.Collections.Generic.List[string]
            $groupOrder.Add($g) | Out-Null
        }
        $groupMembers[$g].Add("$($id):$($entry.name)") | Out-Null
    }

    foreach ($g in $groupOrder) {
        $members = $groupMembers[$g]
        Write-Host " ▸ $g " -NoNewline -ForegroundColor $DashPrimary
        Write-Host "($($members.Count) agents)" -ForegroundColor $DashMuted
        $line = ($members -join '   ')
        $wrapped = @(Wrap-ConsoleText -Text $line -Width ($innerLen - 4))
        foreach ($w in $wrapped) {
            Write-Host "    $w" -ForegroundColor $DashText
        }
        Write-Host ""
    }

    $ollamaProc = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    $procStatus = if ($ollamaProc -and !$ollamaProc.HasExited) { "ONLINE" } else { "STANDBY" }
    $metricsText = " METRICS: $agentCount Nodes | Status: $procStatus | Active Model: $(Get-CurrentActiveModel) | Profile: $script:SelectedProfile | Routing: SEMANTIC-FIRST"
    $commandTexts = @(
        " BASIC: [1-$agentCount] Agent | nexus | quad | debate | pipe | task | vram",
        " TOOLS: groups | map | find | out | stats | profile | settings | commands | routeaudit | team",
        " SYSTEM: addons | models | pull | preflight | recover | bckup | theme | layout | [q] Exit"
    )
    Write-Host "╔$topBotLine╗" -ForegroundColor $DashPrimary
    $metricLines = @(Wrap-ConsoleText -Text $metricsText -Width ($innerLen - 2))
    foreach ($lineText in $metricLines) {
        $safeLine = $lineText
        if ($safeLine.Length -gt $innerLen) { $safeLine = $safeLine.Substring(0, $innerLen) }
        $metricPad = ' ' * [Math]::Max(0, $innerLen - $safeLine.Length)
        Write-Host "║$safeLine$metricPad║" -ForegroundColor $DashPrimary
    }
    Write-Host "╠$topBotLine╣" -ForegroundColor $DashDim
    foreach ($commandText in $commandTexts) {
        $wrapped = @(Wrap-ConsoleText -Text $commandText -Width ($innerLen - 2))
        foreach ($lineText in $wrapped) {
            $safeLine = $lineText
            if ($safeLine.Length -gt $innerLen) { $safeLine = $safeLine.Substring(0, $innerLen) }
            $pad = ' ' * [Math]::Max(0, $innerLen - $safeLine.Length)
            Write-Host "║$safeLine$pad║" -ForegroundColor $DashMuted
        }
    }
    Write-Host "╚$topBotLine╝" -ForegroundColor $DashPrimary
    Write-Host ""
}

function Show-DashboardCompactDense {
    Clear-Host
     $DashPrimary = $Theme.DashPrimary
    $DashDim     = $Theme.DashDim
    $DashText    = $Theme.DashText
    $DashMuted   = $Theme.DashMuted

    $termWidth = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width)
    $innerLen = $termWidth - 2

    $agentCount = $script:AgentRegistry.Count
    $activeName = if ($global:ActiveTaskWorkspace) { Split-Path $global:ActiveTaskWorkspace -Leaf } else { "NONE" }
    $procTag = if (Get-Process -Name "ollama" -ErrorAction SilentlyContinue) { "ONLINE" } else { "STANDBY" }
    $thinkState = if ($script:HideModelThinking) { 'HIDDEN' } else { 'VISIBLE' }

    # No ASCII logo, no per-cell borders - just a single status strip and a
    # tight column grid, so the most agents fit on screen with the least
    # scrolling on small/narrow terminals.
    $statusLine = "$($script:ThemeEmoji) CYPRATEAM [$agentCount NODES] . $procTag . task:$activeName . model:$(Get-CurrentActiveModel) . profile:$script:SelectedProfile . think:$thinkState"
    if ($statusLine.Length -gt $innerLen) { $statusLine = $statusLine.Substring(0, $innerLen) }
    Write-Host $statusLine -ForegroundColor $DashPrimary
    Write-Host ('─' * $innerLen) -ForegroundColor $DashDim
    Write-Host ""

    $minCellWidth = 20
    $columns = [Math]::Floor($innerLen / ($minCellWidth + 1))
    if ($columns -lt 1) { $columns = 1 }

    $agents = @($script:AgentRegistry.Keys | Sort-Object {[int]$_})
    $rows = [Math]::Ceiling($agents.Count / $columns)
    for ($row = 0; $row -lt $rows; $row++) {
        $rowStart = $row * $columns
        for ($col = 0; $col -lt $columns; $col++) {
            $idx = $rowStart + $col
            if ($idx -ge $agents.Count) {
                Write-Host (' ' * ($minCellWidth + 1)) -NoNewline
                continue
            }
            $key = $agents[$idx]
            $entry = $script:AgentRegistry[$key]
            $name = [string]$entry.name
            $nameLen = [Math]::Max(1, $minCellWidth - 5)
            $cellText = ("{0,3}:{1}" -f $key, $name.Substring(0, [Math]::Min($nameLen, $name.Length)))
            if ($cellText.Length -lt ($minCellWidth + 1)) {
                $cellText = $cellText.PadRight($minCellWidth + 1)
            }
            Write-Host $cellText -NoNewline -ForegroundColor $DashText
        }
        Write-Host ""
    }
    Write-Host ""
    Write-Host ('─' * $innerLen) -ForegroundColor $DashDim
    Write-Host " groups | map | find | stats | profile | settings | theme | layout | commands | [q] Exit" -ForegroundColor $DashMuted
    Write-Host ""
}

function Show-DashboardCommandDeck {
    Clear-Host
     $DashPrimary = $Theme.DashPrimary
    $DashDim     = $Theme.DashDim
    $DashText    = $Theme.DashText
    $DashMuted   = $Theme.DashMuted

    $termWidth = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width)
    $innerLen = $termWidth - 2
    $topBotLine = '═' * $innerLen

    $agentCount = $script:AgentRegistry.Count
    $activeName = if ($global:ActiveTaskWorkspace) { Split-Path $global:ActiveTaskWorkspace -Leaf } else { "NONE" }
    $ollamaProc = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    $procStatus = if ($ollamaProc -and !$ollamaProc.HasExited) { "ONLINE" } else { "STANDBY" }
    $thinkState = if ($script:HideModelThinking) { 'HIDDEN' } else { 'VISIBLE' }

    $title = "$($script:ThemeEmoji) CYPRATEAM // COMMAND DECK $($script:ThemeEmoji)"
    if ($title.Length -gt $innerLen) { $title = $title.Substring(0, $innerLen) }
    $titlePad = ' ' * [Math]::Max(0, $innerLen - $title.Length)
    Write-Host "╔$topBotLine╗" -ForegroundColor $DashPrimary
    Write-Host "║$title$titlePad║" -ForegroundColor $DashPrimary
    Write-Host "╚$topBotLine╝" -ForegroundColor $DashPrimary
    Write-Host ""

    # --- VITALS TICKER --------------------------------------------------
    # Redesigned from the old row-of-boxed-cards into a single instrument-
    # panel strip, tick-separated like a HUD readout. Cheaper to render,
    # scales cleanly to any terminal width, and reads faster at a glance.
    $vitalsParts = @(
        "NODES $agentCount", "STATUS $procStatus", "TASK $activeName",
        "MODEL $(Get-CurrentActiveModel)", "PROFILE $script:SelectedProfile", "THINK $thinkState"
    )
    $vitalsLine = " " + ($vitalsParts -join "  ┃  ")
    $vitalsRule = '─' * $innerLen
    Write-Host "┌$vitalsRule┐" -ForegroundColor $DashDim
    $vwrapped = @(Wrap-ConsoleText -Text $vitalsLine -Width ($innerLen - 1))
    foreach ($w in $vwrapped) {
        $safeLine = $w
        if ($safeLine.Length -gt $innerLen) { $safeLine = $safeLine.Substring(0, $innerLen) }
        $pad = ' ' * [Math]::Max(0, $innerLen - $safeLine.Length)
        Write-Host "│$safeLine$pad│" -ForegroundColor $DashText
    }
    Write-Host "└$vitalsRule┘" -ForegroundColor $DashDim
    Write-Host ""

    # --- QUICK ACCESS DECK -----------------------------------------------
    # A curated shortcut deck, not the full roster - with hundreds of agents
    # registered, printing every single one as an inline-wrapped chip stream
    # produced an unreadable, misaligned wall of text. Instead this shows a
    # small set of go-to agents (the Core group when one exists, otherwise
    # just the first agents in the registry) as a real fixed-width grid, with
    # a pointer to 'find'/'map'/'groups' for the rest of the roster.
    Write-Host " QUICK ACCESS DECK" -ForegroundColor $DashPrimary
    $agents = @($script:AgentRegistry.Keys | Sort-Object {[int]$_})
    $maxChips = 16
    $quickIds = @($agents | Where-Object { [string]$script:AgentRegistry[$_].group -eq "Core" })
    if ($quickIds.Count -eq 0) { $quickIds = $agents }
    $shownIds = @($quickIds | Select-Object -First $maxChips)

    $chipInnerWidth = 22
    $chipWidth = $chipInnerWidth + 4   # "[ " + content + " ]"
    $columns = [Math]::Max(1, [Math]::Floor($innerLen / ($chipWidth + 1)))

    for ($i = 0; $i -lt $shownIds.Count; $i += $columns) {
        $rowIds = @($shownIds[$i..([Math]::Min($i + $columns - 1, $shownIds.Count - 1))])
        Write-Host "  " -NoNewline
        foreach ($key in $rowIds) {
            $entry = $script:AgentRegistry[[string]$key]
            $name = [string]$entry.name
            $idStr = ([string]$key).PadLeft(3)
            $label = "$idStr ▸ $name"
            if ($label.Length -gt $chipInnerWidth) { $label = $label.Substring(0, $chipInnerWidth) }
            $chipText = "[ " + $label.PadRight($chipInnerWidth) + " ]"
            Write-Host "$chipText " -NoNewline -ForegroundColor $DashText
        }
        Write-Host ""
    }

    $remaining = $agentCount - $shownIds.Count
    if ($remaining -gt 0) {
        Write-Host "  " -NoNewline
        Write-Host ("+{0}" -f $remaining) -NoNewline -ForegroundColor $DashPrimary
        Write-Host " agents not on this deck. Type an ID (1-$agentCount) or " -NoNewline -ForegroundColor $DashMuted
        Write-Host "find" -NoNewline -ForegroundColor $DashPrimary
        Write-Host " keyword  ·  " -NoNewline -ForegroundColor $DashMuted
        Write-Host "groups" -NoNewline -ForegroundColor $DashPrimary
        Write-Host "  ·  " -NoNewline -ForegroundColor $DashMuted
        Write-Host "map" -ForegroundColor $DashPrimary
    }
    Write-Host ""

    # --- GROUP LOAD --------------------------------------------------------
    # Per-group counts as small horizontal load bars rather than a plain
    # "Name (count)" text line, so relative group size is visible at a glance.
    Write-Host " GROUP LOAD" -ForegroundColor $DashPrimary
    $groupCounts = [ordered]@{}
    foreach ($id in $agents) {
        $g = [string]$script:AgentRegistry[$id].group
        if (-not $groupCounts.Contains($g)) { $groupCounts[$g] = 0 }
        $groupCounts[$g] = $groupCounts[$g] + 1
    }
    $maxCount = 1
    foreach ($g in $groupCounts.Keys) { if ($groupCounts[$g] -gt $maxCount) { $maxCount = $groupCounts[$g] } }
    $barWidth = 20
    $labelWidth = 0
    foreach ($g in $groupCounts.Keys) { if ($g.Length -gt $labelWidth) { $labelWidth = $g.Length } }
    $labelWidth = [Math]::Min($labelWidth, [Math]::Max(10, $innerLen - $barWidth - 10))
    foreach ($g in $groupCounts.Keys) {
        $count = $groupCounts[$g]
        $filled = [Math]::Max(1, [Math]::Round(($count / $maxCount) * $barWidth))
        $bar = ('█' * $filled).PadRight($barWidth, '░')
        $label = $g
        if ($label.Length -gt $labelWidth) { $label = $label.Substring(0, $labelWidth) }
        Write-Host ("  " + $label.PadRight($labelWidth) + " ") -NoNewline -ForegroundColor $DashMuted
        Write-Host $bar -NoNewline -ForegroundColor $DashPrimary
        Write-Host (" $count") -ForegroundColor $DashText
    }
    Write-Host ""

    $metricsText = " METRICS: $agentCount Nodes | Status: $procStatus | Active Model: $(Get-CurrentActiveModel) | Profile: $script:SelectedProfile | Routing: SEMANTIC-FIRST"
    $commandTexts = @(
        " BASIC: [1-$agentCount] Agent | nexus | quad | debate | pipe | task | vram",
        " TOOLS: groups | map | find | out | stats | profile | settings | commands | routeaudit | team",
        " SYSTEM: addons | models | pull | preflight | recover | bckup | theme | layout | [q] Exit"
    )
    Write-Host "╔$topBotLine╗" -ForegroundColor $DashPrimary
    $metricLines = @(Wrap-ConsoleText -Text $metricsText -Width ($innerLen - 2))
    foreach ($lineText in $metricLines) {
        $safeLine = $lineText
        if ($safeLine.Length -gt $innerLen) { $safeLine = $safeLine.Substring(0, $innerLen) }
        $metricPad = ' ' * [Math]::Max(0, $innerLen - $safeLine.Length)
        Write-Host "║$safeLine$metricPad║" -ForegroundColor $DashPrimary
    }
    Write-Host "╠$topBotLine╣" -ForegroundColor $DashDim
    foreach ($commandText in $commandTexts) {
        $wrapped = @(Wrap-ConsoleText -Text $commandText -Width ($innerLen - 2))
        foreach ($lineText in $wrapped) {
            $safeLine = $lineText
            if ($safeLine.Length -gt $innerLen) { $safeLine = $safeLine.Substring(0, $innerLen) }
            $pad = ' ' * [Math]::Max(0, $innerLen - $safeLine.Length)
            Write-Host "║$safeLine$pad║" -ForegroundColor $DashMuted
        }
    }
    Write-Host "╚$topBotLine╝" -ForegroundColor $DashPrimary
    Write-Host ""
}

function Show-DashboardOpsFeed {
    Clear-Host
     $DashPrimary = $Theme.DashPrimary
    $DashDim     = $Theme.DashDim
    $DashText    = $Theme.DashText
    $DashMuted   = $Theme.DashMuted

    $termWidth = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width)
    $innerLen = $termWidth - 2

    $agentCount = $script:AgentRegistry.Count
    $activeName = if ($global:ActiveTaskWorkspace) { Split-Path $global:ActiveTaskWorkspace -Leaf } else { "NONE" }
    $ollamaProc = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    $procStatus = if ($ollamaProc -and !$ollamaProc.HasExited) { "ONLINE" } else { "STANDBY" }
    $thinkState = if ($script:HideModelThinking) { 'HIDDEN' } else { 'VISIBLE' }

    # No boxes anywhere in this layout - it's meant to read like a plain
    # system manifest/log rather than a bordered dashboard panel.
    Write-Host " $($script:ThemeEmoji) CYPRATEAM // OPS FEED $($script:ThemeEmoji)  ($agentCount NODES)" -ForegroundColor $DashPrimary
    Write-Host (' ' + ('─' * $innerLen)) -ForegroundColor $DashDim
    Write-Host " TASK    : $activeName" -ForegroundColor $DashText
    Write-Host " MODEL   : $(Get-CurrentActiveModel)" -ForegroundColor $DashText
    Write-Host " PROFILE : $script:SelectedProfile   STATUS: $procStatus   THINK: $thinkState" -ForegroundColor $DashMuted
    Write-Host (' ' + ('─' * $innerLen)) -ForegroundColor $DashDim
    Write-Host ""

    # One row per agent, dot-leader aligned so the tag column lines up flush
    # right regardless of name length - a manifest/log feed rather than a grid.
    $agents = @($script:AgentRegistry.Keys | Sort-Object {[int]$_})
    $tagColWidth = 12
    foreach ($key in $agents) {
        $entry = $script:AgentRegistry[[string]$key]
        $name = [string]$entry.name
        $tag  = "[" + [string]$entry.tag + "]"
        if ($tag.Length -gt $tagColWidth) { $tag = $tag.Substring(0, $tagColWidth) }

        $idStr = ([string]$key).PadLeft(3)
        $prefix = " $idStr ⟩ $name "
        $leaderWidth = $innerLen - $prefix.Length - $tagColWidth
        if ($leaderWidth -lt 1) { $leaderWidth = 1 }
        $leader = '.' * $leaderWidth

        Write-Host $prefix -NoNewline -ForegroundColor $DashText
        Write-Host $leader -NoNewline -ForegroundColor $DashDim
        Write-Host (" " + $tag.PadRight($tagColWidth)) -ForegroundColor $DashMuted
    }
    Write-Host ""

    Write-Host (' ' + ('─' * $innerLen)) -ForegroundColor $DashDim
    $metricsText = " METRICS: $agentCount Nodes | Status: $procStatus | Active Model: $(Get-CurrentActiveModel) | Profile: $script:SelectedProfile | Routing: SEMANTIC-FIRST"
    foreach ($w in @(Wrap-ConsoleText -Text $metricsText -Width $innerLen)) { Write-Host $w -ForegroundColor $DashPrimary }
    foreach ($commandText in @(
        " BASIC: [1-$agentCount] Agent | nexus | quad | debate | pipe | task | vram",
        " TOOLS: groups | map | find | out | stats | profile | settings | commands | routeaudit | team",
        " SYSTEM: addons | models | pull | preflight | recover | bckup | theme | layout | [q] Exit"
    )) {
        foreach ($w in @(Wrap-ConsoleText -Text $commandText -Width $innerLen)) { Write-Host $w -ForegroundColor $DashMuted }
    }
    Write-Host ""
}

function Get-MatrixCoreIds {
    param([int]$Take = 8)
    $agents = @($script:AgentRegistry.Keys | Sort-Object { [int]$_ })
    $core = @($agents | Where-Object { [string]$script:AgentRegistry[$_].group -eq "Core" })
    if ($core.Count -eq 0) { $core = $agents }
    return @($core | Select-Object -First $Take)
}

function Show-DashboardQuiet {
    Clear-Host
    $c = $Theme.DashPrimary
    $t = $Theme.DashText
    $m = $Theme.DashMuted
    $d = $Theme.DashDim
    $agentCount = $script:AgentRegistry.Count
    $proc = if (Get-Process -Name "ollama" -ErrorAction SilentlyContinue) { "online" } else { "standby" }
    $model = Get-CurrentActiveModel
    $w = [Math]::Max(36, [int]$Host.UI.RawUI.WindowSize.Width - 4)

    Write-Host ""
    Write-Host ("  {0}  CYPRATEAM" -f $script:ThemeEmoji) -ForegroundColor $c
    Write-Host ("  " + ('─' * [Math]::Min(28, $w))) -ForegroundColor $d
    Write-Host "  " -NoNewline
    Write-Host $proc -NoNewline -ForegroundColor $c
    Write-Host "   $agentCount agents   " -NoNewline -ForegroundColor $m
    Write-Host $script:SelectedProfile -NoNewline -ForegroundColor $t
    Write-Host ""
    Write-Host ("  model  {0}" -f $model) -ForegroundColor $m
    Write-Host ""
    Write-Host "  CORE" -ForegroundColor $c
    foreach ($key in (Get-MatrixCoreIds -Take 8)) {
        $entry = $script:AgentRegistry[$key]
        $name = [string]$entry.name
        $tag = [string]$entry.tag
        Write-Host ("    {0,3}  " -f $key) -NoNewline -ForegroundColor $c
        Write-Host ("{0,-16}" -f $name) -NoNewline -ForegroundColor $t
        Write-Host ("  {0}" -f $tag) -ForegroundColor $m
    }
    Write-Host ""
    Write-Host "  type an ID to open   " -NoNewline -ForegroundColor $m
    Write-Host "find" -NoNewline -ForegroundColor $c
    Write-Host "  " -NoNewline
    Write-Host "theme" -NoNewline -ForegroundColor $c
    Write-Host "  " -NoNewline
    Write-Host "layout" -NoNewline -ForegroundColor $c
    Write-Host "  " -NoNewline
    Write-Host "q" -ForegroundColor $c
    Write-Host ""
}

function Show-DashboardFocus {
    Clear-Host
    $c = $Theme.DashPrimary
    $t = $Theme.DashText
    $m = $Theme.DashMuted
    $d = $Theme.DashDim
    $agentCount = $script:AgentRegistry.Count
    $proc = if (Get-Process -Name "ollama" -ErrorAction SilentlyContinue) { "online" } else { "standby" }
    $model = Get-CurrentActiveModel
    $w = [Math]::Max(36, [int]$Host.UI.RawUI.WindowSize.Width - 4)

    Write-Host ""
    Write-Host "  FOCUS" -NoNewline -ForegroundColor $c
    Write-Host ("   {0}   {1} agents" -f $proc, $agentCount) -ForegroundColor $m
    Write-Host ("  {0}" -f $script:SelectedProfile) -ForegroundColor $t
    Write-Host ("  {0}" -f $model) -ForegroundColor $d
    Write-Host ("  " + ('─' * [Math]::Min(36, $w))) -ForegroundColor $d
    Write-Host ""
    foreach ($key in (Get-MatrixCoreIds -Take 16)) {
        $entry = $script:AgentRegistry[$key]
        $name = [string]$entry.name
        $tag = [string]$entry.tag
        Write-Host ("  {0,3}  " -f $key) -NoNewline -ForegroundColor $c
        Write-Host ("{0,-18}" -f $name) -NoNewline -ForegroundColor $t
        if (-not [string]::IsNullOrWhiteSpace($tag)) {
            Write-Host (" {0}" -f $tag) -ForegroundColor $m
        } else {
            Write-Host ""
        }
    }
    Write-Host ("  " + ('─' * [Math]::Min(36, $w))) -ForegroundColor $d
    Write-Host "  Type an ID to open that agent." -ForegroundColor $m
    Write-Host "  " -NoNewline
    Write-Host "find" -NoNewline -ForegroundColor $c
    Write-Host " word   searches all $agentCount   " -NoNewline -ForegroundColor $m
    Write-Host "q" -NoNewline -ForegroundColor $c
    Write-Host "  leaves" -ForegroundColor $m
    Write-Host ""
}

# Interactive picker for the dashboard's structural layout. Deliberately
# separate from Show-ThemeEditor: colors and layout are independent choices
# and either can be changed without touching the other.
function Show-LayoutPicker {
    Clear-Host
    Show-CommandActivation -Command 'layout'
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host "             🧩 DASHBOARD LAYOUT PICKER 🧩" -ForegroundColor $Theme.Info
    Write-Host "===================================================================>" -ForegroundColor $Theme.Info
    Write-Host ""
    Write-Host " Current layout: $($script:DashboardLayout)" -ForegroundColor $Theme.MutedLight
    Write-Host " This is independent of your color theme - mix and match freely." -ForegroundColor $Theme.MutedLight
    Write-Host ""

    $i = 0
    foreach ($name in $script:DashboardLayoutNames) {
        $i++
        $marker = if ($name -eq $script:DashboardLayout) { "●" } else { " " }
        Write-Host ("  [{0}] {1} " -f $i, $marker) -NoNewline -ForegroundColor $Theme.MutedLight
        Write-Host ("{0,-16}" -f $name) -NoNewline -ForegroundColor $Theme.Primary
        Write-Host ("- $($script:DashboardLayoutDescriptions[$name])") -ForegroundColor $Theme.MutedLight
    }
    Write-Host ""
    $choice = (Read-Host "Pick a layout by number (Enter to cancel)").Trim()

    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $script:DashboardLayoutNames.Count) {
        $chosen = $script:DashboardLayoutNames[[int]$choice - 1]
        $script:DashboardLayout = $chosen
        $matrixConfig.DashboardLayout = $chosen

        # Saved through Save-ThemeConfig - the same function/file (ThemeConfig.json)
        # the color theme uses - so layout persists the same way theme does.
        Save-ThemeConfig

        Write-Host "[+] Dashboard layout set to: $chosen (saved to ThemeConfig.json)" -ForegroundColor $Theme.Success
        Start-Sleep -Milliseconds 800
    }
}
function Show-AgentHeader {
    param($model, $tag, $summary, $color)
    Clear-Host

    $termWidth = [Math]::Max(60, $Host.UI.RawUI.WindowSize.Width)
    $innerLen = $termWidth - 2
    $line = '═' * $innerLen
    $separator = '─' * $innerLen

    $nodeTitle = "$model node deployed ($tag)"
    $declaredBase = Get-AgentDeclaredBaseModel -AgentModel ([string]$model)
    $channelText = "STATUS: ACTIVE  |  PROFILE: $script:SelectedProfile  |  CHANNEL: SECURE"

    function Format-BoxLine($label, $content, $labelColor, $contentColor, $width) {
        $prefix = "║ $label : "
        $suffix = "║"
        $maxContentLen = $width - $prefix.Length - $suffix.Length
        if ($maxContentLen -lt 5) { $maxContentLen = 5 }
        if ($content.Length -gt $maxContentLen) { $content = $content.Substring(0, $maxContentLen) }
        $currentLen = $prefix.Length + $content.Length + $suffix.Length
        $padNeeded = $width - $currentLen
        if ($padNeeded -lt 0) { $padNeeded = 0 }
        $padding = ' ' * $padNeeded

        Write-Host "$prefix" -NoNewline -ForegroundColor $labelColor
        Write-Host "$content" -NoNewline -ForegroundColor $contentColor
        Write-Host "$padding$suffix" -ForegroundColor $labelColor
    }

    if ($channelText.Length -gt $innerLen) { $channelText = $channelText.Substring(0, $innerLen) }
    $chanPaddingLen = $innerLen - $channelText.Length
    if ($chanPaddingLen -lt 0) { $chanPaddingLen = 0 }
    $chanPadding = ' ' * $chanPaddingLen

    Write-Host ""
    Write-Host "╔$line╗" -ForegroundColor $color
    Write-Host "║$channelText$chanPadding║" -ForegroundColor $Theme.Muted
    Write-Host "╠$line╣" -ForegroundColor $color
    Format-BoxLine "AGENT MODEL" ([string]$model) $color "White" $termWidth
    Format-BoxLine "ACTIVE BASE" (Get-CurrentActiveModel) $Theme.Warning "Yellow" $termWidth
    Format-BoxLine "AGENT BASE" ([string]$declaredBase) $Theme.Info "Cyan" $termWidth
    Format-BoxLine "SPECIALTY" $summary "DarkGray" "Gray" $termWidth
    Write-Host "╚$line╝" -ForegroundColor $color
    Write-Host ""
}

function Ensure-ModelAvailable($targetModel) {
    $targetModel = ([string]$targetModel).Trim()
    if ([string]::IsNullOrWhiteSpace($targetModel)) {
        throw "Target model name is empty."
    }

    # CypraTeam agent names must come from modinstall.ps1 so the installed
    # SYSTEM directive is preserved. Never replace one with a Hub pull.
    $resolvedModel = Ensure-AgentDirectiveModel -ModelName $targetModel
    if (-not (Test-Path $script:TaskRoot)) { New-Item -ItemType Directory -Path $script:TaskRoot -Force | Out-Null }
    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $safeAgent = $AgentId -replace '[^0-9]',''
    $taskId = "task_${stamp}_agent${safeAgent}_${resolvedModel}"
    $path = Join-Path $script:TaskRoot $taskId
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    @{ task_id=$taskId; agent_id=$AgentId; model=$resolvedModel; prompt=$Prompt; created=(Get-Date).ToString("o") } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $path "metadata.json") -Encoding utf8
    $global:ActiveTaskWorkspace = $path
    $global:ActiveTaskPath = $path
    $global:ActiveTaskId = $taskId
    return $path
}

# ============================================================================
# CYPRATEAM MATRIX ADDON SUBSYSTEM - 27 INTEGRATED SERVICES
# ============================================================================
$script:MatrixDataRoot = Join-Path $PSScriptRoot "MatrixData"
$script:MatrixMemoryRoot = Join-Path $script:MatrixDataRoot "Memory"
$script:MatrixKnowledgeRoot = Join-Path $script:MatrixDataRoot "Knowledge"
$script:MatrixSandboxRoot = Join-Path $script:MatrixDataRoot "Sandboxes"
$script:MatrixAnalyticsRoot = Join-Path $script:MatrixDataRoot "Analytics"
$script:MatrixMissionRoot = Join-Path $script:MatrixDataRoot "Missions"
$script:MatrixLearningFile = Join-Path $script:MatrixDataRoot "learning.json"
$script:MatrixCapabilityFile = Join-Path $script:MatrixDataRoot "capabilities.json"
$script:MatrixManifestFile = Join-Path $script:MatrixDataRoot "model_manifest.json"
$script:MatrixWorkflowFile = Join-Path $script:MatrixDataRoot "workflows.json"

function Initialize-MatrixAddonStorage {
    $sessionRoot = Join-Path $script:MatrixDataRoot "Sessions"
    foreach ($d in @($script:MatrixDataRoot,$script:MatrixSandboxRoot,$script:MatrixAnalyticsRoot,$script:MatrixMissionRoot,$sessionRoot)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $script:MatrixSessionRoot = $sessionRoot
    if (-not (Test-Path $script:MatrixLearningFile)) { @{ tasks=@(); agents=@{} } | ConvertTo-Json -Depth 10 | Set-Content $script:MatrixLearningFile -Encoding utf8 }
    if (-not (Test-Path $script:MatrixWorkflowFile)) { @{} | ConvertTo-Json | Set-Content $script:MatrixWorkflowFile -Encoding utf8 }
}

function Normalize-OllamaModelName {
    param([AllowEmptyString()][string]$Name)

    $n = ([string]$Name).Trim()
    $n = $n -replace "^\uFEFF", ""
    $n = $n -replace "\x1b\[[0-9;?]*[ -/]*[@-~]", ""
    if ($n.EndsWith(":latest", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $n.Substring(0, $n.Length - 7)
    }
    return $n
}

function Get-ExistingOllamaModels {
    $result = @()
    try {
        $rows = @( & ollama list 2>$null )
        foreach($row in $rows){
            $line = ([string]$row).Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $line = $line -replace "^\uFEFF", ""
            $line = $line -replace "\x1b\[[0-9;?]*[ -/]*[@-~]", ""
            if ($line -match '^(NAME|MODEL)\s') { continue }

            $parts = @($line -split '\s+')
            if ($parts.Count -lt 1) { continue }

            $name = [string]$parts[0]
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            $result += [pscustomobject]@{
                Name        = $name
                Canonical   = (Normalize-OllamaModelName $name)
                Raw         = $line
            }
        }
    } catch {}

    return @($result | Sort-Object Canonical -Unique)
}

function Get-OllamaRunningModelNames {
    $names = @()
    try {
        $rows = @( & ollama ps 2>$null )
        foreach ($row in ($rows | Select-Object -Skip 1)) {
            $line = ([string]$row).Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $line = $line -replace "\x1b\[[0-9;?]*[ -/]*[@-~]", ""
            $parts = @($line -split '\s+')
            if ($parts.Count -ge 1 -and $parts[0] -notmatch '^(NAME|MODEL)$') {
                $names += (Normalize-OllamaModelName $parts[0])
            }
        }
    } catch {}
    return @($names | Sort-Object -Unique)
}

function Get-ModelfileManifest {
    $items=@()
    $files=@()
    $files += @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Modfiles') -Filter 'Modelfile_*' -File -ErrorAction SilentlyContinue)
    $files += @(Get-ChildItem -Path $PSScriptRoot -Filter 'Modelfile_*' -File -ErrorAction SilentlyContinue)
    $files = @($files | Sort-Object FullName -Unique)
    foreach($f in $files){
        $text=Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        $from=''; $directive=''
        if($text -match '(?m)^FROM\s+(.+)$'){ $from=$matches[1].Trim() }
        if($text -match '(?ms)^SYSTEM\s+"""(.*?)"""'){ $directive=$matches[1].Trim() }
        elseif($text -match '(?ms)^SYSTEM\s+"(.*?)"\s*(?:$|\r?\n)'){ $directive=$matches[1] }
        $name=$f.Name -replace '^Modelfile_',''
        $items += [pscustomobject]@{Name=$name; File=$f.FullName; Base=$from; DirectiveHash=([System.BitConverter]::ToString(([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($directive)))).Replace('-',''))}
    }
    return @($items)
}

function Update-ModelManifest {
    Initialize-MatrixAddonStorage

    $mods = @(Get-ModelfileManifest)
    $installed = @(Get-ExistingOllamaModels)
    $installedKeys = @{}
    foreach ($item in $installed) {
        $installedKeys[(Normalize-OllamaModelName $item.Name).ToLowerInvariant()] = $true
    }

    $runningKeys = @{}
    foreach ($name in @(Get-OllamaRunningModelNames)) {
        $runningKeys[(Normalize-OllamaModelName $name).ToLowerInvariant()] = $true
    }

    $out = @()
    foreach($m in $mods){
        $key = (Normalize-OllamaModelName $m.Name).ToLowerInvariant()
        $isInstalled = $installedKeys.ContainsKey($key)
        $isActive = $runningKeys.ContainsKey($key)

        $modelfileRel = [string]$m.File
        if (-not [string]::IsNullOrWhiteSpace($modelfileRel) -and $modelfileRel.StartsWith($PSScriptRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $modelfileRel = $modelfileRel.Substring($PSScriptRoot.Length).TrimStart('\','/')
        }
        $out += [pscustomobject]@{
            agent         = $m.Name
            modelfile     = $modelfileRel
            base_model    = $m.Base
            base_installed = $installedKeys.ContainsKey((Normalize-OllamaModelName $m.Base).ToLowerInvariant())
            installed     = $isInstalled
            active        = $isActive
            status        = if ($isActive) { "ACTIVE / LOADED" } elseif ($isInstalled) { "INSTALLED / READY" } else { "NOT REGISTERED" }
            directive_hash = $m.DirectiveHash
            timestamp     = (Get-Date).ToString('o')
        }
    }

    $out | ConvertTo-Json -Depth 10 | Set-Content $script:MatrixManifestFile -Encoding utf8
    return @($out)
}

function Get-AgentCapabilities {
    Initialize-MatrixAddonStorage
    if(Test-Path $script:MatrixCapabilityFile){
        try { return Get-Content $script:MatrixCapabilityFile -Raw | ConvertFrom-Json } catch {}
    }
    $caps=@{}
    foreach($id in ($script:AgentRegistry.Keys | Sort-Object {[int]$_})){
        $e=$script:AgentRegistry[$id]; $caps[[string]$id]=[ordered]@{name=$e.name; group=$e.group; summary=$e.summary; strengths=@($e.group,$e.tag,$e.summary)}
    }
    $caps | ConvertTo-Json -Depth 10 | Set-Content $script:MatrixCapabilityFile -Encoding utf8
    return $caps
}

function Invoke-InstalledAgentQuery {
    param([string]$ModelName,[string]$Prompt,[switch]$TrackLearning)
    $model=Get-AgentBaseModel -ModelName $ModelName
    $null=Invoke-VramAwareScheduler -ModelName $model

    # Match the context window to the VRAM-safe size from Get-DynamicModelParameters
    # and treat that as a hard CEILING, never raise it to fit the prompt - on a
    # tight-VRAM system that previously caused ollama to crash outright (exit
    # code 1, no output at all) instead of just returning a truncated answer.
    # If the prompt doesn't fit in the safe context, trim the prompt instead.
    $dynParams = Get-DynamicModelParameters -ModelName $model
    $safeCtx = [int]$dynParams.ContextLength
    $env:OLLAMA_CONTEXT_LENGTH = [string]$safeCtx

    # Rough chars-per-token estimate, leave room for the model's own reply.
    $maxPromptChars = [Math]::Max(500, ($safeCtx - 512) * 3.5)
    $payload = $Prompt
    $wasTruncated = $false
    if (([string]$payload).Length -gt $maxPromptChars) {
        $payload = ([string]$payload).Substring(0, [int]$maxPromptChars)
        $wasTruncated = $true
        Write-Host "[!] Prompt trimmed to fit the VRAM-safe context ($safeCtx tokens) for '$model'. Some input material was cut to avoid a crash." -ForegroundColor $Theme.Warning
    }

    $timer=[Diagnostics.Stopwatch]::StartNew()
    $out = Invoke-OllamaRun -Model $model -Prompt $payload -CaptureStderr
    $exit=$LASTEXITCODE; $timer.Stop()
    $joinedOut = ($out -join "`n")
    if ($exit -eq 0 -and $joinedOut -notmatch '(?i)out of memory|CUDA error') {
        Register-NewAgentActivation -ModelName $model
    }
    if($TrackLearning){
        Update-AgentLearning -ModelName $model -Prompt $Prompt -Success ($exit -eq 0 -and -not [string]::IsNullOrWhiteSpace($joinedOut)) -DurationMs $timer.ElapsedMilliseconds
    }
    if($exit -eq 0 -and $joinedOut -notmatch '(?i)out of memory|CUDA error') {
        Save-AgentConversationMemory -ModelName $model -UserPrompt $Prompt -Response $joinedOut -Source "addon-query"
        Save-ConversationToKnowledge -ModelName $model -Prompt $Prompt -Response $joinedOut -Source "addon-query"
    }
    if ([string]::IsNullOrWhiteSpace($joinedOut)) {
        Write-Host "[!] Agent '$model' returned no output (exit code $exit, context $safeCtx$(if($wasTruncated){', prompt trimmed'})). With this little free VRAM the model is likely crashing outright rather than returning an error - check 'ollama serve' logs if this repeats." -ForegroundColor $Theme.Error
    }
    return [pscustomobject]@{Model=$model; Output=$joinedOut; ExitCode=$exit; DurationMs=$timer.ElapsedMilliseconds; Truncated=$wasTruncated}
}

function Update-AgentLearning {
    param([string]$ModelName,[string]$Prompt,[bool]$Success,[long]$DurationMs)
    Initialize-MatrixAddonStorage

    # Normalize the learning store before using ContainsKey/index operations.
    # Older JSON files can deserialize into PSCustomObject objects, which do not
    # expose Hashtable.ContainsKey().  QUAD calls this function after every
    # specialist run, so a stale/legacy learning file must never break QUAD.
    $data = @{tasks=@();agents=@{}}
    try {
        if (Test-Path $script:MatrixLearningFile) {
            $raw = Get-Content $script:MatrixLearningFile -Raw | ConvertFrom-Json
            if ($null -ne $raw) {
                $data = ConvertTo-CompatHashtable $raw
            }
        }
    } catch {
        $data = @{tasks=@();agents=@{}}
    }

    if (-not ($data -is [System.Collections.IDictionary])) {
        $data = @{}
    }

    if (-not $data.ContainsKey('tasks') -or $null -eq $data['tasks']) {
        $data['tasks'] = @()
    }

    if (-not $data.ContainsKey('agents') -or $null -eq $data['agents']) {
        $data['agents'] = @{}
    } elseif (-not ($data['agents'] -is [System.Collections.IDictionary])) {
        $data['agents'] = ConvertTo-CompatHashtable $data['agents']
    }

    if (-not ($data['agents'] -is [System.Collections.IDictionary])) {
        $data['agents'] = @{}
    }

    if (-not $data['agents'].ContainsKey($ModelName) -or $null -eq $data['agents'][$ModelName]) {
        $data['agents'][$ModelName] = @{
            runs=0
            success=0
            total_ms=0
            last_used=$null
            keywords=@{}
        }
    }

    $a = $data['agents'][$ModelName]
    if (-not ($a -is [System.Collections.IDictionary])) {
        $a = ConvertTo-CompatHashtable $a
    }
    if (-not ($a -is [System.Collections.IDictionary])) {
        $a = @{
            runs=0
            success=0
            total_ms=0
            last_used=$null
            keywords=@{}
        }
        $data['agents'][$ModelName] = $a
    }

    if (-not $a.ContainsKey('runs'))      { $a['runs'] = 0 }
    if (-not $a.ContainsKey('success'))   { $a['success'] = 0 }
    if (-not $a.ContainsKey('total_ms'))  { $a['total_ms'] = 0 }
    if (-not $a.ContainsKey('last_used')) { $a['last_used'] = $null }
    if (-not $a.ContainsKey('keywords') -or $null -eq $a['keywords']) {
        $a['keywords'] = @{}
    } elseif (-not ($a['keywords'] -is [System.Collections.IDictionary])) {
        $a['keywords'] = ConvertTo-CompatHashtable $a['keywords']
    }
    if (-not ($a['keywords'] -is [System.Collections.IDictionary])) {
        $a['keywords'] = @{}
    }

    $a['runs'] = [int]$a['runs'] + 1
    if ($Success) { $a['success'] = [int]$a['success'] + 1 }
    $a['total_ms'] = [long]$a['total_ms'] + $DurationMs
    $a['last_used'] = (Get-Date).ToString('o')

    $learnText = Get-MatrixLearningPromptText -Prompt $Prompt
    foreach($w in (($learnText.ToLower() -split '\W+') | Where-Object {
        $_.Length -ge 5 -and -not $script:MatrixLearningStopwords.Contains($_)
    } | Select-Object -First 12)){
        if (-not $a['keywords'].ContainsKey($w)) { $a['keywords'][$w] = 0 }
        $a['keywords'][$w]++
    }

    $data | ConvertTo-Json -Depth 12 | Set-Content $script:MatrixLearningFile -Encoding utf8
}


# 25. Nexus Task Classifier
function Invoke-NexusTaskClassifier {
    Clear-Host
    Show-CommandActivation -Command 'classifier'
    Write-Host 'NEXUS TASK CLASSIFIER' -ForegroundColor $Theme.Info
    Write-Host '[i] Classifies the task before execution so routing can use domain, task type, risk, and capability signals.' -ForegroundColor $Theme.MutedLight
    Write-Host ''
    $task = Read-Host 'Describe the task'
    if ([string]::IsNullOrWhiteSpace($task)) { return }

    $prompt = @"
You are NEXUS-PRIME, the task classification node for a 700-agent local AI matrix.

TASK:
$task

Classify this task using exactly these fields:
DOMAIN:
SUBDOMAINS:
TASK TYPE:
RISK:
PRIORITY:
REQUIRED CAPABILITIES:
RECOMMENDED AGENT GROUPS:
EXPECTED AGENT COUNT:
ROUTING NOTES:

Use concise, practical wording. Do not invent facts about the user or project.
"@

    $r = Invoke-InstalledAgentQuery -ModelName 'nexus-prime' -Prompt $prompt -TrackLearning
    if ($r.ExitCode -eq 0) {
        $r.Output | Out-Host
        Initialize-MatrixAddonStorage
        $record = [ordered]@{
            timestamp = (Get-Date).ToString('o')
            task = $task
            classification = $r.Output
        }
        $file = Join-Path $script:MatrixMissionRoot ('classification_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.json')
        $record | ConvertTo-Json -Depth 10 | Set-Content $file -Encoding utf8
        Write-Host "[+] Classification saved: $file" -ForegroundColor $Theme.Success
    } else {
        Write-Host '[!] Nexus classifier failed.' -ForegroundColor $Theme.Error
    }
    Read-Host 'Enter'
}

# 26. Task Summarizer
function Invoke-TaskSummarizer {
    Initialize-MatrixAddonStorage
    Clear-Host
    Show-CommandActivation -Command 'summarize'
    Write-Host 'TASK SUMMARIZER' -ForegroundColor $Theme.Info
    Write-Host '[i] Creates a reusable summary of a completed or active task and saves it inside the task workspace.' -ForegroundColor $Theme.MutedLight
    Write-Host ''

    $tasksDir = $script:TaskRoot
    if (-not (Test-Path $tasksDir)) {
        $tasksDir = Join-Path $PSScriptRoot 'Tasks'
    }
    if (-not (Test-Path $tasksDir)) {
        Write-Host '[!] Tasks directory not found.' -ForegroundColor $Theme.Error
        Read-Host 'Enter'
        return
    }

    $folders = @(Get-ChildItem -Path $tasksDir -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { (Test-Path (Join-Path $_.FullName 'task.json')) -or (Test-Path (Join-Path $_.FullName 'metadata.json')) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 50)

    if ($folders.Count -eq 0) {
        Write-Host '[i] No task workspaces found.' -ForegroundColor $Theme.Muted
        Read-Host 'Enter'
        return
    }

    for ($i=0; $i -lt $folders.Count; $i++) {
        Write-Host ("[{0}] {1}" -f ($i+1), $folders[$i].FullName) -ForegroundColor $Theme.MutedLight
    }
    $choice = Read-Host 'Select task to summarize'
    if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $folders.Count) { return }
    $taskPath = $folders[[int]$choice-1].FullName

    $files = @(Get-ChildItem -Path $taskPath -File -ErrorAction SilentlyContinue)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files | Where-Object { $_.Name -in @('task.json','metadata.json','prompt.txt','result.txt','transcript.txt','chat_history.txt','status.json') }) {
        $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($content) {
            if ($content.Length -gt 16000) { $content = $content.Substring(0,16000) }
            [void]$parts.Add("### $($f.Name)`n$content")
        }
    }
    if ($parts.Count -eq 0) {
        Write-Host '[!] No task content was found to summarize.' -ForegroundColor $Theme.Warning
        Read-Host 'Enter'
        return
    }

    $prompt = @"
You are NEXUS-PRIME producing a durable task summary.
Create a concise but useful summary from the workspace material below.
Include exactly these sections:
TASK
OBJECTIVE
WHAT HAPPENED
KEY DECISIONS
RESULT
UNRESOLVED ISSUES
NEXT STEPS
AGENTS / MODELS USED

TASK WORKSPACE:
$taskPath

MATERIAL:
$($parts -join "`n`n")
"@

    $r = Invoke-InstalledAgentQuery -ModelName 'nexus-prime' -Prompt $prompt -TrackLearning
    if ($r.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.Output)) {
        $summaryPath = Join-Path $taskPath 'task_summary.md'
        @("# Task Summary","","Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')","","$($r.Output)") | Set-Content $summaryPath -Encoding utf8
        Write-Host "[+] Task summary saved: $summaryPath" -ForegroundColor $Theme.Success
        Write-Host ''
        $r.Output | Out-Host
    } else {
        Write-Host "[!] Task summary generation failed: nexus-prime returned no usable output (exit code $($r.ExitCode))." -ForegroundColor $Theme.Error
    }
    Read-Host 'Enter'
}

# 27. Task Resume Intelligence
function Invoke-TaskResumeIntelligence {
    Initialize-MatrixAddonStorage
    Clear-Host
    Show-CommandActivation -Command 'resume'
    Write-Host 'TASK RESUME INTELLIGENCE' -ForegroundColor $Theme.Info
    Write-Host '[i] Restores task context from prompt, history, status, summary, memory, and knowledge records.' -ForegroundColor $Theme.MutedLight
    Write-Host ''

    $tasksDir = $script:TaskRoot
    if (-not (Test-Path $tasksDir)) { $tasksDir = Join-Path $PSScriptRoot 'Tasks' }
    $folders = @(Get-ChildItem -Path $tasksDir -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { (Test-Path (Join-Path $_.FullName 'task.json')) -or (Test-Path (Join-Path $_.FullName 'metadata.json')) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 50)
    if ($folders.Count -eq 0) { Write-Host '[i] No task workspaces found.' -ForegroundColor $Theme.Muted; Read-Host 'Enter'; return }

    for ($i=0; $i -lt $folders.Count; $i++) { Write-Host ("[{0}] {1}" -f ($i+1), $folders[$i].FullName) -ForegroundColor $Theme.MutedLight }
    $choice = Read-Host 'Select task to resume'
    if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $folders.Count) { return }
    $taskPath = $folders[[int]$choice-1].FullName

    $global:ActiveTaskWorkspace = $taskPath
    $global:ActiveTaskPath = $taskPath
    $global:ActiveTaskId = Split-Path $taskPath -Leaf
    Set-Location -Path $taskPath

    $contextFiles = @('task.json','metadata.json','prompt.txt','task_summary.md','result.txt','transcript.txt','chat_history.txt','status.json')
    $material = New-Object System.Collections.Generic.List[string]
    foreach ($name in $contextFiles) {
        $f = Join-Path $taskPath $name
        if (Test-Path $f) {
            $content = Get-Content $f -Raw -ErrorAction SilentlyContinue
            if ($content) {
                if ($content.Length -gt 12000) { $content = $content.Substring([Math]::Max(0,$content.Length-12000)) }
                [void]$material.Add("### $name`n$content")
            }
        }
    }

    $resumePrompt = @"
You are NEXUS-PRIME preparing a task-resume briefing.
Review the existing workspace context below and produce:
CURRENT STATUS:
LAST KNOWN RESULT:
UNRESOLVED ISSUES:
IMPORTANT DECISIONS:
RELEVANT AGENT CONTEXT:
RECOMMENDED NEXT ACTION:
RECOMMENDED AGENT:

Do not claim work was completed when the workspace does not show evidence of completion.

WORKSPACE:
$taskPath

CONTEXT:
$($material -join "`n`n")
"@

    $r = Invoke-InstalledAgentQuery -ModelName 'nexus-prime' -Prompt $resumePrompt -TrackLearning
    if ($r.ExitCode -eq 0) {
        Write-Host ''
        $r.Output | Out-Host
        $resumeFile = Join-Path $taskPath 'resume_briefing.md'
        @("# Resume Briefing","","Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')","","$($r.Output)") | Set-Content $resumeFile -Encoding utf8
        Write-Host "[+] Resume briefing saved: $resumeFile" -ForegroundColor $Theme.Success
        Write-Host ''
        $launch = Read-Host 'Launch an agent for this task now? (y/n)'
        if ($launch -match '^y') {
            $recommended = [regex]::Match([string]$r.Output, '(?im)^RECOMMENDED AGENT:\s*(.+)$').Groups[1].Value.Trim()
            $model = $null
            if ($recommended) {
                $candidate = $script:AgentRegistry.Values | Where-Object { $_.name -ieq $recommended -or $_.model -ieq $recommended } | Select-Object -First 1
                if ($candidate) { $model = $candidate.model }
            }
            if (-not $model) { $model = Read-Host 'Enter agent model name (blank = nexus-prime)' }
            if ([string]::IsNullOrWhiteSpace($model)) { $model = 'nexus-prime' }
            Write-Host "[i] Resume context loaded. Run the selected agent with: $model" -ForegroundColor $Theme.Info
        }
    } else {
        Write-Host '[!] Resume intelligence failed.' -ForegroundColor $Theme.Error
    }
    Read-Host 'Enter'
}

# 1. Nexus Prime Mission Control
function Invoke-NexusMissionControl {
    Clear-Host
    Show-CommandActivation -Command 'mission'; Write-Host 'NEXUS PRIME MISSION CONTROL' -ForegroundColor $Theme.Info; Write-Host ''
    $task=Read-Host 'Describe the mission'; if([string]::IsNullOrWhiteSpace($task)){return}
    $ids=@(Invoke-NexusAgentSelection -TaskPrompt $task -Count 1 -ExcludeIds (Get-NexusDefaultExcludedIds));
    if($ids.Count -lt 1){Write-Host '[!] Could not select a specialist for this mission.' -ForegroundColor $Theme.Error; Read-Host 'Enter'; return}
    $id=$ids[0]; $entry=$script:AgentRegistry[[string]$id]
    Write-Host "`nMISSION PLAN" -ForegroundColor $Theme.Warning
    Write-Host ("{0,3}  {1,-22} {2}" -f $id,$entry.name,$entry.group) -ForegroundColor $entry.color
    Write-Host 'Execution: single specialist, routed by NEXUS-PRIME' -ForegroundColor $Theme.InfoDim
    $go=Read-Host 'Execute mission? (y/n)'; if($go -notmatch '^y'){return}
    $missionDir=Join-Path $script:MatrixMissionRoot ('mission_'+(Get-Date -Format 'yyyyMMdd_HHmmss')); New-Item -ItemType Directory -Path $missionDir -Force|Out-Null

    # The specialist gets the raw mission task grounded in an explicit
    # "answer for real, don't invent scenery" instruction. Without this,
    # small local models tend to free-associate off the agent's persona
    # name/group (e.g. an agent literally named "vortex" will drift into
    # unrelated sci-fi/technical flavor text) instead of answering the task.
    $specialistPrompt=@"
You are the $($entry.name) specialist ($($entry.group)) inside a real-world
task-execution system. Your answer will be read and relied on by a real
person, so accuracy matters more than creativity.

MISSION:
$task

Answer only what is actually being asked. Rules:
- Stay strictly on-topic and literal. Do not invent a fictional framing,
  story, code, or scenario that was not asked for.
- Give concrete, practical, verifiable information from your specialty.
- If the task involves physical safety (vehicles, electrical, medical,
  structural, chemical), lead with the relevant safety caveat before any
  instructions.
- If something is outside your specialty or you are not confident, say so
  plainly instead of guessing.
- Prefer a short, direct, numbered/step answer over a long narrative one.
"@
    $r=Invoke-InstalledAgentQuery -ModelName $map[[string]$id] -Prompt $specialistPrompt -TrackLearning
    $r.Output|Set-Content (Join-Path $missionDir ("agent_$id.txt")) -Encoding utf8

    if ([string]::IsNullOrWhiteSpace($r.Output)) {
        Write-Host ''
        Write-Host "[!] $($entry.name) returned no usable output (exit code $($r.ExitCode))." -ForegroundColor $Theme.Error
        Write-Host "[i] Try again, or re-run with a shorter/clearer mission description if this keeps happening." -ForegroundColor $Theme.InfoDim
        Read-Host 'Enter'
        return
    }

    Write-Host ''
    $r.Output|Out-Host
    Write-Host "`n[i] Specialist transcript saved to: $missionDir" -ForegroundColor $Theme.InfoDim
    Read-Host 'Enter'
}

# 2. Agent Capability Graph
function Show-AgentCapabilityGraph {
    Clear-Host; $caps=Get-AgentCapabilities; Write-Host 'AGENT CAPABILITY GRAPH' -ForegroundColor $Theme.Info; Write-Host ''
    $query=Read-Host 'Search capability (blank = show selected agents)';
    $rows=@(); foreach($id in ($script:AgentRegistry.Keys|Sort-Object {[int]$_})){ $e=$script:AgentRegistry[$id]; $hay="$($e.name) $($e.group) $($e.tag) $($e.summary)"; if([string]::IsNullOrWhiteSpace($query) -or $hay -match [regex]::Escape($query)){$rows += [pscustomobject]@{ID=$id;Agent=$e.name;Group=$e.group;Tag=$e.tag}} }
    $rows|Select-Object -First 40|Format-Table -AutoSize|Out-Host; Read-Host 'Enter'
}

# ==============================================================
# MEMORY / KNOWLEDGE SANITIZER
# ==============================================================
# Cleans text BEFORE it is written to Memory, Knowledge, or learning
# keywords. The live terminal, ollama run session, and Logs/*.log files
# are left exactly as they are. Same chat / routing / workflows —
# less junk in the vaults.

$script:MatrixLearningStopwords = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
@(
    'about','after','again','agent','agents','along','already','also','always',
    'among','another','answer','around','because','before','being','below',
    'between','both','could','debate','domain','exactly','following','identity',
    'original','other','please','provide','round','should','specialist',
    'specialists','their','there','these','they','this','those','through',
    'under','using','where','which','while','would','your','youre'
) | ForEach-Object { [void]$script:MatrixLearningStopwords.Add($_) }

function Get-MatrixCleanText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $t = [string]$Text

    # ANSI / CSI / OSC / charset noise from ollama TTY and Start-Transcript
    $t = $t -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', ''
    $t = $t -replace '\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', ''
    $t = $t -replace '\x1b[()][AB012]', ''
    $t = $t -replace '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', ''

    # PowerShell Start-Transcript / Stop-Transcript banners
    $t = [regex]::Replace($t, '(?s)\*{6,}\s*Windows PowerShell transcript start.*?(?:SerializationVersion:[^\r\n]+\s*)?\*{6,}', '')
    $t = [regex]::Replace($t, '(?s)\*{6,}\s*Windows PowerShell transcript end.*?\*{6,}', '')
    $t = [regex]::Replace($t, '(?m)^\*{6,}\s*$', '')

    # Gemma / ollama visible thinking block
    $t = [regex]::Replace($t, '(?s)Thinking\.\.\.\s*.*?\.{3}done thinking\.\s*', '')

    # Interactive ollama exit / spinner leftovers
    $t = [regex]::Replace($t, '(?m)^\s*>>>\s*/(?:bye|exit|quit)\s*$', '')
    $t = $t -replace '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]', ''

    $t = $t -replace "`r`n", "`n"
    $t = $t -replace "`r", "`n"
    $t = [regex]::Replace($t, '[ \t]+\n', "`n")
    $t = [regex]::Replace($t, '\n{3,}', "`n`n")
    return $t.Trim()
}

function Get-MatrixInteractiveExchange {
    param([string]$RawText)

    $clean = Get-MatrixCleanText $RawText
    $userLines = New-Object System.Collections.Generic.List[string]
    $agentLines = New-Object System.Collections.Generic.List[string]

    foreach ($line in ($clean -split "`n")) {
        if ($line -match '^\s*>>>\s*(.*)$') {
            $typed = ([string]$Matches[1]).Trim()
            if (-not [string]::IsNullOrWhiteSpace($typed) -and $typed -notmatch '^/') {
                [void]$userLines.Add($typed)
            }
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            [void]$agentLines.Add($line.TrimEnd())
        }
    }

    $prompt = ($userLines -join "`n").Trim()
    $response = ($agentLines -join "`n").Trim()
    return [pscustomobject]@{
        Prompt   = $prompt
        Response = $response
    }
}

function Get-MatrixPersistedExchange {
    param(
        [string]$Prompt,
        [string]$Response,
        [string]$Source = ""
    )

    $cleanPrompt = Get-MatrixCleanText $Prompt
    $cleanResponse = Get-MatrixCleanText $Response
    $looksInteractive = ($Source -like 'interactive-session*') -or
                        ($cleanResponse -match 'Windows PowerShell transcript') -or
                        ($cleanPrompt -match '(?i)^interactive session')

    if ($looksInteractive) {
        $ex = Get-MatrixInteractiveExchange -RawText $Response
        if (-not [string]::IsNullOrWhiteSpace($ex.Prompt)) { $cleanPrompt = $ex.Prompt }
        if (-not [string]::IsNullOrWhiteSpace($ex.Response)) { $cleanResponse = $ex.Response }
        if ($cleanPrompt -match '(?i)^interactive session') { $cleanPrompt = "" }
    }

    return [pscustomobject]@{
        Prompt   = $cleanPrompt
        Response = $cleanResponse
    }
}

function Get-MatrixLearningPromptText {
    param([string]$Prompt)

    $t = Get-MatrixCleanText $Prompt
    if ([string]::IsNullOrWhiteSpace($t)) { return "" }

    $orig = [regex]::Match($t, '(?is)ORIGINAL TASK:\s*(.+?)(?:\r?\n\s*\r?\n|\r?\nThis is Round)')
    if ($orig.Success) { return $orig.Groups[1].Value.Trim() }

    $task = [regex]::Match($t, '(?im)^TASK:\s*(.+)$')
    if ($task.Success) { return $task.Groups[1].Value.Trim() }

    return $t
}

# 3. Persistent Agent Memory Vault (retired — no-op)
function Save-AgentConversationMemory {
    param(
        [Parameter(Mandatory=$true)][string]$ModelName,
        [string]$UserPrompt,
        [string]$Response,
        [string]$Source = "conversation"
    )
    return
    if (-not [bool]$matrixConfig.MemoryEnabled) { return }
    try {
        $exchange = Get-MatrixPersistedExchange -Prompt $UserPrompt -Response $Response -Source $Source
        if ([string]::IsNullOrWhiteSpace($exchange.Prompt) -and [string]::IsNullOrWhiteSpace($exchange.Response)) { return }

        Initialize-MatrixAddonStorage
        $safe = (($ModelName -replace '[^A-Za-z0-9_.-]','_').Trim('_'))
        if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'unknown-agent' }
        $agentFile = Join-Path $script:MatrixMemoryRoot "$safe.json"
        $globalFile = Join-Path $script:MatrixMemoryRoot "global.json"
        $entry = [pscustomobject]@{
            timestamp = (Get-Date).ToString('o')
            agent = $ModelName
            source = $Source
            prompt = $exchange.Prompt.Substring(0,[Math]::Min(12000,$exchange.Prompt.Length))
            response = $exchange.Response.Substring(0,[Math]::Min(20000,$exchange.Response.Length))
        }
        foreach ($file in @($agentFile,$globalFile)) {
            $items = @()
            if (Test-Path $file) {
                try {
                    $loaded = Get-Content $file -Raw -ErrorAction Stop | ConvertFrom-Json
                    if ($loaded) { $items = @($loaded) }
                } catch { $items = @() }
            }
            $items += $entry
            if ($items.Count -gt 200) { $items = @($items | Select-Object -Last 200) }
            $items | ConvertTo-Json -Depth 12 | Set-Content -Path $file -Encoding utf8
        }
    } catch {
        Write-Host "[!] Could not persist conversation memory: $($_.Exception.Message)" -ForegroundColor $Theme.Warning
    }
}

function Invoke-AgentMemoryVault {
    Initialize-MatrixAddonStorage
    Clear-Host
    Show-CommandActivation -Command 'memory'
    Write-Host 'AGENT MEMORY VAULT' -ForegroundColor $Theme.Info
    Write-Host '[i] Memory is persistent conversation history separate from Modelfiles. Successful conversations are saved automatically while Memory is enabled.' -ForegroundColor $Theme.MutedLight
    Write-Host ''
    Write-Host '[1] View global memory  [2] View agent memory  [3] Add manual memory  [4] Clear agent memory  [5] Clear ALL Matrix memory  [6] Return' -ForegroundColor $Theme.Warning
    $c=Read-Host 'Select'
    switch($c){
        '1' {
            $f=Join-Path $script:MatrixMemoryRoot 'global.json'
            if(Test-Path $f){Get-Content $f -Raw|Out-Host}else{Write-Host 'No global memory saved yet.' -ForegroundColor $Theme.Muted}
            Read-Host 'Enter'
        }
        '2' {
            $scope=Read-Host 'Agent model name'
            $safe=(($scope -replace '[^A-Za-z0-9_.-]','_').Trim('_'))
            $f=Join-Path $script:MatrixMemoryRoot "$safe.json"
            if(Test-Path $f){Get-Content $f -Raw|Out-Host}else{Write-Host "No memory saved for '$scope'." -ForegroundColor $Theme.Muted}
            Read-Host 'Enter'
        }
        '3' {
            $txt=Read-Host 'Memory text'
            if([string]::IsNullOrWhiteSpace($txt)){return}
            $scope=Read-Host 'Scope (global or agent name)'; if([string]::IsNullOrWhiteSpace($scope)){$scope='global'}
            $safe=(($scope -replace '[^A-Za-z0-9_.-]','_').Trim('_')); $f=Join-Path $script:MatrixMemoryRoot "$safe.json"; $arr=@()
            if(Test-Path $f){try{$loaded=Get-Content $f -Raw|ConvertFrom-Json;if($loaded){$arr=@($loaded)}}catch{}}
            $arr += [pscustomobject]@{timestamp=(Get-Date).ToString('o');agent=$scope;source='manual';prompt='';response=$txt}
            if($arr.Count -gt 200){$arr=@($arr|Select-Object -Last 200)}
            $arr|ConvertTo-Json -Depth 12|Set-Content $f -Encoding utf8
            Write-Host '[+] Memory saved.' -ForegroundColor $Theme.Success; Read-Host 'Enter'
        }
        '4' {
            $scope=Read-Host 'Agent model name to clear'; $safe=(($scope -replace '[^A-Za-z0-9_.-]','_').Trim('_')); $f=Join-Path $script:MatrixMemoryRoot "$safe.json"
            if(Test-Path $f){Remove-Item $f -Force;Write-Host '[+] Agent memory cleared.' -ForegroundColor $Theme.Success}else{Write-Host '[i] No memory file found.' -ForegroundColor $Theme.Muted}; Read-Host 'Enter'
        }
        '5' {
            $confirm=Read-Host 'Type CLEAR MEMORY to confirm'; if($confirm -eq 'CLEAR MEMORY'){Get-ChildItem $script:MatrixMemoryRoot -File -ErrorAction SilentlyContinue|Remove-Item -Force;Write-Host '[+] ALL Matrix memory cleared.' -ForegroundColor $Theme.Success}else{Write-Host '[i] Cancelled.' -ForegroundColor $Theme.Muted}; Read-Host 'Enter'
        }
    }
}

function Save-ConversationToKnowledge {
    param(
        [Parameter(Mandatory=$true)][string]$ModelName,
        [string]$Prompt,
        [string]$Response,
        [string]$Source = "conversation"
    )
    return
    if (-not [bool]$matrixConfig.KnowledgeEnabled) { return }
    try {
        $exchange = Get-MatrixPersistedExchange -Prompt $Prompt -Response $Response -Source $Source
        if ([string]::IsNullOrWhiteSpace($exchange.Prompt) -and [string]::IsNullOrWhiteSpace($exchange.Response)) { return }

        Initialize-MatrixAddonStorage
        $conversationDir = Join-Path $script:MatrixKnowledgeRoot 'Conversations'
        if (-not (Test-Path $conversationDir)) { New-Item -ItemType Directory -Path $conversationDir -Force | Out-Null }
        $safe=(($ModelName -replace '[^A-Za-z0-9_.-]','_').Trim('_')); if([string]::IsNullOrWhiteSpace($safe)){$safe='unknown-agent'}
        $stamp=Get-Date -Format 'yyyyMMdd_HHmmss_fff'; $file=Join-Path $conversationDir "${stamp}_${safe}.md"
        $userBlock = $exchange.Prompt
        $agentBlock = $exchange.Response
        $content=@"
# CypraTeam Conversation Record

- Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
- Agent: $ModelName
- Source: $Source

## User
$userBlock

## Agent
$agentBlock
"@
        Set-Content -Path $file -Value $content -Encoding utf8
    } catch {
        Write-Host "[!] Could not persist conversation knowledge record: $($_.Exception.Message)" -ForegroundColor $Theme.Warning
    }
}

# Persists a completed agent turn to both memory stores in one call.
# Used by Invoke-AgentPipeline-style call sites so the pairing of
# Save-AgentConversationMemory + Save-ConversationToKnowledge (previously
# copy-pasted at every call site, once per run/retry) can't drift apart.
function Save-AgentRunOutcome {
    param(
        [Parameter(Mandatory=$true)][string]$ModelName,
        [Parameter(Mandatory=$true)][string]$UserPrompt,
        [Parameter(Mandatory=$true)][string]$Response,
        [Parameter(Mandatory=$true)][string]$Source,
        # Optional: use different wording for the knowledge-store record
        # (e.g. "Interactive session transcript" vs "Interactive session").
        # Defaults to $UserPrompt when not given.
        [string]$KnowledgePrompt
    )
    if ([string]::IsNullOrEmpty($KnowledgePrompt)) { $KnowledgePrompt = $UserPrompt }
    Save-AgentConversationMemory -ModelName $ModelName -UserPrompt $UserPrompt -Response $Response -Source $Source
    Save-ConversationToKnowledge -ModelName $ModelName -Prompt $KnowledgePrompt -Response $Response -Source $Source
}

function Get-MatrixChatSessionRoot {
    if ([string]::IsNullOrWhiteSpace([string]$script:MatrixSessionRoot)) {
        $script:MatrixSessionRoot = Join-Path $script:MatrixDataRoot "Sessions"
    }
    if (-not (Test-Path $script:MatrixSessionRoot)) {
        New-Item -ItemType Directory -Path $script:MatrixSessionRoot -Force | Out-Null
    }
    return $script:MatrixSessionRoot
}

function Build-MatrixChatPayload {
    param(
        [System.Collections.IList]$History,
        [string]$UserText,
        [int]$MaxChars = 1800
    )
    if ($MaxChars -lt 400) { $MaxChars = 400 }
    $blocks = New-Object System.Collections.Generic.List[string]
    if ($History) {
        foreach ($turn in $History) {
            $role = [string]$turn.role
            $text = [string]$turn.text
            if ([string]::IsNullOrWhiteSpace($text)) { $text = [string]$turn.content }
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            if ($role -eq 'assistant') {
                [void]$blocks.Add("Assistant:`n$text")
            } else {
                [void]$blocks.Add("User:`n$text")
            }
        }
    }
    [void]$blocks.Add("User:`n$UserText")
    $payload = ($blocks -join "`n`n")
    while ($payload.Length -gt $MaxChars -and $blocks.Count -gt 1) {
        $blocks.RemoveAt(0)
        $payload = ($blocks -join "`n`n")
    }
    if ($payload.Length -gt $MaxChars) {
        $payload = $payload.Substring($payload.Length - $MaxChars)
    }
    return $payload
}

function Get-MatrixLastChatPath {
    param([string]$ModelName)
    $safe = (($ModelName -replace '[^A-Za-z0-9_.-]', '_').Trim('_'))
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'agent' }
    return (Join-Path (Get-MatrixChatSessionRoot) ("last_{0}.json" -f $safe))
}

function Save-MatrixLastChat {
    param([string]$ModelName, [System.Collections.IList]$Messages)
    try {
        $path = Get-MatrixLastChatPath -ModelName $ModelName
        $payload = [ordered]@{
            agent     = $ModelName
            updated   = (Get-Date).ToString('o')
            messages  = @($Messages)
        }
        $payload | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding utf8
    } catch {}
}

function Get-MatrixPriorConversation {
    param(
        [string]$ModelName,
        [int]$MaxTurns = 6
    )
    $empty = [pscustomobject]@{ HasPrior = $false; Messages = @(); ResumePrompt = '' }
    try {
    $msgs = New-Object System.Collections.Generic.List[object]

    foreach ($m in @(Read-MatrixLastChat -ModelName $ModelName)) {
        [void]$msgs.Add($m)
    }

    $safe = (($ModelName -replace '[^A-Za-z0-9_.-]', '_').Trim('_'))
    $memFile = Join-Path $script:MatrixMemoryRoot "$safe.json"
    if (Test-Path -LiteralPath $memFile) {
        try {
            $arr = @(Get-Content -LiteralPath $memFile -Raw | ConvertFrom-Json)
            foreach ($e in ($arr | Select-Object -Last $MaxTurns)) {
                $p = [string]$e.prompt
                $r = [string]$e.response
                if ($p -and $p -notmatch '(?i)^Interactive session') {
                    [void]$msgs.Add([pscustomobject]@{ role = 'user'; content = $p })
                }
                if ($r -and $r -notmatch '(?i)^\(native ollama') {
                    [void]$msgs.Add([pscustomobject]@{ role = 'assistant'; content = $r })
                }
            }
        } catch {}
    }

    $kdir = Join-Path $script:MatrixKnowledgeRoot 'Conversations'
    if ((Test-Path $kdir) -and $msgs.Count -eq 0) {
        $hit = @(Get-ChildItem -LiteralPath $kdir -Filter "*${safe}*.md" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        if ($hit) {
            try {
                $raw = Get-Content -LiteralPath $hit[0].FullName -Raw
                $um = [regex]::Match($raw, '(?s)## User\s*(.+?)(?=## Agent|\z)')
                $am = [regex]::Match($raw, '(?s)## Agent\s*(.+?)\s*\z')
                if ($um.Success) { [void]$msgs.Add([pscustomobject]@{ role = 'user'; content = $um.Groups[1].Value.Trim() }) }
                if ($am.Success) { [void]$msgs.Add([pscustomobject]@{ role = 'assistant'; content = $am.Groups[1].Value.Trim() }) }
            } catch {}
        }
    }

    $fileHint = $false
    if (Test-Path -LiteralPath $memFile) { $fileHint = $true }
    $lastPath = Get-MatrixLastChatPath -ModelName $ModelName
    if (Test-Path -LiteralPath $lastPath) { $fileHint = $true }
    if ((Test-Path $kdir) -and @(Get-ChildItem -LiteralPath $kdir -Filter "*${safe}*.md" -File -ErrorAction SilentlyContinue).Count -gt 0) { $fileHint = $true }
    $users = @($msgs | Where-Object { [string]$_.role -eq 'user' -and -not [string]::IsNullOrWhiteSpace($_.content) })
    $has = ($users.Count -gt 0) -or $fileHint
    $blob = New-Object System.Text.StringBuilder
    [void]$blob.AppendLine('The operator is returning to a prior conversation. Records from Memory / Knowledge:')
    [void]$blob.AppendLine('')
    $take = @($msgs | Select-Object -Last ($MaxTurns * 2))
    foreach ($m in $take) {
        $role = if ([string]$m.role -eq 'assistant') { 'Agent' } else { 'User' }
        $text = [string]$m.content
        if ($text.Length -gt 800) { $text = $text.Substring(0, 800) + '...' }
        [void]$blob.AppendLine("${role}: $text")
        [void]$blob.AppendLine('')
    }
    [void]$blob.AppendLine('Acknowledge briefly that you remember this thread. Stay in character. Then wait for their next message.')

    return [pscustomobject]@{
        HasPrior = $has
        Messages = @($msgs)
        ResumePrompt = $blob.ToString()
    }
    } catch {
        return $empty
    }
}

function Read-MatrixLastChat {
    param([string]$ModelName)
    $path = Get-MatrixLastChatPath -ModelName $ModelName
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        $msgs = @()
        foreach ($m in @($raw.messages)) {
            $role = [string]$m.role
            $content = [string]$m.content
            if ([string]::IsNullOrWhiteSpace($content)) { $content = [string]$m.text }
            if ([string]::IsNullOrWhiteSpace($role) -or [string]::IsNullOrWhiteSpace($content)) { continue }
            $msgs += [pscustomobject]@{ role = $role; content = $content }
        }
        return @($msgs)
    } catch {
        return @()
    }
}

function Restore-MatrixConsoleInput {
    try { [Console]::TreatControlCAsInput = $false } catch {}
    try { [Console]::CursorVisible = $true } catch {}
}

function Test-MatrixJunkMemoryLine {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    if ($Text -match '(?i)^Chat session ') { return $true }
    if ($Text -match '(?i)^Recorded in Memory') { return $true }
    if ($Text -match '(?i)^Native Ollama') { return $true }
    if ($Text -match '(?i)^Interactive session') { return $true }
    if ($Text -match '(?i)^\(native ollama') { return $true }
    return $false
}

function Read-MatrixLine {
    param([string]$Label = "You")
    Restore-MatrixConsoleInput
    $line = Read-Host $Label
    if ($null -eq $line) { return "" }
    return ([string]$line).Trim()
}

function Invoke-MatrixMemoryChat {
    param(
        [string]$ModelName,
        [System.Collections.IList]$SeedMessages
    )
    $history = New-Object System.Collections.Generic.List[object]
    foreach ($m in @($SeedMessages)) {
        if (-not $m) { continue }
        $t = [string]$m.content
        if ([string]::IsNullOrWhiteSpace($t)) { $t = [string]$m.text }
        if (Test-MatrixJunkMemoryLine $t) { continue }
        [void]$history.Add($m)
    }
    Restore-MatrixConsoleInput
    Write-Host "[+] MEMORY SESSION. Type at You:   /bye leaves." -ForegroundColor $Theme.Success
    $emptyHits = 0
    while ($true) {
        $cmd = Read-MatrixLine -Label "You"
        if ([string]::IsNullOrWhiteSpace($cmd)) {
            $emptyHits++
            if ($emptyHits -ge 2) {
                Write-Host "[i] Empty input. Type a message or /bye." -ForegroundColor $Theme.Muted
                $emptyHits = 0
            }
            continue
        }
        $emptyHits = 0
        if ($cmd -match '^(?i)/(bye|exit|quit)$' -or $cmd -eq 'q') { break }
        if ($cmd -match '^(?i)/help$') {
            Write-Host "  Type a message to talk. /bye leaves. Memory is recording this thread." -ForegroundColor $Theme.MutedLight
            continue
        }
        [void]$history.Add([pscustomobject]@{ role = 'user'; content = $cmd })
        $priorTurns = @(
            $history | Where-Object {
                $t = [string]$_.content
                if ([string]::IsNullOrWhiteSpace($t)) { $t = [string]$_.text }
                -not (Test-MatrixJunkMemoryLine $t) -and -not ([string]$_.role -eq 'user' -and $t -eq $cmd)
            } | Select-Object -Last 6 | ForEach-Object {
                $t = [string]$_.content
                if ([string]::IsNullOrWhiteSpace($t)) { $t = [string]$_.text }
                [pscustomobject]@{ role = $_.role; text = $t }
            }
        )
        $payload = Build-MatrixChatPayload -History $priorTurns -UserText $cmd -MaxChars 1200
        Write-Host ""
        Write-Host ("[*] {0} is answering — wait. Do not press Enter again." -f $ModelName) -ForegroundColor $Theme.Warning
        Invoke-OllamaRun -Model $ModelName -Prompt $payload
        Write-Host ""
        try {
            Save-MatrixLastChat -ModelName $ModelName -Messages $history
            Save-AgentConversationMemory -ModelName $ModelName -UserPrompt $cmd -Response "Recorded in Memory." -Source "memory-chat"
            if (Get-Command Save-ConversationToKnowledge -ErrorAction SilentlyContinue) {
                Save-ConversationToKnowledge -ModelName $ModelName -Prompt $cmd -Response "Recorded in Memory." -Source "memory-chat"
            }
        } catch {}
    }
}

function New-MatrixMemorySessionModel {
    param(
        [string]$BaseAgent,
        [System.Collections.IList]$Messages
    )
    $session = "$BaseAgent-mem"
    $tmp = Join-Path $env:TEMP ("matrix_mem_{0}_{1}.Modelfile" -f (($BaseAgent -replace '[^A-Za-z0-9_.-]','_')), [guid]::NewGuid().ToString('N').Substring(0,8))
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("FROM $BaseAgent")
    [void]$sb.AppendLine("")
    $n = 0
    foreach ($m in @($Messages | Select-Object -Last 12)) {
        $role = [string]$m.role
        if ($role -eq 'assistant') { $role = 'assistant' } else { $role = 'user' }
        $text = [string]$m.content
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text.Length -gt 1500) { $text = $text.Substring(0, 1500) }
        $text = $text -replace '"""', "''"
        [void]$sb.AppendLine("MESSAGE $role `"`"`"")
        [void]$sb.AppendLine($text)
        [void]$sb.AppendLine("`"`"`"")
        [void]$sb.AppendLine("")
        $n++
    }
    if ($n -eq 0) { return $BaseAgent }
    $sb.ToString() | Set-Content -Path $tmp -Encoding utf8
    try {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $null = & ollama create $session -f $tmp 2>&1
        $ErrorActionPreference = $prev
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[+] Memory loaded into this session (directives unchanged)." -ForegroundColor $Theme.Success
            return $session
        }
    } catch {}
    Write-Host "[i] Could not attach Memory to the model. Starting without a seeded thread." -ForegroundColor $Theme.Muted
    return $BaseAgent
}

function Remove-MatrixMemorySessionModel {
    param([string]$SessionModel, [string]$BaseAgent)
    if ([string]::IsNullOrWhiteSpace($SessionModel) -or $SessionModel -eq $BaseAgent) { return }
    if ($SessionModel -notlike '*-mem') { return }
    try {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $null = & ollama rm $SessionModel 2>&1
        $ErrorActionPreference = $prev
    } catch {}
}

function Get-MatrixOllamaKeepAlive {
    $keep = '5m'
    try { if (-not [string]::IsNullOrWhiteSpace([string]$matrixConfig.KeepAlive)) { $keep = [string]$matrixConfig.KeepAlive } } catch {}
    return $keep
}

function Invoke-OllamaChatTurn {
    param(
        [Parameter(Mandatory=$true)][string]$Model,
        [Parameter(Mandatory=$true)][System.Collections.IList]$Messages,
        [int]$ContextLength = 1024,
        [switch]$ShowStream
    )

    $uri = "http://{0}/api/chat" -f $script:CypraOllamaHost
    $keep = Get-MatrixOllamaKeepAlive

    $msgPayload = @()
    foreach ($m in $Messages) {
        $role = [string]$m.role
        $content = [string]$m.content
        if ([string]::IsNullOrWhiteSpace($content)) { $content = [string]$m.text }
        if ([string]::IsNullOrWhiteSpace($role) -or [string]::IsNullOrWhiteSpace($content)) { continue }
        $msgPayload += @{ role = $role; content = $content }
    }

    $body = @{
        model      = $Model
        messages   = $msgPayload
        stream     = $true
        keep_alive = $keep
        think      = -not [bool]$script:HideModelThinking
        options    = @{ num_ctx = [int]$ContextLength }
    }

    $json = $body | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    try {
        $req = [System.Net.HttpWebRequest]::Create($uri)
        $req.Method = 'POST'
        $req.ContentType = 'application/json; charset=utf-8'
        $req.Timeout = 600000
        $req.ReadWriteTimeout = 600000
        $req.ContentLength = $bytes.Length
        $reqStream = $req.GetRequestStream()
        $reqStream.Write($bytes, 0, $bytes.Length)
        $reqStream.Close()

        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $sbAnswer = New-Object System.Text.StringBuilder
        $inThink = $false
        $started = $false

        if ($ShowStream) {
            Write-Host "[thinking + answer will stream here]" -ForegroundColor $Theme.Muted
        }

        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $obj = $null
            try { $obj = $line | ConvertFrom-Json } catch { continue }

            $thinkChunk = ''
            $answerChunk = ''
            if ($obj.message) {
                $thinkChunk = [string]$obj.message.thinking
                $answerChunk = [string]$obj.message.content
            }

            if ($ShowStream -and -not $script:HideModelThinking -and -not [string]::IsNullOrWhiteSpace($thinkChunk)) {
                if (-not $inThink) {
                    Write-Host ""
                    Write-Host "Thinking..." -ForegroundColor $Theme.MutedLight
                    $inThink = $true
                    $started = $true
                }
                Write-Host $thinkChunk -NoNewline -ForegroundColor $Theme.Muted
            }

            if (-not [string]::IsNullOrWhiteSpace($answerChunk)) {
                if ($ShowStream) {
                    if ($inThink) {
                        Write-Host ""
                        Write-Host "...done thinking." -ForegroundColor $Theme.MutedLight
                        $inThink = $false
                    }
                    if (-not $started) { Write-Host ""; $started = $true }
                    Write-Host $answerChunk -NoNewline
                }
                [void]$sbAnswer.Append($answerChunk)
            }
            if ($obj.done -eq $true) { break }
        }

        if ($ShowStream -and $inThink) {
            Write-Host ""
            Write-Host "...done thinking." -ForegroundColor $Theme.MutedLight
        }
        if ($ShowStream -and $started) { Write-Host "" }
        try { $reader.Close() } catch {}
        try { $resp.Close() } catch {}

        return [pscustomobject]@{
            Ok      = $true
            Content = [string]$sbAnswer.ToString()
            Error   = $null
        }
    } catch {
        return [pscustomobject]@{
            Ok      = $false
            Content = ''
            Error   = [string]$_.Exception.Message
        }
    }
}

function Initialize-OllamaChatReady {
    param(
        [Parameter(Mandatory=$true)][string]$ModelName,
        [int]$ContextLength = 1024
    )

    $keep = Get-MatrixOllamaKeepAlive
    Write-Host ""
    Write-Host "[*] Loading '$ModelName' into memory..." -ForegroundColor $Theme.Warning
    Write-Host "[*] First load can take a few minutes on 6 GB VRAM. Do not type yet." -ForegroundColor $Theme.MutedLight

    $loaded = $false
    try {
        $genUri = "http://{0}/api/generate" -f $script:CypraOllamaHost
        $genBody = @{
            model      = $ModelName
            prompt     = ''
            stream     = $false
            keep_alive = $keep
            options    = @{ num_ctx = [int]$ContextLength }
        } | ConvertTo-Json -Compress
        $genBytes = [System.Text.Encoding]::UTF8.GetBytes($genBody)
        $null = Invoke-RestMethod -Uri $genUri -Method Post -Body $genBytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 600
        $loaded = $true
        Write-Host "[+] Weights are in memory." -ForegroundColor $Theme.Success
    } catch {
        Write-Host "[i] Preload ping failed ($($_.Exception.Message)). Asking the agent to come online..." -ForegroundColor $Theme.Warning
    }

    $greet = @(
        [pscustomobject]@{ role = 'user'; content = 'Session start. Reply with exactly: STATUS: Online. Ready — write a message.' }
    )
    $hello = Invoke-OllamaChatTurn -Model $ModelName -Messages $greet -ContextLength $ContextLength -ShowStream
    if ($hello.Ok -and -not [string]::IsNullOrWhiteSpace($hello.Content)) {
        $shown = Get-MatrixCleanText $hello.Content
        if ([string]::IsNullOrWhiteSpace($shown)) { $shown = [string]$hello.Content }
        if (-not $hello.Content) { Write-Host $shown }
        $loaded = $true
    } elseif (-not $loaded) {
        Write-Host "[!] Agent did not answer the ready ping. You can still type; the first reply may be slow." -ForegroundColor $Theme.Error
    }

    Write-Host ""
    Write-Host ('═' * 62) -ForegroundColor $Theme.Success
    Write-Host ("  READY — write a message and press Enter") -ForegroundColor $Theme.Success
    Write-Host ("  Agent: {0}   /help  /clear  /export  /bye" -f $ModelName) -ForegroundColor $Theme.Info
    Write-Host ('═' * 62) -ForegroundColor $Theme.Success
    Write-Host ""
    return $loaded
}

function Write-MatrixChatTurnArtifacts {
    param(
        [string]$ModelName,
        [string]$UserText,
        [string]$AgentText,
        [string]$LogFile,
        [string]$TaskPath,
        [string]$SessionFile
    )
    Save-AgentRunOutcome -ModelName $ModelName -UserPrompt $UserText -Response $AgentText -Source "interactive-session"
    Update-AgentLearning -ModelName $ModelName -Prompt $UserText -Success $true -DurationMs 0
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        "[$stamp] USER: $UserText`n[$stamp] AGENT: $AgentText`n---" | Out-File -FilePath $LogFile -Append -Encoding utf8
    }
    if (-not [string]::IsNullOrWhiteSpace($TaskPath) -and (Test-Path $TaskPath)) {
        "User: $UserText`nAgent ($ModelName): $AgentText`n---" | Out-File -FilePath (Join-Path $TaskPath "chat_history.txt") -Append -Encoding utf8
        $AgentText | Out-File -FilePath (Join-Path $TaskPath "result.txt") -Encoding utf8
    }
    if (-not [string]::IsNullOrWhiteSpace($SessionFile)) {
        $row = [pscustomobject]@{ timestamp = (Get-Date).ToString('o'); agent = $ModelName; prompt = $UserText; response = $AgentText }
        ($row | ConvertTo-Json -Compress -Depth 4) | Out-File -FilePath $SessionFile -Append -Encoding utf8
    }
}

function Get-MatrixChatMotionStyle {
    $emoji = [string]$script:ThemeEmoji
    switch ($emoji) {
        { $_ -in @('🟢','🧪','☢') } { return 'rain' }
        { $_ -in @('💜','🔮','🕶️','🎪') } { return 'glitch' }
        { $_ -in @('📟','👑') } { return 'scan' }
        { $_ -in @('🌊','📼') } { return 'wave' }
        { $_ -in @('🔴','🌅','🥇','🩸','☀️') } { return 'ember' }
        { $_ -in @('❄️','🧊') } { return 'frost' }
        { $_ -in @('🌌') } { return 'void' }
        default { return 'pulse' }
    }
}

function Get-MatrixChatMotionMarks {
    switch (Get-MatrixChatMotionStyle) {
        'rain'   { return @('0','1','|','/') }
        'glitch' { return @([string][char]0x2591, [string][char]0x2592, [string][char]0x2593, [string][char]0x2588) }
        'scan'   { return @([string][char]0x25AF, [string][char]0x25AE, [string][char]0x25A0, [string][char]0x25AE) }
        'wave'   { return @('~','~','~','~') }
        'ember'  { return @([string][char]0x00B7,'*',[string][char]0x00B7,'*') }
        'frost'  { return @([string][char]0x00B0,[string][char]0x00B7,[string][char]0x00B0,[string][char]0x00B7) }
        'void'   { return @([string][char]0x2219, [string][char]0x22C5, [string][char]0x2218, [string][char]0x22C5) }
        default  { return @([string][char]0x22C5, ':', [string][char]0x2E2C, [string][char]0x2059) }
    }
}

function ConvertTo-MatrixConsoleColor {
    param([string]$Name)
    try { return [ConsoleColor]$Name } catch { return [ConsoleColor]::Cyan }
}

function Find-MatrixOllamaPromptCell {
    $ui = $Host.UI.RawUI
    $win = $ui.WindowPosition
    $sz = $ui.WindowSize
    $x2 = [Math]::Max($win.X, $win.X + $sz.Width - 1)
    $y2 = [Math]::Max($win.Y, $win.Y + $sz.Height - 1)
    $rect = New-Object System.Management.Automation.Host.Rectangle $win.X, $win.Y, $x2, $y2
    $buf = $ui.GetBufferContents($rect)
    $rows = $buf.GetLength(0)
    $cols = $buf.GetLength(1)
    for ($r = $rows - 1; $r -ge 0; $r--) {
        $sb = New-Object System.Text.StringBuilder
        for ($c = 0; $c -lt $cols; $c++) { [void]$sb.Append(([System.Management.Automation.Host.BufferCell]$buf.GetValue($r, $c)).Character) }
        $s = $sb.ToString()
        $idx = -1
        if ($s.Contains('Native Ollama') -or $s.Contains('Native session') -or $s.Contains('Type at') -or $s.Contains('/bye disconnects') -or $s.Contains('Write a message') -or $s.Contains('ollama help') -or $s.Contains('/bye leaves') -or $s.Contains('Open native') -or $s.Contains('Continue chat') -or $s.Contains('Last prompts') -or $s.Contains('Matrix commands') -or $s.Contains('prompt appears') -or $s.Contains('Resume last') -or $s.Contains('Prior conversation')) { continue }
        if ($s.Contains('Send a message')) {
            $idx = $s.IndexOf(')')
            if ($idx -lt 0) { $idx = $s.LastIndexOf('p') }
            $idx = $idx + 2
        } elseif ($s.Contains('>>>')) {
            $idx = $s.IndexOf('>>>') - 2
        }
        if ($idx -lt 0) { continue }
        if ($idx -ge $cols) { $idx = $cols - 1 }
        return @{ X = ($win.X + $idx); Y = ($win.Y + $r) }
    }
    return $null
}

function Set-MatrixBufferMark {
    param([int]$X, [int]$Y, [char]$Ch, [string]$ColorName)
    $ui = $Host.UI.RawUI
    $fg = ConvertTo-MatrixConsoleColor $ColorName
    $cell = New-Object System.Management.Automation.Host.BufferCell $Ch, $fg, $ui.BackgroundColor, 'Complete'
    $rect = New-Object System.Management.Automation.Host.Rectangle $X, $Y, $X, $Y
    $ui.SetBufferContents($rect, $cell)
}

function Invoke-MatrixInteractiveChat {
    param(
        [Parameter(Mandatory=$true)][string]$ModelName,
        [string]$LogFile,
        [string]$TaskPath,
        [int]$ContextLength = 1024
    )

    $script:HideModelThinking = $false
    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        throw "Interactive launch blocked: target model resolved to an empty value."
    }

    $exe = (Get-Command ollama -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($exe)) {
        Write-Host "[!] ollama.exe was not found on PATH." -ForegroundColor $Theme.Error
        return 1
    }

    Write-Host ""
    $argList = [System.Collections.Generic.List[string]]::new()
    $argList.Add('run')
    $argList.Add($ModelName)

    while ($true) {
        $p = Start-Process -FilePath $exe -ArgumentList $argList.ToArray() -NoNewWindow -PassThru
        if ($p) {
            $marks = @(Get-MatrixChatMotionMarks)
            $cols = @($Theme.Info, $Theme.Brand, $Theme.Accent, $Theme.Success)
            $i = 0
            try {
                while (-not $p.HasExited) {
                    try {
                        $spot = Find-MatrixOllamaPromptCell
                        if ($spot) {
                            $ch = [string]$marks[$i % $marks.Count]
                            if ($ch.Length -gt 0) {
                                Set-MatrixBufferMark -X ([int]$spot.X) -Y ([int]$spot.Y) -Ch $ch[0] -ColorName $cols[$i % $cols.Count]
                            }
                        }
                    } catch {}
                    Start-Sleep -Milliseconds 80
                    $i++
                }
            } catch {}
        }

        Write-Host ""
        Write-Host "  Continue chat?  " -NoNewline -ForegroundColor $Theme.Muted
        Write-Host "Y" -NoNewline -ForegroundColor $Theme.Success
        Write-Host "  stay   " -NoNewline -ForegroundColor $Theme.Muted
        Write-Host "n" -NoNewline -ForegroundColor $Theme.Accent
        Write-Host "  dashboard" -ForegroundColor $Theme.Muted
        $again = ([string](Read-Host "Continue chat")).Trim()
        if ($again -match '^(?i)n') { break }
    }

    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') native session model=$ModelName" |
            Out-File -FilePath $LogFile -Append -Encoding utf8
    }
    return 0
}

# Handles the "an agent run failed/OOM'd, so reset the engine and retry on
# CPU" sequence. Previously written out twice (once for the quick-prompt
# path, once for the interactive path) with slightly different messages;
# centralizing it means a fix here applies to both call sites instead of
# needing to be made twice.
function Invoke-CpuFallbackReset {
    param(
        [string]$FailureMessage = "[!] Ollama reported a failure.",
        # The quick-prompt path first cycles the engine back to a clean
        # (GPU) state before forcing CPU mode; the interactive path skips
        # straight to CPU mode. Pass -FullReset to get the former.
        [switch]$FullReset
    )
    Write-Host ""
    Write-Host $FailureMessage -ForegroundColor $Theme.Error
    if ($FullReset) {
        Write-Host "[*] Releasing all loaded models and resetting the Ollama engine..." -ForegroundColor $Theme.Warning
        $null = Start-OllamaEngine
    }
    Write-Host "[*] Switching this agent to CPU-safe mode..." -ForegroundColor $Theme.Warning
    $null = Start-OllamaEngine -CpuOnly $true
}

# 4. Persistent Knowledge / RAG Workspace index
function Invoke-KnowledgeWorkspace {
    Initialize-MatrixAddonStorage
    Clear-Host
    Show-CommandActivation -Command 'knowledge'
    Write-Host 'KNOWLEDGE WORKSPACE / RAG INDEX' -ForegroundColor $Theme.Info
    Write-Host '[i] Conversation records are archived under MatrixData\Knowledge\Conversations when Knowledge is enabled.' -ForegroundColor $Theme.MutedLight
    Write-Host ''
    $defaultDir=Join-Path $script:MatrixKnowledgeRoot 'Conversations'
    $dir=Read-Host "Folder to index (Enter for default: $defaultDir)"
    if([string]::IsNullOrWhiteSpace($dir)){$dir=$defaultDir}
    $dir=(Resolve-Path -LiteralPath $dir -ErrorAction SilentlyContinue).Path
    if([string]::IsNullOrWhiteSpace($dir)){Write-Host '[!] Folder not found.' -ForegroundColor $Theme.Error;Read-Host 'Enter';return}
    # If the user points at the Knowledge root, automatically use its Conversations child.
    if((Split-Path $dir -Leaf) -ieq 'Knowledge'){
        $conversationDir=Join-Path $dir 'Conversations'
        if(Test-Path $conversationDir){$dir=$conversationDir}
    }
    $files=@(Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue|Where-Object{$_.Extension -in '.txt','.md','.ps1','.py','.js','.json','.csv','.xml','.yaml','.yml','.log'})
    $index=@()
    foreach($f in $files|Select-Object -First 2000){
        $text=Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        $index += [pscustomobject]@{path=$f.FullName;size=$f.Length;modified=$f.LastWriteTime;preview=([string]$text).Substring(0,[Math]::Min(500,([string]$text).Length))}
    }
    $index|ConvertTo-Json -Depth 6|Set-Content (Join-Path $script:MatrixKnowledgeRoot 'index.json') -Encoding utf8
    Write-Host "[+] Indexed $($index.Count) files from: $dir" -ForegroundColor $Theme.Success
    if($index.Count -eq 0){Write-Host '[i] No supported files were found. Run a conversation/agent task first, then index the Conversations folder.' -ForegroundColor $Theme.Warning}
    $q=Read-Host 'Search indexed text (Enter to skip)'
    if($q){
        $hits=@($index|Where-Object{$_.preview -match [regex]::Escape($q) -or $_.path -match [regex]::Escape($q)})
        if($hits){$hits|Select-Object -First 20|Format-Table -AutoSize|Out-Host}else{Write-Host "[i] No indexed record matched '$q'." -ForegroundColor $Theme.Warning}
    }
    Read-Host 'Enter'
}

# 5. Agent file intelligence
function Invoke-AgentFileIntelligence {
    Clear-Host
    Show-CommandActivation -Command 'scan'
    $path=Read-Host "Workspace/file path (Enter for project root: $script:ProjectRoot)"
    if([string]::IsNullOrWhiteSpace($path)){$path=$script:ProjectRoot}
    if(-not(Test-Path $path)){Write-Host "[!] Not found: $path" -ForegroundColor $Theme.Error;Read-Host 'Enter';return}
    $item=Get-Item $path -ErrorAction SilentlyContinue
    if($null -eq $item){Write-Host "[!] Path could not be read: $path" -ForegroundColor $Theme.Error;Read-Host 'Enter';return}
    $items=@(if($item.PSIsContainer){Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue}else{$item})
    if($items.Count -eq 0){Write-Host '[i] No files found under the selected path.' -ForegroundColor $Theme.Warning;Read-Host 'Enter';return}
    $ext=$items|Group-Object Extension|Sort-Object Count -Descending
    Write-Host 'FILE INTELLIGENCE' -ForegroundColor $Theme.Info
    $ext|Format-Table Name,Count -AutoSize|Out-Host
    $dupes=@($items|Group-Object Length|Where-Object{$_.Count -gt 1})
    Write-Host "Potential duplicate-size groups: $($dupes.Count)" -ForegroundColor $Theme.Warning
    Read-Host 'Enter'
}

# 6. Code Review Arena
function Invoke-CodeReviewArena { Invoke-AgentFileReview }

function Invoke-AgentFileReview {
    Clear-Host
    Show-CommandActivation -Command 'review'
    Write-Host 'AGENT FILE REVIEW' -ForegroundColor $Theme.Info
    Write-Host 'Pick one agent + file. Configure focus, depth, and severity.' -ForegroundColor $Theme.MutedLight
    Write-Host ''

    $agentInput = Read-Host 'Agent ID or name'
    if ([string]::IsNullOrWhiteSpace($agentInput)) { return }

    $resolvedId = Resolve-AgentIdentifier $agentInput
    if ($null -eq $resolvedId) {
        Write-Host "[!] Agent '$agentInput' not found in the registry." -ForegroundColor $Theme.Error
        Read-Host 'Enter'
        return
    }

    $entry = $script:AgentRegistry[[string]$resolvedId]
    $modelName = [string]$entry.model
    Write-Host ("[+] Agent: {0} ({1})  [{2}]" -f $entry.name, $resolvedId, $entry.group) -ForegroundColor $Theme.Success

    $file = Read-Host 'File path to review'
    if ([string]::IsNullOrWhiteSpace($file)) { return }
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Host "[!] File not found: $file" -ForegroundColor $Theme.Error
        Read-Host 'Enter'
        return
    }

    $item = Get-Item -LiteralPath $file
    if ($item.PSIsContainer) {
        Write-Host '[!] Path is a folder. Provide a file path.' -ForegroundColor $Theme.Error
        Read-Host 'Enter'
        return
    }

    $text = Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-Host '[!] File is empty or unreadable.' -ForegroundColor $Theme.Warning
        Read-Host 'Enter'
        return
    }

    Write-Host ''
    Write-Host 'REVIEW PARAMETERS (Enter = defaults)' -ForegroundColor $Theme.Info
    Write-Host '  Focus   : correctness, security, maintainability, performance, clarity' -ForegroundColor $Theme.MutedLight
    Write-Host '  Depth   : quick | standard | deep' -ForegroundColor $Theme.MutedLight
    Write-Host '  Severity: all | critical | high+ | medium+' -ForegroundColor $Theme.MutedLight
    Write-Host '  Format  : bullets | sections | checklist' -ForegroundColor $Theme.MutedLight
    Write-Host ''

    $focus = Read-Host 'Focus areas (comma-separated)'
    if ([string]::IsNullOrWhiteSpace($focus)) {
        $focus = 'correctness, security, maintainability, performance, clarity'
    }

    $depth = (Read-Host 'Depth [quick/standard/deep]').Trim().ToLowerInvariant()
    if ($depth -notin @('quick','standard','deep')) { $depth = 'standard' }

    $severity = (Read-Host 'Min severity [all/critical/high+/medium+]').Trim().ToLowerInvariant()
    if ($severity -notin @('all','critical','high+','medium+')) { $severity = 'all' }

    $fmt = (Read-Host 'Output format [bullets/sections/checklist]').Trim().ToLowerInvariant()
    if ($fmt -notin @('bullets','sections','checklist')) { $fmt = 'sections' }

    $extra = Read-Host 'Extra instructions (optional)'

    $maxChars = switch ($depth) {
        'quick'    { 40000 }
        'deep'     { 160000 }
        default    { 120000 }
    }
    $trimmed = $false
    if ($text.Length -gt $maxChars) {
        $text = $text.Substring(0, $maxChars)
        $trimmed = $true
        Write-Host "[!] File truncated to $maxChars chars for depth=$depth." -ForegroundColor $Theme.Warning
    }

    $depthGuide = switch ($depth) {
        'quick'    { 'Keep the review short. Top findings only. No long explanations.' }
        'deep'     { 'Be thorough. Cite specific lines/sections. Explain impact and suggest concrete fixes.' }
        default    { 'Balanced detail. Key findings with brief rationale and practical fixes.' }
    }

    $sevGuide = switch ($severity) {
        'critical' { 'Report ONLY critical issues.' }
        'high+'    { 'Report only CRITICAL and HIGH severity issues.' }
        'medium+'  { 'Report CRITICAL, HIGH, and MEDIUM. Skip LOW/NIT unless safety-related.' }
        default    { 'Report all severities: CRITICAL / HIGH / MEDIUM / LOW / NIT.' }
    }

    $fmtGuide = switch ($fmt) {
        'bullets'    { 'Use compact bullet lists. One finding per bullet.' }
        'checklist'  { 'Use a checklist style with [ ] / [x] markers where useful.' }
        default      { 'Use clear section headers. Group findings by severity.' }
    }

    $prompt = @"
You are reviewing a file as specialist agent $($entry.name) (ID $resolvedId, group: $($entry.group)).

REVIEW FOCUS: $focus
DEPTH: $depth — $depthGuide
SEVERITY FILTER: $severity — $sevGuide
OUTPUT FORMAT: $fmt — $fmtGuide

Rules:
- Be concrete (cite lines/sections when possible).
- Separate findings by severity labels.
- Note assumptions and anything unverifiable from the file alone.
- End with a short prioritized action list.
$(if (-not [string]::IsNullOrWhiteSpace($extra)) { "EXTRA INSTRUCTIONS:`n$extra" } else { '' })

FILE: $($item.FullName)
SIZE: $($item.Length) bytes
$(if ($trimmed) { 'NOTE: Content was truncated for context limits.' } else { '' })

CONTENT:
$text
"@

    Write-Host ''
    Write-Host ("[*] Reviewing with {0} | depth={1} | severity={2} | format={3}" -f $modelName, $depth, $severity, $fmt) -ForegroundColor $Theme.Warning
    $r = Invoke-InstalledAgentQuery -ModelName $modelName -Prompt $prompt -TrackLearning
    Write-Host ''
    Write-Host 'REVIEW RESULT' -ForegroundColor $Theme.Success
    Write-Host ('-' * 70) -ForegroundColor $Theme.Muted
    if ([string]::IsNullOrWhiteSpace([string]$r.Output)) {
        Write-Host '[!] No usable review output.' -ForegroundColor $Theme.Error
    } else {
        $r.Output | Out-Host
    }
    Read-Host 'Enter'
}

# 7. Autonomous Debugger
function Invoke-AutonomousDebugger {
    Clear-Host
    Show-CommandActivation -Command 'debug'
    $err=Read-Host 'Paste error/traceback'
    if([string]::IsNullOrWhiteSpace($err)){return}
    $r=Invoke-InstalledAgentQuery -ModelName 'debugger' -Prompt "Diagnose this error, identify the likely source, and propose a minimal safe fix:`n$err" -TrackLearning
    $r.Output|Out-Host
    Read-Host 'Enter'
}

# 8. Agent Sandbox
function New-AgentSandbox {
    Initialize-MatrixAddonStorage
    Clear-Host
    Show-CommandActivation -Command 'sandbox'
    $name=Read-Host 'Sandbox name'
    if([string]::IsNullOrWhiteSpace($name)){return}
    $safe=$name-replace '[^A-Za-z0-9_.-]','_'
    $p=Join-Path $script:MatrixSandboxRoot ($safe+'_'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $p -Force|Out-Null
    Write-Host "[+] Sandbox: $p" -ForegroundColor $Theme.Success
    Set-Location $p
    Read-Host 'Enter'
}

# 9. Diff viewer
function Show-MatrixDiff {
    Clear-Host
    Show-CommandActivation -Command 'diff'
    $a=Read-Host 'Original file'
    $b=Read-Host 'Changed file'
    if([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)){return}
    if((!(Test-Path $a)) -or (!(Test-Path $b))){Write-Host '[!] Both file paths must exist.' -ForegroundColor $Theme.Error;Read-Host 'Enter';return}
    $da=Get-Content $a
    $db=Get-Content $b
    Compare-Object $da $db|Out-Host
    Read-Host 'Enter'
}

# 10. Debate 2.0
function Invoke-Debate2 { Invoke-NexusTwoAgentDebate }

# 11. Confidence / evidence
function Invoke-ConfidenceGate {
    Clear-Host
    Show-CommandActivation -Command 'confidence'
    Write-Host 'CONFIDENCE / EVIDENCE GATE' -ForegroundColor $Theme.Info
    Write-Host 'Uses at most 2 specialist reviewers, then 1 Nexus-Prime judge.' -ForegroundColor $Theme.MutedLight
    $claim=Read-Host 'Claim/answer to evaluate'
    if([string]::IsNullOrWhiteSpace($claim)){ return }

    $exclude=Get-NexusDefaultExcludedIds
    $ids=@(Invoke-NexusAgentSelection -TaskPrompt $claim -Count 2 -ExcludeIds $exclude | Select-Object -Unique -First 2)
    if($ids.Count -eq 0){
        Write-Host '[!] No suitable specialist reviewers were found.' -ForegroundColor $Theme.Warning
        Read-Host 'Enter'
        return
    }
    Write-Host ''
    Write-Host ("Selected reviewers: {0} of maximum 2" -f $ids.Count) -ForegroundColor $Theme.Success
    $outs=@()
    foreach($id in $ids){
        $entry=$script:AgentRegistry[[string]$id]
        if(-not $entry){continue}
        Write-Host ("  [{0}] {1} / {2}" -f $id,$entry.name,$entry.group) -ForegroundColor $Theme.InfoDim
        $reviewPrompt=@"
Assess this claim for confidence and evidence quality.
Return four concise sections: CONFIDENCE, EVIDENCE, ASSUMPTIONS, UNCERTAINTY.
Do not invent sources. State when the claim cannot be verified from the information provided.
CLAIM:
$claim
"@
        $r=Invoke-InstalledAgentQuery -ModelName $entry.model -Prompt $reviewPrompt
        if($r -and $r.Output){$outs+=("[$id - $($entry.name)]`n$($r.Output)")}
    }
    if($outs.Count -eq 0){
        Write-Host '[!] Specialist review returned no usable output.' -ForegroundColor $Theme.Warning
        Read-Host 'Enter'
        return
    }
    $judgePrompt=@"
You are Nexus-Prime acting as the final confidence judge.
Score the claim from 0-100 based only on the specialist reviews below.
Do not treat reviewer agreement as proof. Separate evidence quality from confidence.
Return: SCORE, VERDICT, EVIDENCE QUALITY, KEY ASSUMPTIONS, UNCERTAINTIES.
CLAIM:
$claim
SPECIALIST REVIEWS:
$($outs -join "`n---`n")
"@
    $final=(Invoke-InstalledAgentQuery -ModelName 'nexus-prime' -Prompt $judgePrompt).Output
    Write-Host ''
    Write-Host 'NEXUS-PRIME CONFIDENCE RESULT' -ForegroundColor $Theme.Primary
    $final|Out-Host
    Write-Host ''
    Write-Host 'Pipeline: 2 specialist reviewers max → 1 Nexus-Prime judge → Dashboard.' -ForegroundColor $Theme.MutedLight
    Read-Host 'Enter'
}

# 12. Hallucination cross-checker
function Invoke-HallucinationCheck {
    Show-CommandActivation -Command 'verify'; $text=Read-Host 'Answer/text to cross-check'; if(!$text){return}; $r=Invoke-InstalledAgentQuery -ModelName 'fact-checker' -Prompt "Cross-check the following text. List unsupported claims, contradictions, unverifiable statements, and what evidence would be needed. Do not invent sources.`n$text"; $r.Output|Out-Host; Read-Host 'Enter' }

# 13. Agent health monitor
function Show-AgentHealthMonitor { Clear-Host
    Show-CommandActivation -Command 'health'; Write-Host 'AGENT HEALTH MONITOR' -ForegroundColor $Theme.Info; $loaded=@(Get-OllamaLoadedModelTelemetry); $models=@(Get-ExistingOllamaModels); foreach($m in $models|Select-Object -First 50){$run=(@($loaded|Where-Object{$_.Name -ieq $m.Name}).Count -gt 0); Write-Host ("{0,-26} {1}" -f $m.Name, $(if($run){'RUNNING / READY'}else{'INSTALLED / READY'})) -ForegroundColor $(if($run){$Theme.Success}else{$Theme.MutedLight})}; Read-Host 'Enter' }

# 14. Intelligent VRAM queue
function Show-VramQueue { Clear-Host
    Show-CommandActivation -Command 'queue'; Write-Host 'INTELLIGENT VRAM QUEUE' -ForegroundColor $Theme.Info; $snap=Get-VramSnapshot; $loaded=@(Get-OllamaLoadedModelTelemetry); if($snap.Available){Write-Host "Free VRAM: $($snap.FreeMB) MB / $($snap.TotalMB) MB" -ForegroundColor $Theme.Success}; foreach($m in $loaded){Write-Host ("RUNNING: {0,-28} {1} MB" -f $m.Name,$m.SizeMB) -ForegroundColor $Theme.Info}; Write-Host 'Policy: reuse exact running model; let Ollama manage residency when switching.' -ForegroundColor $Theme.MutedLight; Read-Host 'Enter' }

# 15. Existing-model resolver
function Resolve-ExistingAgentModel { param([string]$Name); $mods=@(Get-ModelfileManifest); $hit=$mods|Where-Object{$_.Name -ieq $Name}|Select-Object -First 1; if($hit){return $hit.Name}; $local=@(Get-ExistingOllamaModels)|Where-Object{$_.Name -ieq $Name -or $_.Name -ieq "$Name`:latest"}|Select-Object -First 1; if($local){return $local.Name}; throw "No installed model named '$Name' was found." }

# 16. Directive integrity checker
function Invoke-DirectiveIntegrity {
    $manifest = @(Update-ModelManifest)
    Clear-Host
    Show-CommandActivation -Command 'integrity'

    Write-Host 'DIRECTIVE INTEGRITY / MODEL REGISTRY' -ForegroundColor $Theme.Info
    Write-Host ('-' * 118) -ForegroundColor $Theme.Muted

    $installedCount = @($manifest | Where-Object { $_.installed }).Count
    $activeCount    = @($manifest | Where-Object { $_.active }).Count
    $missingCount   = @($manifest | Where-Object { -not $_.installed }).Count
    $baseMissing    = @($manifest | Where-Object { -not $_.base_installed }).Count

    Write-Host ("Agents represented by Modelfiles : {0}" -f $manifest.Count) -ForegroundColor $Theme.InfoDim
    Write-Host ("Installed / ready               : {0}" -f $installedCount) -ForegroundColor $Theme.Success
    Write-Host ("Active / loaded right now       : {0}" -f $activeCount) -ForegroundColor $(if($activeCount){$Theme.Success}else{$Theme.MutedLight})
    Write-Host ("Not registered                  : {0}" -f $missingCount) -ForegroundColor $(if($missingCount){$Theme.Warning}else{$Theme.Success})
    Write-Host ("Missing base models             : {0}" -f $baseMissing) -ForegroundColor $(if($baseMissing){$Theme.Warning}else{$Theme.Success})
    Write-Host ""

    $pageSize = 32
    $page = 0
    while ($true) {
        $start = $page * $pageSize
        if ($start -ge $manifest.Count) { $page = 0; $start = 0 }

        $pageRows = @($manifest | Select-Object -Skip $start -First $pageSize |
            Select-Object @{N='AGENT';E={$_.agent}},
                          @{N='BASE';E={$_.base_model}},
                          @{N='INSTALLED';E={if($_.installed){'TRUE'}else{'FALSE'}}},
                          @{N='ACTIVE';E={if($_.active){'TRUE'}else{'FALSE'}}},
                          @{N='STATUS';E={$_.status}})

        $pageRows | Format-Table -AutoSize | Out-Host
        Write-Host ("Showing {0}-{1} of {2}" -f ($start+1),([Math]::Min($start+$pageSize,$manifest.Count)),$manifest.Count) -ForegroundColor $Theme.MutedLight
        Write-Host "[Enter] return   [N] next page   [P] previous page   [R] refresh" -ForegroundColor $Theme.InfoDim
        $nav = (Read-Host 'Directive integrity').Trim().ToUpperInvariant()

        if ($nav -eq '') { break }
        if ($nav -eq 'R') {
            $manifest = @(Update-ModelManifest)
            $page = 0
            Clear-Host
            continue
        }
        if ($nav -eq 'N') {
            if (($page + 1) * $pageSize -lt $manifest.Count) { $page++ } else { $page = 0 }
            Clear-Host
            continue
        }
        if ($nav -eq 'P') {
            if ($page -gt 0) { $page-- } else { $page = [Math]::Max(0,[Math]::Ceiling($manifest.Count / $pageSize)-1) }
            Clear-Host
            continue
        }
    }
}


# 17. Install models manager
function Show-InstallModelsManager {
    Clear-Host
    Show-CommandActivation -Command 'models'
    Write-Host 'MODEL CENTER' -ForegroundColor $Theme.Info
    Write-Host "Cypra Ollama host : $script:CypraOllamaHost" -ForegroundColor $Theme.InfoDim
    Write-Host "Portable store    : $defaultModelStorePath" -ForegroundColor $Theme.InfoDim
    Write-Host ""
    Write-Host '[1] Verify installed models / agent directives' -ForegroundColor $Theme.Success
    Write-Host '[2] Install a base model' -ForegroundColor $Theme.Info
    Write-Host '[3] Install / register an agent' -ForegroundColor $Theme.Info
    Write-Host '[4] List portable models' -ForegroundColor $Theme.Info
    Write-Host '[5] Return' -ForegroundColor $Theme.Warning
    $c = Read-Host 'Select'

    switch ($c) {
        '1' {
            Invoke-DirectiveIntegrity
        }
        '2' {
            $modelName = Read-Host 'Base model to install (e.g. qwen3.5:4b)'
            if (-not [string]::IsNullOrWhiteSpace($modelName)) {
                Write-Host "[*] Installing base model '$modelName' into the portable store..." -ForegroundColor $Theme.Info
                & ollama pull $modelName
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "[+] Base model installed locally." -ForegroundColor $Theme.Success
                } else {
                    Write-Host "[!] Base model install failed with exit code $LASTEXITCODE." -ForegroundColor $Theme.Error
                }
            }
            Read-Host 'Enter'
        }
        '3' {
            $agentName = Read-Host 'Agent to install/register (e.g. cypra)'
            if (-not [string]::IsNullOrWhiteSpace($agentName)) {
                try {
                    Install-AgentDirectiveModel -ModelName $agentName | Out-Null
                } catch {
                    Write-Host "[!] $($_.Exception.Message)" -ForegroundColor $Theme.Error
                }
            }
            Read-Host 'Enter'
        }
        '4' {
            $installed = @(Get-MatrixInstalledModels)
            $running = @{}
            foreach($n in @(Get-OllamaRunningModelNames)) { $running[(Normalize-OllamaModelName $n).ToLowerInvariant()] = $true }

            if ($installed.Count -eq 0) {
                Write-Host 'No installed models were returned by Ollama.' -ForegroundColor $Theme.Warning
            } else {
                $rows = foreach($m in $installed) {
                    $key = (Normalize-OllamaModelName $m.Name).ToLowerInvariant()
                    [pscustomobject]@{
                        Name = $m.Name
                        Status = if($running.ContainsKey($key)) {'ACTIVE / LOADED'} else {'INSTALLED / READY'}
                        Size = $m.Size
                        Modified = $m.Modified
                    }
                }
                $rows | Format-Table Name,Status,Size,Modified -AutoSize | Out-Host
            }
            Read-Host 'Enter'
        }
        '5' { return }
        default {
            Write-Host '[!] Invalid selection.' -ForegroundColor $Theme.Warning
            Read-Host 'Enter'
        }
    }
}

# 18. Duplicate / orphan detector
function Invoke-ModelStorageAudit { Initialize-MatrixAddonStorage; $local=@(Get-ExistingOllamaModels); $mods=@(Get-ModelfileManifest); $valid=@($mods.Name); $orphans=@($local|Where-Object{$valid -notcontains ($_.Name -replace ':latest$','') -and $_.Name -notin @($matrixConfig.CoreModels,'gemma4:latest')}); $dupes=@($local|Group-Object {($_.Name -replace ':latest$','')}|Where-Object{$_.Count -gt 1}); Clear-Host
    Show-CommandActivation -Command 'audit'; Write-Host 'MODEL STORAGE AUDIT' -ForegroundColor $Theme.Info; Write-Host "Local: $($local.Count) | Modelfiles: $($mods.Count) | Potential orphan/unknown: $($orphans.Count) | Duplicate families: $($dupes.Count)"; $orphans|Select-Object Name|Format-Table -AutoSize|Out-Host; Write-Host '[i] No automatic deletion. Review then use Ollama commands manually.' -ForegroundColor $Theme.Warning; Read-Host 'Enter' }

# 19. Task dependency engine
function Invoke-TaskDependencyEngine { Clear-Host
    Show-CommandActivation -Command 'deps'; Write-Host 'TASK DEPENDENCY ENGINE' -ForegroundColor $Theme.Info; $t=Read-Host 'Task'; if(!$t){return}; $r=(Invoke-InstalledAgentQuery -ModelName 'project-manager' -Prompt "Build a dependency graph for this task. Output phases, predecessors, parallel-safe branches, and completion gates:`n$t").Output; $r|Out-Host; Read-Host 'Enter' }

# 20. Specialization packs
function Show-SpecializationPacks {
    Clear-Host
    Show-CommandActivation -Command 'packs'; Write-Host 'SPECIALIZATION PACKS' -ForegroundColor $Theme.Info; Write-Host ''
    $packs=[ordered]@{
        '1'='DEV - software, debugging, architecture'; '2'='SEC - security, privacy, incident response'; '3'='AI - machine learning, data, vision, NLP';
        '4'='OPS - planning, scheduling, risk'; '5'='RESEARCH - evidence, science, analysis'; '6'='CREATIVE - language, media, design'
    }
    $packs.GetEnumerator()|ForEach-Object{Write-Host "[$($_.Key)] $($_.Value)" -ForegroundColor $Theme.MutedLight}
    $choice=Read-Host 'Select pack'; if(-not $packs.Contains($choice)){return}
    $term=($packs[$choice] -split ' - ')[1]; $rows=@()
    foreach($id in ($script:AgentRegistry.Keys|Sort-Object {[int]$_})){ $e=$script:AgentRegistry[$id]; $hay="$($e.name) $($e.group) $($e.summary)"; $score=0; foreach($w in ($term -split ', ')){if($hay.ToLower().Contains($w.Split(' ')[0].ToLower())){$score++}}; if($score -gt 0){$rows+=[pscustomobject]@{ID=$id;Agent=$e.name;Group=$e.group;Score=$score}} }
    $rows|Sort-Object Score -Descending|Select-Object -First 20|Format-Table -AutoSize|Out-Host; Read-Host 'Enter'
}

# 21. Workflow templates
function Show-WorkflowTemplates {
    Clear-Host
    Show-CommandActivation -Command 'workflows'; Write-Host 'WORKFLOW TEMPLATES' -ForegroundColor $Theme.Info; Write-Host ''
    $templates=[ordered]@{'1'='build';'2'='debug';'3'='research';'4'='security-audit';'5'='data-analysis';'6'='refactor';'7'='documentation';'8'='full-review'}
    $templates.GetEnumerator()|ForEach-Object{Write-Host "[$($_.Key)] $($_.Value)" -ForegroundColor $Theme.Warning}
    $choice=Read-Host 'Select workflow'; if(-not $templates.Contains($choice)){return}; $task=Read-Host 'Describe the task'; if(!$task){return}
    $wf=$templates[$choice]
    $model = switch ($wf) {
        'build'          { 'software-architect' }
        'debug'          { 'debugger' }
        'research'       { 'researcher' }
        'security-audit' { 'security-architect' }
        'data-analysis'  { 'data-scientist' }
        'refactor'       { 'refactorer' }
        'documentation'  { 'technical-writer' }
        default          { 'nexus-prime' }
    }
    $prompt="Execute workflow '$wf' for this task. Provide phases, checks, deliverables, and concrete next actions.`nTASK:`n$task"; $r=Invoke-InstalledAgentQuery -ModelName $model -Prompt $prompt -TrackLearning; $r.Output|Out-Host; Read-Host 'Enter'
}

# 22. Live task timeline
function Show-TaskTimeline {
    Clear-Host
    Show-CommandActivation -Command 'timeline'; Write-Host 'LIVE TASK TIMELINE' -ForegroundColor $Theme.Info; Write-Host ''
    if(-not(Test-Path $script:TaskRoot)){Write-Host 'No task workspace.' -ForegroundColor $Theme.Muted;Read-Host 'Enter';return}
    foreach($d in @(Get-ChildItem $script:TaskRoot -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object { (Test-Path (Join-Path $_.FullName 'task.json')) -or (Test-Path (Join-Path $_.FullName 'metadata.json')) } | Sort-Object LastWriteTime -Descending | Select-Object -First 25)){
        $meta=Join-Path $d.FullName 'metadata.json'; $status=Join-Path $d.FullName 'status.json'; $model=''; $state='RUNNING/UNKNOWN'; if(Test-Path $meta){try{$m=Get-Content $meta -Raw|ConvertFrom-Json;$model=$m.model}catch{}}; if(Test-Path $status){try{$st=Get-Content $status -Raw|ConvertFrom-Json;$state=$st.status}catch{}}; Write-Host ("{0:yyyy-MM-dd HH:mm:ss} | {1,-18} | {2,-20} | {3}" -f $d.LastWriteTime,$state,$model,$d.Name) -ForegroundColor $Theme.MutedLight
    }
    Read-Host 'Enter'
}

# 23. Resource analytics
function Show-ResourceAnalytics { Clear-Host
    Show-CommandActivation -Command 'analytics'; Write-Host 'RESOURCE ANALYTICS' -ForegroundColor $Theme.Info; $snap=Get-VramSnapshot; if($snap.Available){Write-Host "GPU: $($snap.GpuName) | VRAM: $($snap.UsedMB)/$($snap.TotalMB) MB | $($snap.Percent)% used"}; if(Test-Path $script:MatrixLearningFile){$d=Get-Content $script:MatrixLearningFile -Raw|ConvertFrom-Json; if($d.agents){$d.agents.psobject.Properties|ForEach-Object{Write-Host ("{0,-24} runs={1} success={2} avgMs={3}" -f $_.Name,$_.Value.runs,$_.Value.success,[math]::Round($_.Value.total_ms/[math]::Max(1,$_.Value.runs),0)) -ForegroundColor $Theme.MutedLight}}}; Read-Host 'Enter' }

# 24. Nexus learning router
function Invoke-NexusLearningRouter {
    Show-CommandActivation -Command 'learn';
    $task=Read-Host 'Task to route'
    if(!$task){return}
    $data=ConvertTo-CompatHashtable (Get-Content $script:MatrixLearningFile -Raw|ConvertFrom-Json)
    $agents=$null
    if($data -is [System.Collections.IDictionary] -and $data.ContainsKey('agents')){$agents=$data['agents']}
    elseif($data -and $data.PSObject.Properties['agents']){$agents=ConvertTo-CompatHashtable $data.agents}
    $scores=@()
    foreach($id in ($script:AgentRegistry.Keys|Sort-Object {[int]$_})){
        $e=$script:AgentRegistry[$id]
        $hay="$($e.name) $($e.group) $($e.summary)"
        $score=0
        foreach($w in (($task.ToLower()-split '\W+')|Where-Object{$_.Length -ge 5}|Select-Object -First 20)){
            if($hay.ToLower().Contains($w)){$score++}
        }
        $model=[string]$e.model
        if($agents -is [System.Collections.IDictionary] -and $agents.ContainsKey($model)){
            $a=$agents[$model]
            $score += [math]::Min(5,[int]$a.success)
        }
        $scores += [pscustomobject]@{ID=$id;Name=$e.name;Score=$score}
    }
    $scores|Sort-Object Score -Descending|Select-Object -First 10|Format-Table -AutoSize|Out-Host
    Read-Host 'Enter'
}

# RESET ALL - restores original runtime state while preserving installed Ollama models.
function Reset-AllMatrixState {
    Clear-Host
    Show-CommandActivation -Command 'resetall'
    Write-Host 'RESET ALL MATRIX STATE' -ForegroundColor $Theme.Error
    Write-Host 'This clears Memory, Knowledge, learning, chat sessions, resume seeds,' -ForegroundColor $Theme.Warning
    Write-Host 'and temporary *-mem session models. Next agent open will not offer Resume.' -ForegroundColor $Theme.Warning
    Write-Host 'Settings return to the same portable defaults used on first launch.' -ForegroundColor $Theme.Warning
    Write-Host 'Installed fleet models (cypra, base weights) and Modelfiles are NOT deleted.' -ForegroundColor $Theme.Info
    $c = Read-Host 'Type RESET ALL to continue'
    if ($c -ne 'RESET ALL') {
        Write-Host '[i] Cancelled.' -ForegroundColor $Theme.Muted
        Read-Host 'Enter'
        return
    }

    $memRemoved = 0
    try {
        $rows = @(& ollama list 2>$null)
        foreach ($row in $rows) {
            $line = ([string]$row).Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^NAME\s') { continue }
            $name = ($line -split '\s+')[0]
            if ($name -like '*-mem') {
                try { Remove-MatrixMemorySessionModel -SessionModel $name -BaseAgent 'reset' } catch {}
                $prev = $ErrorActionPreference
                $ErrorActionPreference = 'SilentlyContinue'
                $null = & ollama rm $name 2>&1
                $ErrorActionPreference = $prev
                $memRemoved++
            }
        }
    } catch {}

    foreach ($extra in @('Sessions','Exports','Memory','Knowledge')) {
        $p = Join-Path $script:MatrixDataRoot $extra
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path $script:MatrixDataRoot) {
        Remove-Item $script:MatrixDataRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:MatrixSessionRoot = $null
    Initialize-MatrixAddonStorage

    $defaults = Get-MatrixDefaultConfig
    $script:matrixConfig = $defaults
    $script:matrixConfig.ModelStorePath = $defaultModelStorePath
    $script:SelectedProfile = [string]$defaults.DefaultProfile
    $script:OllamaContextLength = [int]$defaults.DefaultContext
    $env:OLLAMA_CONTEXT_LENGTH = [string]$defaults.DefaultContext
    $env:OLLAMA_KEEP_ALIVE = [string]$defaults.KeepAlive
    $env:OLLAMA_MODELS = $defaultModelStorePath
    Save-MatrixConfig

    Write-Host '[+] Memory, Knowledge, Sessions, Exports, and learning were wiped.' -ForegroundColor $Theme.Success
    Write-Host ("[+] Removed {0} temporary *-mem session model(s)." -f $memRemoved) -ForegroundColor $Theme.Success
    Write-Host '[+] Resume will not appear until you chat again.' -ForegroundColor $Theme.Success
    Write-Host ("[+] Settings restored: profile {0}, context {1}, keep-alive {2}." -f $defaults.DefaultProfile, $defaults.DefaultContext, $defaults.KeepAlive) -ForegroundColor $Theme.Success
    Write-Host '[+] Fleet models and Modelfiles were left untouched.' -ForegroundColor $Theme.Success
    Read-Host 'Enter'
}


# ============================================================================
# CYPRATEAM MATRIX ADDON WAVE 2 - ADDONS 28 THROUGH 50; ADDON WAVE 3 - 51 THROUGH 55
# ============================================================================
$script:MatrixEvidenceRoot = Join-Path $script:MatrixDataRoot "Evidence"
$script:MatrixPlansRoot = Join-Path $script:MatrixDataRoot "Plans"
$script:MatrixCheckpointsRoot = Join-Path $script:MatrixDataRoot "Checkpoints"
$script:MatrixReplayRoot = Join-Path $script:MatrixDataRoot "Replays"
$script:MatrixOpsRoot = Join-Path $script:MatrixDataRoot "Operations"

function Initialize-MatrixWave2Storage {
    foreach($d in @($script:MatrixEvidenceRoot,$script:MatrixPlansRoot,$script:MatrixCheckpointsRoot,$script:MatrixReplayRoot,$script:MatrixOpsRoot)){
        if(-not(Test-Path $d)){New-Item -ItemType Directory -Path $d -Force | Out-Null}
    }
}

function Invoke-OrchestrationPlanner {
    Initialize-MatrixWave2Storage; Clear-Host
    Show-CommandActivation -Command 'orchestrate'
    Write-Host "NEXUS ORCHESTRATION PLANNER" -ForegroundColor $Theme.Info
    $task=Read-Host "Task to plan"; if(!$task){return}
    $r=Invoke-InstalledAgentQuery -ModelName "nexus-prime" -Prompt @"
Create an execution plan for this task:
$task

Return:
DOMAIN:
OBJECTIVE:
SPECIALIST ROLES:
DEPENDENCIES:
PARALLEL-SAFE WORK:
SEQUENTIAL WORK:
VERIFICATION:
FINAL SYNTHESIS:
VRAM / RESOURCE NOTES:
"@ -TrackLearning
    $r.Output | Out-Host
    $path=Join-Path $script:MatrixPlansRoot ("plan_"+(Get-Date -Format "yyyyMMdd_HHmmss")+".md")
    $r.Output | Set-Content $path -Encoding utf8
    Write-Host "[+] Plan saved: $path" -ForegroundColor $Theme.Success
    Read-Host "Enter"
}

function Invoke-EvidenceLocker {
    Initialize-MatrixWave2Storage; Clear-Host
    Show-CommandActivation -Command 'evidence'
    Write-Host "EVIDENCE LOCKER" -ForegroundColor $Theme.Info
    Write-Host "[1] Add evidence  [2] View evidence  [3] Search evidence  [4] Return" -ForegroundColor $Theme.Warning
    $c=Read-Host "Select"
    $f=Join-Path $script:MatrixEvidenceRoot "evidence.jsonl"
    switch($c){
        "1" {
            $claim=Read-Host "Claim"; $source=Read-Host "Source"; $notes=Read-Host "Notes"
            [pscustomobject]@{timestamp=(Get-Date).ToString("o");claim=$claim;source=$source;notes=$notes}|ConvertTo-Json -Compress|Add-Content $f
            Write-Host "[+] Evidence recorded." -ForegroundColor $Theme.Success
        }
        "2" { if(Test-Path $f){Get-Content $f | Select-Object -Last 30 | Out-Host}else{Write-Host "No evidence recorded." -ForegroundColor $Theme.Muted} }
        "3" { $q=Read-Host "Search"; if(Test-Path $f){Get-Content $f | Select-String -SimpleMatch $q | Select-Object -Last 30 | Out-Host} }
    }
    Read-Host "Enter"
}

function Invoke-ContradictionResolver {
    Clear-Host
    Show-CommandActivation -Command 'resolve'; Write-Host "CONTRADICTION RESOLVER" -ForegroundColor $Theme.Info
    $topic=Read-Host "Question / disputed conclusion"; if(!$topic){return}
    $a=Read-Host "Position A"; $b=Read-Host "Position B"
    $r=Invoke-InstalledAgentQuery -ModelName "nexus-prime" -Prompt "Resolve this disagreement. Topic: $topic`nPosition A: $a`nPosition B: $b`nCompare evidence, assumptions, logical gaps, and practical consequences. State which position is best supported, what remains uncertain, and what evidence would settle the disagreement." -TrackLearning
    $r.Output|Out-Host; Read-Host "Enter"
}

function Show-AgentConsensusScores {
    Clear-Host
    Show-CommandActivation -Command 'consensus-scores'; Write-Host "AGENT CONSENSUS SCORES" -ForegroundColor $Theme.Info
    if(Test-Path $script:MatrixLearningFile){
        $d=Get-Content $script:MatrixLearningFile -Raw|ConvertFrom-Json
        if($d.agents){$d.agents.psobject.Properties|ForEach-Object{
            $runs=[int]$_.Value.runs; $succ=[int]$_.Value.success; $rate=if($runs){[math]::Round(($succ/$runs)*100,1)}else{0}
            [pscustomobject]@{Agent=$_.Name;Runs=$runs;Success=$succ;SuccessRate="$rate%";AvgMs=[math]::Round($_.Value.total_ms/[math]::Max(1,$runs),0)}
        }|Sort-Object SuccessRate -Descending|Select-Object -First 50|Format-Table -AutoSize|Out-Host}else{Write-Host "No learning data yet." -ForegroundColor $Theme.Muted}}
    Read-Host "Enter"
}

function Invoke-TaskRiskAnalyzer {
    Clear-Host
    Show-CommandActivation -Command 'risk'; Write-Host "TASK RISK ANALYZER" -ForegroundColor $Theme.Info
    $task=Read-Host "Task"; if(!$task){return}
    $r=Invoke-InstalledAgentQuery -ModelName "risk-manager" -Prompt "Analyze this task for operational risk. Task: $task`nReturn: RISK LEVEL, DATA LOSS RISK, SECURITY RISK, SYSTEM CHANGE RISK, REVERSIBILITY, HUMAN APPROVAL REQUIRED, TOP RISKS, MITIGATIONS, VALIDATION STEPS." -TrackLearning
    $r.Output|Out-Host
    $path=Join-Path $script:MatrixOpsRoot ("risk_"+(Get-Date -Format "yyyyMMdd_HHmmss")+".md"); $r.Output|Set-Content $path -Encoding utf8
    Read-Host "Enter"
}

function Invoke-ChangeApprovalGate {
    Clear-Host
    Show-CommandActivation -Command 'approve'; Write-Host "CHANGE APPROVAL GATE" -ForegroundColor $Theme.Info
    $file=Read-Host "Proposed change / patch file"; if(!(Test-Path $file)){Write-Host "[!] File not found." -ForegroundColor $Theme.Error;Read-Host "Enter";return}
    $content=Get-Content $file -Raw
    Write-Host "`nPROPOSED CHANGE:" -ForegroundColor $Theme.Warning
    $content | Select-Object -First 120 | Out-Host
    $choice=Read-Host "Type APPLY to approve, REJECT to deny, or REVISE"
    if($choice -eq "APPLY"){Write-Host "[+] Approved. This gate records approval; it does not automatically modify source." -ForegroundColor $Theme.Success}
    elseif($choice -eq "REJECT"){Write-Host "[i] Change rejected." -ForegroundColor $Theme.Warning}
    else{Write-Host "[i] Revision requested." -ForegroundColor $Theme.Info}
    Read-Host "Enter"
}

function Invoke-PatchGenerator {
    Clear-Host
    Show-CommandActivation -Command 'patch'; Write-Host "PATCH GENERATOR" -ForegroundColor $Theme.Info
    $file=Read-Host "Source file"; $goal=Read-Host "Desired change"
    if((!(Test-Path $file)) -or !$goal){return}
    $text=Get-Content $file -Raw
    $r=Invoke-InstalledAgentQuery -ModelName "patch" -Prompt "Generate a minimal unified diff for this file only. Do not rewrite unrelated sections. Desired change: $goal`nFILE: $file`nCONTENT:`n$text" -TrackLearning
    $patchPath=Join-Path $script:MatrixOpsRoot ("patch_"+(Get-Date -Format "yyyyMMdd_HHmmss")+".diff")
    $r.Output|Set-Content $patchPath -Encoding utf8
    $r.Output|Out-Host; Write-Host "[+] Patch saved: $patchPath" -ForegroundColor $Theme.Success
    Read-Host "Enter"
}

function Invoke-AutomatedTestRunner {
    Clear-Host
    Show-CommandActivation -Command 'test'; Write-Host "AUTOMATED TEST RUNNER" -ForegroundColor $Theme.Info
    $path=Read-Host "Script / project path"; if(!(Test-Path $path)){return}
    $item=Get-Item $path
    try {
        if($item.Extension -eq ".ps1"){& (Get-PowerShellExe) -NoProfile -ExecutionPolicy Bypass -File $item.FullName}
        elseif($item.Extension -eq ".py"){python $item.FullName}
        elseif($item.PSIsContainer -and (Test-Path (Join-Path $item.FullName "package.json"))){npm test --prefix $item.FullName}
        else{Write-Host "[i] No automatic test runner matched. Run the project's documented tests manually." -ForegroundColor $Theme.Warning}
    } catch {Write-Host "[!] Test runner error: $_" -ForegroundColor $Theme.Error}
    Read-Host "Enter"
}

function Invoke-RegressionGuard {
    Clear-Host
    Show-CommandActivation -Command 'regression'; Write-Host "REGRESSION GUARD" -ForegroundColor $Theme.Info
    $before=Read-Host "Baseline results file"; $after=Read-Host "Current results file"
    if((!(Test-Path $before)) -or (!(Test-Path $after))){Write-Host "[!] Results file missing." -ForegroundColor $Theme.Error;Read-Host "Enter";return}
    $diff=Compare-Object (Get-Content $before) (Get-Content $after)
    if($diff){Write-Host "[!] Regression / output drift detected." -ForegroundColor $Theme.Warning;$diff|Out-Host}else{Write-Host "[+] No textual regression detected." -ForegroundColor $Theme.Success}
    Read-Host "Enter"
}

function Show-ProjectHealth {
    Clear-Host
    Show-CommandActivation -Command 'projecthealth'; Write-Host "PROJECT HEALTH SCORE" -ForegroundColor $Theme.Info
    $path=Read-Host "Project folder"; if(!(Test-Path $path)){return}
    $files=@(Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue)
    $exts=@($files|Group-Object Extension|Sort-Object Count -Descending|Select-Object -First 10)
    $score=100
    if($files.Count -gt 2000){$score-=10}
    if(-not (Test-Path (Join-Path $path "README.md"))){$score-=10}
    if(-not ($files|Where-Object{$_.Name -match 'test|spec'})){ $score-=15 }
    [pscustomobject]@{Project=$path;Files=$files.Count;HealthScore=[math]::Max(0,$score);Documentation=if(Test-Path (Join-Path $path "README.md")){"Present"}else{"Missing"};Tests=if($files|Where-Object{$_.Name -match 'test|spec'}){"Detected"}else{"Not detected"}}|Format-List|Out-Host
    Read-Host "Enter"
}

function Invoke-DependencyScanner {
    Clear-Host
    Show-CommandActivation -Command 'depscan'; Write-Host "DEPENDENCY SCANNER" -ForegroundColor $Theme.Info
    $path=Read-Host "Project folder"; if(!(Test-Path $path)){return}
    $findings=@()
    if(Test-Path (Join-Path $path "requirements.txt")){$findings += "Python requirements.txt"}
    if(Test-Path (Join-Path $path "package.json")){$findings += "Node package.json"}
    if(Test-Path (Join-Path $path "go.mod")){$findings += "Go go.mod"}
    if(Test-Path (Join-Path $path "Cargo.toml")){$findings += "Rust Cargo.toml"}
    if(Get-ChildItem $path -Filter "*.psd1" -Recurse -ErrorAction SilentlyContinue){$findings += "PowerShell module manifests"}
    if($findings){$findings|ForEach-Object{Write-Host "[+] $_" -ForegroundColor $Theme.Success}}else{Write-Host "No recognized dependency manifests found." -ForegroundColor $Theme.Warning}
    Read-Host "Enter"
}

function Show-EnvironmentSnapshot {
    Clear-Host
    Show-CommandActivation -Command 'env'; Write-Host "ENVIRONMENT SNAPSHOT" -ForegroundColor $Theme.Info
    $snap=Get-VramSnapshot
    [pscustomobject]@{Computer=(Get-MatrixHostName);PowerShell=$PSVersionTable.PSVersion.ToString();OllamaHost=$env:OLLAMA_HOST;OllamaVersion=((& ollama --version) -join " ");GPU=if($snap.Available){$snap.GpuName}else{"Unavailable"};VRAM=if($snap.Available){"$($snap.FreeMB) MB free / $($snap.TotalMB) MB"}else{"Unavailable"};Profile=$script:SelectedProfile;Context=$env:OLLAMA_CONTEXT_LENGTH;AgentCount=$script:AgentRegistry.Count}|Format-List|Out-Host
    Read-Host "Enter"
}

function Show-AgentWarmPool {
    Clear-Host
    Show-CommandActivation -Command 'warm'; Write-Host "AGENT WARM POOL" -ForegroundColor $Theme.Info
    $loaded=@(Get-OllamaLoadedModelTelemetry)
    Write-Host "Currently loaded:" -ForegroundColor $Theme.Warning
    if($loaded){$loaded|Format-Table Name,SizeMB,Expires -AutoSize|Out-Host}else{Write-Host "None" -ForegroundColor $Theme.Muted}
    Write-Host "Policy: warm only actively reused models." -ForegroundColor $Theme.InfoDim
    Read-Host "Enter"
}

function Invoke-ResidencyPredictor {
    Clear-Host
    Show-CommandActivation -Command 'residency'; Write-Host "SMART MODEL RESIDENCY PREDICTOR" -ForegroundColor $Theme.Info
    $task=Read-Host "Upcoming task"; if(!$task){return}
    $ids=@(Invoke-NexusAgentSelection -TaskPrompt $task -Count 4 -ExcludeIds (Get-NexusDefaultExcludedIds))
    Write-Host "Likely models to use:" -ForegroundColor $Theme.Success
    foreach($id in $ids){Write-Host ("  {0,3} {1}" -f $id,$script:AgentRegistry[[string]$id].model) -ForegroundColor $Theme.Info}
    Read-Host "Enter"
}

function Invoke-ConversationCompression {
    Initialize-MatrixAddonStorage
    Clear-Host
    Show-CommandActivation -Command 'compress'
    $src=Read-Host "Conversation/task file (Enter to cancel)"
    if([string]::IsNullOrWhiteSpace($src)){
        Write-Host '[i] No file supplied; compression cancelled safely.' -ForegroundColor $Theme.Warning
        Read-Host 'Enter'; return
    }
    $resolved=Resolve-Path -LiteralPath $src -ErrorAction SilentlyContinue
    if($null -eq $resolved){
        Write-Host "[!] File not found: $src" -ForegroundColor $Theme.Error
        Read-Host 'Enter'; return
    }
    $src=$resolved.Path
    if((Get-Item $src).PSIsContainer){
        Write-Host '[!] Compression expects a conversation/task file, not a folder.' -ForegroundColor $Theme.Error
        Read-Host 'Enter'; return
    }
    $text=Get-Content $src -Raw -ErrorAction SilentlyContinue
    if([string]::IsNullOrWhiteSpace($text)){
        Write-Host '[!] The selected file is empty or unreadable.' -ForegroundColor $Theme.Warning
        Read-Host 'Enter'; return
    }
    $r=Invoke-InstalledAgentQuery -ModelName "nexus-prime" -Prompt "Compress this conversation into a durable context package. Preserve decisions, constraints, unresolved issues, exact file names, important commands, and next actions. Remove repetition.`n$text"
    $out=Join-Path (Split-Path $src -Parent) "compressed_context.md"
    $r.Output|Set-Content $out -Encoding utf8
    $r.Output|Out-Host
    Write-Host "[+] Saved: $out" -ForegroundColor $Theme.Success
    Read-Host "Enter"
}

function Invoke-MemoryRelevance {
    Clear-Host
    Show-CommandActivation -Command 'memorymatch'; Write-Host "MEMORY RELEVANCE ENGINE" -ForegroundColor $Theme.Info
    $task=Read-Host "Current task"; if(!$task){return}
    $files=@(Get-ChildItem $script:MatrixMemoryRoot -File -Filter "*.json" -ErrorAction SilentlyContinue)
    foreach($f in $files){
        $hits=@(Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue | Select-String -SimpleMatch (($task -split '\W+'|Where-Object{$_.Length -ge 5}|Select-Object -First 3) -join " "))
        if($hits){Write-Host "[MATCH] $($f.Name)" -ForegroundColor $Theme.Success}
    }
    Write-Host "Use the Memory Vault to inspect and curate high-value entries." -ForegroundColor $Theme.MutedLight
    Read-Host "Enter"
}

function Invoke-KnowledgeCitations {
    Clear-Host
    Show-CommandActivation -Command 'citations'; Write-Host "KNOWLEDGE CITATION ENGINE" -ForegroundColor $Theme.Info
    $q=Read-Host "Question"; if(!$q){return}
    $index=Join-Path $script:MatrixKnowledgeRoot "index.json"
    if(Test-Path $index){
        $data=Get-Content $index -Raw|ConvertFrom-Json
        $terms=($q.ToLower()-split '\W+'|Where-Object{$_.Length -ge 4}|Select-Object -First 6)
        foreach($row in $data){$hay="$($row.path) $($row.preview)".ToLower(); if($terms|Where-Object{$hay.Contains($_)}|Select-Object -First 1){Write-Host ("[SOURCE] {0}" -f $row.path) -ForegroundColor $Theme.Info}}
    }else{Write-Host "Knowledge index not found. Run knowledge first." -ForegroundColor $Theme.Warning}
    Read-Host "Enter"
}

function Show-KnowledgeFreshness {
    Clear-Host
    Show-CommandActivation -Command 'freshness'; Write-Host "KNOWLEDGE FRESHNESS MONITOR" -ForegroundColor $Theme.Info
    $index=Join-Path $script:MatrixKnowledgeRoot "index.json"
    if(!(Test-Path $index)){Write-Host "No knowledge index found." -ForegroundColor $Theme.Warning;Read-Host "Enter";return}
    $data=Get-Content $index -Raw|ConvertFrom-Json
    foreach($row in $data|Select-Object -First 100){
        $age=(Get-Date)-(Get-Date $row.modified)
        $state=if($age.TotalDays -gt 14){"OUTDATED"}elseif($age.TotalDays -gt 3){"AGING"}else{"CURRENT"}
        Write-Host ("{0,-10} {1}" -f $state,$row.path) -ForegroundColor $(if($state -eq "CURRENT"){$Theme.Success}else{$Theme.Warning})
    }
    Read-Host "Enter"
}

function Start-ProjectWatcher {
    Clear-Host
    Show-CommandActivation -Command 'watch'; Write-Host "PROJECT WATCHER" -ForegroundColor $Theme.Info
    $path=Read-Host "Folder to watch"; if(!(Test-Path $path)){return}
    Write-Host "Watching for 30 seconds. Press Ctrl+C to stop." -ForegroundColor $Theme.Warning
    $fsw=New-Object System.IO.FileSystemWatcher $path -Property @{IncludeSubdirectories=$true;EnableRaisingEvents=$true}
    $handler=Register-ObjectEvent $fsw Changed -Action { Write-Host "[CHANGE] $($Event.SourceEventArgs.FullPath)" -ForegroundColor Cyan }
    Start-Sleep -Seconds 30
    Unregister-Event -SourceIdentifier $handler.Name -ErrorAction SilentlyContinue; $fsw.Dispose()
    Read-Host "Enter"
}

function Show-AgentCapabilityLearning {
    Clear-Host
    Show-CommandActivation -Command 'caplearn'
    Write-Host "AGENT CAPABILITY LEARNING" -ForegroundColor $Theme.Info
    $path=$script:MatrixLearningFile
    if(!(Test-Path $path)){Write-Host "No learning data yet. Run an agent query first." -ForegroundColor $Theme.Muted;Read-Host "Enter";return}
    $filter=Read-Host 'Agent ID or name (Enter for all)'
    $resolved=$null
    if(-not [string]::IsNullOrWhiteSpace($filter)){
        $resolved=Resolve-AgentIdentifier $filter
        if($null -eq $resolved){Write-Host "[!] No registered agent matched '$filter'." -ForegroundColor $Theme.Error;Read-Host "Enter";return}
        $model=[string]$script:AgentRegistry[[string]$resolved].model
        Write-Host ("[+] Resolved: {0} ({1})" -f $resolved,$script:AgentRegistry[[string]$resolved].name) -ForegroundColor $Theme.Success
    }
    try{$d=Get-Content $path -Raw|ConvertFrom-Json}catch{Write-Host "[!] Learning data could not be read: $($_.Exception.Message)" -ForegroundColor $Theme.Error;Read-Host "Enter";return}
    $shown=0
    if($d.agents){
        $d.agents.psobject.Properties|ForEach-Object{
            if($resolved -and [string]$_.Name -ne $model){return}
            $avg=[math]::Round($_.Value.total_ms/[math]::Max(1,[int]$_.Value.runs),0)
            Write-Host ("{0,-28} runs={1,3} success={2,3} avgMs={3}" -f $_.Name,$_.Value.runs,$_.Value.success,$avg) -ForegroundColor $Theme.MutedLight
            $shown++
        }
    }
    if($shown -eq 0){Write-Host "No capability-learning record matched the selected agent." -ForegroundColor $Theme.Warning}
    Read-Host "Enter"
}

function Show-AgentPairings {
    Clear-Host
    Show-CommandActivation -Command 'pairings'; Write-Host "AGENT PAIRING ENGINE" -ForegroundColor $Theme.Info
    $pairs=@(
        "debugger + runtime","software-architect + security-architect","researcher + fact-checker",
        "data-scientist + data-visualizer","platform-engineer + site-reliability-engineer",
        "rag-engineer + knowledge-engineer","product-manager + ux-researcher","test-engineer + debugger"
    )
    $pairs|ForEach-Object{Write-Host "  $_" -ForegroundColor $Theme.Info}
    Write-Host "These pairings seed Nexus; historical learning may refine them over time." -ForegroundColor $Theme.MutedLight
    Read-Host "Enter"
}

function Invoke-MissionCheckpoint {
    Initialize-MatrixWave2Storage; Clear-Host
    Show-CommandActivation -Command 'checkpoint'; Write-Host "MISSION CHECKPOINTS" -ForegroundColor $Theme.Info
    $task=Read-Host "Task / mission name"; if(!$task){return}
    $id='cp_'+(Get-Date -Format "yyyyMMdd_HHmmss")
    $path=Join-Path $script:MatrixCheckpointsRoot "$id.json"
    [ordered]@{id=$id;task=$task;timestamp=(Get-Date).ToString("o");workspace=$global:ActiveTaskWorkspace;status="checkpoint"}|ConvertTo-Json|Set-Content $path -Encoding utf8
    Write-Host "[+] Checkpoint saved: $path" -ForegroundColor $Theme.Success
    Read-Host "Enter"
}

function Invoke-MissionReplay {
    Clear-Host
    Show-CommandActivation -Command 'replay'; Write-Host "MISSION REPLAY" -ForegroundColor $Theme.Info
    $path=Read-Host "Task workspace or replay file"; if(!(Test-Path $path)){return}
    $files=@(Get-ChildItem $path -File -ErrorAction SilentlyContinue)
    foreach($f in $files|Sort-Object LastWriteTime){Write-Host ("{0:HH:mm:ss}  {1}" -f $f.LastWriteTime,$f.Name) -ForegroundColor $Theme.MutedLight}
    Write-Host "Replay view lists the recorded artifacts in execution order." -ForegroundColor $Theme.InfoDim
    Read-Host "Enter"
}


# 51. Incident Playbook Generator
function Invoke-IncidentPlaybookGenerator {
    Clear-Host
    Show-CommandActivation -Command 'incident'
    Write-Host 'INCIDENT PLAYBOOK GENERATOR' -ForegroundColor $Theme.Info
    $scenario = Read-Host 'Describe the incident/scenario'
    if ([string]::IsNullOrWhiteSpace($scenario)) { return }
    $model = if ($map.Values -contains 'incident-commander') { 'incident-commander' } else { 'nexus-prime' }
    $prompt = "Create an operational incident playbook for this scenario. Include detection, severity, roles, containment, stabilization, communications, evidence capture, recovery, validation, and post-incident review. Do not invent system-specific facts; label assumptions.`nSCENARIO:`n$scenario"
    $r = Invoke-InstalledAgentQuery -ModelName $model -Prompt $prompt -TrackLearning
    $r.Output | Out-Host
    $saveRoot = if ($global:ActiveTaskWorkspace -and (Test-Path $global:ActiveTaskWorkspace)) { $global:ActiveTaskWorkspace } else { $script:MatrixMissionRoot }
    if (-not (Test-Path $saveRoot)) { New-Item -ItemType Directory -Path $saveRoot -Force | Out-Null }
    $path = Join-Path $saveRoot ('incident_playbook_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.md')
    $r.Output | Set-Content $path -Encoding utf8
    Write-Host "[+] Playbook saved: $path" -ForegroundColor $Theme.Success
    Read-Host 'Enter'
}

# 52. Test Matrix Builder
function Invoke-TestMatrixBuilder {
    Clear-Host
    Show-CommandActivation -Command 'testmatrix'
    Write-Host 'TEST MATRIX BUILDER' -ForegroundColor $Theme.Info
    $subject = Read-Host 'Feature, file, component, or task to test'
    if ([string]::IsNullOrWhiteSpace($subject)) { return }
    $model = if ($map.Values -contains 'test-architect') { 'test-architect' } else { 'nexus-prime' }
    $prompt = "Build a professional test matrix for: $subject`nCover functional, negative, boundary, integration, performance, security, recovery, and regression cases as applicable. Include ID, purpose, preconditions, steps, expected result, priority, and automation recommendation."
    $r = Invoke-InstalledAgentQuery -ModelName $model -Prompt $prompt -TrackLearning
    $r.Output | Out-Host
    $saveRoot = if ($global:ActiveTaskWorkspace -and (Test-Path $global:ActiveTaskWorkspace)) { $global:ActiveTaskWorkspace } else { $script:MatrixKnowledgeRoot }
    if (-not (Test-Path $saveRoot)) { New-Item -ItemType Directory -Path $saveRoot -Force | Out-Null }
    $path = Join-Path $saveRoot ('test_matrix_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.md')
    $r.Output | Set-Content $path -Encoding utf8
    Write-Host "[+] Test matrix saved: $path" -ForegroundColor $Theme.Success
    Read-Host 'Enter'
}

# 53. Secure Change Journal
function Invoke-SecureChangeJournal {
    Initialize-MatrixAddonStorage
    Clear-Host
    Show-CommandActivation -Command 'journal'
    Write-Host 'SECURE CHANGE JOURNAL' -ForegroundColor $Theme.Info
    $journal = Join-Path $script:MatrixDataRoot 'change_journal.jsonl'
    Write-Host '[1] Add change entry' -ForegroundColor $Theme.Warning
    Write-Host '[2] View recent entries' -ForegroundColor $Theme.Warning
    Write-Host '[3] Verify journal hash chain' -ForegroundColor $Theme.Warning
    Write-Host '[4] Return' -ForegroundColor $Theme.Warning
    $choice = Read-Host 'Select'
    switch ($choice) {
        '1' {
            $change = Read-Host 'Change description'
            if ([string]::IsNullOrWhiteSpace($change)) { return }
            $author = Read-Host 'Author/agent'
            $prevHash = ''
            $lines = @()
            if (Test-Path $journal) { $lines = @(Get-Content $journal -ErrorAction SilentlyContinue); if ($lines.Count -gt 0) { try { $prevHash = ([string]($lines[-1] | ConvertFrom-Json).hash) } catch {} } }
            $payload = "$(Get-Date -Format o)|$author|$change|$prevHash"
            $hashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))
            $hash = [BitConverter]::ToString($hashBytes).Replace('-','')
            [ordered]@{timestamp=(Get-Date).ToString('o');author=$author;change=$change;previous_hash=$prevHash;hash=$hash}|ConvertTo-Json -Compress|Add-Content -Path $journal -Encoding utf8
            Write-Host "[+] Journal entry recorded: $hash" -ForegroundColor $Theme.Success
            Read-Host 'Enter'
        }
        '2' {
            if (Test-Path $journal) { Get-Content $journal -Tail 25 | ForEach-Object { $_ | Out-Host } } else { Write-Host '[i] Journal is empty.' -ForegroundColor $Theme.Muted }
            Read-Host 'Enter'
        }
        '3' {
            $lines = if (Test-Path $journal) { @(Get-Content $journal) } else { @() }
            $prev = ''
            $ok = $true
            foreach ($line in $lines) {
                try { $row = $line | ConvertFrom-Json } catch { $ok = $false; break }
                if ([string]$row.previous_hash -ne $prev) { $ok = $false; break }
                $payload = "$($row.timestamp)|$($row.author)|$($row.change)|$($row.previous_hash)"
                $expected = [BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))).Replace('-','')
                if ($expected -ne [string]$row.hash) { $ok = $false; break }
                $prev = [string]$row.hash
            }
            Write-Host ($(if ($ok) { '[+] Journal integrity: VALID' } else { '[!] Journal integrity: FAILED' })) -ForegroundColor $(if ($ok) { $Theme.Success } else { $Theme.Error })
            Read-Host 'Enter'
        }
    }
}

# 54. Context Budget Optimizer
function Invoke-ContextBudgetOptimizer {
    Clear-Host
    Show-CommandActivation -Command 'context'
    Write-Host 'CONTEXT BUDGET OPTIMIZER' -ForegroundColor $Theme.Info
    $text = Read-Host 'Paste prompt/context to estimate'
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $chars = $text.Length
    $estTokens = [math]::Ceiling($chars / 4)
    $limit = [int]$env:OLLAMA_CONTEXT_LENGTH
    if ($limit -le 0) { $limit = 1024 }
    $pct = [math]::Round(($estTokens / [math]::Max(1,$limit)) * 100,1)
    Write-Host "Estimated tokens : $estTokens" -ForegroundColor $Theme.Info
    Write-Host "Context limit     : $limit" -ForegroundColor $Theme.Info
    Write-Host "Estimated usage   : $pct%" -ForegroundColor $(if ($pct -le 75) { $Theme.Success } elseif ($pct -le 100) { $Theme.Warning } else { $Theme.Error })
    if ($pct -gt 100) { Write-Host '[!] Context exceeds the current profile. Compress, split, or raise context deliberately.' -ForegroundColor $Theme.Error }
    elseif ($pct -gt 75) { Write-Host '[!] Context is getting tight. Keep the task focused or compress older material.' -ForegroundColor $Theme.Warning }
    else { Write-Host '[+] Context estimate fits the configured budget.' -ForegroundColor $Theme.Success }
    Write-Host "Tip: use 'compress' to create a compact task context before a long run." -ForegroundColor $Theme.MutedLight
    Read-Host 'Enter'
}

# 55. Agent Skill Gap Analyzer
function Invoke-AgentSkillGapAnalyzer {
    Clear-Host
    Show-CommandActivation -Command 'skillgap'
    Write-Host 'AGENT SKILL GAP ANALYZER' -ForegroundColor $Theme.Info
    $task = Read-Host 'Describe the task/capability needed'
    if ([string]::IsNullOrWhiteSpace($task)) { return }
    $words = @($task.ToLower() -split '\W+' | Where-Object { $_.Length -ge 5 } | Select-Object -First 40)
    $rows = @()
    foreach ($id in ($script:AgentRegistry.Keys | Sort-Object {[int]$_})) {
        $e = $script:AgentRegistry[[string]$id]
        $hay = "$($e.name) $($e.group) $($e.tag) $($e.summary)".ToLower()
        $score = 0
        foreach ($w in $words) { if ($hay.Contains($w)) { $score++ } }
        if ($score -gt 0) { $rows += [pscustomobject]@{ID=[int]$id;Agent=$e.name;Group=$e.group;Score=$score} }
    }
    $top = @($rows | Sort-Object -Property @{Expression='Score';Descending=$true}, @{Expression='ID';Descending=$false} | Select-Object -First 15)
    if ($top.Count) { $top | Format-Table -AutoSize | Out-Host } else { Write-Host '[i] No direct capability matches were found in the current registry metadata.' -ForegroundColor $Theme.Warning }
    Write-Host ''
    Write-Host 'Potential gaps are terms in the task that do not appear in the current agent metadata.' -ForegroundColor $Theme.MutedLight
    $allMeta = (($script:AgentRegistry.Values | ForEach-Object { "$($_.name) $($_.group) $($_.tag) $($_.summary)" }) -join ' ').ToLower()
    $gaps = @($words | Where-Object { -not $allMeta.Contains($_) } | Select-Object -Unique)
    Write-Host ("Unrepresented capability terms: " + $(if ($gaps.Count) { $gaps -join ', ' } else { 'none detected' })) -ForegroundColor $Theme.Warning
    Read-Host 'Enter'
}

# ============================================================================
# CYPRATEAM MATRIX ADDON WAVE 4 - ADDONS 56 THROUGH 60
# ============================================================================

# 56. Prompt Macro Library
function Invoke-PromptMacroLibrary {
    Initialize-MatrixAddonStorage
    Clear-Host
    Show-CommandActivation -Command 'macro'
    Write-Host 'PROMPT MACRO LIBRARY' -ForegroundColor $Theme.Info
    $macroFile = Join-Path $script:MatrixDataRoot 'macros.json'
    if (-not (Test-Path $macroFile)) { '{}' | Set-Content $macroFile -Encoding utf8 }
    $rawMacros = Get-Content $macroFile -Raw | ConvertFrom-Json
    $macros = @{}
    if ($rawMacros -and $rawMacros.PSObject.Properties.Count -gt 0) { $macros = ConvertTo-CompatHashtable $rawMacros }
    Write-Host '[1] Save macro  [2] Run macro  [3] List macros  [4] Delete macro  [5] Return' -ForegroundColor $Theme.Warning
    $c = Read-Host 'Select'
    switch ($c) {
        '1' {
            $name = Read-Host 'Macro name'
            if ([string]::IsNullOrWhiteSpace($name)) { return }
            $body = Read-Host 'Prompt text (use {PLACEHOLDER} for variables)'
            if ([string]::IsNullOrWhiteSpace($body)) { return }
            $macros[$name] = $body
            ($macros | ConvertTo-Json -Depth 5) | Set-Content $macroFile -Encoding utf8
            Write-Host "[+] Macro '$name' saved." -ForegroundColor $Theme.Success
        }
        '2' {
            if ($macros.Count -eq 0) { Write-Host '[i] No macros saved yet.' -ForegroundColor $Theme.Muted; Read-Host 'Enter'; return }
            $macros.Keys | Sort-Object | ForEach-Object { Write-Host "  - $_" -ForegroundColor $Theme.MutedLight }
            $name = Read-Host 'Macro to run'
            if (-not $macros.ContainsKey($name)) { Write-Host '[!] Macro not found.' -ForegroundColor $Theme.Error; Read-Host 'Enter'; return }
            $body = [string]$macros[$name]
            $tokens = @([regex]::Matches($body, '\{([A-Za-z0-9_]+)\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
            foreach ($t in $tokens) { $val = Read-Host "Value for {$t}"; $body = $body.Replace("{$t}", $val) }
            $model = Read-Host 'Agent model name to run this with (blank = nexus-prime)'
            if ([string]::IsNullOrWhiteSpace($model)) { $model = 'nexus-prime' }
            $r = Invoke-InstalledAgentQuery -ModelName $model -Prompt $body -TrackLearning
            $r.Output | Out-Host
        }
        '3' {
            if ($macros.Count -eq 0) { Write-Host '[i] No macros saved yet.' -ForegroundColor $Theme.Muted }
            else { $macros.Keys | Sort-Object | ForEach-Object { Write-Host "  - $_" -ForegroundColor $Theme.MutedLight } }
        }
        '4' {
            $name = Read-Host 'Macro to delete'
            if ($macros.ContainsKey($name)) {
                $macros.Remove($name)
                ($macros | ConvertTo-Json -Depth 5) | Set-Content $macroFile -Encoding utf8
                Write-Host "[+] Deleted '$name'." -ForegroundColor $Theme.Success
            } else { Write-Host '[!] Macro not found.' -ForegroundColor $Theme.Error }
        }
    }
    Read-Host 'Enter'
}

# 57. Secrets & Credential Scanner
function Invoke-SecretsScanner {
    Clear-Host
    Show-CommandActivation -Command 'secrets'
    Write-Host 'SECRETS & CREDENTIAL SCANNER' -ForegroundColor $Theme.Info
    Write-Host '[1] Scan pasted text  [2] Scan a file  [3] Return' -ForegroundColor $Theme.Warning
    $c = Read-Host 'Select'
    $target = $null
    if ($c -eq '1') { $target = Read-Host 'Paste text to scan' }
    elseif ($c -eq '2') {
        $path = Read-Host 'File path'
        if (Test-Path $path) { $target = Get-Content $path -Raw -ErrorAction SilentlyContinue }
        else { Write-Host '[!] File not found.' -ForegroundColor $Theme.Error; Read-Host 'Enter'; return }
    } else { return }
    if ([string]::IsNullOrWhiteSpace($target)) { Write-Host '[i] Nothing to scan.' -ForegroundColor $Theme.Muted; Read-Host 'Enter'; return }
    $patterns = [ordered]@{
        'AWS Access Key'    = 'AKIA[0-9A-Z]{16}'
        'Generic API Key'   = '(?i)(api[_-]?key|apikey)\s*[:=]\s*[A-Za-z0-9_\-]{16,}'
        'Bearer Token'      = '(?i)bearer\s+[A-Za-z0-9_\-\.]{16,}'
        'Private Key Block' = '-----BEGIN (RSA|EC|OPENSSH|PGP) PRIVATE KEY-----'
        'Slack Token'       = 'xox[baprs]-[A-Za-z0-9-]{10,}'
        'Generic Password'  = '(?i)(password|passwd|pwd)\s*[:=]\s*\S{6,}'
        'Connection String' = '(?i)(mongodb|postgres(?:ql)?|mysql|redis)://\S+'
    }
    $hits = @()
    foreach ($label in $patterns.Keys) {
        $ms = [regex]::Matches($target, $patterns[$label])
        foreach ($m in $ms) {
            $val = if ($m.Value.Length -gt 60) { $m.Value.Substring(0, 60) + '...' } else { $m.Value }
            $hits += [pscustomobject]@{Type = $label; Match = $val}
        }
    }
    if ($hits.Count -eq 0) { Write-Host '[+] No likely secrets detected by the built-in patterns.' -ForegroundColor $Theme.Success }
    else {
        Write-Host "[!] $($hits.Count) possible secret(s) detected:" -ForegroundColor $Theme.Error
        $hits | Format-Table -AutoSize | Out-Host
        Write-Host '[i] Review and redact before sending this content to an agent or committing it.' -ForegroundColor $Theme.Warning
    }
    Read-Host 'Enter'
}

# 58. Multi-Agent Majority Vote
function Invoke-MultiAgentVote {
    Clear-Host
    Show-CommandActivation -Command 'vote'
    Write-Host 'MULTI-AGENT MAJORITY VOTE' -ForegroundColor $Theme.Info
    $question = Read-Host 'Question to put to multiple agents'
    if ([string]::IsNullOrWhiteSpace($question)) { return }
    $modelsRaw = Read-Host 'Comma-separated agent model names to poll (blank = cypra,anomaly,quantum,nexus-prime)'
    $models = @()
    if ([string]::IsNullOrWhiteSpace($modelsRaw)) { $models = @('cypra','anomaly','quantum','nexus-prime') }
    else { $models = @($modelsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($models.Count -lt 2) { Write-Host '[!] Need at least two agents to vote.' -ForegroundColor $Theme.Error; Read-Host 'Enter'; return }
    $answers = @()
    foreach ($m in $models) {
        Write-Host "[*] Asking $m..." -ForegroundColor $Theme.MutedLight
        $r = Invoke-InstalledAgentQuery -ModelName $m -Prompt "Answer concisely and end your reply with a single line 'VERDICT: <your short final answer>'.`nQUESTION:`n$question" -TrackLearning
        $verdict = if ($r.Output -match '(?im)^VERDICT:\s*(.+)$') { $matches[1].Trim() } else { ($r.Output -split "`n" | Select-Object -Last 1) }
        $answers += [pscustomobject]@{Agent = $m; Verdict = $verdict}
        Write-Host "  -> $verdict" -ForegroundColor $Theme.MutedLight
    }
    $answers | Format-Table -AutoSize | Out-Host
    $judgePrompt = "Multiple independent agents answered this question. Identify the majority position (or note there is no majority), summarize the disagreement if any, and give a final recommended answer.`nQUESTION:`n$question`nANSWERS:`n" + (($answers | ForEach-Object { "$($_.Agent): $($_.Verdict)" }) -join "`n")
    $judge = Invoke-InstalledAgentQuery -ModelName 'nexus-prime' -Prompt $judgePrompt -TrackLearning
    Write-Host ''
    Write-Host 'MAJORITY SYNTHESIS:' -ForegroundColor $Theme.Success
    $judge.Output | Out-Host
    Read-Host 'Enter'
}

# 59. Agent Response Benchmark
function Invoke-AgentResponseBenchmark {
    Initialize-MatrixAddonStorage
    Clear-Host
    Show-CommandActivation -Command 'benchmark'
    Write-Host 'AGENT RESPONSE BENCHMARK' -ForegroundColor $Theme.Info
    $model = Read-Host 'Agent model name to benchmark'
    if ([string]::IsNullOrWhiteSpace($model)) { return }
    $prompt = Read-Host 'Prompt to time (blank = short default prompt)'
    if ([string]::IsNullOrWhiteSpace($prompt)) { $prompt = 'Reply with a one-sentence status check.' }
    $r = Invoke-InstalledAgentQuery -ModelName $model -Prompt $prompt -TrackLearning
    $chars = ([string]$r.Output).Length
    $estTokens = [math]::Ceiling($chars / 4)
    $seconds = [math]::Max(0.001, $r.DurationMs / 1000)
    $tps = [math]::Round($estTokens / $seconds, 2)
    Write-Host "Model         : $($r.Model)" -ForegroundColor $Theme.Info
    Write-Host "Duration      : $($r.DurationMs) ms" -ForegroundColor $Theme.Info
    Write-Host "Output length : $chars chars (~$estTokens tokens)" -ForegroundColor $Theme.Info
    Write-Host "Est. speed    : $tps tokens/sec" -ForegroundColor $Theme.Info
    $logPath = Join-Path $script:MatrixAnalyticsRoot 'benchmarks.jsonl'
    [pscustomobject]@{timestamp=(Get-Date).ToString('o');model=$r.Model;duration_ms=$r.DurationMs;est_tokens=$estTokens;tokens_per_sec=$tps} | ConvertTo-Json -Compress | Add-Content $logPath -Encoding utf8
    Write-Host "[+] Benchmark logged: $logPath" -ForegroundColor $Theme.Success
    Read-Host 'Enter'
}

# 60. Session Export Bundle
function Invoke-SessionExportBundle {
    Clear-Host
    Show-CommandActivation -Command 'export'
    Write-Host 'SESSION EXPORT BUNDLE' -ForegroundColor $Theme.Info
    if (-not $global:ActiveTaskWorkspace -or -not (Test-Path $global:ActiveTaskWorkspace)) {
        Write-Host '[!] No active task workspace to export. Start or open a task first.' -ForegroundColor $Theme.Error
        Read-Host 'Enter'; return
    }
    $exportRoot = Join-Path $script:MatrixDataRoot 'Exports'
    if (-not (Test-Path $exportRoot)) { New-Item -ItemType Directory -Path $exportRoot -Force | Out-Null }
    $name = Split-Path -Leaf $global:ActiveTaskWorkspace
    $zipPath = Join-Path $exportRoot ($name + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.zip')
    try {
        Compress-Archive -Path (Join-Path $global:ActiveTaskWorkspace '*') -DestinationPath $zipPath -Force -ErrorAction Stop
        Write-Host "[+] Session bundle exported: $zipPath" -ForegroundColor $Theme.Success
    } catch {
        Write-Host "[!] Export failed: $($_.Exception.Message)" -ForegroundColor $Theme.Error
    }
    Read-Host 'Enter'
}

function Show-AllCommandsPage {
    # This page is the single user-facing command index.  Every command listed
    # here is wired to the main command dispatcher below.  Aliases are shown
    # explicitly so a command copied from this page can be typed directly.
    $pages = @(
        @(
            @{Title='CORE / NAVIGATION'; Items=@(
                '1-700 [ID]            Launch an agent by Node ID; optional prompt follows the ID.';
                'launch / run / agent  Launch a registered agent by ID or name.';
                'commands / cmds       Open this command reference.';
                'h / help              Open Matrix help.';
                'q / exit              Leave the Matrix.';
                'task / tasks          Browse saved task workspaces.';
                'taskview              View the active task workspace.';
                'taskopen / explorer   Open the active task workspace.';
                'out / output / inspect Inspect latest captured output.';
                'hist                  Browse session logs.';
                'stats / stat          Show session/runtime statistics.'
            )};
            @{Title='ORCHESTRATION'; Items=@(
                'nexus / mission       Nexus Mission Control.';
                'pipe                  Sequential multi-agent pipeline.';
                'quad / consensus      Four-agent independent consensus.';
                'debate / debate2      Two-agent adversarial debate + Nexus judge.';
                'find / search         Search the agent registry.';
                'groups / group        Browse agent groups.';
                'map / graph            Show agent relationship map.'
            )}
        );
        @(
            @{Title='NEXUS INTELLIGENCE / ROUTING'; Items=@(
                'routeaudit / routing-audit Explain why agents were selected.';
                'team / teambuilder     Build/store a complementary expert team.';
                'teamrun / team-run / runteam Run the active four-agent team.';
                'teamask / team-ask     Build a new team and run it immediately.';
                'teamshow / active-team Show the currently active team.';
                'teamclear / clearteam  Clear the active team.';
                'capabilities / capability Inspect agent capability profiles.';
                'exclusions / negative  View negative-expertise routing rules.';
                'performance / agentstats View historical agent success/runtime.';
                'replace / replacement  Find replacement specialists.';
                'confidence-report / routeconfidence Show routing-confidence inputs.';
                'routing-test / routingtest Run routing regression tests.';
                'evaluate / eval        Evaluate one agent on a test task.';
                'learn                  View Nexus learning/router analytics.';
                'caplearn               View agent capability learning.'
            )};
            @{Title='MEMORY / KNOWLEDGE'; Items=@(
                'memory / knowledge     Retired. Not a Matrix feature.';
                'memorybridge / bridge  Check memory/knowledge storage.';
                'memorymatch            Find relevant memory.';
                'citations              Search indexed knowledge sources.';
                'freshness              Check knowledge freshness.';
                'compress               Compress a conversation into context.'
            )}
        );
        @(
            @{Title='ENGINEERING / REVIEW'; Items=@(
                'scan                  Project/file intelligence.';
                'review / filereview   Single-agent file review (configurable).';
                'debug                 Autonomous Debugger.';
                'diff                  Review file changes.';
                'verify                Hallucination/verification check.';
                'confidence            Confidence/evidence gate.';
                'evidence              Evidence Locker.';
                'resolve               Contradiction Resolver.';
                'patch                 Minimal patch/diff generator.';
                'test                  Automated Test Runner.';
                'regression            Regression Guard.';
                'depscan               Dependency Scanner.';
                'projecthealth         Project Health Score.'
            )};
            @{Title='MISSION / PLANNING'; Items=@(
                'orchestrate / plan    Build an execution plan.';
                'classifier / classify Classify a task.';
                'summarize / summary  Save a durable task summary.';
                'resume / taskresume  Reconstruct/resume task context.';
                'deps                  Task dependency engine.';
                'risk                  Task Risk Analyzer.';
                'approve               Change Approval Gate.';
                'checkpoint            Save a mission checkpoint.';
                'replay                Review recorded mission artifacts.';
                'incident / playbook  Generate an incident playbook.';
                'testmatrix / test-matrix Build a professional test matrix.';
                'journal / changes    Secure change journal.'
            )}
        );
        @(
            @{Title='WORKSPACE / ADDONS'; Items=@(
                'sandbox               Agent sandbox workspace.';
                'packs                 Specialization packs.';
                'workflows             Workflow templates.';
                'timeline              Task execution timeline.';
                'watch                 Project watcher.';
                'pairings              Agent pairing engine.';
                'skillgap / skill-gap  Agent skill-gap analyzer.';
                'macro / macros        Prompt macro library.';
                'secrets / creds       Secrets/credential scanner.';
                'vote / poll            Multi-agent majority vote.';
                'benchmark / bench     Agent response benchmark.';
                'export / bundle       Session export bundle.';
                'addons / addon / matrix Addon control center.'
            )};
            @{Title='RUNTIME / VRAM / MODELS'; Items=@(
                'hud                   Live GPU / VRAM telemetry.';
                'vram                  VRAM Control Center.';
                'clearvram             Run the local CLEARVRAM.bat VRAM reclaim utility.';
                'queue                 VRAM/runtime queue.';
                'profile               Switch runtime profile.';
                'think / thinking / hidethink  Toggle model thinking display (hide/show reasoning trace).';
                'warm                  Agent warm-pool status.';
                'residency             Smart model residency predictor.';
                'models                Installed-model manager.';
                'pull                  Pull/update configured model dependencies.';
                'audit                 Duplicate/orphan model audit.';
                'integrity             Installed agent/directive integrity.';
                'preflight / check     System/Ollama/VRAM/registry checks.';
                'recover / recovery    Matrix recovery sequence.'
            )}
        );
        @(
            @{Title='SYSTEM / SETTINGS'; Items=@(
                'settings / config     Matrix settings.';
                'theme / colors / colours Customize all UI colors, live.';
                'think / thinking / hidethink  Toggle model thinking display.';
                'bckup / backup        Workspace backup.';
                'resetall / reset-all  Restore Matrix runtime/addon state.';
                'env                   Environment snapshot.';
                'analytics             Resource/performance analytics.';
                'health                Agent health monitor.'
            )}
        )
    )

    # The command loader runs once when the explicit `commands` command is
    # opened. Paging with N/P is instant and does not replay the animation.
    Show-CommandActivation -Command 'commands'
    $page = 0
    while ($true) {
        Clear-Host
        $termWidth = [Math]::Max(78, $Host.UI.RawUI.WindowSize.Width)
        $innerLen = $termWidth - 2
        $line = '═' * $innerLen
        Write-Host "╔$line╗" -ForegroundColor $Theme.Info
        $title = "CYPRATEAM MATRIX COMMAND CENTER  |  PAGE $($page + 1)/$($pages.Count)"
        $title = $title.PadRight([Math]::Min($innerLen,$title.Length))
        if ($title.Length -gt $innerLen) { $title = $title.Substring(0,$innerLen) }
        Write-Host "║$title" -NoNewline -ForegroundColor $Theme.Info
        Write-Host (' ' * [Math]::Max(0,$innerLen-$title.Length)) -NoNewline -ForegroundColor $Theme.Info
        Write-Host '║' -ForegroundColor $Theme.Info
        Write-Host "╠$line╣" -ForegroundColor $Theme.InfoDim
        Write-Host "║ N=Next  P=Previous  Q=Dashboard  Enter=Dashboard  |  Type a command to run it" -ForegroundColor $Theme.MutedLight
        Write-Host "╚$line╝" -ForegroundColor $Theme.Info

        foreach ($section in $pages[$page]) {
            Write-Host ''
            Write-Host ("  $($section.Title)") -ForegroundColor $Theme.Warning
            Write-Host ('  ' + ('─' * [Math]::Min(72,$innerLen-4))) -ForegroundColor $Theme.Muted
            foreach ($item in $section.Items) {
                $parts = $item -split '\s{2,}', 2
                if ($parts.Count -eq 2) {
                    Write-Host ('  ' + $parts[0].PadRight(24) + $parts[1]) -ForegroundColor $Theme.MutedLight
                } else {
                    Write-Host ('  ' + $item) -ForegroundColor $Theme.MutedLight
                }
            }
        }

        Write-Host ''
        Write-Host ("Page $($page+1) of $($pages.Count)   [N]ext  [P]revious  [Q]uit") -ForegroundColor $Theme.Success
        $choice = Read-Host 'Command / navigation'
        $c = ([string]$choice).Trim().ToLower()

        if ([string]::IsNullOrWhiteSpace($c) -or $c -eq 'q' -or $c -eq 'exit') { return }
        if ($c -eq 'n' -or $c -eq 'next') { $page = ($page + 1) % $pages.Count; continue }
        if ($c -eq 'p' -or $c -eq 'prev' -or $c -eq 'previous') { $page = ($page - 1 + $pages.Count) % $pages.Count; continue }

        # Return the typed command to the SAME dispatcher used by Dashboard.
        # This is what makes commands such as "debate" work from this page too.
        return $c
    }
}

function Show-MatrixAddonCenter {
    Clear-Host
    Show-CommandActivation -Command 'addons'
    Write-Host 'CYPRATEAM MATRIX ADDON CENTER' -ForegroundColor $Theme.Info
    Write-Host 'W = workflow (runs an agent or writes files)    P = panel (status / lookup)' -ForegroundColor $Theme.MutedLight
    Write-Host ''
    $items=@(
        'W  1 Mission Control','P  2 Capability Graph','P  3 Memory (retired)','P  4 Knowledge (retired)','W  5 File Intelligence',
        'W  6 Code Review Arena','W  7 Autonomous Debugger','W  8 Agent Sandbox','P  9 Diff Viewer','W 10 Debate',
        'W 11 Confidence / Evidence','W 12 Hallucination Checker','P 13 Agent Health','P 14 VRAM Queue',
        'P 15 Existing Model Resolver','W 16 Directive Integrity','W 17 Install Models Manager','W 18 Duplicate / Orphan Audit',
        'W 19 Task Dependency Engine','P 20 Specialization Packs','W 21 Workflow Templates','P 22 Task Timeline',
        'P 23 Resource Analytics','W 24 Nexus Learning Router','W 25 Task Classifier','W 26 Task Summarizer',
        'W 27 Task Resume Intelligence','W 28 Orchestration Planner','W 29 Evidence Locker','W 30 Contradiction Resolver',
        'P 31 Agent Consensus Scores','W 32 Task Risk Analyzer','P 33 Change Approval Gate','W 34 Patch Generator',
        'P 35 Automated Test Runner','P 36 Regression Guard','P 37 Project Health','P 38 Dependency Scanner',
        'P 39 Environment Snapshot','P 40 Agent Warm Pool','P 41 Residency Predictor','W 42 Conversation Compression',
        'P 43 Memory (retired)','P 44 Knowledge (retired)','P 45 Freshness (retired)','P 46 Project Watcher',
        'P 47 Capability Learning','P 48 Agent Pairings','W 49 Mission Checkpoints','W 50 Mission Replay',
        'W 51 Incident Playbook','W 52 Test Matrix Builder','W 53 Secure Change Journal','W 54 Context Budget Optimizer',
        'W 55 Agent Skill Gap Analyzer','W 56 Prompt Macro Library','W 57 Secrets / Credential Scanner','W 58 Multi-Agent Majority Vote',
        'W 59 Agent Response Benchmark','W 60 Session Export Bundle','W  R Reset All  (settings + leftover data folders)'
    )
    foreach($item in $items){
        $color = $Theme.MutedLight
        if ($item -like 'W*') { $color = $Theme.Info }
        Write-Host ("  " + $item) -ForegroundColor $color
    }
    $c=Read-Host 'Select addon'
    switch($c){
        '1'{Invoke-NexusMissionControl}; '2'{Show-AgentCapabilityGraph}; '3'{Write-Host '[i] Memory is not a Matrix feature.'; Read-Host 'Enter'}; '4'{Write-Host '[i] Knowledge is not a Matrix feature.'; Read-Host 'Enter'}; '5'{Invoke-AgentFileIntelligence};
        '6'{Invoke-CodeReviewArena}; '7'{Invoke-AutonomousDebugger}; '8'{New-AgentSandbox}; '9'{Show-MatrixDiff}; '10'{Invoke-Debate2};
        '11'{Invoke-ConfidenceGate}; '12'{Invoke-HallucinationCheck}; '13'{Show-AgentHealthMonitor}; '14'{Show-VramQueue};
        '15'{$n=Read-Host 'Enter installed agent model name';try{Write-Host (Resolve-ExistingAgentModel $n) -ForegroundColor $Theme.Success}catch{Write-Host $_ -ForegroundColor $Theme.Error};Read-Host 'Enter'};
        '16'{Invoke-DirectiveIntegrity}; '17'{Show-InstallModelsManager}; '18'{Invoke-ModelStorageAudit}; '19'{Invoke-TaskDependencyEngine};
        '20'{Show-SpecializationPacks}; '21'{Show-WorkflowTemplates}; '22'{Show-TaskTimeline}; '23'{Show-ResourceAnalytics}; '24'{Invoke-NexusLearningRouter};
        '25'{Invoke-TaskClassifier}; '26'{Invoke-TaskSummarizer}; '27'{Invoke-TaskResumeIntelligence}; '28'{Invoke-OrchestrationPlanner};
        '29'{Invoke-EvidenceLocker}; '30'{Invoke-ContradictionResolver}; '31'{Show-AgentConsensusScores}; '32'{Invoke-TaskRiskAnalyzer};
        '33'{Invoke-ChangeApprovalGate}; '34'{Invoke-PatchGenerator}; '35'{Invoke-AutomatedTestRunner}; '36'{Invoke-RegressionGuard};
        '37'{Show-ProjectHealth}; '38'{Invoke-DependencyScanner}; '39'{Show-EnvironmentSnapshot}; '40'{Show-AgentWarmPool};
        '41'{Invoke-ResidencyPredictor}; '42'{Invoke-ConversationCompression}; '43'{Write-Host '[i] Memory is not a Matrix feature.'; Read-Host 'Enter'}; '44'{Write-Host '[i] Knowledge is not a Matrix feature.'; Read-Host 'Enter'};
        '45'{Write-Host '[i] Knowledge is not a Matrix feature.'; Read-Host 'Enter'}; '46'{Start-ProjectWatcher}; '47'{Show-AgentCapabilityLearning}; '48'{Show-AgentPairings};
        '49'{Invoke-MissionCheckpoint}; '50'{Invoke-MissionReplay}; '51'{Invoke-IncidentPlaybookGenerator}; '52'{Invoke-TestMatrixBuilder};
        '53'{Invoke-SecureChangeJournal}; '54'{Invoke-ContextBudgetOptimizer}; '55'{Invoke-AgentSkillGapAnalyzer};
        '56'{Invoke-PromptMacroLibrary}; '57'{Invoke-SecretsScanner}; '58'{Invoke-MultiAgentVote};
        '59'{Invoke-AgentResponseBenchmark}; '60'{Invoke-SessionExportBundle}; 'R'{Reset-AllMatrixState}; 'r'{Reset-AllMatrixState}
    }
}

Initialize-MatrixAddonStorage
$null=Update-ModelManifest

# Main Loop
Show-BootSequence
Invoke-MatrixFirstRun
Show-Dashboard
$script:PendingCommand = $null
$script:AnimateNextCommandActivation = $false

while ($true) {
    Write-Host ""
    if ($script:PendingCommand) {
        # Commands selected from the command-reference page execute directly
        # without the Dashboard command loader. Paging remains animation-free.
        $trimmedInput = ([string]$script:PendingCommand).Trim().ToLower()
        $script:PendingCommand = $null
        $script:AnimateNextCommandActivation = $false
        Write-Host ("[>] Dispatching: {0}" -f $trimmedInput) -ForegroundColor $Theme.InfoDim
    } else {
        $rawInput = Read-Host "Select Node ID, or 'q' to quit"
        $trimmedInput = $rawInput.Trim().ToLower()
        $script:AnimateNextCommandActivation = -not [string]::IsNullOrWhiteSpace($trimmedInput)
    }

    if ($trimmedInput -eq 'q' -or $trimmedInput -eq 'exit') {
        Show-CommandActivation -Command 'exit'
        Write-Host "`n[*] Leaving Ollama and currently running model allocations intact." -ForegroundColor $Theme.Info
        Write-Host "Shutting down Matrix... Goodbye!" -ForegroundColor $Theme.Warning
        break
    }

    if ($trimmedInput -eq 'h' -or $trimmedInput -eq 'help') {
        Show-HelpMenu
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'hud') {
        Show-LiveHud
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'task' -or $trimmedInput -eq 'tasks' -or $trimmedInput -eq 'taskview') {
        Show-TaskWorkspace
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'taskopen' -or $trimmedInput -eq 'explorer') {
        Open-TaskWorkspaceExplorer
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'settings' -or $trimmedInput -eq 'config') {
        Show-SettingsMenu
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'theme' -or $trimmedInput -eq 'colors' -or $trimmedInput -eq 'colours') {
        Show-ThemeEditor
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'layout' -or $trimmedInput -eq 'layouts' -or $trimmedInput -eq 'dashboardlayout') {
        Show-LayoutPicker
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'think' -or $trimmedInput -eq 'thinking' -or $trimmedInput -eq 'hidethink') {
        Show-CommandActivation -Command 'think'
        $script:HideModelThinking = -not $script:HideModelThinking
        $state = if ($script:HideModelThinking) { 'HIDDEN (final answer only)' } else { 'VISIBLE (reasoning trace shown)' }
        Write-Host "[+] Model thinking display: $state" -ForegroundColor $Theme.Success
        Start-Sleep -Milliseconds 900
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'stats' -or $trimmedInput -eq 'stat') {
        Show-SessionStats
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'find' -or $trimmedInput -eq 'search') {
        $script:PendingAgentSelection = $null
        Invoke-AgentSearch

        if ($script:PendingAgentSelection) {
            $trimmedInput = $script:PendingAgentSelection
            $script:PendingAgentSelection = $null
        } else {
            Show-Dashboard
            continue
        }
    }

    if ($trimmedInput -eq 'bckup' -or $trimmedInput -eq 'backup') {
        Invoke-WorkspaceBackup
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'profile') {
        Set-MatrixProfile
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'pipe') {
        Invoke-AgentPipeline
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'quad' -or $trimmedInput -eq 'consensus') {
        Invoke-ConsensusPipeline
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'debate' -or $trimmedInput -eq 'debate2') {
        Invoke-NexusTwoAgentDebate
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'hist') {
        Show-LogBrowser
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'groups' -or $trimmedInput -eq 'group') {
        $script:PendingAgentSelection = $null
        Show-AgentGroups

        if ($script:PendingAgentSelection) {
            $trimmedInput = $script:PendingAgentSelection
            $script:PendingAgentSelection = $null
        } else {
            Show-Dashboard
            continue
        }
    }

    if ($trimmedInput -eq 'map' -or $trimmedInput -eq 'graph') {
        Show-AgentRelationshipMap
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'out' -or $trimmedInput -eq 'output' -or $trimmedInput -eq 'inspect') {
        Show-AgentOutputInspector
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'preflight' -or $trimmedInput -eq 'check') {
        Invoke-PreflightCheck
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'recover' -or $trimmedInput -eq 'recovery') {
        Invoke-RecoverySystem
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'vram') {
        Invoke-VramCleanup
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'clearvram' -or $trimmedInput -eq 'clear-vram' -or $trimmedInput -eq 'clearvram.bat') {
        Invoke-ClearVramBat
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'delmodels' -or $trimmedInput -eq 'deletemodels' -or $trimmedInput -eq 'delmodels.bat' -or $trimmedInput -eq 'pull' -or $trimmedInput -eq 'portable' -or $trimmedInput -eq 'portablestatus' -or $trimmedInput -eq 'portable-status' -or $trimmedInput -eq 'store') {
        Show-PortableStoreCenter
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'commands' -or $trimmedInput -eq 'cmds' -or $trimmedInput -eq 'allcommands') {
        $nextCommand = Show-AllCommandsPage
        if ($nextCommand) {
            $script:PendingCommand = $nextCommand
            continue
        } else {
            Show-Dashboard
            continue
        }
    }

    # Explicit launch compatibility: 'launch'/'run'/'agent' are dashboard commands.
    # Resolve the requested target immediately so the alias can never fall through to
    # the generic invalid-selection path. This supports both agent IDs and registered
    # agent names/models.
    if ($trimmedInput -eq 'launch' -or $trimmedInput -eq 'run' -or $trimmedInput -eq 'agent') {
        Show-CommandActivation -Command 'launch'
        Write-Host 'LAUNCH REGISTERED AGENT' -ForegroundColor $Theme.Info
        Write-Host 'Enter an agent ID, registered agent name, or model name.' -ForegroundColor $Theme.Muted
        $launchTarget = (Read-Host 'Agent ID / name').Trim()
        if ([string]::IsNullOrWhiteSpace($launchTarget)) {
            Write-Host '[i] Launch cancelled.' -ForegroundColor $Theme.Muted
            Read-Host 'Enter'
            Show-Dashboard
            continue
        }

        $launchResolvedId = Resolve-AgentIdentifier $launchTarget
        if ($null -eq $launchResolvedId) {
            Write-Host "[!] Agent '$launchTarget' is not registered in the live AgentRegistry." -ForegroundColor $Theme.Error
            Write-Host '[i] Use an agent ID (1-700), registered agent name, or model name.' -ForegroundColor $Theme.Muted
            Read-Host 'Enter'
            Show-Dashboard
            continue
        }

        # Hand the resolved numeric ID to the existing, fully tested launch path.
        $trimmedInput = [string]$launchResolvedId
    }

    if ($trimmedInput -eq 'addons' -or $trimmedInput -eq 'addon' -or $trimmedInput -eq 'matrix') {
        Show-MatrixAddonCenter
        Show-Dashboard
        continue
    }

    if ($trimmedInput -eq 'routeaudit' -or $trimmedInput -eq 'routing-audit') { Invoke-NexusRoutingAudit; Show-Dashboard; continue }
    if ($trimmedInput -eq 'team' -or $trimmedInput -eq 'teambuilder') { Invoke-NexusTeamBuilder; Show-Dashboard; continue }
    if ($trimmedInput -eq 'teamrun' -or $trimmedInput -eq 'team-run' -or $trimmedInput -eq 'runteam') { Invoke-NexusTeamRun; Show-Dashboard; continue }
    if ($trimmedInput -eq 'teamask' -or $trimmedInput -eq 'team-ask') { Invoke-NexusTeamAsk; Show-Dashboard; continue }
    if ($trimmedInput -eq 'teamshow' -or $trimmedInput -eq 'active-team') { Show-NexusActiveTeam -Pause; Show-Dashboard; continue }
    if ($trimmedInput -eq 'teamclear' -or $trimmedInput -eq 'clearteam') { Invoke-NexusTeamClear; Show-Dashboard; continue }
    if ($trimmedInput -eq 'capabilities' -or $trimmedInput -eq 'capability') { Show-AgentCapabilityProfiles; Show-Dashboard; continue }
    if ($trimmedInput -eq 'exclusions' -or $trimmedInput -eq 'negative') { Show-AgentExclusionRules; Show-Dashboard; continue }
    if ($trimmedInput -eq 'performance' -or $trimmedInput -eq 'agentstats') { Show-AgentPerformanceHistory; Show-Dashboard; continue }
    if ($trimmedInput -eq 'replace' -or $trimmedInput -eq 'replacement') { Invoke-AgentReplacementAdvisor; Show-Dashboard; continue }
    if ($trimmedInput -eq 'evaluate' -or $trimmedInput -eq 'eval') { Invoke-AgentEvaluation; Show-Dashboard; continue }
    if ($trimmedInput -eq 'routing-test' -or $trimmedInput -eq 'routingtest') { Invoke-NexusRoutingRegression; Show-Dashboard; continue }
    if ($trimmedInput -eq 'memorybridge' -or $trimmedInput -eq 'bridge' -or $trimmedInput -eq 'memory' -or $trimmedInput -eq 'knowledge' -or $trimmedInput -eq 'rag' -or $trimmedInput -eq 'memorymatch' -or $trimmedInput -eq 'citations' -or $trimmedInput -eq 'freshness') {
        Write-Host "[i] Memory and Knowledge are not part of this Matrix. Chat is a native Ollama session only." -ForegroundColor $Theme.Muted
        Read-Host "Enter"
        Show-Dashboard
        continue
    }
    if ($trimmedInput -eq 'confidence-report' -or $trimmedInput -eq 'routeconfidence') { Invoke-NexusConfidenceReport; Show-Dashboard; continue }

    if ($trimmedInput -eq 'mission' -or $trimmedInput -eq 'nexus') { Invoke-NexusMissionControl; Show-Dashboard; continue }

    if ($trimmedInput -eq 'scan') { Invoke-AgentFileIntelligence; Show-Dashboard; continue }
    if ($trimmedInput -eq 'review' -or $trimmedInput -eq 'filereview' -or $trimmedInput -eq 'areview' -or $trimmedInput -eq 'file-review') { Invoke-AgentFileReview; Show-Dashboard; continue }
    if ($trimmedInput -eq 'debug') { Invoke-AutonomousDebugger; Show-Dashboard; continue }
    if ($trimmedInput -eq 'sandbox') { New-AgentSandbox; Show-Dashboard; continue }
    if ($trimmedInput -eq 'diff') { Show-MatrixDiff; Show-Dashboard; continue }
    if ($trimmedInput -eq 'confidence') { Invoke-ConfidenceGate; Show-Dashboard; continue }
    if ($trimmedInput -eq 'verify') { Invoke-HallucinationCheck; Show-Dashboard; continue }
    if ($trimmedInput -eq 'health') { Show-AgentHealthMonitor; Show-Dashboard; continue }
    if ($trimmedInput -eq 'queue') { Show-VramQueue; Show-Dashboard; continue }
    if ($trimmedInput -eq 'integrity') { Invoke-DirectiveIntegrity; Show-Dashboard; continue }
    if ($trimmedInput -eq 'models') { Show-PortableStoreCenter; Show-Dashboard; continue }
    if ($trimmedInput -eq 'audit') { Invoke-ModelStorageAudit; Show-Dashboard; continue }
    if ($trimmedInput -eq 'deps') { Invoke-TaskDependencyEngine; Show-Dashboard; continue }
    if ($trimmedInput -eq 'packs') { Show-SpecializationPacks; Show-Dashboard; continue }
    if ($trimmedInput -eq 'workflows') { Show-WorkflowTemplates; Show-Dashboard; continue }
    if ($trimmedInput -eq 'timeline') { Show-TaskTimeline; Show-Dashboard; continue }
    if ($trimmedInput -eq 'analytics') { Show-ResourceAnalytics; Show-Dashboard; continue }
    if ($trimmedInput -eq 'learn') { Invoke-NexusLearningRouter; Show-Dashboard; continue }
    if ($trimmedInput -eq 'classifier' -or $trimmedInput -eq 'classify') { Invoke-NexusTaskClassifier; Show-Dashboard; continue }
    if ($trimmedInput -eq 'summarize' -or $trimmedInput -eq 'summary') { Invoke-TaskSummarizer; Show-Dashboard; continue }
    if ($trimmedInput -eq 'resume' -or $trimmedInput -eq 'taskresume') { Invoke-TaskResumeIntelligence; Show-Dashboard; continue }
    if ($trimmedInput -eq 'orchestrate' -or $trimmedInput -eq 'plan') { Invoke-OrchestrationPlanner; Show-Dashboard; continue }
    if ($trimmedInput -eq 'evidence') { Invoke-EvidenceLocker; Show-Dashboard; continue }
    if ($trimmedInput -eq 'resolve') { Invoke-ContradictionResolver; Show-Dashboard; continue }
    if ($trimmedInput -eq 'consensus-scores') { Show-AgentConsensusScores; Show-Dashboard; continue }
    if ($trimmedInput -eq 'risk') { Invoke-TaskRiskAnalyzer; Show-Dashboard; continue }
    if ($trimmedInput -eq 'approve') { Invoke-ChangeApprovalGate; Show-Dashboard; continue }
    if ($trimmedInput -eq 'patch') { Invoke-PatchGenerator; Show-Dashboard; continue }
    if ($trimmedInput -eq 'test') { Invoke-AutomatedTestRunner; Show-Dashboard; continue }
    if ($trimmedInput -eq 'regression') { Invoke-RegressionGuard; Show-Dashboard; continue }
    if ($trimmedInput -eq 'projecthealth') { Show-ProjectHealth; Show-Dashboard; continue }
    if ($trimmedInput -eq 'depscan') { Invoke-DependencyScanner; Show-Dashboard; continue }
    if ($trimmedInput -eq 'env') { Show-EnvironmentSnapshot; Show-Dashboard; continue }
    if ($trimmedInput -eq 'warm') { Show-AgentWarmPool; Show-Dashboard; continue }
    if ($trimmedInput -eq 'residency') { Invoke-ResidencyPredictor; Show-Dashboard; continue }
    if ($trimmedInput -eq 'compress') { Invoke-ConversationCompression; Show-Dashboard; continue }

    if ($trimmedInput -eq 'watch') { Start-ProjectWatcher; Show-Dashboard; continue }
    if ($trimmedInput -eq 'caplearn') { Show-AgentCapabilityLearning; Show-Dashboard; continue }
    if ($trimmedInput -eq 'pairings') { Show-AgentPairings; Show-Dashboard; continue }
    if ($trimmedInput -eq 'checkpoint') { Invoke-MissionCheckpoint; Show-Dashboard; continue }
    if ($trimmedInput -eq 'replay') { Invoke-MissionReplay; Show-Dashboard; continue }
    if ($trimmedInput -eq 'resetall' -or $trimmedInput -eq 'reset-all') { Reset-AllMatrixState; Show-Dashboard; continue }
    if ($trimmedInput -eq 'incident' -or $trimmedInput -eq 'playbook') { Invoke-IncidentPlaybookGenerator; Show-Dashboard; continue }
    if ($trimmedInput -eq 'testmatrix' -or $trimmedInput -eq 'test-matrix') { Invoke-TestMatrixBuilder; Show-Dashboard; continue }
    if ($trimmedInput -eq 'journal' -or $trimmedInput -eq 'changes') { Invoke-SecureChangeJournal; Show-Dashboard; continue }
    if ($trimmedInput -eq 'context' -or $trimmedInput -eq 'contextbudget') { Invoke-ContextBudgetOptimizer; Show-Dashboard; continue }
    if ($trimmedInput -eq 'skillgap' -or $trimmedInput -eq 'skill-gap') { Invoke-AgentSkillGapAnalyzer; Show-Dashboard; continue }
    if ($trimmedInput -eq 'macro' -or $trimmedInput -eq 'macros') { Invoke-PromptMacroLibrary; Show-Dashboard; continue }
    if ($trimmedInput -eq 'secrets' -or $trimmedInput -eq 'creds') { Invoke-SecretsScanner; Show-Dashboard; continue }
    if ($trimmedInput -eq 'vote' -or $trimmedInput -eq 'poll') { Invoke-MultiAgentVote; Show-Dashboard; continue }
    if ($trimmedInput -eq 'benchmark' -or $trimmedInput -eq 'bench') { Invoke-AgentResponseBenchmark; Show-Dashboard; continue }
    if ($trimmedInput -eq 'export' -or $trimmedInput -eq 'bundle') { Invoke-SessionExportBundle; Show-Dashboard; continue }

    $inputParts = $trimmedInput -split '\s+', 2
    $selection  = $inputParts[0]
    $quickPrompt = if ($inputParts.Count -gt 1) { $inputParts[1] } else { $null }

    if ($selection -match '^(?:[1-9][0-9]{0,2})$' -and $script:AgentRegistry.Contains($selection)) {
        if ($map.ContainsKey($selection)) {
            $registryEntry   = $script:AgentRegistry[[string]$selection]
            $baseTargetModel = [string]$registryEntry.model
            $targetTag       = [string]$registryEntry.tag
            $targetSummary   = [string]$registryEntry.summary
            $targetGroup     = [string]$registryEntry.group
            $targetColor     = [string]$registryEntry.color
            $script:CurrentAgentModel = $baseTargetModel

            # Check if active task workspace exists and change working location
            if ($global:ActiveTaskWorkspace -and (Test-Path $global:ActiveTaskWorkspace)) {
                Set-Location -Path $global:ActiveTaskWorkspace
                Write-Host "[i] Executing agent within Active Workspace: $global:ActiveTaskWorkspace" -ForegroundColor $Theme.Info
            } else {
                Write-Host "[!] No active task loaded. Operating in default directory." -ForegroundColor $Theme.Warning
            }

            Write-Host ""
            Write-Host ("[AGENT LAUNCH] Deploying {0}  |  ID {1}  |  GROUP: {2}" -f $baseTargetModel, $selection, $targetGroup) -ForegroundColor $Theme.Success
            Write-Host "[AGENT LAUNCH] Preparing runtime and releasing prior agent residency if required..." -ForegroundColor $Theme.InfoDim
            Show-BootSequence -Force -ArtFile "agentload.txt" -Fast
            Write-Host "  > MODEL BOOT: $baseTargetModel" -ForegroundColor $Theme.Success
            Start-Sleep -Milliseconds 60
            Show-AgentHeader -model $baseTargetModel -tag $targetTag -summary $targetSummary -color $targetColor
            Write-Host "[GROUP] $targetGroup" -ForegroundColor $Theme.InfoDim

            # Initialize workspace folder if none set globally
            if (-not $global:ActiveTaskWorkspace) {
                $taskPath = Start-TaskWorkspace -AgentId $selection -ModelName $baseTargetModel -Prompt $quickPrompt
            } else {
                $taskPath = $global:ActiveTaskWorkspace
            }

            # Resolve the installed directive-backed agent before touching the
            # scheduler or Ollama. The previous code could swallow a failed
            # resolution and then execute `ollama run` with an empty model,
            # producing the misleading "requires at least 1 arg(s)" error.
            $targetModel = $null
            try {
                $targetModel = Confirm-AndInstallAgent -ModelName $baseTargetModel
                $targetModel = ([string]$targetModel).Trim()
            } catch {
                Write-Host "[!] Agent '$baseTargetModel' could not be made ready: $($_.Exception.Message)" -ForegroundColor $Theme.Error
                Write-Host "[i] Use 'models' or INSTALL_MODELS.bat if the base model is missing." -ForegroundColor $Theme.Warning
                Read-Host "Press Enter to return to Dashboard"
                Show-Dashboard
                continue
            }

            if ([string]::IsNullOrWhiteSpace($targetModel)) {
                Write-Host "[!] Agent resolution returned an empty model name. Launch cancelled safely." -ForegroundColor $Theme.Error
                Read-Host "Press Enter to return to Dashboard"
                Show-Dashboard
                continue
            }

            Invoke-VramAwareScheduler -ModelName $targetModel | Out-Null

            $dynParams = Get-DynamicModelParameters -ModelName $baseTargetModel
            $env:OLLAMA_CONTEXT_LENGTH = [string]$dynParams.ContextLength
            $env:OLLAMA_NUM_PARALLEL = [string]$dynParams.NumParallel
            Write-Host "[i] Profile Config -> Context: $($dynParams.ContextLength) | Parallel: $($dynParams.NumParallel)" -ForegroundColor $Theme.Muted

            if ($script:OllamaCpuFallbackActive) {
                Write-Host "[i] Ollama is in CPU-safe fallback mode for this session." -ForegroundColor $Theme.WarningDim
            }

            $logDir = Join-Path $PSScriptRoot "Logs"
            if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            $timeStamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
            $logFile = Join-Path $logDir "${baseTargetModel}_${timeStamp}.log"

            Write-Host "[i] Session transcript saving to: $logFile" -ForegroundColor $Theme.InfoDim
            Write-MatrixChatHintLine
            Write-Host "  Write a message  ·  /? ollama help  ·  /bye leaves" -ForegroundColor $Theme.Info
            Write-Host "  " -NoNewline
            Write-Host "[+]" -NoNewline -ForegroundColor $Theme.Success
            Write-Host " Native session" -NoNewline -ForegroundColor $Theme.Brand
            Write-Host "  ·  " -NoNewline -ForegroundColor $Theme.Muted
            Write-Host "prompt appears then type" -NoNewline -ForegroundColor $Theme.Info
            Write-Host "  ·  " -NoNewline -ForegroundColor $Theme.Muted
            Write-Host "/bye disconnects" -ForegroundColor $Theme.Accent
            Write-Host ""

            try {
                if ($quickPrompt) {
                    Write-Host ">>> Direct Query: $quickPrompt" -ForegroundColor $Theme.Info
                    Write-Host "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────" -ForegroundColor $Theme.Muted

                    $modePrompt = $quickPrompt
                    if ([string]::IsNullOrWhiteSpace($targetModel)) {
                        throw "Launch blocked: target model resolved to an empty value."
                    }
                    $response = Invoke-OllamaRun -Model $targetModel -Prompt $modePrompt
                    $runExitCode = $LASTEXITCODE
                    $response | Out-Host

                    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [QUERY] $quickPrompt" | Out-File -FilePath $logFile -Append -Encoding utf8
                    $response | Out-File -FilePath $logFile -Append -Encoding utf8
                    $response | Out-File -FilePath (Join-Path $taskPath "result.txt") -Encoding utf8

                    if ($global:ActiveTaskWorkspace) {
                        $taskLogFile = Join-Path $global:ActiveTaskWorkspace "chat_history.txt"
                        "User: $quickPrompt`nAgent ($targetModel): $response`n---" | Out-File -FilePath $taskLogFile -Append -Encoding utf8
                    }

                    if ($runExitCode -eq 0 -and ([string]$response) -notmatch '(?i)out of memory|CUDA error') {
                        Save-AgentRunOutcome -ModelName $targetModel -UserPrompt $quickPrompt -Response ([string]$response) -Source "direct-query"
                    }

                    if ($runExitCode -ne 0 -or ($response -match '(?i)out of memory|CUDA error')) {
                        Invoke-CpuFallbackReset -FailureMessage "[!] Ollama reported a GPU memory allocation failure." -FullReset

                        if ([string]::IsNullOrWhiteSpace($targetModel)) {
                            throw "CPU fallback blocked: target model resolved to an empty value."
                        }
                        $response = Invoke-OllamaRun -Model $targetModel -Prompt $modePrompt
                        $runExitCode = $LASTEXITCODE
                        $response | Out-Host
                        $response | Out-File -FilePath $logFile -Append -Encoding utf8
                        $response | Out-File -FilePath (Join-Path $taskPath "result.txt") -Append -Encoding utf8

                        if ($global:ActiveTaskWorkspace) {
                            $taskLogFile = Join-Path $global:ActiveTaskWorkspace "chat_history.txt"
                            "User: $quickPrompt`nAgent ($targetModel) [CPU Fallback]: $response`n---" | Out-File -FilePath $taskLogFile -Append -Encoding utf8
                        }
                        if ($runExitCode -eq 0) {
                            Save-AgentRunOutcome -ModelName $targetModel -UserPrompt $quickPrompt -Response ([string]$response) -Source "direct-query-cpu-fallback"
                        }
                    }

                    Write-Host ""
                    Read-Host "Press Enter to return to Dashboard..."
                } else {
                    $runExitCode = Invoke-MatrixInteractiveChat -ModelName $targetModel -LogFile $logFile -TaskPath $taskPath -ContextLength ([int]$dynParams.ContextLength)
                }

                if ($runExitCode -eq 0) {
                    Register-NewAgentActivation -ModelName $targetModel
                }

                if ($runExitCode -ne 0) {
                    Write-Host "[!] Execution Error: Failed to run agent '$targetModel' (exit code $runExitCode)." -ForegroundColor $Theme.Error
                }
            }
            catch {
                Write-Host "[!] Execution Error: Failed to run agent '$targetModel'." -ForegroundColor $Theme.Error
                if ($_.Exception -and $_.Exception.Message) {
                    Write-Host ("    {0}" -f $_.Exception.Message) -ForegroundColor $Theme.Muted
                }
            }

            if ($taskPath -and (Test-Path $taskPath)) {
                $completion = [ordered]@{
                    completed = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                    exit_code = [int]$runExitCode
                    status = if ($runExitCode -eq 0) { "complete" } else { "failed" }
                }
                $completion | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $taskPath "status.json") -Encoding utf8
                Write-Host "[TASK] Output saved to workspace. Use 'out' to inspect it." -ForegroundColor $Theme.InfoDim
            }

            Read-Host "Enter to return to Dashboard"
            Show-Dashboard
        }
    } else {
        Write-Host "[!] Invalid selection! Please enter a valid Node Agent ID or command keyword." -ForegroundColor $Theme.Error
        Start-Sleep -Seconds 1
        Show-Dashboard
    }
}
