#!/usr/bin/env python3
"""MCP stdio adapter for the computer-use bridge (port of Codex CUA design).

Newline-delimited JSON-RPC on stdio -> TCP JSON-RPC to the Swift service
on 127.0.0.1 (discovery: /tmp/computer_use_bridge.json, default 11260).
"""
import json
import os
import socket
import sys

DEFAULT_PORT = 11260
DISCOVERY = "/tmp/computer_use_bridge.json"

TOOLS = [
    {"name": "ping", "description": "Check bridge health",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "check_permissions", "description": "Accessibility + Screen Recording grant status",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "list_apps", "description": "List running GUI apps (pid, name, bundle_id)",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "list_windows", "description": "List on-screen windows (owner, title, frame)",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "skyshot", "description": "Activate app, capture window PNG + indexed accessibility tree. Elements can be clicked by 'index'.",
     "inputSchema": {"type": "object", "properties": {
         "app": {"type": "string", "description": "App name, bundle id, or 'frontmost'"},
         "pid": {"type": "integer"}}}},
    {"name": "ui_elements", "description": "Indexed accessibility tree only (no screenshot)",
     "inputSchema": {"type": "object", "properties": {
         "app": {"type": "string"}, "pid": {"type": "integer"}}}},
    {"name": "click", "description": "Click by element index or pixel coordinates",
     "inputSchema": {"type": "object", "properties": {
         "index": {"type": "integer"}, "x": {"type": "number"}, "y": {"type": "number"},
         "button": {"type": "string", "enum": ["left", "right", "middle"]},
         "clicks": {"type": "integer", "description": "2 = double click"}}}},
    {"name": "set_text", "description": "Set AXValue of an element by index (text fields)",
     "inputSchema": {"type": "object", "properties": {
         "index": {"type": "integer"}, "text": {"type": "string"}},
         "required": ["index", "text"]}},
    {"name": "type_text", "description": "Type text into the focused app (unicode-safe)",
     "inputSchema": {"type": "object", "properties": {
         "text": {"type": "string"}}, "required": ["text"]}},
    {"name": "press_key", "description": "Press a key with optional modifiers (cmd, shift, ctrl, opt)",
     "inputSchema": {"type": "object", "properties": {
         "key": {"type": "string"}, "modifiers": {"type": "array", "items": {"type": "string"}}},
         "required": ["key"]}},
    {"name": "scroll", "description": "Scroll at coordinates (dx/dy pixels)",
     "inputSchema": {"type": "object", "properties": {
         "x": {"type": "number"}, "y": {"type": "number"},
         "dx": {"type": "integer"}, "dy": {"type": "integer"}}}},
    {"name": "drag", "description": "Drag from one point to another",
     "inputSchema": {"type": "object", "properties": {
         "from_x": {"type": "number"}, "from_y": {"type": "number"},
         "to_x": {"type": "number"}, "to_y": {"type": "number"}},
         "required": ["from_x", "from_y", "to_x", "to_y"]}},
    {"name": "move_mouse", "description": "Move cursor without clicking",
     "inputSchema": {"type": "object", "properties": {
         "x": {"type": "number"}, "y": {"type": "number"}},
         "required": ["x", "y"]}},
    {"name": "wait", "description": "Wait ms",
     "inputSchema": {"type": "object", "properties": {"ms": {"type": "integer"}}}},
    {"name": "wait_settle", "description": "Wait until the app's UI tree stops changing",
     "inputSchema": {"type": "object", "properties": {
         "app": {"type": "string"}, "pid": {"type": "integer"},
         "timeout_ms": {"type": "integer"}}}},
    {"name": "focus_app", "description": "Bring an app to the foreground",
     "inputSchema": {"type": "object", "properties": {
         "app": {"type": "string"}, "pid": {"type": "integer"}}}},
]

_req_id = 0


def bridge_port():
    try:
        with open(DISCOVERY) as f:
            return int(json.load(f)["port"])
    except Exception:
        return int(os.environ.get("COMPUTER_USE_PORT", DEFAULT_PORT))


def bridge_call(method, params):
    global _req_id
    _req_id += 1
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(60)
    s.connect(("127.0.0.1", bridge_port()))
    s.sendall((json.dumps({"jsonrpc": "2.0", "id": _req_id,
                           "method": method, "params": params}) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    s.close()
    resp = json.loads(buf) if buf else {}
    if "error" in resp:
        raise RuntimeError(resp["error"].get("message", "bridge error"))
    return resp.get("result")


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def result(msg_id, res):
    send({"jsonrpc": "2.0", "id": msg_id, "result": res})


def error(msg_id, code, message):
    send({"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        method = msg.get("method", "")
        msg_id = msg.get("id")
        params = msg.get("params") or {}

        try:
            if method == "initialize":
                result(msg_id, {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "computer-use", "version": "0.1.0"},
                })
            elif method == "notifications/initialized" or method.startswith("notifications/"):
                pass
            elif method == "ping":
                result(msg_id, {})
            elif method == "tools/list":
                result(msg_id, {"tools": TOOLS})
            elif method == "tools/call":
                name = params.get("name")
                args = params.get("arguments") or {}
                out = bridge_call(name, args)
                result(msg_id, {
                    "content": [{"type": "text", "text": json.dumps(out)}],
                    "isError": False,
                })
            elif msg_id is not None:
                error(msg_id, -32601, f"Method not found: {method}")
        except Exception as e:
            if method == "tools/call":
                result(msg_id, {
                    "content": [{"type": "text", "text": json.dumps({"error": str(e)})}],
                    "isError": True,
                })
            elif msg_id is not None:
                error(msg_id, -32603, str(e))


if __name__ == "__main__":
    main()
