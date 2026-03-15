#!/bin/bash
#
# orchestrate.sh - Multi-Agent Orchestration Script
#
# This script implements the orchestration flow for AgentBox, mirroring the logic
# originally implemented in Swift (CLIRunner.swift). It provides:
#   - check_prereqs: Verify available CLI agents
#   - plan_task: Generate JSON orchestration plan
#   - run_agent: Execute a single agent task
#   - consolidate: Merge results into final report
#
# Usage:
#   orchestrate.sh check_prereqs [settings_json]
#   orchestrate.sh plan_task <instruction_file> [settings_json]
#   orchestrate.sh run_agent <subtask_json> [previous_results_json]
#   orchestrate.sh consolidate <original_task> <plan_json> <results_json> [settings_json]
#

set -euo pipefail

# Configuration
TIMEOUT=${ORCHESTRATE_TIMEOUT:-180}
CLAUDE_CLI="${CLAUDE_CLI:-/opt/homebrew/bin/claude}"
CODEX_CLI="${CODEX_CLI:-/opt/homebrew/bin/codex}"
GEMINI_CLI="${GEMINI_CLI:-/opt/homebrew/bin/gemini}"
OLLAMA_CLI="${OLLAMA_CLI:-/usr/local/bin/ollama}"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3}"
MINIMAX_BASE_URL="${MINIMAX_BASE_URL:-https://api.minimax.io/anthropic}"
MINIMAX_AUTH_TOKEN="${MINIMAX_AUTH_TOKEN:-}"
MINIMAX_MODEL="${MINIMAX_MODEL:-kimi-k2.5:cloud}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[orchestrate.sh]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[orchestrate.sh]${NC} $1" >&2; }
log_error() { echo -e "${RED}[orchestrate.sh]${NC} $1" >&2; }

# Parse settings from JSON (optional)
parse_settings() {
    local settings_json="$1"
    if [[ -n "$settings_json" && -f "$settings_json" ]]; then
        CLAUDE_CLI=$(jq -r '.claudeCLICommand // "/opt/homebrew/bin/claude" | split(" ")[0]' "$settings_json" 2>/dev/null || echo "$CLAUDE_CLI")
        CODEX_CLI=$(jq -r '.codexCLICommand // "/opt/homebrew/bin/codex" | split(" ")[0]' "$settings_json" 2>/dev/null || echo "$CODEX_CLI")
        GEMINI_CLI=$(jq -r '.geminiCLICommand // "/opt/homebrew/bin/gemini" | split(" ")[0]' "$settings_json" 2>/dev/null || echo "$GEMINI_CLI")
        OLLAMA_CLI=$(jq -r '.ollamaCLICommand // "/usr/local/bin/ollama" | split(" ")[0]' "$settings_json" 2>/dev/null || echo "$OLLAMA_CLI")
        OLLAMA_MODEL=$(jq -r '.ollamaModelName // "llama3"' "$settings_json" 2>/dev/null || echo "$OLLAMA_MODEL")
        MINIMAX_BASE_URL=$(jq -r '.minimaxBaseURL // "https://api.minimax.io/anthropic"' "$settings_json" 2>/dev/null || echo "$MINIMAX_BASE_URL")
        MINIMAX_AUTH_TOKEN=$(jq -r '.minimaxAuthToken // ""' "$settings_json" 2>/dev/null || echo "")
        MINIMAX_MODEL=$(jq -r '.minimaxModelName // "kimi-k2.5:cloud"' "$settings_json" 2>/dev/null || echo "$MINIMAX_MODEL")
    fi
}

