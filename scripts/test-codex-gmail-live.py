#!/usr/bin/env python3
"""Opt-in Gmail metadata/policy check. No model turns and no mailbox tool calls.

Run with --live /absolute/path/to/codex after connecting Gmail in ChatGPT.
"""
import argparse
import ast
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
APP_ID = 'connector_2128aebfecb84f64a069897515042a44'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--live', required=True, metavar='CODEX_PATH')
args = parser.parse_args()

# Share the standalone adapter stubs without importing/executing the browser test.
module = ast.parse((ROOT / 'scripts/test-codex-browser-live.py').read_text())
support = next(ast.literal_eval(node.value) for node in module.body
               if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'HARNESS' for t in node.targets))
support = support.split('@main struct Harness')[0]
harness = support + r'''
@main struct Harness {
    static func main() async throws {
        let gmail = await CodexConnectors.discover(custom: CommandLine.arguments[1])
        let result: [String: Any] = ["status": gmail.status,
            "tools": gmail.allowedTools.map(Connector.shortName),
            "arguments": CodexConnectors.arguments(for: [gmail]),
            "environment": CLIEnvironment.make().filter {
                ["PATH", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"].contains($0.key)
            }]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }
}
'''
# Simulate a Finder launch. Swift's CLIEnvironment supplies the macOS system proxy.
env = {key: os.environ[key] for key in ['HOME', 'USER', 'LOGNAME', 'TMPDIR', 'SHELL'] if key in os.environ}
env['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
codex = str(Path(args.live).expanduser().absolute())
with tempfile.TemporaryDirectory(prefix='bot27-gmail-live-') as directory:
    tmp = Path(directory)
    source, binary = tmp / 'Harness.swift', tmp / 'check'
    source.write_text(harness)
    subprocess.run(['swiftc', '-parse-as-library', '-enable-bare-slash-regex', '-module-cache-path', str(tmp / 'modules'),
                    *[str(ROOT / 'Sources/Bot27' / name) for name in
                      ['NativeBrowser.swift', 'CodexCLI.swift', 'CLIEnvironment.swift', 'CodexConnectors.swift', 'Connectors.swift']],
                    str(source), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), codex], env=env, capture_output=True, text=True, timeout=40, check=True)
    discovered = json.loads(result.stdout)
    assert discovered['status'] == 'connected', discovered['status']
    assert {'search_emails', 'read_email', 'batch_read_email', 'create_draft'} <= set(discovered['tools']), discovered['tools']
    assert not {'send_email', 'send_draft', 'delete_emails', 'archive_emails'} & set(discovered['tools'])
    print('PASS: production Swift discovery, ChatGPT Gmail login, read/draft allowlist')
    env.update(discovered['environment'])

    # Inspect effective runtime policy in an ephemeral session. Never send turn/start
    # or mcpServer/tool/call: this test cannot ask a model to access the mailbox.
    process = subprocess.Popen([codex, 'app-server', '-c', 'features.plugins=false',
                                *discovered['arguments']], cwd=directory, env=env,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    lines = queue.Queue()
    def drain():
        for line in process.stdout:
            lines.put(json.loads(line))
        lines.put(None)
    threading.Thread(target=drain, daemon=True).start()
    next_id = 0
    def rpc(method, params):
        global next_id
        assert method in {'initialize', 'thread/start', 'app/installed', 'mcpServerStatus/list'}
        next_id += 1
        process.stdin.write(json.dumps({'id': next_id, 'method': method, 'params': params}) + '\n')
        process.stdin.flush()
        deadline = time.monotonic() + 40
        while True:
            response = lines.get(timeout=max(0.1, deadline - time.monotonic()))
            assert response is not None, 'app-server exited'
            if response.get('id') != next_id:
                assert time.monotonic() < deadline, method
                continue
            assert 'error' not in response, response.get('error')
            return response['result']
    try:
        rpc('initialize', {'clientInfo': {'name': 'bot27', 'version': '1.0'},
                           'capabilities': {'experimentalApi': True, 'explicitGatewayOauth': True}})
        process.stdin.write('{"method":"initialized"}\n'); process.stdin.flush()
        thread = rpc('thread/start', {'ephemeral': True, 'cwd': directory})['thread']['id']
        apps = rpc('app/installed', {'threadId': thread, 'forceRefresh': True})['apps']
        assert any(a['id'] == APP_ID and a['callable'] for a in apps), apps
        assert all(not a['callable'] for a in apps if a['id'] != APP_ID)
        inventory = rpc('mcpServerStatus/list', {'threadId': thread, 'serverName': 'codex_apps', 'detail': 'toolsAndAuthOnly'})
        tools = next(s['tools'] for s in inventory['data'] if s['name'] == 'codex_apps')
        # Per-app policy keys match these public titles, not the raw dotted MCP names.
        for tool in discovered['tools']:
            assert tools['gmail.' + tool]['title'] == tool
        print('PASS: Gmail callable, every other app blocked, tool policy titles match runtime')
        config = {f'apps.{APP_ID}.tools.{tool}.enabled': False for tool in discovered['tools']}
        blocked_thread = rpc('thread/start', {'ephemeral': True, 'cwd': directory, 'config': config})['thread']['id']
        blocked = rpc('app/installed', {'threadId': blocked_thread, 'forceRefresh': True})['apps']
        assert all(not a['callable'] for a in blocked), 'Non-allowlisted tools became callable'
        print('PASS: with the allowlist off, no Gmail tool is callable (default deny)')
        print('No model turns, email reads, drafts, sends or deletions were performed.')
    finally:
        process.terminate()
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()
