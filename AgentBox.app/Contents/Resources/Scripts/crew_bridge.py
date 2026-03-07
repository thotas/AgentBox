#!/usr/bin/env python3
"""
AgentBox model bridge.

Modes:
- plan: manager model generates execution plan
- execute: worker creates draft, manager synthesizes final output

By default this script runs real provider API calls.
Set AGENTBOX_FAKE_LLM=1 to run deterministic fake responses for tests.
Set AGENTBOX_ENABLE_FALLBACK=1 to emit fallback content when API calls fail.
"""

from __future__ import annotations

import argparse
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path


class BridgeError(RuntimeError):
    pass


@dataclass(frozen=True)
class ModelSpec:
    alias: str
    provider: str
    model_id: str
    key_env: str


MODEL_ALIASES = {
    "anthropic claude": ("anthropic", "AGENTBOX_ANTHROPIC_CLAUDE_MODEL", "claude-3-5-haiku-latest", "ANTHROPIC_API_KEY"),
    "anthropic sonnet": ("anthropic", "AGENTBOX_ANTHROPIC_SONNET_MODEL", "claude-3-7-sonnet-latest", "ANTHROPIC_API_KEY"),
    "google gemini": ("gemini", "AGENTBOX_GEMINI_MODEL", "gemini-1.5-flash", "GEMINI_API_KEY"),
    "minimax2.5": ("minimax", "AGENTBOX_MINIMAX_MODEL", "abab6.5-chat", "MINIMAX_API_KEY"),
    "codex": ("openai", "AGENTBOX_CODEX_MODEL", "gpt-5-codex", "OPENAI_API_KEY"),
}


