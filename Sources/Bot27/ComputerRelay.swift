import Foundation

/// Runs computer-use actions inside the Bot27 app, where the user granted Screen Recording and
/// Accessibility. The `--computer-mcp` process (started by the claude CLI) only forwards each tool
/// call here over a Unix socket in the user's Application Support folder.
final class ComputerRelay: @unchecked Sendable {
    static let shared = ComputerRelay()

    /// New every launch; handed to the MCP process through its environment.
    let token = UUID().uuidString
    let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Bot27/computer.sock").path

    private let lock = NSLock()
    private var _active = false

    /// Requests are refused unless a bot with computer use is running right now.
    var active: Bool {
        get { lock.withLock { _active } }
        set { lock.withLock { _active = newValue } }
    }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Thread.detachNewThread { [self] in serve() }
    }

    private func serve() {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, UnixSocket.withAddress(path, { bind(fd, $0, $1) }) == 0 else { return }
        chmod(path, 0o600)
        guard listen(fd, 4) == 0 else { return }
        while true {
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { continue }
            UnixSocket.prepare(conn)
            handle(conn)  // one action at a time, in order
            close(conn)
        }
    }

    private func handle(_ conn: Int32) {
        func respond(_ result: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: result) { UnixSocket.send(conn, data) }
        }
        guard let line = UnixSocket.receiveLine(conn),
              let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              request["token"] as? String == token else { return }
        guard active else {
            respond(ComputerMCP.failure("Computer use isn't active in Bot27 right now."))
            return
        }
        respond(ComputerMCP.perform(request["name"] as? String ?? "",
                                    request["arguments"] as? [String: Any] ?? [:]))
    }

    /// Called by the MCP process for each tool call.
    static func forward(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["BOT27_RELAY_SOCKET"], let token = env["BOT27_RELAY_TOKEN"] else {
            return ComputerMCP.failure("Bot27 didn't start this computer-use server.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        guard fd >= 0, UnixSocket.withAddress(path, { connect(fd, $0, $1) }) == 0 else {
            return ComputerMCP.failure("Couldn't reach Bot27. Is it still open?")
        }
        UnixSocket.prepare(fd)
        guard let request = try? JSONSerialization.data(withJSONObject: ["token": token, "name": name, "arguments": arguments]) else {
            return ComputerMCP.failure("Couldn't encode the request.")
        }
        UnixSocket.send(fd, request)
        guard let line = UnixSocket.receiveLine(fd),
              let result = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return ComputerMCP.failure("Bot27 didn't answer.")
        }
        return result
    }
}

/// Newline-delimited JSON over a Unix domain socket.
enum UnixSocket {
    static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (i, b) in bytes.enumerated() { buffer[i] = b }
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// No SIGPIPE if the other side goes away; give up on a silent peer after a minute.
    static func prepare(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func send(_ fd: Int32, _ data: Data) {
        var payload = data
        payload.append(10)
        payload.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    static func receiveLine(_ fd: Int32) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            if let end = chunk[0..<n].firstIndex(of: 10) {
                data.append(contentsOf: chunk[0..<end])
                return data
            }
            data.append(contentsOf: chunk[0..<n])
        }
    }
}
