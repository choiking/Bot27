import CFNetwork
import Foundation

/// Environment for the claude/codex CLIs. Apps opened from Finder don't inherit the shell's
/// proxy variables, so pass on the macOS system proxy (e.g. one set by Clash) when there is one.
enum CLIEnvironment {
    static func make() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        let hasProxy = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
            .contains { env[$0]?.isEmpty == false }
        if !hasProxy, let proxy = systemProxy() {
            for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] { env[key] = proxy }
            env["NO_PROXY"] = env["NO_PROXY"] ?? "localhost,127.0.0.1,::1,.local"
            env["no_proxy"] = env["no_proxy"] ?? env["NO_PROXY"]
        }
        return env
    }

    private static func systemProxy() -> String? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        for (enable, host, port) in [("HTTPSEnable", "HTTPSProxy", "HTTPSPort"), ("HTTPEnable", "HTTPProxy", "HTTPPort")] {
            if (settings[enable] as? Int) == 1, let h = settings[host] as? String, !h.isEmpty,
               let p = settings[port] as? Int {
                return "http://\(h):\(p)"
            }
        }
        return nil
    }
}
