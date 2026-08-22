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

let orange = color(0xFF5A2B)
let hotPink = color(0xFF147D)
let magenta = color(0xE20BCE)
let violet = color(0x8D19FF)
let electricBlue = color(0x2450FF)
let deepMagenta = color(0x7A0878)

func makeIcon(pixels: Int) throws -> Data {
    let side = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    let bounds = NSRect(x: 0, y: 0, width: side, height: side)
    let background = NSGradient(colors: [orange, hotPink, magenta, violet, electricBlue])!
    background.draw(in: bounds, angle: -45)

    // Large S loop, inspired by the selected SnapLoop mark.
    let sPath = NSBezierPath()
    sPath.move(to: CGPoint(x: side * 0.73, y: side * 0.73))
    sPath.line(to: CGPoint(x: side * 0.42, y: side * 0.73))
    sPath.curve(
        to: CGPoint(x: side * 0.39, y: side * 0.50),
        controlPoint1: CGPoint(x: side * 0.22, y: side * 0.73),
        controlPoint2: CGPoint(x: side * 0.22, y: side * 0.55)
    )
    sPath.curve(
        to: CGPoint(x: side * 0.61, y: side * 0.50),
        controlPoint1: CGPoint(x: side * 0.44, y: side * 0.51),
        controlPoint2: CGPoint(x: side * 0.56, y: side * 0.49)
    )
    sPath.curve(
        to: CGPoint(x: side * 0.27, y: side * 0.27),
        controlPoint1: CGPoint(x: side * 0.78, y: side * 0.51),
        controlPoint2: CGPoint(x: side * 0.78, y: side * 0.27)
    )
    sPath.line(to: CGPoint(x: side * 0.58, y: side * 0.27))
    sPath.lineWidth = max(3, side * 0.135)
    sPath.lineCapStyle = .round
    sPath.lineJoinStyle = .round
    NSColor.white.setStroke()
    sPath.stroke()

    // Central shutter.
    let shutterRect = NSRect(x: side * 0.345, y: side * 0.345, width: side * 0.31, height: side * 0.31)
    let shutterCircle = NSBezierPath(ovalIn: shutterRect)
    deepMagenta.setFill()
    shutterCircle.fill()

    let center = CGPoint(x: side * 0.50, y: side * 0.50)
    let outer = side * 0.145
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
        NSColor(calibratedWhite: 1.0, alpha: 0.94).setFill()
        blade.fill()
    }

    let centerCircle = NSBezierPath(ovalIn: NSRect(
        x: center.x - side * 0.034,
        y: center.y - side * 0.034,
        width: side * 0.068,
        height: side * 0.068
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

print("SnapLoop S-shutter icons generated in \(output.path)")
