// SPDX-License-Identifier: GPL-3.0-only
// Exact geometry from Branding/Android, Android 0.7.8 commit 69c1d5a.
import AppKit

let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let appIcon = project.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let brandLogo = project.appendingPathComponent("Resources/Assets.xcassets/BrandLogo.imageset/BrandLogo.png")
let sourceIcon = project.appendingPathComponent("distribution/icon.png")

func drawBrand(_ context: CGContext) {
    context.setFillColor(CGColor(srgbRed: 232.0 / 255, green: 70.0 / 255, blue: 63.0 / 255, alpha: 1))
    let fruit = CGMutablePath()
    fruit.addEllipse(in: CGRect(x: 34, y: 38, width: 40, height: 40))
    fruit.move(to: CGPoint(x: 50.75, y: 50.31))
    fruit.addQuadCurve(to: CGPoint(x: 48.50, y: 51.60), control: CGPoint(x: 48.50, y: 49.00))
    fruit.addLine(to: CGPoint(x: 48.50, y: 64.40))
    fruit.addQuadCurve(to: CGPoint(x: 50.75, y: 65.69), control: CGPoint(x: 48.50, y: 67.00))
    fruit.addLine(to: CGPoint(x: 61.75, y: 59.31))
    fruit.addQuadCurve(to: CGPoint(x: 61.75, y: 56.69), control: CGPoint(x: 64.00, y: 58.00))
    fruit.closeSubpath()
    context.addPath(fruit)
    context.drawPath(using: .eoFill)
    let leaf = CGMutablePath()
    leaf.move(to: CGPoint(x: 55, y: 37))
    leaf.addCurve(to: CGPoint(x: 68.5, y: 25), control1: CGPoint(x: 55, y: 29.5), control2: CGPoint(x: 60.5, y: 25))
    leaf.addCurve(to: CGPoint(x: 55, y: 37), control1: CGPoint(x: 68.5, y: 32.5), control2: CGPoint(x: 63, y: 37))
    leaf.closeSubpath()
    context.addPath(leaf)
    context.fillPath()
}

func render(pixels: Int, transparent: Bool, viewport: CGFloat, translation: CGPoint = .zero) throws -> Data {
    let alpha = transparent ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.setAllowsAntialiasing(true)
    let canvas = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    if transparent { context.clear(canvas) }
    else {
        // iOS applies its own icon mask; fill the square with Android's #FFF9F6.
        context.setFillColor(CGColor(srgbRed: 1, green: 249.0 / 255, blue: 246.0 / 255, alpha: 1))
        context.fill(canvas)
    }
    context.translateBy(x: 0, y: CGFloat(pixels))
    let scale = CGFloat(pixels) / viewport
    context.scaleBy(x: scale, y: -scale)
    context.translateBy(x: translation.x, y: translation.y)
    drawBrand(context)
    guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

let icon = try render(pixels: 1024, transparent: false, viewport: 108)
for path in [appIcon, sourceIcon] {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try icon.write(to: path, options: .atomic)
}
try FileManager.default.createDirectory(at: brandLogo.deletingLastPathComponent(), withIntermediateDirectories: true)
try render(pixels: 224, transparent: true, viewport: 56, translation: CGPoint(x: -26, y: -23.5))
    .write(to: brandLogo, options: .atomic)
print("Generated Android-matched AppIcon (1024, opaque), BrandLogo (224), and distribution/icon.png")