# check_prereqs - Verify available CLI agents
check_prereqs() {
    local settings_json="${1:-}"

    [[ -n "$settings_json" ]] && parse_settings "$settings_json"

    log_info "Checking available agents..."

    local result="{}"

    # Check Claude CLI
    if [[ -x "$CLAUDE_CLI" ]]; then
        result=$(echo "$result" | jq '.claude = true')
        log_info "  ✓ Claude CLI: $CLAUDE_CLI"
    else
        result=$(echo "$result" | jq '.claude = false')
        log_warn "  ✗ Claude CLI not found: $CLAUDE_CLI"
    fi

    # Check Codex CLI
    if [[ -x "$CODEX_CLI" ]]; then
        result=$(echo "$result" | jq '.codex = true')
        log_info "  ✓ Codex CLI: $CODEX_CLI"
    else
        result=$(echo "$result" | jq '.codex = false')
        log_warn "  ✗ Codex CLI not found: $CODEX_CLI"
    fi

    # Check Gemini CLI
    if [[ -x "$GEMINI_CLI" ]]; then
        result=$(echo "$result" | jq '.gemini = true')
        log_info "  ✓ Gemini CLI: $GEMINI_CLI"
    else
        result=$(echo "$result" | jq '.gemini = false')
        log_warn "  ✗ Gemini CLI not found: $GEMINI_CLI"
    fi

    # Check Ollama
    if [[ -x "$OLLAMA_CLI" ]]; then
        local model_list
        model_list=$("$OLLAMA_CLI" list 2>/dev/null || echo "")
        if echo "$model_list" | grep -qE "${OLLAMA_MODEL}|${OLLAMA_MODEL}:"; then
            result=$(echo "$result" | jq '.ollama = true')
            log_info "  ✓ Ollama: $OLLAMA_CLI (model: $OLLAMA_MODEL)"
        else
            result=$(echo "$result" | jq '.ollama = false')
            log_warn "  ✗ Ollama model not available: $OLLAMA_MODEL"
        fi
    else
        result=$(echo "$result" | jq '.ollama = false')
        log_warn "  ✗ Ollama CLI not found: $OLLAMA_CLI"
    fi

    # Check MiniMax (requires Claude CLI + auth token)
    if [[ -x "$CLAUDE_CLI" && -n "$MINIMAX_AUTH_TOKEN" ]]; then
        result=$(echo "$result" | jq '.minimax = true')
        log_info "  ✓ MiniMax: configured (using Claude CLI)"
    else
        result=$(echo "$result" | jq '.minimax = false')
        if [[ ! -x "$CLAUDE_CLI" ]]; then
            log_warn "  ✗ MiniMax: requires Claude CLI"
        else
            log_warn "  ✗ MiniMax: requires auth token"
        fi
    fi

    echo "$result"
}

# run_claude_agent - Run Claude agent
run_claude_agent() {
    local description="$1"
    local needs_files="${2:-false}"
    local project_dir="${3:-}"

    if [[ "$needs_files" == "true" && -n "$project_dir" && -d "$project_dir" ]]; then
        # Agentic mode (no --print, with tool access)
        log_info "Running Claude in agentic mode (needs_files=true)"
        "$CLAUDE_CLI" --dangerously-skip-permissions --no-session-persistence "$description" 2>&1
    else
        # Print mode (stdin)
        log_info "Running Claude in print mode"
        echo "$description" | "$CLAUDE_CLI" --print 2>&1
    fi
}

# run_minimax_agent - Run MiniMax agent
run_minimax_agent() {
    local description="$1"
    local needs_files="${2:-false}"
    local project_dir="${3:-}"

    if [[ "$needs_files" == "true" && -n "$project_dir" && -d "$project_dir" ]]; then
        # Agentic mode with env overrides
        log_info "Running MiniMax in agentic mode"
        ANTHROPIC_BASE_URL="$MINIMAX_BASE_URL" \
        ANTHROPIC_AUTH_TOKEN="$MINIMAX_AUTH_TOKEN" \
        "$CLAUDE_CLI" --dangerously-skip-permissions --no-session-persistence --model "$MINIMAX_MODEL" "$description" 2>&1
    else
        # Print mode with env overrides
        log_info "Running MiniMax in print mode"
        echo "$description" | ANTHROPIC_BASE_URL="$MINIMAX_BASE_URL" \
            ANTHROPIC_AUTH_TOKEN="$MINIMAX_AUTH_TOKEN" \
            "$CLAUDE_CLI" --print --model "$MINIMAX_MODEL" 2>&1
    fi
}

# run_codex_agent - Run Codex agent
run_codex_agent() {
    local description="$1"
    local needs_files="${2:-false}"
    local project_dir="${3:-}"

    if [[ "$needs_files" == "true" && -n "$project_dir" && -d "$project_dir" ]]; then
        log_info "Running Codex in project directory: $project_dir"
        echo "$description" | "$CODEX_CLI" --quiet 2>&1
    else
        log_info "Running Codex via stdin"
        echo "$description" | "$CODEX_CLI" --quiet 2>&1
    fi
}

