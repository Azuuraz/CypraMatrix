# CypraMatrix

**A portable command deck for local multi-agent AI — on your hardware, in your folder, under your control.**

[Windows] [Ollama] [PowerShell] [700 agents] [6 GB VRAM] [localhost :11435]

Most people install Ollama, run one model, and chat. That is a start. It is not a shop.

CypraMatrix is the layer that comes next: **specialists with real directives**, routing that scores the *problem*, pipelines and debates, a **project-local model store**, and honest behavior on a 6–8 GB card. No cloud account. No second “global” Ollama hiding your weights.

> **CYPRATEAM** · Portable AI Development Infrastructure · v1.4

---

## Why this exists

```text
Install Ollama → run a model → chat
```

Fine — until you need a medic and a packet sleuth on the same machine, a repeatable debate, or a store you can copy to another PC without mixing it into the host’s models.

CypraMatrix is an **operating layer**, not another chatbot skin:

- Directives live in Modelfiles. Profiles change *runtime*, not identity.
- Nexus Prime routes by domain and task — not by the prettiest name.
- Models stay in `.\OllamaModels` on **127.0.0.1:11435**. The host Ollama stays global.
- You decide when to pull, register, or delete. Boot never silently rewrites the fleet.

Local-first. Operator in the chair. Core work does not need the internet.

---

## What you get

| Capability | Detail |
| --- | --- |
| **700 agents** | Embedded registry (IDs 1–700). Groups, tags, search, capability map. |
| **Nexus Prime routing** | Scores domain, specialty, tags, verbs, terminology, and VRAM fit. Auto-picks a Quad if you leave the team blank. |
| **Workflows** | `pipe` (sequential), `quad` / `consensus` (independent then synthesize), `debate` (two agents, Nexus judges). |
| **Directive-first identity** | Each agent is an Ollama Modelfile. Change profile without rewriting the persona. |
| **Portable models** | `.\OllamaModels` only. Host store is ignored. One page in the Matrix: status, pull, delete (`portable`). |
| **VRAM-aware runtime** | HUD, headroom estimates, Low-VRAM / Turbo / CPU-Only. Conservative parallel = 1. |
| **On-demand register** | Pick an ID → create from the local Modelfile. No need to `ollama create` all 700 first. |
| **Fleet tools** | `INSTALL_MODELS.bat` is for new PCs and fleet jobs: status, pull base, Core four, register all, or rebuild onto a new base. |
| **Task workspaces** | Per-run folders for prompts, output, transcripts. |
| **Themes & layouts** | Live color editor, presets, and decks (Classic through Quiet / Focus). Theme and layout are separate. |
| **Addons** | Mission, review, integrity, VRAM, benchmarks, and operator panels. Marked **W** (workflow) or **P** (panel). Memory/Knowledge vaults are **not** a product feature. |

Agents share **one base model**. Specialization is the SYSTEM directive — that is how 700 names stay portable on a 6 GB card.

---

## Architecture

```text
                    Operator
                        |
                   CypraMatrix
                        |
         +--------------+--------------+
         |              |              |
      Agents         Routing        Models
         |              |              |
   Modelfiles      Nexus Prime     Ollama
   (identity)      (coordination)  :11435 + .\OllamaModels
         |              |              |
         +--------------+--------------+
                        |
              GPU / VRAM / CPU / RAM
```

**Identity** is the directive. **Runtime** is profile, context, layout. Changing one does not quietly rewrite the other.

Copy the folder. Scripts resolve the project root from their own location. Empty store → first-run menu, or pick an ID and confirm create. See `PORTABLE.txt`.

---

## Multi-agent workflows

| Workflow | Command | What it does |
| --- | --- | --- |
| **Pipeline** | `pipe` | Chain agents (min 2, max 5). Each stage refines the last. |
| **Consensus / Quad** | `quad` / `consensus` | Same problem to independent specialists → Nexus synthesizes. Blank IDs = auto four. |
| **Debate** | `debate` | Two specialists, two rounds. **Nexus is the only judge.** |

