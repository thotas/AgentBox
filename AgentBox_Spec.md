# Technical Specification: AgentBox (Mac Native Task Orchestrator)

## 1. Project Overview
**AgentBox** is a high-performance, native macOS application built with **Swift and SwiftUI**. It functions as a secure, file-based "bridge" between the user and a multi-model AI crew. It follows a **Manager-Worker** architecture where a central Manager (Claude) plans tasks, and specialized Workers (Gemini/MiniMax) execute them.

### Key Constraints:
- **Language:** Swift (macOS Native).
- **Design:** Modern Dark Mode (Apple Design Language).
- **Process:** Hierarchical (Manager -> Workers).
- **Trigger:** Cron-based (15-minute polling interval).
- **Visibility:** A "Mission Control" UI showing live status.

---

## 2. Architecture & Components

### A. The File-System Bridge (The "Air Gap")
The app monitors a specific directory structure:
- `~/AgentBox/01_Inbox/`: User drops `.txt` instructions here.
- `~/AgentBox/02_Processing/`: Active tasks being handled by the Crew.
- `~/AgentBox/03_Completed/`: Final results and status updates.

### B. The Orchestration Engine (CrewAI + Swift)
The app will wrap a Python-based CrewAI execution environment. 
- **Manager Agent:** Powered by `anthropic/claude-3-5-sonnet`. Responsible for reading the inbox, creating a task plan, and reviewing worker output.
- **Worker Agent 1:** Powered by `google/gemini-1.5-flash`. Best for file-system reading and large context tasks.
- **Worker Agent 2:** Powered by `minimax/abab6.5-chat`. Used for creative variations or high-speed iteration.

### C. The Dispatcher (Cron Logic)
Instead of Folder Actions, the Swift app will manage a `BackgroundTimer` or a `LaunchAgent` that wakes the app every **900 seconds (15 minutes)** to:
1. Scan `01_Inbox`.
2. Move valid files to `02_Processing`.
3. Trigger the CrewAI `kickoff()`.

---

## 3. Configuration (Configurable & Extensible)
The app must include a `Settings.json` file (editable via the UI) to allow the user to change:
- **Model Selection:** Dropdowns for Manager and Worker LLMs.
- **API Keys:** Secure storage in macOS Keychain for Claude, Gemini, and MiniMax.
- **Cron Interval:** Slider/Input for polling frequency (default 15m).
- **Directories:** Custom path selection for the Inbox/Outbox.

---

## 4. UI/UX Requirements (Dark Mode)
- **Dashboard View:** A `List` view showing "Current Missions."
    - **Pending:** Files in Inbox waiting for the next cron cycle.
    - **Active:** Progress bar or "Thinking" animation for files in Processing.
    - **Completed:** History of tasks with "View Result" buttons.
- **Artifact Integration:** Support for Antigravity's **Artifacts** system so the user can review the "Plan" before workers begin execution.
- **Visuals:** Deep matte black background (#000000), San Francisco fonts, and vibrant blue/purple accents for status indicators.

---

## 5. Development Steps for Antigravity Agent
1. **Scaffold:** Create a new SwiftUI macOS project named "AgentBox."
2. **Logic:** Implement a `FolderWatcher` class using `FileManager`.
3. **Bridge:** Set up a `PythonRunner` service to execute the CrewAI script with the user's specific LLM choices.
4. **State Management:** Use a local `State.json` to track the status of every file for the UI dashboard.
5. **Cron:** Implement the `BackgroundTimer` logic for 15-minute check-ins.