# run_gemini_agent - Run Gemini agent
run_gemini_agent() {
    local description="$1"
    local needs_files="${2:-false}"
    local project_dir="${3:-}"

    if [[ "$needs_files" == "true" && -n "$project_dir" && -d "$project_dir" ]]; then
        log_info "Running Gemini in project directory: $project_dir"
        echo "$description" | "$GEMINI_CLI" 2>&1
    else
        log_info "Running Gemini via stdin"
        echo "$description" | "$GEMINI_CLI" 2>&1
    fi
}

# run_ollama_agent - Run Ollama agent (text only)
run_ollama_agent() {
    local description="$1"

    log_info "Running Ollama (model: $OLLAMA_MODEL)"

    # Check if model is available
    local model_list
    model_list=$("$OLLAMA_CLI" list 2>/dev/null || echo "")
    if ! echo "$model_list" | grep -qE "${OLLAMA_MODEL}|${OLLAMA_MODEL}:"; then
        log_info "Pulling Ollama model: $OLLAMA_MODEL"
        "$OLLAMA_CLI" pull "$OLLAMA_MODEL" 2>&1
    fi

    echo "$description" | "$OLLAMA_CLI" run "$OLLAMA_MODEL" 2>&1
}

# run_agent - Dispatch to appropriate agent
run_agent() {
    local agent="$1"
    local description="$2"
    local needs_files="${3:-false}"
    local project_dir="${4:-}"

    case "$agent" in
        claude)
            run_claude_agent "$description" "$needs_files" "$project_dir"
            ;;
        minimax)
            run_minimax_agent "$description" "$needs_files" "$project_dir"
            ;;
        codex)
            run_codex_agent "$description" "$needs_files" "$project_dir"
            ;;
        gemini)
            run_gemini_agent "$description" "$needs_files" "$project_dir"
            ;;
        ollama)
            run_ollama_agent "$description"
            ;;
        *)
            log_error "Unknown agent: $agent, falling back to claude"
            run_claude_agent "$description" "$needs_files" "$project_dir"
            ;;
    esac
}

