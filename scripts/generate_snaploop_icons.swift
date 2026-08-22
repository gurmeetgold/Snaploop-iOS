#!/usr/bin/env swift
import AppKit
import Foundation

let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Sources/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

struct IconSpec {
    let filename: String
    let pixels: Int
}

let specs: [IconSpec] = [
    .init(filename: "Icon-20@1x.png", pixels: 20),
    .init(filename: "Icon-20@2x.png", pixels: 40),
    .init(filename: "Icon-20@3x.png", pixels: 60),
    .init(filename: "Icon-29@1x.png", pixels: 29),
    .init(filename: "Icon-29@2x.png", pixels: 58),
    .init(filename: "Icon-29@3x.png", pixels: 87),
    .init(filename: "Icon-40@1x.png", pixels: 40),
    .init(filename: "Icon-40@2x.png", pixels: 80),
    .init(filename: "Icon-40@3x.png", pixels: 120),
    .init(filename: "Icon-60@2x.png", pixels: 120),
    .init(filename: "Icon-60@3x.png", pixels: 180),
    .init(filename: "Icon-76@1x.png", pixels: 76),
    .init(filename: "Icon-76@2x.png", pixels: 152),
    .init(filename: "Icon-83.5@2x.png", pixels: 167),
    .init(filename: "Icon-1024.png", pixels: 1024)
]

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

let orange = color(0xFF9214)
let peach = color(0xFF7A2E)
let coral = color(0xFF4057)
let hotPink = color(0xFF0878)
let magenta = color(0xDE05BA)
let violet = color(0x8C1FFA)
let deepViolet = color(0x6E14D8)

func point(center: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPoint {
    CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
}

func makeIcon(pixels: Int) throws -> Data {
    let side = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high
    let bounds = NSRect(x: 0, y: 0, width: side, height: side)

    NSGradient(colors: [orange, peach, coral, hotPink, magenta, violet])!
        .draw(in: bounds, angle: -45)

    let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.23), NSColor.white.withAlphaComponent(0)])!
    glow.draw(in: NSRect(x: 0, y: side * 0.52, width: side, height: side * 0.48), angle: 90)

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let font = NSFont.systemFont(ofSize: side * 0.72, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
        .shadow: {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.18)
            s.shadowBlurRadius = side * 0.025
            s.shadowOffset = NSSize(width: 0, height: -side * 0.012)
            return s
        }()
    ]
    let sText = NSAttributedString(string: "S", attributes: attrs)
    let textHeight = font.ascender - font.descender
    sText.draw(in: NSRect(x: side * 0.08, y: (side - textHeight) * 0.50 - side * 0.01, width: side * 0.84, height: textHeight * 1.08))

    let center = CGPoint(x: side * 0.50, y: side * 0.50)
    let shutterRadius = side * 0.155
    let shutterRect = NSRect(
        x: center.x - shutterRadius,
        y: center.y - shutterRadius,
        width: shutterRadius * 2,
        height: shutterRadius * 2
    )
    let shutterCircle = NSBezierPath(ovalIn: shutterRect)
    NSGradient(colors: [coral, hotPink, magenta, deepViolet])!
        .draw(in: shutterCircle, angle: -45)

    let outer = shutterRadius * 0.92
    let inner = shutterRadius * 0.27
    for index in 0..<6 {
        let a0 = CGFloat(index) * (.pi / 3) - .pi / 2
        let a1 = a0 + .pi / 3
        let aMid = a0 + .pi / 6
        let blade = NSBezierPath()
        blade.move(to: point(center: center, radius: outer, angle: a0))
        blade.line(to: point(center: center, radius: outer, angle: a1))
        blade.line(to: point(center: center, radius: inner, angle: aMid))
        blade.close()
        NSColor.white.withAlphaComponent(0.98).setFill()
        blade.fill()
    }

    let centerDot = NSBezierPath(ovalIn: NSRect(
        x: center.x - side * 0.028,
        y: center.y - side * 0.028,
        width: side * 0.056,
        height: side * 0.056
    ))
    magenta.setFill()
    centerDot.fill()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [.compressionFactor: 0.95]) else {
        throw NSError(domain: "SnapLoopIconGenerator", code: 1)
    }
    return png
}

for spec in specs {
    let data = try makeIcon(pixels: spec.pixels)
    try data.write(to: output.appendingPathComponent(spec.filename), options: .atomic)
    print("Generated \(spec.filename)")
}

print("Instagram-palette SnapLoop S-aperture icons generated in \(output.path)")
