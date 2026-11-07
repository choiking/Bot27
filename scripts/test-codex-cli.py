#!/usr/bin/env python3
"""Exercise the real Swift Codex adapter against deterministic child processes."""
import os
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation
struct AppConfig {
    enum Provider: String { case claude, gpt, xai; var canUseComputer: Bool { self != .xai } }
    var codexPath: String
    var gptModel = "test-model"
    var claudePath = ""
    var systemPrompt = "test"
}
struct Message {}
struct Conversation { var text: String; var images: [String] = [] }
enum ClaudeCLI {
    static func locate(custom: String) -> String? { custom.isEmpty ? nil : custom }
    static func prompt(for messages: [Message]) -> Conversation {
        Conversation(text: String(repeating: "test ", count: 100_000))
    }
}
enum ClaudeError: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): return message }
    }
}
struct ComputerRelay {
    static let shared = ComputerRelay()
    let path = "/tmp/Bot27 test/computer.sock"
    let token = "test-relay-secret"
}
enum ComputerMCP { static let server = "computer" }
struct ModelChoice { var provider: AppConfig.Provider }
struct Bot {
    var modelChoice = ModelChoice(provider: .gpt)
    var connections: [String]? = nil
    var computerUse: Bool? = nil
    var browserUse: Bool? = nil
}
enum BrowserUse { static let prefix = "mcp__claude-in-chrome__" }
enum ImageStore { static func url(_ name: String) -> URL { URL(fileURLWithPath: name) } }
@main struct Harness {
    static func main() async {
        let mode = ProcessInfo.processInfo.environment["BOT27_TEST_MODE"] ?? ""
        if mode.hasPrefix("discover_") {
            let result = await CodexConnectors.discover(custom: CommandLine.arguments[1], timeout: 0.8)
            print("DISCOVER: " + result.status + " " + result.allowedTools.map(Connector.shortName).sorted().joined(separator: ","))
            return
        }
        let gmail = mode == "gmail_config" || mode == "gmail_browser"
        let computer = ["mcp_config", "both_tools", "secret_error", "cancel"].contains(mode)
        let browser = ["browser_config", "both_tools", "missing_browser", "cancel_browser", "gmail_browser"].contains(mode)
        let config = AppConfig(codexPath: CommandLine.arguments[1],
                               claudePath: mode == "missing_browser" ? "" : "/tmp/Claude \"test\"/claude")
        var connections: [Connector] = []
        if gmail {
            // Even if stale/corrupt metadata contains writes or unknown tools, they stay blocked.
            connections = [CodexConnectors.gmail(status: "connected", tools: ["search_emails", "batch_read_email", "create_draft", "send_email", "send_draft", "delete_emails", "new_tool"])]
        } else if mode == "gmail_disconnected" {
            connections = [CodexConnectors.gmail(status: "needs-auth", tools: ["search_emails"])]
        } else if mode == "claude_connector" {
            connections = [Connector(id: "claude_ai_Gmail", name: "Gmail", status: "connected", tools: ["search_emails"])]
        }
        let legacy = try! JSONDecoder().decode(Connector.self, from: Data(#"{"id":"claude_ai_Gmail","name":"Gmail","status":"connected","tools":[]}"#.utf8))
        precondition(legacy.provider == .claude)
        let bot = Bot(connections: [CodexConnectors.gmailID])
        let hint = Connector.chatInstructions(bot: bot, catalog: [legacy] + connections, provider: .gpt)
        precondition(hint.contains("ChatGPT") && !hint.contains("Claude") && !hint.contains("claude.ai"))
        let stream = CodexCLI(config: config, connectors: connections,
                             onActivity: { print("ACTIVITY: " + $0) },
                             computerUse: computer, onComputer: { print("COMPUTER") },
                             browserUse: browser, onBrowser: { print("BROWSER") }).stream([])
        if mode == "cancel" || mode == "cancel_browser" {
            let consumer = Task {
                for try await _ in stream {}
            }
            // Wait for the child to be running before simulating the Stop button.
            let marker = ProcessInfo.processInfo.environment["BOT27_TEST_STARTED"]!
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: marker) { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            consumer.cancel()
            _ = await consumer.result
            // Give the adapter's termination handler time to stop its child.
            try? await Task.sleep(for: .milliseconds(300))
            print("CANCELLED")
            return
        }
        do {
            var replies = ""
            for try await reply in stream {
                replies += reply
            }
            print("SUCCESS: " + replies)
        } catch { print("FAILURE: " + error.localizedDescription) }
    }
}
'''
CHILD = r'''#!/usr/bin/env python3
import json, os, sys, time
mode = os.environ["BOT27_TEST_MODE"]
if mode.startswith("discover_"):
    assert sys.argv[1] == "app-server"
    for line in sys.stdin:
        request = json.loads(line)
        method = request['method']
        if method == 'initialized': continue
        assert method in ('initialize', 'app/installed', 'app/read'), method
        if mode == 'discover_exit': sys.exit(2)
        if mode == 'discover_timeout': time.sleep(5); sys.exit(2)
        if mode == 'discover_error':
            print(json.dumps({'id': request['id'], 'error': {'code': -32601, 'message': 'unsupported'}}), flush=True)
            continue
        result = {}
        if method == 'app/installed':
            result = {'apps': [] if mode == 'discover_missing' else [
                {'id': 'connector_2128aebfecb84f64a069897515042a44', 'runtimeName': 'Gmail',
                 'enabled': True, 'callable': mode != 'discover_disabled'}]}
        elif method == 'app/read':
            assert request['params']['includeTools']
            result = {'apps': [{'id': 'connector_2128aebfecb84f64a069897515042a44', 'toolSummaries': [
                {'name': 'search_emails', 'isEnabled': True},
                {'name': 'batch_read_email', 'isEnabled': True},
                {'name': 'create_draft', 'isEnabled': True},
                {'name': 'read_email', 'isEnabled': False},
                {'name': 'send_email', 'isEnabled': True},
                {'name': 'future_tool', 'isEnabled': True}]}]}
        # Notifications and out-of-order responses must not advance discovery.
        print(json.dumps({'method': 'app/list/updated', 'params': {}}), flush=True)
        print(json.dumps({'id': 999, 'result': {}}), flush=True)
        print(json.dumps({'id': request['id'], 'result': result}), flush=True)
    sys.exit(0)
if mode == "missing_browser":
    raise AssertionError("Codex must not start when the browser CLI is missing")
if mode in ("early_exit", "partial_input"):
    if mode == "partial_input":
        os.read(0, 1024)
    sys.stderr.write("Error: test startup failure\n")
    sys.exit(2)
prompt = sys.stdin.read()
overrides = [sys.argv[i + 1] for i, arg in enumerate(sys.argv[:-1]) if arg == "-c"]
assert "--ignore-user-config" in sys.argv
assert sys.argv[sys.argv.index("-s") + 1] == "read-only"
for feature in ("shell_tool", "plugins", "computer_use", "browser_use", "browser_use_external", "in_app_browser"):
    assert f"features.{feature}=false" in overrides
gmail = mode in ('gmail_config', 'gmail_browser')
assert f"features.apps={str(gmail).lower()}" in overrides
assert 'apps._default.enabled=false' in overrides
prefix = 'apps.connector_2128aebfecb84f64a069897515042a44'
assert (f'{prefix}.enabled=true' in overrides) == gmail
if gmail:
    assert f'{prefix}.default_tools_enabled=false' in overrides
    enabled = {item.split('.tools.', 1)[1].split('.')[0] for item in overrides if item.startswith(prefix + '.tools.') and item.endswith('.enabled=true')}
    assert enabled == {'search_emails', 'batch_read_email', 'create_draft'}, enabled
    for tool in enabled: assert f'{prefix}.tools.{tool}.approval_mode="approve"' in overrides
computer = mode in ("mcp_config", "both_tools", "secret_error", "cancel")
browser = mode in ("browser_config", "both_tools", "cancel_browser", "gmail_browser")
assert any(arg.startswith("mcp_servers.computer.") for arg in overrides) == computer
assert any(arg.startswith("mcp_servers.cua_repl.") for arg in overrides) == browser
for server in (["computer"] if computer else []) + (["cua_repl"] if browser else []):
    for setting in ("enabled=true", "required=true", "startup_timeout_sec=30", 'default_tools_approval_mode="approve"'):
        assert f"mcp_servers.{server}.{setting}" in overrides
if computer:
    assert not any(r'\/' in arg for arg in overrides), "escaped slash is invalid TOML"
    env = next(arg for arg in overrides if arg.startswith("mcp_servers.computer.env="))
    assert 'BOT27_RELAY_SOCKET="/tmp/Bot27 test/computer.sock"' in env
    args = next(arg.split("=", 1)[1] for arg in overrides if arg.startswith("mcp_servers.computer.args="))
    assert json.loads(args) == ["--computer-mcp"]
if browser:
    command = next(arg.split("=", 1)[1] for arg in overrides if arg.startswith("mcp_servers.cua_repl.command="))
    assert json.loads(command) == os.environ["BOT27_TEST_NODE"]
    assert not any("claude-in-chrome" in arg or "claude_in_chrome" in arg for arg in overrides)
    browser_env = next(arg for arg in overrides if arg.startswith("mcp_servers.cua_repl.env="))
    assert "CUA_REPL_NODE_REPL_PATH" in browser_env
    assert "NODE_REPL_TRUSTED_SERVICES" in browser_env
    assert "startup_timeout_sec=120" in next(arg for arg in reversed(overrides) if arg.startswith("mcp_servers.cua_repl.startup_timeout_sec="))
    args = next(arg.split("=", 1)[1] for arg in overrides if arg.startswith("mcp_servers.cua_repl.args="))
    assert json.loads(args) == [os.environ["BOT27_TEST_SCRIPT"]]
    allowed = json.loads(next(arg.split("=", 1)[1] for arg in overrides if arg.startswith("mcp_servers.cua_repl.enabled_tools=")))
    assert set(allowed) == {"js", "js_reset"}
    forwarded = json.loads(next(arg.split("=", 1)[1] for arg in overrides if arg.startswith("mcp_servers.cua_repl.env_vars=")))
    assert forwarded == ["BROWSER_USE_ACCESS_PIPE_PATH"]
if computer or browser:
    assert "Use the enabled Bot27 computer or browser tools" in prompt
if mode in ("cancel", "cancel_browser"):
    import subprocess, signal
    marker = os.environ["BOT27_TEST_STARTED"]
    helper = subprocess.Popen([sys.executable, "-c", 'import signal,time,sys; from pathlib import Path; signal.signal(signal.SIGTERM, lambda *_: (Path(sys.argv[1]).write_text("stopped"), sys.exit(0))); Path(sys.argv[2]).write_text("ready"); time.sleep(30)', marker + ".helper-stopped", marker + ".helper-ready"])
    for _ in range(100):
        if os.path.exists(marker + ".helper-ready"): break
        time.sleep(0.01)
    signal.signal(signal.SIGTERM, lambda *_: (helper.wait(timeout=2), sys.exit(0)))
    with open(marker, "w") as file:
        file.write(str(os.getpid()))
    time.sleep(30)
    sys.exit(1)
if mode == "secret_error":
    sys.stderr.write("Error: invalid config test-relay-secret")
    sys.exit(1)
if mode == "stderr":
    sys.stderr.write("x" * 200_000 + "\nError: test authentication failure\n")
    sys.exit(2)
if mode == "json":
    print(json.dumps({"type": "error", "message": '{"error":{"message":"test model unavailable"}}'}))
    sys.exit(1)
if mode == "empty":
    sys.exit(0)
if mode in ("mcp_config", "browser_config", "both_tools"):
    for server, tool in ([("computer", "screenshot")] if computer else []) + ([("cua_repl", "js")] if browser else []):
        print(json.dumps({"type": "item.started", "item": {"type": "mcp_tool_call", "server": server, "tool": tool}}))
        print(json.dumps({"type": "item.completed", "item": {"type": "mcp_tool_call", "server": server, "tool": tool}}))
print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "OK"}}))
if gmail:
    print(json.dumps({"type": "item.started", "item": {"type": "mcp_tool_call", "server": "codex_apps", "tool": "gmail.search_emails"}}))
