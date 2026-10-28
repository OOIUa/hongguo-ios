import AppKit
let target = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let rect = NSRect(origin: .zero, size: size)
NSGradient(starting: NSColor(srgbRed: 0.93, green: 0.33, blue: 0.15, alpha: 1), ending: NSColor(srgbRed: 0.71, green: 0.16, blue: 0.07, alpha: 1))!.draw(in: rect, angle: -45)
let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
let font = NSFont(name: "PingFangSC-Semibold", size: 680) ?? NSFont.systemFont(ofSize: 680, weight: .semibold)
("果" as NSString).draw(in: NSRect(x: 0, y: 105, width: 1024, height: 800), withAttributes: [.font:font, .foregroundColor:NSColor.white, .paragraphStyle:paragraph])
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: target))