# plan_task - Generate JSON orchestration plan
plan_task() {
    local instruction_file="$1"
    local settings_json="${2:-}"

    [[ -n "$settings_json" ]] && parse_settings "$settings_json"

    local instruction
    instruction=$(cat "$instruction_file")

    # Get project directory from settings if available
    local project_context=""
    if [[ -n "$settings_json" && -f "$settings_json" ]]; then
        local project_dir
        project_dir=$(jq -r '.projectDirectory // ""' "$settings_json" 2>/dev/null || echo "")
        if [[ -n "$project_dir" && -d "$project_dir" ]]; then
            project_context="
Project directory: $project_dir
NOTE: Agents that need to read/write files MUST set \"needs_files\": true in their subtask JSON.
      Claude and minimax agents with needs_files=true will run in agentic mode (can read/write files).
      Ollama cannot access files — only assign text/analysis tasks to it."
        fi
    fi

    local prompt
    prompt=$(cat <<EOF
IMPORTANT: Respond ONLY with valid JSON, no markdown fences, no explanation.

You are an expert AI orchestrator. Break down the following task into parallel sub-tasks and assign each to the most appropriate agent.

Available agents:
- claude: Best for complex reasoning, architecture, code review, file editing, implementation
- codex: Best for code generation, refactoring, implementation
- gemini: Best for research, documentation, broad knowledge tasks
- ollama (local/$OLLAMA_MODEL): Best for simple text tasks, summarization, formatting (NO file access)
- minimax ($MINIMAX_MODEL): Best for creative tasks, multilingual content, alternative perspective, file editing

Task: $instruction
$project_context

Respond ONLY with valid JSON in this exact structure (no markdown, no backticks):
{
  "task_summary": "one-line summary",
  "subtasks": [
    {
      "id": "task_1",
      "title": "Short title",
      "description": "Detailed description of what this agent should do",
      "agent": "claude|codex|gemini|ollama|minimax",
      "needs_files": false,
      "depends_on": [],
      "priority": 1
    }
  ],
  "consolidation_notes": "Instructions for how to consolidate results"
}
EOF
)

    local output
    output=$(echo "$prompt" | "$CLAUDE_CLI" --print 2>&1)

    # Clean output - remove markdown fences
    output=$(echo "$output" | sed 's/```json//g' | sed 's/```//g' | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Extract JSON object
    local json
    json=$(echo "$output" | grep -oP '\{.*\}' || echo "$output")

    # Validate it's valid JSON
    if echo "$json" | jq . >/dev/null 2>&1; then
        echo "$json"
    else
        log_error "Invalid JSON response from planning agent"
        echo "$output"
        exit 1
    fi
}

# consolidate - Merge results into final report
consolidate() {
    local original_task="$1"
    local plan_json="$2"
    local results_json="$3"
    local settings_json="${4:-}"

    [[ -n "$settings_json" ]] && parse_settings "$settings_json"

    # Build results summary
    local all_results=""
    local subtasks
    subtasks=$(echo "$plan_json" | jq -c '.subtasks[]' 2>/dev/null || echo "")

    while IFS= read -r subtask; do
        local task_id
        task_id=$(echo "$subtask" | jq -r '.id')
        local result
        result=$(echo "$results_json" | jq -r ".[\"$task_id\"] // empty")

        if [[ -n "$result" ]]; then
            all_results+="## Result: $task_id\n\n$result\n\n---\n\n"
        fi
    done <<< "$subtasks"

    local consolidation_notes
    consolidation_notes=$(echo "$plan_json" | jq -r '.consolidation_notes // "Combine all results into a coherent summary."')

    local prompt
    prompt=$(cat <<EOF
You are consolidating results from multiple AI agents.

Original task: $original_task

Consolidation instructions: $consolidation_notes

Sub-task results:
$all_results

Please:
1. Review all agent outputs for quality and correctness
2. Identify any conflicts, gaps, or errors
3. Synthesize a coherent final result
4. Produce a final consolidated output that fully satisfies the original task
5. End with a brief ## Quality Assessment section noting any concerns

Format your response as clean Markdown.
EOF
)

    echo "$prompt" | "$CLAUDE_CLI" --print 2>&1
}

# Main entry point
main() {
    local mode="$1"
    shift

    case "$mode" in
        check_prereqs)
            check_prereqs "$@"
            ;;
        plan_task)
            plan_task "$@"
            ;;
        run_agent)
            local subtask_json="$1"
            local previous_results_json="${2:-}"
            local settings_json="${3:-}"

            [[ -n "$settings_json" ]] && parse_settings "$settings_json"

            local agent description needs_files project_dir
            agent=$(echo "$subtask_json" | jq -r '.agent')
            description=$(echo "$subtask_json" | jq -r '.description')
            needs_files=$(echo "$subtask_json" | jq -r '.needs_files')
            project_dir=$(echo "$subtask_json" | jq -r '.project_directory // ""')

            # Inject context from previous results if any
            if [[ -n "$previous_results_json" && "$previous_results_json" != "null" ]]; then
                local depends_on
                depends_on=$(echo "$subtask_json" | jq -r '.depends_on[]' 2>/dev/null || echo "")
                if [[ -n "$depends_on" ]]; then
                    local dep_context=""
                    for dep_id in $depends_on; do
                        local dep_result
                        dep_result=$(echo "$previous_results_json" | jq -r ".[\"$dep_id\"] // empty")
                        if [[ -n "$dep_result" ]]; then
                            dep_context+="--- Output from $dep_id ---\n$dep_result\n\n"
                        fi
                    done
                    if [[ -n "$dep_context" ]]; then
                        description="$description\n\nContext from previous tasks:\n\n$dep_context"
                    fi
                fi
            fi

            run_agent "$agent" "$description" "$needs_files" "$project_dir"
            ;;
        consolidate)
            consolidate "$@"
            ;;
        *)
            echo "Usage: $0 {check_prereqs|plan_task|run_agent|consolidate} [args...]" >&2
            exit 1
            ;;
    esac
}

main "$@"
