import AppKit
import UniformTypeIdentifiers

/// Attached images live as downscaled JPEGs in Application Support; messages keep only file names.
enum ImageStore {
    static let maxSide: CGFloat = 1568

    static let dir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bot27/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let cache = NSCache<NSString, NSImage>()

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static func image(_ name: String) -> NSImage? {
        if let hit = cache.object(forKey: name as NSString) { return hit }
        guard let image = NSImage(contentsOf: url(name)) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    static func base64(_ name: String) -> String? {
        try? Data(contentsOf: url(name)).base64EncodedString()
    }

    static func isImage(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) ?? false
    }

    static func save(fileURL: URL) -> String? {
        guard isImage(fileURL), let image = NSImage(contentsOf: fileURL) else { return nil }
        return save(image)
    }

    /// Downscales to fit `maxSide`, flattens onto white, and writes a JPEG. Safe off the main thread.
    static func save(_ image: NSImage) -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let w = max(1, Int(CGFloat(cg.width) * scale)), h = max(1, Int(CGFloat(cg.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return nil }
        let name = UUID().uuidString + ".jpg"
        do { try data.write(to: url(name)) } catch { return nil }
        return name
    }

    static func delete(_ names: [String]) {
        for name in names {
            cache.removeObject(forKey: name as NSString)
            try? FileManager.default.removeItem(at: url(name))
        }
    }

    /// Loads images from a drag-and-drop (Finder files, or image data from other apps).
    static func load(_ providers: [NSItemProvider], into handler: @escaping @MainActor (String) -> Void) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    // Finder hands over file-reference URLs as data; resolve them to a path.
                    let raw = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (item as? URL)
                    let url = (raw as NSURL?)?.filePathURL ?? raw
                    guard let url, let name = save(fileURL: url) else { return }
                    Task { @MainActor in handler(name) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage, let name = save(image) else { return }
                    Task { @MainActor in handler(name) }
                }
            }
        }
    }
}
