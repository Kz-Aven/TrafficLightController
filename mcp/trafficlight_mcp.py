#!/usr/bin/env python3
"""Minimal stdio MCP proxy for TrafficLight's installed CLI."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import uuid
from typing import Any

CLI = os.environ.get("TRAFFICLIGHT_BIN", "trafficlight")

TOOLS = [
    {"name": "start_task", "description": "开始本地 Agent 任务并显示橙灯。",
     "inputSchema": {"type": "object", "properties": {
         "id": {"type": "string"}, "name": {"type": "string"}}, "required": ["name"]}},
    {"name": "complete_task", "description": "结束任务；success 显示绿灯，fail 回到红灯。",
     "inputSchema": {"type": "object", "properties": {
         "id": {"type": "string"}, "result": {"type": "string", "enum": ["success", "fail"]}}, "required": ["id", "result"]}},
    {"name": "idle", "description": "在等待用户输入或取消时回到红灯。",
     "inputSchema": {"type": "object", "properties": {"reason": {"type": "string"}}}},
    {"name": "status", "description": "读取当前 TrafficLight 状态。", "inputSchema": {"type": "object", "properties": {}}},
]


def call_cli(args: list[str]) -> dict[str, Any]:
    try:
        result = subprocess.run([CLI, *args], capture_output=True, text=True, timeout=8, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"ok": False, "error": "cli-unavailable", "message": str(exc)}
    try:
        payload = json.loads(result.stdout.strip())
    except json.JSONDecodeError:
        payload = {"ok": False, "error": "bad-cli-response", "message": result.stderr.strip() or result.stdout.strip()}
    return payload


def tool_call(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    if name == "start_task":
        task_id = str(arguments.get("id") or f"mcp-{uuid.uuid4()}")
        return call_cli(["start", "--id", task_id, "--name", str(arguments["name"])])
    if name == "complete_task":
        return call_cli(["done", "--id", str(arguments["id"]), "--result", str(arguments["result"])])
    if name == "idle":
        args = ["idle"]
        if arguments.get("reason"):
            args += ["--reason", str(arguments["reason"])]
        return call_cli(args)
    if name == "status":
        return call_cli(["status"])
    return {"ok": False, "error": "unknown-tool", "message": name}


def respond(request_id: Any, result: dict[str, Any]) -> None:
    print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}, ensure_ascii=False), flush=True)


def main() -> None:
    for line in sys.stdin:
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        method, request_id = request.get("method"), request.get("id")
        if method == "initialize":
            respond(request_id, {"protocolVersion": request.get("params", {}).get("protocolVersion", "2024-11-05"), "capabilities": {"tools": {}}, "serverInfo": {"name": "trafficlight", "version": "1.0.0"}})
        elif method == "tools/list":
            respond(request_id, {"tools": TOOLS})
        elif method == "tools/call":
            params = request.get("params", {})
            payload = tool_call(str(params.get("name", "")), dict(params.get("arguments") or {}))
            respond(request_id, {"content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False)}], "isError": not bool(payload.get("ok"))})


if __name__ == "__main__":
    main()
