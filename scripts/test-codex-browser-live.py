#!/usr/bin/env python3
"""Opt-in, read-only check of the production Swift adapter and installed OpenAI runtime.

Uses the signed-in Codex account (one model request). Does not navigate, click, type,
or expose page contents. Run with --live /absolute/path/to/codex.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation
struct AppConfig {
    enum Provider: String { case claude, gpt, xai; var canUseComputer: Bool { self != .xai } }
    var codexPath: String
    var gptModel = "gpt-6-astra"
    var systemPrompt = NativeBrowser.botRules
}
struct Message {}
enum ClaudeCLI {
    static func prompt(for messages: [Message]) -> (text: String, images: [String]) {
        ("This is a read-only integration check. Call mcp__cua_repl.js exactly once with code: let app = await cua.getApp(\"com.google.Chrome\"); . Do not click, type, navigate, create tabs, or use other tools. If reading the Chrome window succeeds, reply with exactly BROWSER_READ_OK. Otherwise report the error. Never include page contents or personal data.", [])
    }
}
enum ClaudeError: LocalizedError {
    case failed(String)
    var errorDescription: String? { switch self { case .failed(let text): return text } }
}
struct ComputerRelay { static let shared = ComputerRelay(); let path = ""; let token = "unused" }
enum ComputerMCP { static let server = "bot27_computer" }
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
        do {
            let client = CodexCLI(config: AppConfig(codexPath: CommandLine.arguments[1]),
                                  onActivity: { if !$0.isEmpty { print("TOOL " + $0) } },
                                  browserUse: true, onBrowser: { print("BROWSER_CALLBACK") })
            for try await text in client.stream([]) { print(text) }
        } catch { print("FAILURE: " + error.localizedDescription); exit(1) }
    }
}
'''

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--live', metavar='CODEX_PATH', required=True)
args = parser.parse_args()
codex = str(Path(args.live).expanduser().absolute())
with tempfile.TemporaryDirectory(prefix='bot27-native-browser-') as directory:
    tmp = Path(directory)
    harness, binary = tmp / 'Harness.swift', tmp / 'check'
    harness.write_text(HARNESS)
    subprocess.run([
        'swiftc', '-parse-as-library', '-enable-bare-slash-regex', '-module-cache-path', str(tmp / 'modules'),
        *[str(ROOT / 'Sources/Bot27' / name) for name in ['NativeBrowser.swift', 'CodexCLI.swift', 'CLIEnvironment.swift', 'CodexConnectors.swift', 'Connectors.swift']],
        str(harness), '-o', str(binary),
    ], check=True)
    # Simulate a GUI launch, without inheriting the parent Codex session's runtime
    # connection variables, proxy configuration, plugin credentials, or shell PATH.
    env = {key: os.environ[key] for key in ['HOME', 'USER', 'LOGNAME', 'TMPDIR', 'SHELL'] if key in os.environ}
    env['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
    result = subprocess.run([str(binary), codex], env=env, capture_output=True, text=True, timeout=100)
    assert result.returncode == 0, result.stdout + result.stderr[-2000:]
    assert 'TOOL Browser · js' in result.stdout, result.stdout
    assert 'BROWSER_CALLBACK' in result.stdout, result.stdout
    assert 'BROWSER_READ_OK' in result.stdout, result.stdout
    assert 'claude-in-chrome' not in result.stdout, result.stdout
    print('PASS: production Swift adapter → Codex → OpenAI cua_repl → read-only Chrome window')
    print('PASS: GUI-like environment; browser activity callback; no Claude MCP')
