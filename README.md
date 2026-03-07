# AgentBox

A native macOS app for orchestrating AI agents with configurable models.

## Overview

AgentBox is a task orchestration system that uses a Manager-Worker pattern:
- **Manager Agent**: Plans tasks and coordinates execution
- **Worker Agents**: Execute subtasks in parallel

The app monitors folders for incoming tasks and provides a Mission Control UI for monitoring progress.

## Features

- **Multi-Model Support**: Configure Manager and Worker models independently
- **CLI Integration**: Use Claude Code CLI, Codex CLI, Gemini CLI, or Ollama
- **Local Models**: Run Ollama models locally (no API key needed)
- **API Support**: Direct API calls to Anthropic, Google Gemini, OpenAI/Codex, MiniMax
- **Dark Mode**: Native macOS dark theme
- **Folder-Based Workflow**: Drop tasks in Inbox, review plans, approve execution

## Supported Models

### CLI Tools (Recommended - Default)
- `claude-cli` - Claude Code CLI (uses your Claude subscription)
- `codex-cli` - Codex CLI (uses your Codex subscription)
- `gemini-cli` - Gemini CLI (uses your Google account)
- `ollama llama3.3` - Ollama (local, no API key needed)
- `ollama qwen2.5-coder` - Ollama (local, no API key needed)

### API-Based (Legacy Mode)
- `anthropic sonnet` - Anthropic Claude Sonnet
- `anthropic haiku` - Anthropic Claude Haiku
- `google gemini` - Google Gemini
- `minimax2.5` - MiniMax
- `codex` - OpenAI Codex

## Installation

1. Build the app:
   ```bash
   swift build -c release
   ```

2. The app bundle is created at `AgentBox.app`

3. Or run directly:
   ```bash
   swift run
   ```

## Configuration

### CLI Mode (Default)
In CLI mode, the app uses local CLI tools instead of direct API calls. This is the recommended approach:
- Claude Code CLI: Uses your existing Claude subscription
- Codex CLI: Uses your Codex subscription
- Gemini CLI: Uses your Google account
- Ollama: Runs completely locally - no API key needed!

### API Mode
Set `useCLIMode: false` in settings to use direct API calls. Requires API keys to be configured.

### API Keys (for API mode)
Store API keys in macOS Keychain (or fallback to `~/AgentBox/Secrets.json`):
- Claude API Key
- Gemini API Key
- MiniMax API Key
- Codex/OpenAI API Key

## Folder Structure

```
~/AgentBox/
├── 01_Inbox/       # Drop task instructions here (.txt files)
├── 02_Processing/  # Active tasks being processed
├── 03_Completed/   # Finished results
├── Settings.json   # App configuration
├── State.json      # Mission history
└── Secrets.json    # API keys (fallback)
```

## Usage

1. **Drop a task**: Create a `.txt` file in `~/AgentBox/01_Inbox/`
2. **Wait for poll**: The app polls based on your interval (default: 15 min)
3. **Review plan**: Manager generates a plan, you approve or reject
4. **Execute**: Workers run the task, results go to `03_Completed/`

## Architecture

- **SwiftUI** for native macOS UI
- **MVVM** pattern with ObservableObject ViewModels
- **Actor-based** services for async operations
- **File-based** state persistence
- **Dual execution modes**: CLI tools or Python bridge for APIs

## Tech Stack

- Swift 6
- SwiftUI (macOS 13+)
- Native macOS frameworks

## Requirements

- macOS 13 or later
- Optional: Claude Code CLI, Codex CLI, Gemini CLI, or Ollama for local execution

## Build App Bundle

```bash
swift build -c release
rm -rf AgentBox.app
mkdir -p AgentBox.app/Contents/MacOS AgentBox.app/Contents/Resources
cp .build/arm64-apple-macosx/release/AgentBox AgentBox.app/Contents/MacOS/AgentBox
cp -R .build/arm64-apple-macosx/release/AgentBox_AgentBox.bundle/Assets.xcassets AgentBox.app/Contents/Resources/
cp -R .build/arm64-apple-macosx/release/AgentBox_AgentBox.bundle/Scripts AgentBox.app/Contents/Resources/
cp Info.plist AgentBox.app/Contents/Info.plist
```

## Run

```bash
open AgentBox.app
```

## Tests

```bash
swift test
```

## Environment Variables (for API mode)

- `AGENTBOX_FAKE_LLM=1` - Use deterministic fake outputs for testing
- `AGENTBOX_ENABLE_FALLBACK=1` - Enable fallback text when model calls fail

## License

MIT