Route automatically or pick IDs by hand. You stay in charge.

---

## Model & portable contract

1. Ollama **binary** stays on the host (`PATH`).
2. CypraMatrix uses **only** `.\OllamaModels`.
3. Endpoint: **`127.0.0.1:11435`** (localhost on purpose).
4. Register is explicit. Boot does not mass-create agents.
5. Valid existing models are reused.
6. Full portable wipe needs **`DELETE PORTABLE`**. Host global store is left alone.
7. Workspace backups **skip** `OllamaModels`.

Marker: `.cypra_portable_store` in the project model directory.

**Current defaults**

| Setting | Value |
| --- | --- |
| Fleet base | `huihui_ai/gemma-4-abliterated:e4b` |
| Registry | **700** agents |
| Profile | `Low-VRAM 6GB` |
| Context | **1024** (live window; Turbo up to 4096) |
| Keep-alive | `5m` |
| Core | `cypra`, `anomaly`, `quantum`, `nexus-prime` |
| Engine | `OLLAMA_NUM_PARALLEL=1`, single-stream |

Modelfiles are the source of truth for `FROM`. Chat is a **native `ollama run`** in the same window. Wait for `>>> Send a message`, then type. `/bye` returns to the deck.

Pick an unregistered ID → the Matrix offers to create it from the local Modelfile (and pull the base if needed).

---

## Runtime profiles

| Profile | Typical context | Intent |
| --- | --- | --- |
| **Low-VRAM 6GB** | 1024 | Default. Honest on constrained cards. |
| **Turbo / High-Context** | up to 4096 | When free VRAM allows. |
| **CPU-Only Offline** | 2048 | When the GPU is gone. |

`hud` — GPU name, driver, used/free VRAM, temperature, utilization, loaded models.

`clearvram` — unload GPU models or restart the portable engine (does not delete weights). Explorer restart is last-resort only.

---

## Command surface

| Command | Purpose |
| --- | --- |
| `1`–`700` | Launch agent (optional prompt after the ID) |
| `h` / `help` | Operator help |
| `commands` | Full command index |
| `q` / `exit` | Leave Matrix (Ollama stays up) |
| `find` / `search` | Search the roster |
| `groups` / `map` | Groups and relationship map |
| `pipe` · `quad` · `debate` | Orchestration |
| `nexus` / `mission` | Mission Control |
| `theme` / `layout` / `profile` | Look, deck structure, VRAM profile |
| `hud` · `vram` · `clearvram` | Telemetry and GPU reclaim |
| `portable` · `pull` · `models` · `delmodels` | **One store page:** status, pull, delete agents or all |
| `preflight` · `recover` | Checks and non-destructive repair |
| `addons` | Service center (W = workflow, P = panel) |
| `task` / `tasks` · `out` | Workspaces and last output |
| `bckup` | Workspace zip (skips weights) |
| `resetall` | Restore runtime defaults (does **not** delete fleet models) |

Type a command from `commands` — same dispatcher as the dashboard.

---

## Add-on Center

Mission, engineering, verification, VRAM, benchmarks, operator panels. Some items **run work**. Some **show live state**. Both are labeled.

Memory Vault / Knowledge RAG are **retired** in this tree. Chat does not load a Matrix memory vault.

---

## Layout

```text
CypraMatrix/
├── README.md
├── PORTABLE.txt
├── launch_chat.ps1           # Deck, routing, workflows
├── START_CHAT_MATRIX.bat     # Launch
├── INSTALL_MODELS.bat        # Fleet tools (status / pull / Core / all / rebuild)
├── modinstall.ps1
├── INSTALL_AGENT.ps1         # One existing Modelfile
├── CLEARVRAM.bat / clearvram.ps1
├── DELMODELS.bat / delmodels.ps1
├── PORTABLE_STATUS.bat
├── CREATE_SHORTCUT.bat
├── MatrixConfig.json
├── ThemeConfig.json
├── boot.txt / agentload.txt / commandload.txt
├── Modfiles/                 # 700 directives + manifest.json
├── OllamaModels/             # Weights + .cypra_portable_store
├── MatrixData/               # Created on use
├── Tasks/   Logs/   Icons/   Backups/
```

