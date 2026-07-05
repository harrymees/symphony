#!/usr/bin/env python3
"""Minimal Codex app-server compatible bridge for OpenCode.

Symphony's Elixir runtime currently speaks the Codex app-server JSON-RPC
protocol. This bridge implements the small subset Symphony needs and delegates
turn execution to `opencode run`, allowing a Symphony instance to use OpenCode as
its default coding harness while keeping the existing runtime protocol stable.

Only JSON-RPC messages are written to stdout. Diagnostic logs, when enabled, are
written to OPENCODE_BRIDGE_LOG to avoid corrupting the stdio protocol.
"""
from __future__ import annotations

import json
import os
import shlex
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

_child: subprocess.Popen[str] | None = None


def _now_ms() -> int:
    return int(time.time() * 1000)


def _log(message: str) -> None:
    path = os.environ.get("OPENCODE_BRIDGE_LOG")
    if not path:
        return
    try:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {message}\n")
    except Exception:
        # Never let logging corrupt or stop the app-server protocol.
        pass


def _send(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _result(request_id: Any, result: dict[str, Any]) -> None:
    _send({"id": request_id, "result": result})


def _error(request_id: Any, code: int, message: str, data: Any | None = None) -> None:
    error: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    _send({"id": request_id, "error": error})


def _notify(method: str, params: dict[str, Any] | None = None) -> None:
    _send({"method": method, "params": params or {}})


def _load_hermes_env_if_requested(env: dict[str, str]) -> dict[str, str]:
    if env.get("OPENCODE_LOAD_HERMES_ENV", "1").lower() in {"0", "false", "no"}:
        return env

    allowed = {
        "OPENROUTER_API_KEY",
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "GOOGLE_GENERATIVE_AI_API_KEY",
    }
    env_file = Path(env.get("HERMES_ENV_FILE", str(Path.home() / ".hermes/.env"))).expanduser()
    if not env_file.exists():
        return env

    try:
        for raw_line in env_file.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            if key not in allowed or env.get(key):
                continue
            value = value.strip().strip('"').strip("'")
            if value:
                env[key] = value
    except Exception as exc:  # pragma: no cover - best-effort credential fallback
        _log(f"failed to load Hermes env from {env_file}: {exc!r}")

    return env


def _opencode_command(cwd: str, prompt: str, title: str | None) -> list[str]:
    opencode_bin = os.environ.get("OPENCODE_BIN") or str(Path.home() / ".local/bin/opencode")
    model = os.environ.get("OPENCODE_MODEL", "openrouter/z-ai/glm-5.2")
    agent = os.environ.get("OPENCODE_AGENT")
    extra = shlex.split(os.environ.get("OPENCODE_EXTRA_ARGS", ""))
    pure = os.environ.get("OPENCODE_PURE", "1").lower() not in {"0", "false", "no"}

    cmd = [opencode_bin, "run"]
    if pure:
        cmd.append("--pure")
    cmd.extend(["--format", "json", "--auto", "--model", model, "--dir", cwd])
    if agent:
        cmd.extend(["--agent", agent])
    if title:
        cmd.extend(["--title", title])
    cmd.extend(extra)
    cmd.append(prompt)
    return cmd


def _normalize_usage(tokens: dict[str, Any] | None) -> dict[str, int]:
    tokens = tokens or {}

    def integer(*keys: str) -> int:
        for key in keys:
            value = tokens.get(key)
            if isinstance(value, int) and value >= 0:
                return value
            if isinstance(value, str):
                try:
                    parsed = int(value.strip())
                except ValueError:
                    continue
                if parsed >= 0:
                    return parsed
        return 0

    input_tokens = integer("input", "input_tokens", "prompt", "prompt_tokens", "promptTokens", "inputTokens")
    output_tokens = integer("output", "output_tokens", "completion", "completion_tokens", "completionTokens", "outputTokens")
    total_tokens = integer("total", "total_tokens", "totalTokens") or (input_tokens + output_tokens)
    return {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": total_tokens,
    }


def _handle_opencode_event(event: dict[str, Any], text_parts: list[str], usage: dict[str, int]) -> None:
    event_type = event.get("type")
    raw_part = event.get("part")
    part: dict[str, Any] = raw_part if isinstance(raw_part, dict) else {}

    if event_type == "text":
        text = part.get("text")
        if isinstance(text, str) and text:
            text_parts.append(text)
            _notify(
                "turn/progress",
                {
                    "source": "opencode",
                    "event": "text",
                    "message": text[-1000:],
                    "timestamp": _now_ms(),
                },
            )
        return

    if event_type == "step_start":
        _notify("turn/progress", {"source": "opencode", "event": "step_start", "timestamp": _now_ms()})
        return

    if event_type == "step_finish":
        usage.update(_normalize_usage(part.get("tokens") if isinstance(part, dict) else None))
        _notify(
            "turn/progress",
            {
                "source": "opencode",
                "event": "step_finish",
                "usage": usage,
                "timestamp": _now_ms(),
            },
        )
        return

    # Keep the dashboard alive for non-text events without dumping large payloads.
    if isinstance(event_type, str):
        _notify(
            "turn/progress",
            {
                "source": "opencode",
                "event": event_type,
                "timestamp": _now_ms(),
            },
        )


def _run_opencode(cwd: str, prompt: str, title: str | None) -> tuple[int, str, dict[str, int]]:
    global _child

    env = _load_hermes_env_if_requested(os.environ.copy())
    env["PATH"] = ":".join(
        [
            str(Path.home() / ".local/bin"),
            str(Path.home() / ".npm-global/bin"),
            env.get("PATH", ""),
        ]
    )

    cmd = _opencode_command(cwd, prompt, title)
    _log("starting opencode command: " + " ".join(shlex.quote(part) for part in cmd[:-1]) + " <prompt>")

    text_parts: list[str] = []
    usage: dict[str, int] = {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}
    raw_tail: list[str] = []

    _child = subprocess.Popen(
        cmd,
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    assert _child.stdout is not None
    for line in _child.stdout:
        stripped = line.strip()
        if not stripped:
            continue
        raw_tail.append(stripped[-1000:])
        raw_tail[:] = raw_tail[-20:]
        try:
            event = json.loads(stripped)
        except json.JSONDecodeError:
            _log("non-json opencode output: " + stripped[:1000])
            continue
        if isinstance(event, dict):
            _handle_opencode_event(event, text_parts, usage)

    exit_code = _child.wait()
    _log(f"opencode exited code={exit_code}")
    _child = None

    text = "".join(text_parts).strip()
    if not text and raw_tail:
        text = "\n".join(raw_tail[-5:])
    return exit_code, text, usage


def _handle_turn_start(request_id: Any, params: dict[str, Any], thread_cwd: str) -> None:
    turn_id = f"opencode-turn-{uuid.uuid4().hex}"
    _result(request_id, {"turn": {"id": turn_id}})

    raw_input_items = params.get("input")
    input_items: list[Any] = raw_input_items if isinstance(raw_input_items, list) else []
    prompt_parts = [item.get("text", "") for item in input_items if isinstance(item, dict)]
    prompt = "\n".join(part for part in prompt_parts if isinstance(part, str))
    raw_cwd = params.get("cwd")
    cwd: str = raw_cwd if isinstance(raw_cwd, str) else thread_cwd
    raw_title = params.get("title")
    title = raw_title if isinstance(raw_title, str) else None

    _notify(
        "turn/progress",
        {
            "source": "opencode",
            "event": "started",
            "cwd": cwd,
            "model": os.environ.get("OPENCODE_MODEL", "openrouter/z-ai/glm-5.2"),
            "timestamp": _now_ms(),
        },
    )

    try:
        exit_code, text, usage = _run_opencode(cwd, prompt, title)
    except Exception as exc:
        _log(f"opencode bridge exception: {exc!r}")
        _notify(
            "turn/failed",
            {
                "turnId": turn_id,
                "message": f"OpenCode bridge failed: {exc!r}",
            },
        )
        return

    if exit_code == 0:
        _notify(
            "turn/completed",
            {
                "turnId": turn_id,
                "result": text,
                "usage": usage,
            },
        )
    else:
        _notify(
            "turn/failed",
            {
                "turnId": turn_id,
                "exitCode": exit_code,
                "message": text or f"opencode exited with status {exit_code}",
                "usage": usage,
            },
        )


def _shutdown(_signum: int, _frame: Any) -> None:
    global _child
    if _child is not None and _child.poll() is None:
        try:
            _child.terminate()
            _child.wait(timeout=5)
        except Exception:
            try:
                _child.kill()
            except Exception:
                pass
    raise SystemExit(0)


def main() -> int:
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    thread_cwd = os.getcwd()
    thread_id = f"opencode-thread-{uuid.uuid4().hex}"

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            _log("invalid json-rpc input: " + line[:1000])
            continue

        request_id = message.get("id")
        method = message.get("method")
        params = message.get("params") if isinstance(message.get("params"), dict) else {}

        try:
            if method == "initialize":
                _result(
                    request_id,
                    {
                        "protocolVersion": "opencode-bridge/0.1",
                        "serverInfo": {"name": "opencode-app-server-bridge", "version": "0.1.0"},
                        "capabilities": {},
                    },
                )
            elif method == "initialized":
                continue
            elif method == "thread/start":
                raw_cwd = params.get("cwd")
                if isinstance(raw_cwd, str):
                    thread_cwd = raw_cwd
                _result(request_id, {"thread": {"id": thread_id}})
            elif method == "turn/start":
                _handle_turn_start(request_id, params, thread_cwd)
            else:
                if request_id is not None:
                    _error(request_id, -32601, f"Unsupported method: {method}")
                else:
                    _log(f"ignoring unsupported notification: {method}")
        except Exception as exc:
            _log(f"error handling method {method}: {exc!r}")
            if request_id is not None:
                _error(request_id, -32000, f"Bridge error handling {method}: {exc!r}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
