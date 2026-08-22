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

let orange = color(0xFF5C28)
let coral = color(0xFF3858)
let hotPink = color(0xFF0879)
let magenta = color(0xF000E2)
let violet = color(0x870AFF)
let electricBlue = color(0x1446FF)
let deepMagenta = color(0xA000A0)

func makeIcon(pixels: Int) throws -> Data {
    let side = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    let bounds = NSRect(x: 0, y: 0, width: side, height: side)
    let background = NSGradient(colors: [orange, coral, hotPink, magenta, violet, electricBlue])!
    background.draw(in: bounds, angle: -45)

    // Gloss highlight: keeps the icon vivid without washing out the gradient.
    let glossRect = NSRect(x: 0, y: side * 0.48, width: side, height: side * 0.52)
    let gloss = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0.0)])!
    gloss.draw(in: glossRect, angle: 90)

    // Bright white S loop.
    let sPath = NSBezierPath()
    sPath.move(to: CGPoint(x: side * 0.74, y: side * 0.74))
    sPath.line(to: CGPoint(x: side * 0.42, y: side * 0.74))
    sPath.curve(
        to: CGPoint(x: side * 0.39, y: side * 0.50),
        controlPoint1: CGPoint(x: side * 0.21, y: side * 0.74),
        controlPoint2: CGPoint(x: side * 0.21, y: side * 0.55)
    )
    sPath.curve(
        to: CGPoint(x: side * 0.61, y: side * 0.50),
        controlPoint1: CGPoint(x: side * 0.44, y: side * 0.51),
        controlPoint2: CGPoint(x: side * 0.56, y: side * 0.49)
    )
    sPath.curve(
        to: CGPoint(x: side * 0.26, y: side * 0.26),
        controlPoint1: CGPoint(x: side * 0.79, y: side * 0.51),
        controlPoint2: CGPoint(x: side * 0.79, y: side * 0.26)
    )
    sPath.line(to: CGPoint(x: side * 0.59, y: side * 0.26))
    sPath.lineWidth = max(3, side * 0.145)
    sPath.lineCapStyle = .round
    sPath.lineJoinStyle = .round
    NSColor.white.setStroke()

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
    shadow.shadowBlurRadius = side * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.012)
    shadow.set()
    sPath.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // Central photographic shutter.
    let shutterRect = NSRect(x: side * 0.34, y: side * 0.34, width: side * 0.32, height: side * 0.32)
    let shutterCircle = NSBezierPath(ovalIn: shutterRect)
    let shutterGradient = NSGradient(colors: [hotPink, deepMagenta, violet])!
    shutterGradient.draw(in: shutterCircle, angle: -45)

    let center = CGPoint(x: side * 0.50, y: side * 0.50)
    let outer = side * 0.150
    let inner = side * 0.045

    for i in 0..<6 {
        let a0 = CGFloat(i) * (.pi / 3) - .pi / 2
        let a1 = a0 + .pi / 3
        let aMid = a0 + .pi / 6

        let p1 = CGPoint(x: center.x + cos(a0) * outer, y: center.y + sin(a0) * outer)
        let p2 = CGPoint(x: center.x + cos(a1) * outer, y: center.y + sin(a1) * outer)
        let p3 = CGPoint(x: center.x + cos(aMid) * inner, y: center.y + sin(aMid) * inner)

        let blade = NSBezierPath()
        blade.move(to: p1)
        blade.line(to: p2)
        blade.line(to: p3)
        blade.close()
        NSColor.white.withAlphaComponent(0.98).setFill()
        blade.fill()
    }

    let centerCircle = NSBezierPath(ovalIn: NSRect(
        x: center.x - side * 0.032,
        y: center.y - side * 0.032,
        width: side * 0.064,
        height: side * 0.064
    ))
    violet.setFill()
    centerCircle.fill()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SnapLoopIconGenerator", code: 1)
    }
    return png
}

for spec in specs {
    let data = try makeIcon(pixels: spec.pixels)
    try data.write(to: output.appendingPathComponent(spec.filename), options: .atomic)
    print("Generated \(spec.filename)")
}

print("Vibrant SnapLoop S-shutter icons generated in \(output.path)")