`Logs`, `Tasks`, and `MatrixData` are created as needed.

---

## Quick start

**Need:** Windows 10/11, PowerShell 5.1 or 7, [Ollama](https://ollama.com) on `PATH`.

```cmd
START_CHAT_MATRIX.bat
```

First launch with an empty store: follow the first-run menu, or pick an agent ID and confirm create.

Fleet jobs (new PC, pull base, register Core or all):

```cmd
INSTALL_MODELS.bat
```

Shortcut:

```cmd
CREATE_SHORTCUT.bat
```

Store status from Explorer:

```cmd
PORTABLE_STATUS.bat
```

Same status inside the Matrix: `portable`.

---

## Design principles

- **Local-first** — your machine, your card.
- **Portable** — weights, directives, tasks, and logs live in this tree.
- **Directive-driven** — identity in Modelfiles.
- **Runtime-layered** — profile and layout without a persona swap.
- **Task-aware** — route to the problem.
- **VRAM-honest** — measure; trim or CPU before a silent crash.
- **Explicit** — pull, register, and delete are operator decisions.
- **Honest UI** — workflows and panels are labeled; unused features are not sold.

---

## Validate a build

1. **Routing** — mixed-domain prompts; auto-quad vs manual.
2. **Directives** — open an agent, switch profile, identity holds.
3. **Models** — `portable` → pull, on-demand create, `delmodels` agents-only vs all.
4. **VRAM** — `hud`, `clearvram` unload, Low-VRAM vs CPU-Only.
5. **Workspaces** — run a task; backup skips `OllamaModels`.
6. **UI** — `theme`, `layout` (including Quiet / Focus), `help`.
7. **Registry** — preflight reports **700** agents.

---

## Troubleshooting

| Symptom | Action |
| --- | --- |
| `ollama` not found | Install Ollama; confirm `PATH`. |
| Agent not registered | Pick the ID and confirm create, or `INSTALL_MODELS.bat` → Register Core / All. |
| VRAM / CUDA | Smaller base, context 1024, Low-VRAM, `clearvram`, or CPU-Only. |
| Chat returns to dashboard immediately | Use the current launcher; native `ollama run` must stay in-window. `/bye` is a normal leave, not a crash. |
| Config / theme missing | Launch once. JSON is rewritten from defaults. |
| Parse errors after edits | Keep hashtables and `switch` blocks valid; save as UTF-8 with BOM. |

---

## Distribution zip

Ships **scripts + 700 Modelfiles + icons + default config**. Does **not** include:

- `OllamaModels` weights
- Live `Logs`, `Tasks`, `MatrixData`
- Nested `Backups`

After unzip: Ollama on `PATH` → `START_CHAT_MATRIX.bat` (or `INSTALL_MODELS.bat` for fleet jobs). Weights pull locally so the archive stays small.

---

## Security notes

- Bound to **localhost :11435**. Do not publish that port.
- To block inbound access (Admin PowerShell):

```powershell
New-NetFirewallRule -DisplayName "Block External Cypra Ollama Port" -Direction Inbound -LocalPort 11435 -Protocol TCP -Action Block
```

- Portable store ≠ host global store.
- CypraMatrix orchestrates Ollama; it does not replace it.

---

## License & responsibility

This repo is orchestration for **local** Ollama. Models have their own licenses — read them before you pull. Output quality depends on model, hardware, and prompt. For anything that matters, check the result yourself.

---

Built for people who want a shop, not just a chat box — and who would rather own the machine than rent the model.
