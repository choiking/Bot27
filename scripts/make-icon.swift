// Renders the 1024px app icon: usage `swift scripts/make-icon.swift out.png`
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let box = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.addPath(CGPath(roundedRect: box, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.9, alpha: 1)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.resetClip()

// The default bot: a black circle with one white eye (matches BotAvatar shape 0).
func disc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ gray: CGFloat) {
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}
disc(512, 512, 290, 0.06)
disc(512 + 87, 512 + 70, 99, 1)
disc(512 + 96, 512 + 76, 38, 0.06)

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
