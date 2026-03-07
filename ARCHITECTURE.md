# Architecture

## Layered Structure

- `Domain`
  - Mission state, statuses, settings, models, API keys.
- `Services`
  - `SettingsStore`: persists `Settings.json`.
  - `StateStore`: persists `State.json`.
  - `KeychainService`: stores API keys in Keychain and falls back to `Secrets.json`.
  - `FileBridgeService`: manages inbox/processing/completed file operations.
  - `CLIRunner`: executes CLI tools (claude, codex, gemini, ollama) for model calls.
  - `PythonRunner`: executes bundled Python bridge for API-based model calls (fallback).
- `ViewModels`
  - `MissionControlViewModel`: orchestrates polling, mission lifecycle, persistence, and UI state.
- `Views`
  - `MissionControlView`, `SettingsView`, `RootView`.

## Mission Lifecycle

1. Poller reads `.txt` files from `01_Inbox`.
2. Files move to `02_Processing`.
3. Manager plan is generated through CLI or Python bridge using selected manager model.
4. Mission enters `awaitingApproval`.
5. On approval, mission executes where worker drafts and manager synthesizes final output.
6. Result artifact (`*_result.md`) is written to `03_Completed`.
7. Instruction file is archived to `03_Completed`.
8. `State.json` is updated with final status.

## Execution Modes

### CLI Mode (Default)
- Uses local CLI tools: `claude`, `codex`, `gemini`, `ollama`
- Manager model config determines which CLI to use
- No API keys needed for Ollama
- Claude/Codex/Gemini CLI use their own authentication

### API Mode (Legacy)
- Uses Python bridge for direct API calls
- Requires API keys for: Anthropic, Gemini, MiniMax, OpenAI/Codex

## Data Persistence

- `~/AgentBox/Settings.json`
  - Model selection, polling interval, directories, CLI mode flag.
- `~/AgentBox/State.json`
  - Mission records and last poll timestamp.
- Keychain service `com.agentbox.credentials`
  - `claude`, `gemini`, `minimax`, `codex`, `openai` API keys.
- `~/AgentBox/Secrets.json` (fallback only)
  - Same API keys persisted with `0600` permissions when keychain fails.

## Model Configuration

The app supports multiple model providers:
- `ModelProvider` enum defines all supported providers
- Each provider has different execution requirements:
  - CLI tools: Require executable in PATH
  - API-based: Require API keys
  - Ollama: Local execution, no API key needed

## Extension Points

- Add stronger provider-specific retry/backoff and quota-aware routing.
- Add LaunchAgent-based scheduling for true background execution.
- Add richer mission metadata (worker logs, timing, retries, cost telemetry).
- Support more CLI tools and local models.