if mode == "partial_reply":
    print(json.dumps({"type": "turn.failed", "error": {"message": "test failure after partial reply"}}))
    sys.exit(1)
'''

with tempfile.TemporaryDirectory(prefix="bot27-codex-test-") as directory:
    tmp = Path(directory)
    harness, child, binary = tmp / "Harness.swift", tmp / "fake-cli", tmp / "check"
    harness.write_text(HARNESS)
    child.write_text(CHILD)
    child.chmod(0o700)
    runtime = tmp / 'runtime with spaces'
    runtime.mkdir()
    node = runtime / 'node'
    node.write_text('#!/bin/sh\nexit 0\n')
    node.chmod(0o700)
    script = runtime / 'cua-repl.mjs'
    script.write_text('')
    codex_home = tmp / 'codex-home'
    plugin = codex_home / 'plugins/cache/openai-bundled/unified-computer-use/26.1021.31345'
    plugin.mkdir(parents=True)
    (plugin / '.mcp.json').write_text(json.dumps({'mcpServers': {'cua_repl': {
        'command': str(node), 'args': [str(script)], 'enabled': True,
        'enabled_tools': ['js', 'js_reset', 'turn_ended'], 'startup_timeout_sec': 120,
        'env_vars': ['BROWSER_USE_ACCESS_PIPE_PATH'],
        'env': {'CUA_REPL_NODE_REPL_PATH': str(node), 'NODE_REPL_TRUSTED_SERVICES': '{"sky":"@oai/sky/service"}'},
    }}}))
    subprocess.run([
        "swiftc", "-parse-as-library", "-enable-bare-slash-regex", "-module-cache-path", str(tmp / "modules"),
        str(ROOT / "Sources/Bot27/CodexCLI.swift"),
        str(ROOT / "Sources/Bot27/CodexConnectors.swift"),
        str(ROOT / "Sources/Bot27/Connectors.swift"),
        str(ROOT / "Sources/Bot27/NativeBrowser.swift"),
        str(ROOT / "Sources/Bot27/CLIEnvironment.swift"), str(harness), "-o", str(binary),
    ], check=True)
    cases = {
        "early_exit": "FAILURE: Codex (exit 2): Error: test startup failure",
        "partial_input": "FAILURE: Codex (exit 2): Error: test startup failure",
        "success": "SUCCESS: OK",
        "gmail_config": "ACTIVITY: Gmail · search emails",
        "gmail_browser": "ACTIVITY: Gmail · search emails",
        "gmail_disconnected": "SUCCESS: OK",
        "claude_connector": "SUCCESS: OK",
        "discover_success": "DISCOVER: connected batch_read_email,create_draft,search_emails",
        "discover_missing": "DISCOVER: needs-auth",
        "discover_disabled": "DISCOVER: disabled",
        "discover_error": "DISCOVER: unavailable",
        "discover_exit": "DISCOVER: unavailable",
        "discover_timeout": "DISCOVER: unavailable",
        "stderr": "test authentication failure",
        "json": "FAILURE: Codex (exit 1): test model unavailable",
        "empty": "FAILURE: Codex (exit 0): GPT exited without a reply.",
        "partial_reply": "FAILURE: Codex (exit 1): test failure after partial reply",
        "mcp_config": "SUCCESS: OK",
        "browser_config": "SUCCESS: OK",
        "both_tools": "SUCCESS: OK",
        "missing_browser": "FAILURE: GPT browser use needs the OpenAI computer-use runtime",
        "cancel": "CANCELLED",
        "cancel_browser": "CANCELLED",
        "secret_error": "FAILURE: Codex (exit 1): Error: invalid config [redacted]",
    }
    for mode, expected in cases.items():
        for marker in tmp.glob('started*'): marker.unlink()
        result = subprocess.run([str(binary), str(child)], capture_output=True, text=True,
                                timeout=15, env={**os.environ, "BOT27_TEST_MODE": mode,
                                                 "CODEX_HOME": str(tmp / 'missing') if mode == 'missing_browser' else str(codex_home),
                                                 "BOT27_TEST_NODE": str(node), "BOT27_TEST_SCRIPT": str(script),
                                                 "BOT27_TEST_STARTED": str(tmp / "started")})
        assert result.returncode == 0, (mode, result.returncode, result.stderr)
        assert expected in result.stdout, (mode, result.stdout[-1000:])
        assert len(result.stdout) < 17_000, "stderr capture must stay bounded"
        assert "test-relay-secret" not in result.stdout
        if mode in ("mcp_config", "both_tools"):
            assert result.stdout.count("COMPUTER\n") == 1
            assert "ACTIVITY: Computer · screenshot" in result.stdout
        if mode in ("browser_config", "both_tools"):
            assert result.stdout.count("BROWSER\n") == 1
            assert "ACTIVITY: Browser · js" in result.stdout
        if mode in ("mcp_config", "browser_config", "both_tools"):
            assert "ACTIVITY: \nSUCCESS: OK" in result.stdout
        if mode in ("cancel", "cancel_browser"):
            assert (tmp / 'started.helper-stopped').exists(), "Stop left the browser helper alive"
            pid = int((tmp / "started").read_text())
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass
            else:
                os.kill(pid, 15)
                raise AssertionError("Stop left the Codex process running")
        print(f"{mode}: PASS")
