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

let coral = color(0xFF5757)
let pink = color(0xF52B7A)
let violet = color(0xA63DFF)
let blue = color(0x405CFF)

func drawRoundedLine(from a: CGPoint, to b: CGPoint, width: CGFloat) {
    let path = NSBezierPath()
    path.move(to: a)
    path.line(to: b)
    path.lineWidth = width
    path.lineCapStyle = .round
    NSColor.white.setStroke()
    path.stroke()
}

func makeIcon(pixels: Int) throws -> Data {
    let side = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    let bounds = NSRect(x: 0, y: 0, width: side, height: side)
    let gradient = NSGradient(colors: [coral, pink, violet, blue])!
    gradient.draw(in: bounds, angle: -45)

    let cameraRect = NSRect(x: side * 0.21, y: side * 0.25, width: side * 0.58, height: side * 0.43)
    let camera = NSBezierPath(roundedRect: cameraRect, xRadius: side * 0.11, yRadius: side * 0.11)
    NSColor.white.setFill()
    camera.fill()

    let humpRect = NSRect(x: side * 0.30, y: side * 0.63, width: side * 0.22, height: side * 0.09)
    let hump = NSBezierPath(roundedRect: humpRect, xRadius: side * 0.035, yRadius: side * 0.035)
    hump.fill()

    let lensRect = NSRect(x: side * 0.35, y: side * 0.315, width: side * 0.30, height: side * 0.30)
    let lens = NSBezierPath(ovalIn: lensRect)
    let lensGradient = NSGradient(colors: [pink, violet, blue])!
    lensGradient.draw(in: lens, angle: -45)

    let eyeSize = side * 0.038
    for x in [side * 0.445, side * 0.555] {
        NSBezierPath(ovalIn: NSRect(x: x - eyeSize / 2, y: side * 0.485, width: eyeSize, height: eyeSize)).fill()
    }

    let smile = NSBezierPath()
    smile.move(to: CGPoint(x: side * 0.44, y: side * 0.43))
    smile.curve(
        to: CGPoint(x: side * 0.56, y: side * 0.43),
        controlPoint1: CGPoint(x: side * 0.47, y: side * 0.38),
        controlPoint2: CGPoint(x: side * 0.53, y: side * 0.38)
    )
    smile.lineWidth = side * 0.032
    smile.lineCapStyle = .round
    NSColor.white.setStroke()
    smile.stroke()

    let inset = side * 0.14
    let arm = side * 0.10
    let line = max(2, side * 0.025)
    drawRoundedLine(from: CGPoint(x: inset, y: side - inset), to: CGPoint(x: inset + arm, y: side - inset), width: line)
    drawRoundedLine(from: CGPoint(x: inset, y: side - inset), to: CGPoint(x: inset, y: side - inset - arm), width: line)
    drawRoundedLine(from: CGPoint(x: side - inset, y: side - inset), to: CGPoint(x: side - inset - arm, y: side - inset), width: line)
    drawRoundedLine(from: CGPoint(x: side - inset, y: side - inset), to: CGPoint(x: side - inset, y: side - inset - arm), width: line)
    drawRoundedLine(from: CGPoint(x: inset, y: inset), to: CGPoint(x: inset + arm, y: inset), width: line)
    drawRoundedLine(from: CGPoint(x: inset, y: inset), to: CGPoint(x: inset, y: inset + arm), width: line)
    drawRoundedLine(from: CGPoint(x: side - inset, y: inset), to: CGPoint(x: side - inset - arm, y: inset), width: line)
    drawRoundedLine(from: CGPoint(x: side - inset, y: inset), to: CGPoint(x: side - inset, y: inset + arm), width: line)

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

print("SnapLoop icons generated in \(output.path)")