def read_instruction(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def use_fake_llm() -> bool:
    return os.environ.get("AGENTBOX_FAKE_LLM", "0") == "1"


def allow_fallback() -> bool:
    return os.environ.get("AGENTBOX_ENABLE_FALLBACK", "0") == "1"


def resolve_model(selection: str) -> ModelSpec:
    normalized = selection.strip().lower()

    if normalized in MODEL_ALIASES:
        provider, env_name, default_model, key_env = MODEL_ALIASES[normalized]
        return ModelSpec(
            alias=selection,
            provider=provider,
            model_id=os.environ.get(env_name, default_model),
            key_env=key_env,
        )

    # Backward compatibility for legacy values like anthropic/claude-3-5-sonnet.
    if "/" in normalized:
        prefix, suffix = normalized.split("/", 1)
        provider_map = {
            "anthropic": ("anthropic", "ANTHROPIC_API_KEY"),
            "google": ("gemini", "GEMINI_API_KEY"),
            "openai": ("openai", "OPENAI_API_KEY"),
            "minimax": ("minimax", "MINIMAX_API_KEY"),
        }
        if prefix in provider_map:
            provider, key_env = provider_map[prefix]
            return ModelSpec(alias=selection, provider=provider, model_id=suffix, key_env=key_env)

    raise BridgeError(
        "Unsupported model selection '\n" + selection + "\n'. "
        "Use one of: anthropic claude, anthropic sonnet, google gemini, minimax2.5, codex."
    )


def fallback_plan(text: str, manager: str, worker: str, reason: str) -> str:
    preview = " ".join(text.split())[:260]
    return (
        f"Manager model: {manager}\n"
        f"Worker model: {worker}\n"
        "Bridge mode: fallback\n\n"
        "Execution Plan:\n"
        "1. Parse user instruction and identify deliverables.\n"
        "2. Dispatch execution tasks to selected worker model.\n"
        "3. Synthesize worker output via manager review.\n"
        "4. Emit final output and highlight assumptions.\n\n"
        f"Instruction preview: {preview}\n"
        f"Fallback reason: {reason}\n"
    )


def fallback_result(text: str, manager: str, worker: str, reason: str) -> str:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    bullet_list = "\n".join(f"- {line}" for line in lines[:8]) or "- (no explicit instruction lines found)"

    return (
        "# AgentBox Mission Result\n\n"
        f"Manager: `{manager}`\n"
        f"Worker: `{worker}`\n"
        "Bridge mode: fallback\n\n"
        "## Interpreted Requirements\n"
        f"{bullet_list}\n\n"
        "## Final Deliverable\n"
        "Real model execution was unavailable, so this is a fallback response.\n\n"
        f"Fallback reason: {reason}\n"
    )


def _json_post(url: str, headers: dict[str, str], payload: dict, timeout: int = 60) -> dict:
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8", errors="replace")
            return json.loads(body)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise BridgeError(f"HTTP {exc.code} from {url}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise BridgeError(f"Network error calling {url}: {exc.reason}") from exc


def _require_key(env_name: str, provider: str) -> str:
    value = os.environ.get(env_name, "").strip()
    if value:
        return value
    raise BridgeError(f"Missing API key for {provider}. Expected env var {env_name}.")


def _extract_openai_text(data: dict) -> str:
    if isinstance(data.get("output_text"), str) and data["output_text"].strip():
        return data["output_text"].strip()

    output = data.get("output", [])
    chunks: list[str] = []
    if isinstance(output, list):
        for item in output:
            content = item.get("content", []) if isinstance(item, dict) else []
            for piece in content:
                if isinstance(piece, dict):
                    text = piece.get("text")
                    if isinstance(text, str) and text.strip():
                        chunks.append(text.strip())

    text = "\n".join(chunks).strip()
    if text:
        return text
    raise BridgeError("OpenAI response did not include generated text.")


def _extract_anthropic_text(data: dict) -> str:
    content = data.get("content", [])
    chunks: list[str] = []
    if isinstance(content, list):
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                text = item.get("text")
                if isinstance(text, str) and text.strip():
                    chunks.append(text.strip())

    text = "\n".join(chunks).strip()
    if text:
        return text
    raise BridgeError("Anthropic response did not include generated text.")


def _extract_gemini_text(data: dict) -> str:
    candidates = data.get("candidates", [])
    chunks: list[str] = []
    if isinstance(candidates, list):
        for candidate in candidates:
            content = candidate.get("content", {}) if isinstance(candidate, dict) else {}
            parts = content.get("parts", []) if isinstance(content, dict) else []
            for part in parts:
                if isinstance(part, dict):
                    text = part.get("text")
                    if isinstance(text, str) and text.strip():
                        chunks.append(text.strip())

    text = "\n".join(chunks).strip()
    if text:
        return text
    raise BridgeError("Gemini response did not include generated text.")


def _extract_minimax_text(data: dict) -> str:
    choices = data.get("choices", [])
    if isinstance(choices, list) and choices:
        message = choices[0].get("message", {}) if isinstance(choices[0], dict) else {}
        content = message.get("content") if isinstance(message, dict) else None
        if isinstance(content, str) and content.strip():
            return content.strip()
        if isinstance(content, list):
            chunks = [
                part.get("text", "").strip()
                for part in content
                if isinstance(part, dict) and isinstance(part.get("text"), str) and part.get("text", "").strip()
            ]
            if chunks:
                return "\n".join(chunks)

    raise BridgeError("MiniMax response did not include generated text.")


def _call_openai(model: str, prompt: str, max_output_tokens: int) -> str:
    key = os.environ.get("OPENAI_API_KEY", "").strip() or os.environ.get("CODEX_API_KEY", "").strip()
    if not key:
        raise BridgeError("Missing API key for OpenAI/Codex. Expected OPENAI_API_KEY or CODEX_API_KEY.")
    url = os.environ.get("AGENTBOX_OPENAI_RESPONSES_URL", "https://api.openai.com/v1/responses")
    payload = {
        "model": model,
        "input": prompt,
        "max_output_tokens": max_output_tokens,
    }
    data = _json_post(url, {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}, payload)
    return _extract_openai_text(data)


def _call_anthropic(model: str, prompt: str, max_output_tokens: int) -> str:
    key = _require_key("ANTHROPIC_API_KEY", "Anthropic")
    url = os.environ.get("AGENTBOX_ANTHROPIC_MESSAGES_URL", "https://api.anthropic.com/v1/messages")
    payload = {
        "model": model,
        "max_tokens": max_output_tokens,
        "temperature": 0.2,
        "messages": [{"role": "user", "content": prompt}],
    }
    headers = {
        "x-api-key": key,
        "anthropic-version": os.environ.get("AGENTBOX_ANTHROPIC_VERSION", "2023-06-01"),
        "Content-Type": "application/json",
    }
    data = _json_post(url, headers, payload)
    return _extract_anthropic_text(data)


def _call_gemini(model: str, prompt: str, _max_output_tokens: int) -> str:
    key = _require_key("GEMINI_API_KEY", "Gemini")
    base = os.environ.get("AGENTBOX_GEMINI_BASE_URL", "https://generativelanguage.googleapis.com/v1beta")
    model_path = urllib.parse.quote(model, safe="")
    url = f"{base.rstrip('/')}/models/{model_path}:generateContent?key={urllib.parse.quote(key, safe='')}"
    payload = {
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": {"temperature": 0.2},
    }
    data = _json_post(url, {"Content-Type": "application/json"}, payload)
    return _extract_gemini_text(data)


def _call_minimax(model: str, prompt: str, _max_output_tokens: int) -> str:
    key = _require_key("MINIMAX_API_KEY", "MiniMax")
    base = os.environ.get("AGENTBOX_MINIMAX_BASE_URL", "https://api.minimax.chat/v1")
    url = f"{base.rstrip('/')}/chat/completions"
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.2,
    }
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    data = _json_post(url, headers, payload)
    return _extract_minimax_text(data)


def _fake_response(spec: ModelSpec, prompt: str, max_output_tokens: int) -> str:
    preview = " ".join(prompt.split())[:220]
    return (
        f"[FAKE {spec.provider.upper()}:{spec.model_id}]\n"
        f"max_output_tokens={max_output_tokens}\n"
        f"prompt_preview={preview}"
    )


def generate_from_model(spec: ModelSpec, prompt: str, max_output_tokens: int) -> str:
    if use_fake_llm():
        return _fake_response(spec, prompt, max_output_tokens)

    if spec.provider == "openai":
        return _call_openai(spec.model_id, prompt, max_output_tokens)
    if spec.provider == "anthropic":
        return _call_anthropic(spec.model_id, prompt, max_output_tokens)
    if spec.provider == "gemini":
        return _call_gemini(spec.model_id, prompt, max_output_tokens)
    if spec.provider == "minimax":
        return _call_minimax(spec.model_id, prompt, max_output_tokens)

    raise BridgeError(f"Unsupported provider '{spec.provider}'")


def build_plan_prompt(instruction: str, manager: ModelSpec, worker: ModelSpec) -> str:
    return f"""
You are the AgentBox manager model.

Create an execution plan for this instruction and the selected worker model.
Manager model: {manager.model_id}
Worker model: {worker.model_id}

Return markdown with these sections in order:
1) Mission Understanding
2) Work Breakdown (numbered steps)
3) Validation Plan
4) Risks and Mitigations
5) Output Contract

Instruction:
{instruction}
""".strip()


def build_worker_prompt(instruction: str, worker: ModelSpec) -> str:
    return f"""
You are the AgentBox worker model ({worker.model_id}).

Execute the user's request directly.
If required context is missing, state assumptions first and continue.
Return practical, concrete output in markdown.

Instruction:
{instruction}
""".strip()


def build_synthesis_prompt(instruction: str, worker_output: str, manager: ModelSpec, worker: ModelSpec) -> str:
    return f"""
You are the AgentBox manager model ({manager.model_id}).

Your job is to review the worker output and produce the final deliverable for the user.
Selected worker model: {worker.model_id}

Requirements:
- Preserve user constraints.
- Fix omissions and inconsistencies.
- Return only final user-facing markdown content.

Original instruction:
{instruction}

Worker draft:
{worker_output}
""".strip()


def make_plan(instruction: str, manager_choice: str, worker_choice: str) -> str:
    manager_spec = resolve_model(manager_choice)
    worker_spec = resolve_model(worker_choice)
    prompt = build_plan_prompt(instruction, manager_spec, worker_spec)
    plan = generate_from_model(manager_spec, prompt, max_output_tokens=1200)

    return (
        f"Manager model: {manager_spec.model_id}\n"
        f"Worker model: {worker_spec.model_id}\n"
        "Bridge mode: live\n\n"
        f"{plan.strip()}"
    )


def execute_mission(instruction: str, manager_choice: str, worker_choice: str) -> str:
    manager_spec = resolve_model(manager_choice)
    worker_spec = resolve_model(worker_choice)

    worker_prompt = build_worker_prompt(instruction, worker_spec)
    worker_output = generate_from_model(worker_spec, worker_prompt, max_output_tokens=1800)

    synthesis_prompt = build_synthesis_prompt(instruction, worker_output, manager_spec, worker_spec)
    final_output = generate_from_model(manager_spec, synthesis_prompt, max_output_tokens=2400)

    return (
        "# AgentBox Mission Result\n\n"
        f"Manager: `{manager_spec.model_id}`\n"
        f"Worker: `{worker_spec.model_id}`\n"
        "Bridge mode: live\n\n"
        "## Final Deliverable\n"
        f"{final_output.strip()}\n\n"
        "## Execution Metadata\n"
        f"- Worker draft chars: {len(worker_output)}\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="AgentBox Python bridge")
    parser.add_argument("--mode", choices=["plan", "execute"], required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--manager", required=True)
    parser.add_argument("--worker", required=True)
    args = parser.parse_args()

    try:
        instruction = read_instruction(args.input)

        if args.mode == "plan":
            try:
                content = make_plan(instruction, args.manager, args.worker)
            except BridgeError as exc:
                if not allow_fallback():
                    raise
                content = fallback_plan(instruction, args.manager, args.worker, str(exc))
            print(json.dumps({"plan": content}))
            return 0

        try:
            content = execute_mission(instruction, args.manager, args.worker)
        except BridgeError as exc:
            if not allow_fallback():
                raise
            content = fallback_result(instruction, args.manager, args.worker, str(exc))

        print(json.dumps({"result": content}))
        return 0
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
