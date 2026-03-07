# Technical Decisions

## 1. Swift Package Instead of Xcode Project

Decision: Implemented as a Swift package executable with SwiftUI app entrypoint.

Why:
- Fast to bootstrap in automation.
- Easy CLI verification with `swift build` and `swift test`.

Tradeoff:
- Does not include pre-generated `.xcodeproj`, but can still be opened in Xcode via package support.

## 2. Polling Timer (In-App) for Cron Behavior

Decision: Use `Timer` with configurable `pollingIntervalSeconds` (default 900).

Why:
- Matches spec requirement for 15-minute check-ins.
- Keeps implementation simple and local.

Tradeoff:
- App must be running. A future LaunchAgent can trigger even when app is not foregrounded.

## 3. Plan Approval Gate as Artifact Review

Decision: Missions move to `awaitingApproval` with manager plan before any worker execution.

Why:
- Satisfies requirement to review the plan before dispatching workers.
- Gives user control over mission quality and safety.

Tradeoff:
- Adds one manual step, but this is intentional governance.

## 4. Keychain-First Secrets with Fallback, JSON for Non-Secret Settings

Decision: Keep API keys in Keychain when available, with automatic fallback to `~/AgentBox/Secrets.json` if keychain operations fail. Keep model/directories/polling in `Settings.json`.

Why:
- Clear separation between secrets and configuration.
- Aligns with macOS best practices.
- Avoids user-facing save failures in restricted or headless runtime contexts where keychain prompts are blocked.

Tradeoff:
- Slightly more plumbing in settings UI and secret storage service.

## 5. CLI Mode as Default Execution

Decision: Added CLI mode as the default, using local CLI tools (claude, codex, gemini, ollama) instead of direct API calls.

Why:
- Leverages user's existing CLI subscriptions (Claude Code, Codex, Gemini)
- Ollama runs completely locally - no API key needed, works offline
- Simpler authentication - CLIs handle their own auth
- User explicitly requested using their existing CLI tools

Tradeoff:
- Requires CLI tools to be installed and in PATH
- Different CLI interfaces may need different invocation patterns

## 6. Dual Execution Architecture

Decision: Keep both CLI runner (new) and Python bridge (legacy) in the same app, selectable via `useCLIMode` setting.

Why:
- Backward compatibility with existing API-based workflows
- Users can choose CLI or API based on their setup
- CLI mode is simpler for users with existing CLI tools
- Python bridge remains as fallback for API-only deployments

Tradeoff:
- More code to maintain, but clearer separation of concerns

## 7. Python Bridge with Provider API Dispatch

Decision: Ship a bundled Python bridge that dispatches directly to provider APIs (Anthropic, Gemini, MiniMax, OpenAI/Codex) with deterministic fake mode for tests and optional fallback text mode.

Why:
- Executes real manager/worker model calls instead of placeholder text.
- Supports multiple providers behind one local interface.
- Keeps testing stable without network via `AGENTBOX_FAKE_LLM=1`.

Tradeoff:
- Provider API schema differences require normalization logic and explicit error handling.
