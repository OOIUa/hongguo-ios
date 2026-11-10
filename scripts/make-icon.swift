// SPDX-License-Identifier: GPL-3.0-only
// Exact geometry from Branding/Android, Android 0.7.8 commit 69c1d5a.
import AppKit

let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let appIcon = project.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let brandLogo = project.appendingPathComponent("Resources/Assets.xcassets/BrandLogo.imageset/BrandLogo.png")
let appIconDark = project.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark.png")
let appIconTinted = project.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-Tinted.png")
let sourceIcon = project.appendingPathComponent("distribution/icon.png")

let brandRed = CGColor(srgbRed: 232.0 / 255, green: 70.0 / 255, blue: 63.0 / 255, alpha: 1)
let lightBackground = CGColor(srgbRed: 1, green: 249.0 / 255, blue: 246.0 / 255, alpha: 1)

// Android's 108dp adaptive canvas only shows its inner ~72dp through the launcher mask,
// so rendering all 108dp on iOS left the mark tiny (issue #5). The iOS icon shows an
// 80-unit window, centred on the mark (y 25…78 → 51.5) nudged 1pt toward the heavy fruit.
let iconViewport: CGFloat = 80
let iconOffset = CGPoint(x: iconViewport / 2 - 54, y: iconViewport / 2 - 52.5)

func drawBrand(_ context: CGContext, color: CGColor = brandRed) {
    context.setFillColor(color)
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

func render(pixels: Int, background: CGColor?, viewport: CGFloat, translation: CGPoint = .zero,
    color: CGColor = brandRed) throws -> Data {
    let transparent = background == nil
    let alpha = transparent ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.setAllowsAntialiasing(true)
    let canvas = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    if let background {
        // iOS applies its own icon mask; fill the whole square.
        context.setFillColor(background)
        context.fill(canvas)
    } else { context.clear(canvas) }
    context.translateBy(x: 0, y: CGFloat(pixels))
    let scale = CGFloat(pixels) / viewport
    context.scaleBy(x: scale, y: -scale)
    context.translateBy(x: translation.x, y: translation.y)
    drawBrand(context, color: color)
    guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

func write(_ data: Data, to path: URL) throws {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: path, options: .atomic)
}

// Light: Android's #FFF9F6 square. Dark: transparent so iOS supplies its dark backdrop.
// Tinted: white mark on black; iOS maps luminance to the user's tint colour.
let icon = try render(pixels: 1024, background: lightBackground, viewport: iconViewport, translation: iconOffset)
try write(icon, to: appIcon)
try write(icon, to: sourceIcon)
try write(try render(pixels: 1024, background: nil, viewport: iconViewport, translation: iconOffset), to: appIconDark)
try write(try render(pixels: 1024, background: CGColor(gray: 0, alpha: 1), viewport: iconViewport,
    translation: iconOffset, color: CGColor(gray: 1, alpha: 1)), to: appIconTinted)
try write(try render(pixels: 224, background: nil, viewport: 56, translation: CGPoint(x: -26, y: -23.5)), to: brandLogo)
print("Generated AppIcon light/dark/tinted (1024), BrandLogo (224), and distribution/icon.png")
