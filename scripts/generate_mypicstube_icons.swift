#!/usr/bin/env swift
import AppKit
import Foundation

let fm = FileManager.default
let root = fm.currentDirectoryPath
let outDir = root + "/Sources/Resources/Assets.xcassets/AppIcon.appiconset"
try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

struct IconSpec { let name: String; let pixels: Int }
let specs: [IconSpec] = [
    .init(name: "Icon-20@2x.png", pixels: 40),
    .init(name: "Icon-20@3x.png", pixels: 60),
    .init(name: "Icon-29@2x.png", pixels: 58),
    .init(name: "Icon-29@3x.png", pixels: 87),
    .init(name: "Icon-40@2x.png", pixels: 80),
    .init(name: "Icon-40@3x.png", pixels: 120),
    .init(name: "Icon-60@2x.png", pixels: 120),
    .init(name: "Icon-60@3x.png", pixels: 180),
    .init(name: "Icon-1024.png", pixels: 1024)
]

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

let sunset = color(0xFF7A45)
let rose = color(0xFB7185)
let gold = color(0xFBBF24)
let white = NSColor.white

func drawPerson(in ctx: CGContext, centerX: CGFloat, headY: CGFloat, scale: CGFloat) {
    ctx.setFillColor(white.cgColor)
    ctx.fillEllipse(in: CGRect(x: centerX - 0.075 * scale, y: headY - 0.075 * scale, width: 0.15 * scale, height: 0.15 * scale))
    let body = CGRect(x: centerX - 0.14 * scale, y: headY - 0.29 * scale, width: 0.28 * scale, height: 0.17 * scale)
    let path = CGPath(roundedRect: body, cornerWidth: 0.09 * scale, cornerHeight: 0.09 * scale, transform: nil)
    ctx.addPath(path)
    ctx.fillPath()
}

func render(size: Int, to path: String) throws {
    let w = CGFloat(size)
    let image = NSImage(size: NSSize(width: w, height: w))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { throw NSError(domain: "Icon", code: 1) }

    let colors = [sunset.cgColor, rose.cgColor] as CFArray
    let locations: [CGFloat] = [0, 1]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations)!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: w), end: CGPoint(x: w, y: 0), options: [])

    // Soft lens ring: community + photos without copying any third-party mark.
    ctx.setStrokeColor(white.withAlphaComponent(0.32).cgColor)
    ctx.setLineWidth(w * 0.038)
    ctx.strokeEllipse(in: CGRect(x: w * 0.16, y: w * 0.16, width: w * 0.68, height: w * 0.68))

    drawPerson(in: ctx, centerX: w * 0.41, headY: w * 0.60, scale: w)
    drawPerson(in: ctx, centerX: w * 0.59, headY: w * 0.60, scale: w)

    // Small sparkle for the "found for you" moment.
    ctx.setFillColor(gold.cgColor)
    let cx = w * 0.76, cy = w * 0.76, r = w * 0.085
    let sparkle = CGMutablePath()
    sparkle.move(to: CGPoint(x: cx, y: cy + r))
    sparkle.addLine(to: CGPoint(x: cx + r * 0.25, y: cy + r * 0.25))
    sparkle.addLine(to: CGPoint(x: cx + r, y: cy))
    sparkle.addLine(to: CGPoint(x: cx + r * 0.25, y: cy - r * 0.25))
    sparkle.addLine(to: CGPoint(x: cx, y: cy - r))
    sparkle.addLine(to: CGPoint(x: cx - r * 0.25, y: cy - r * 0.25))
    sparkle.addLine(to: CGPoint(x: cx - r, y: cy))
    sparkle.addLine(to: CGPoint(x: cx - r * 0.25, y: cy + r * 0.25))
    sparkle.closeSubpath()
    ctx.addPath(sparkle)
    ctx.fillPath()

    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Icon", code: 2)
    }
    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
}

for spec in specs {
    try render(size: spec.pixels, to: outDir + "/" + spec.name)
}
print("Generated MyPicsTube AppIcon assets in \(outDir)")
