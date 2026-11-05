#!/usr/bin/env python3
"""Exercise the real Swift Codex adapter against deterministic child processes."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation
struct AppConfig {
    var codexPath: String
    var gptModel = "test-model"
    var claudePath = ""
    var systemPrompt = "test"
}
struct Message {}
struct Conversation { var text: String; var images: [String] = [] }
enum ClaudeCLI {
    static func locate(custom: String) -> String? { nil }
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
enum BrowserUse { static let allowedTools: [String] = []; static let prefix = "browser_" }
enum Connector { static func describe(_ name: String, in catalog: [String]) -> String { name } }
enum ImageStore { static func url(_ name: String) -> URL { URL(fileURLWithPath: name) } }
@main struct Harness {
    static func main() async {
        do {
            var replies = ""
            let computer = ProcessInfo.processInfo.environment["BOT27_TEST_MODE"] == "mcp_config"
                || ProcessInfo.processInfo.environment["BOT27_TEST_MODE"] == "secret_error"
            for try await reply in CodexCLI(config: AppConfig(codexPath: CommandLine.arguments[1]),
                                           computerUse: computer).stream([]) {
                replies += reply
            }
            print("SUCCESS: " + replies)
        } catch { print("FAILURE: " + error.localizedDescription) }
    }
}
'''
CHILD = r'''#!/usr/bin/env python3
import json, os, sys
mode = os.environ["BOT27_TEST_MODE"]
if mode in ("early_exit", "partial_input"):
    if mode == "partial_input":
        os.read(0, 1024)
    sys.stderr.write("Error: test startup failure\n")
    sys.exit(2)
sys.stdin.read()
if mode == "mcp_config":
    overrides = [sys.argv[i + 1] for i, arg in enumerate(sys.argv[:-1]) if arg == "-c"]
    assert not any(r'\/' in arg for arg in overrides), "escaped slash is invalid TOML"
    env = next(arg for arg in overrides if arg.startswith("mcp_servers.computer.env="))
    assert 'BOT27_RELAY_SOCKET="/tmp/Bot27 test/computer.sock"' in env
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
print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "OK"}}))
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
    subprocess.run([
        "swiftc", "-parse-as-library", "-module-cache-path", str(tmp / "modules"),
        str(ROOT / "Sources/Bot27/CodexCLI.swift"),
        str(ROOT / "Sources/Bot27/CLIEnvironment.swift"), str(harness), "-o", str(binary),
    ], check=True)
    cases = {
        "early_exit": "FAILURE: Codex (exit 2): Error: test startup failure",
        "partial_input": "FAILURE: Codex (exit 2): Error: test startup failure",
        "success": "SUCCESS: OK",
        "stderr": "test authentication failure",
        "json": "FAILURE: Codex (exit 1): test model unavailable",
        "empty": "FAILURE: Codex (exit 0): GPT exited without a reply.",
        "partial_reply": "FAILURE: Codex (exit 1): test failure after partial reply",
        "mcp_config": "SUCCESS: OK",
        "secret_error": "FAILURE: Codex (exit 1): Error: invalid config [redacted]",
    }
    for mode, expected in cases.items():
        result = subprocess.run([str(binary), str(child)], capture_output=True, text=True,
                                timeout=15, env={**os.environ, "BOT27_TEST_MODE": mode})
        assert result.returncode == 0, (mode, result.returncode, result.stderr)
        assert expected in result.stdout, (mode, result.stdout[-1000:])
        assert len(result.stdout) < 17_000, "stderr capture must stay bounded"
        assert "test-relay-secret" not in result.stdout
        print(f"{mode}: PASS")
