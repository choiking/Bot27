import AppKit
import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// `Bot27 --computer-mcp`: a small MCP server (JSON-RPC over stdio) that lets Claude see the main
/// display and use the mouse and keyboard. Bot27 hands it to the claude CLI for bots with computer
/// use turned on. The actions themselves run in the Bot27 app (see `ComputerRelay`), because
/// macOS doesn't count this grandchild process as Bot27 for Screen Recording and Accessibility.
enum ComputerMCP {
    static let server = "bot27_computer"
    static let toolNames = ["screenshot", "click", "type", "key", "scroll", "drag", "open_app", "wait"]
    static var toolIDs: [String] { toolNames.map { "mcp__\(server)__\($0)" } }

    /// Screenshots are scaled to this width; coordinates the model sends are in that space.
    private static let imageWidth: CGFloat = 1280

    static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = message["id"] else { continue }  // notifications need no reply
            let params = message["params"] as? [String: Any] ?? [:]
            switch message["method"] as? String ?? "" {
            case "initialize":
                reply(id, ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                           "capabilities": ["tools": [String: Any]()],
                           "serverInfo": ["name": "bot27-computer", "version": "1.0"]])
            case "tools/list":
                reply(id, ["tools": tools])
            case "tools/call":
                reply(id, ComputerRelay.forward(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:]))
            case "ping":
                reply(id, [:])
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
            }
        }
        exit(0)
    }

    private static func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
        fflush(stdout)
    }

    // MARK: - Tools

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    private static let xy: [String: Any] = [
        "x": ["type": "number", "description": "X in screenshot pixels"],
        "y": ["type": "number", "description": "Y in screenshot pixels"],
    ]

    private static let tools: [[String: Any]] = [
        ["name": "screenshot",
         "description": "Capture the main display. Always look before acting; coordinates for other tools are pixels in this image.",
         "inputSchema": schema([:])],
        ["name": "click",
         "description": "Click at a point from the latest screenshot. Returns a new screenshot.",
         "inputSchema": schema(xy.merging([
             "button": ["type": "string", "enum": ["left", "right"]],
             "double": ["type": "boolean", "description": "Double-click"],
         ]) { $1 }, required: ["x", "y"])],
        ["name": "type",
         "description": "Type text at the keyboard focus (any language; \\n presses Return). Returns a new screenshot.",
         "inputSchema": schema(["text": ["type": "string"]], required: ["text"])],
        ["name": "key",
         "description": "Press a key or shortcut, e.g. \"return\", \"escape\", \"cmd+l\", \"cmd+shift+t\", \"down\". Returns a new screenshot.",
         "inputSchema": schema(["keys": ["type": "string"]], required: ["keys"])],
        ["name": "scroll",
         "description": "Scroll at a point. Returns a new screenshot.",
         "inputSchema": schema(xy.merging([
             "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
             "amount": ["type": "number", "description": "Lines, default 5"],
         ]) { $1 }, required: ["x", "y", "direction"])],
        ["name": "drag",
         "description": "Drag from one point to another. Returns a new screenshot.",
         "inputSchema": schema([
             "from_x": ["type": "number"], "from_y": ["type": "number"],
             "to_x": ["type": "number"], "to_y": ["type": "number"],
         ], required: ["from_x", "from_y", "to_x", "to_y"])],
        ["name": "open_app",
         "description": "Open or switch to an app by name, e.g. \"Safari\", \"Notes\". Returns a new screenshot.",
         "inputSchema": schema(["name": ["type": "string"]], required: ["name"])],
        ["name": "wait",
         "description": "Wait for something to load, then return a new screenshot.",
         "inputSchema": schema(["seconds": ["type": "number"]], required: ["seconds"])],
    ]

    private struct Failure: Error { let message: String }

    static func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    /// Runs one tool call. Called inside the Bot27 app, which holds the permissions.
    static func perform(_ name: String, _ args: [String: Any]) -> [String: Any] {
        func number(_ key: String) throws -> CGFloat {
            guard let n = args[key] as? NSNumber else { throw Failure(message: "Missing \(key).") }
            return CGFloat(n.doubleValue)
        }
        do {
            let note: String
            switch name {
            case "screenshot":
                return try screenshotResult(note: nil)
            case "click":
                let x = try number("x"), y = try number("y")
                let p = try point(x, y)
                try requireAccessibility()
                let double = args["double"] as? Bool == true
                click(at: p, right: args["button"] as? String == "right", count: double ? 2 : 1)
                note = "\(double ? "Double-clicked" : "Clicked") at (\(Int(x)), \(Int(y)))."
            case "type":
                guard let text = args["text"] as? String else { throw Failure(message: "Missing text.") }
                try requireAccessibility()
                type(text)
                note = "Typed \(text.count) characters."
            case "key":
                guard let keys = args["keys"] as? String else { throw Failure(message: "Missing keys.") }
                try requireAccessibility()
                try press(keys)
                note = "Pressed \(keys)."
            case "scroll":
                let p = try point(number("x"), number("y"))
                try requireAccessibility()
                let direction = args["direction"] as? String ?? "down"
                scroll(at: p, direction: direction, lines: Int32((args["amount"] as? NSNumber)?.intValue ?? 5))
                note = "Scrolled \(direction)."
            case "drag":
                let from = try point(number("from_x"), number("from_y"))
                let to = try point(number("to_x"), number("to_y"))
                try requireAccessibility()
                drag(from: from, to: to)
                note = "Dragged."
            case "open_app":
                guard let app = args["name"] as? String else { throw Failure(message: "Missing name.") }
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = ["-a", app]
                try open.run()
                open.waitUntilExit()
                guard open.terminationStatus == 0 else { throw Failure(message: "Couldn't find an app named \(app).") }
                usleep(1_200_000)
                note = "Opened \(app)."
            case "wait":
                let seconds = min(max((args["seconds"] as? NSNumber)?.doubleValue ?? 1, 0), 30)
                usleep(UInt32(seconds * 1_000_000))
                note = "Waited \(seconds)s."
            default:
                throw Failure(message: "Unknown tool \(name).")
            }
            usleep(600_000)  // let the screen settle before looking again
            return try screenshotResult(note: note)
        } catch {
            return failure((error as? Failure)?.message ?? error.localizedDescription)
        }
    }

    // MARK: - Screen

    private static var display: CGRect { CGDisplayBounds(CGMainDisplayID()) }

    /// Points per screenshot pixel.
    private static var scale: CGFloat { display.width > imageWidth ? display.width / imageWidth : 1 }

    private static func point(_ x: CGFloat, _ y: CGFloat) throws -> CGPoint {
        let size = CGSize(width: display.width / scale, height: display.height / scale)
        guard x >= 0, y >= 0, x <= size.width, y <= size.height else {
            throw Failure(message: "(\(Int(x)), \(Int(y))) is outside the \(Int(size.width))×\(Int(size.height)) screenshot.")
        }
        return CGPoint(x: display.minX + x * scale, y: display.minY + y * scale)
    }

    private static func screenshotResult(note: String?) throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            throw Failure(message: "Bot27 doesn't have Screen Recording permission. Ask the user to allow Bot27 in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Bot27.")
        }
        let path = NSTemporaryDirectory() + "bot27-screen-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-m", "-t", "png", path]
        try capture.run()
        capture.waitUntilExit()
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(message: "Couldn't capture the screen.")
        }
        let w = Int(display.width / scale), h = Int(display.height / scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw Failure(message: "Couldn't scale the screenshot.")
        }
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        let jpeg = NSMutableData()
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure(message: "Couldn't encode the screenshot.")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let text = [note, "Screenshot of the main display, \(w)×\(h) pixels."].compactMap { $0 }.joined(separator: " ")
        return ["content": [
            ["type": "text", "text": text],
            ["type": "image", "data": (jpeg as Data).base64EncodedString(), "mimeType": "image/jpeg"],
        ]]
    }

    // MARK: - Mouse & keyboard

    private static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw Failure(message: "Bot27 doesn't have Accessibility permission, so it can't use the mouse or keyboard. Ask the user to allow Bot27 in System Settings → Privacy & Security → Accessibility, then reopen Bot27.")
        }
    }

    private static let source = CGEventSource(stateID: .hidSystemState)

    private static func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clicks: Int64 = 1) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: clicks)
        event?.post(tap: .cghidEventTap)
    }

    private static func click(at p: CGPoint, right: Bool, count: Int) {
        post(.mouseMoved, p)
        usleep(50_000)
        for n in 1...count {
            post(right ? .rightMouseDown : .leftMouseDown, p, right ? .right : .left, clicks: Int64(n))
            usleep(30_000)
            post(right ? .rightMouseUp : .leftMouseUp, p, right ? .right : .left, clicks: Int64(n))
            usleep(60_000)
        }
    }

    private static func drag(from: CGPoint, to: CGPoint) {
        post(.mouseMoved, from)
        post(.leftMouseDown, from)
        usleep(150_000)
        for step in 1...20 {
            let t = CGFloat(step) / 20
            post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            usleep(15_000)
        }
        post(.leftMouseUp, to)
    }

    private static func scroll(at p: CGPoint, direction: String, lines: Int32) {
        post(.mouseMoved, p)
        let dy: Int32, dx: Int32
        switch direction {
        case "up": (dy, dx) = (lines, 0)
        case "left": (dy, dx) = (0, lines)
        case "right": (dy, dx) = (0, -lines)
        default: (dy, dx) = (-lines, 0)
        }
        CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    /// Types one character at a time. Keyboard characters are sent as real key presses, since
    /// some apps (Calculator, terminals) ignore Unicode-only events; anything else (Chinese,
    /// emoji, accents) goes as a Unicode event per character.
    private static func type(_ text: String) {
        for character in text {
            if character == "\n" || character == "\r" {
                tap(36, flags: [])
            } else if character == "\t" {
                tap(48, flags: [])
            } else if let (code, shift) = keyPress(for: character) {
                tap(code, flags: shift ? .maskShift : [])
            } else {
                let units = Array(String(character).utf16)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    event?.post(tap: .cghidEventTap)
                }
                usleep(15_000)
            }
        }
    }

    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// The US-layout key (and whether Shift is held) for a plain keyboard character.
    private static func keyPress(for character: Character) -> (CGKeyCode, Bool)? {
        if character == " " { return (49, false) }
        if let base = shifted[character], let code = keyCodes[String(base)] { return (code, true) }
        if character.isUppercase, character.isASCII, let code = keyCodes[character.lowercased()] { return (code, true) }
        if character.isASCII, let code = keyCodes[String(character)] { return (code, false) }
        return nil
    }

    private static func tap(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    private static func press(_ combo: String) throws {
        var flags: CGEventFlags = []
        var code: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "meta", "super": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default:
                guard let c = keyCodes[part] else { throw Failure(message: "Unknown key \"\(part)\".") }
                code = c
            }
        }
        guard let code else { throw Failure(message: "No key in \"\(combo)\".") }
        tap(code, flags: flags)
    }

    private static let keyCodes: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "\\": 42, "`": 50,
        ]
        let keys: [(String, CGKeyCode)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32),
            ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("9", 25), ("7", 26), ("8", 28), ("0", 29),
        ]
        for (k, v) in keys { map[k] = v }
        return map
    }()
}
