# computer-use

Native macOS computer-use executor for AI agents — a clean-room port of the architecture used by OpenAI Codex's `SkyComputerUseService` (formerly Sky / Software Applications Inc).

A small Swift service exposes screenshot capture, indexed accessibility trees, and synthetic input over newline-delimited JSON-RPC, plus a zero-dependency MCP stdio adapter so any agent (Devin, Claude Code, Codex, custom tools) can drive a Mac.

## Architecture

```
Agent ──MCP stdio──► mcp-stdio.py ──NDJSON-RPC──► computer-use (Swift)
                                                  TCP 127.0.0.1:11260
                                                  discovery: /tmp/computer_use_bridge.json
        │
        ├── SCScreenshotManager   per-window capture ("skyshot")
        ├── AXUIElement tree      indexed actionable elements (click by index or pixel)
        ├── CGEvent synthesis     click / drag / scroll / keys via cghidEventTap
        └── settle detection      AX-tree hash until UI is stable
```

## Quick start

```bash
swift build -c release
.build/release/computer-use          # listens on 127.0.0.1:11260, writes discovery file
```

The binary needs **Accessibility** and **Screen Recording** grants (TCC prompts on first use, or call `request_permissions`).

### Probe it

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"ping"}' | nc 127.0.0.1 11260
```

## RPC methods

| Method | Params | Description |
|---|---|---|
| `skyshot` | `{app\|pid\|"frontmost"}` | Activate app → PNG path + indexed AX tree |
| `ui_elements` | `{app\|pid}` | Indexed element tree only (no capture) |
| `click` | `{index}` or `{x,y}`, `button`, `clicks` | `AXPress` for indexed elements, CGEvent for pixels |
| `set_text` | `{index, text}` | Set `AXValue` directly (text fields) |
| `type_text` | `{text}` | Paste + ⌘V (unicode-safe) |
| `press_key` | `{key, modifiers[]}` | CGEvent with cmd/shift/ctrl/opt flags |
| `scroll` / `drag` / `move_mouse` | coordinates | CGEvent pointer synthesis |
| `wait_settle` | `{app\|pid, timeout_ms}` | Wait until the UI tree stops mutating |
| `list_apps` / `list_windows` / `focus_app` | — | `NSWorkspace` / `CGWindowList` |
| `check_permissions` / `request_permissions` / `ping` / `wait` | — | Utility |

## Register as an MCP server

```bash
# Devin CLI
devin mcp add -s user computer-use -- python3 /path/to/mcp-stdio.py

# Claude Code / any MCP host (stdio config)
"computer-use": {
  "command": "python3",
  "args": ["/path/to/mcp-stdio.py"]
}
```

The MCP adapter is a ~200-line, zero-dependency Python bridge — the Swift service must be running.

## What was ported vs intentionally omitted

**Ported**: per-window skyshot (capture + AX indexing), semantic AX actions + CGEvent fallback, click-by-element-index-or-pixel, settle-wait before capture, framed JSON-RPC transport.

**Omitted by design**: peer code-signing authorization, per-bundle-id policy checks, PiP "agent is using your computer" overlay, lock-screen guardian, ambient screen watching (Skysight), iMessage integration, analytics.

## License

Dual-licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
