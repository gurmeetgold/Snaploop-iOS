#!/usr/bin/env swift
import AppKit
import CoreGraphics
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

let coral = color(0xFF6B5E)
let coralDeep = color(0xF45A4B)
let lilac = color(0xA78BFA)
let blue = color(0x4F8DFD)
let ivory = color(0xFFF9F7)
let white = NSColor.white

func fillCircle(_ ctx: CGContext, x: CGFloat, y: CGFloat, radius: CGFloat, color: NSColor) {
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
}

func drawCapsule(_ ctx: CGContext, rect: CGRect, angle: CGFloat, color: NSColor) {
    ctx.saveGState()
    ctx.translateBy(x: rect.midX, y: rect.midY)
    ctx.rotate(by: angle)
    let r = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
    let path = CGPath(roundedRect: r, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
}

func render(size: Int, to path: String) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: false,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else {
        throw NSError(domain: "Icon", code: 1)
    }

    let w = CGFloat(size)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Warm ivory background keeps the icon premium and legible in light/dark home screens.
    ctx.setFillColor(ivory.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: w))

    // Soft brand halo behind the community mark.
    if let halo = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [coral.withAlphaComponent(0.18).cgColor, lilac.withAlphaComponent(0.11).cgColor, blue.withAlphaComponent(0.04).cgColor] as CFArray,
        locations: [0, 0.55, 1]
    ) {
        ctx.drawRadialGradient(
            halo,
            startCenter: CGPoint(x: w * 0.48, y: w * 0.51), startRadius: 0,
            endCenter: CGPoint(x: w * 0.48, y: w * 0.51), endRadius: w * 0.45,
            options: []
        )
    }

    // Flowing central loop, matching the selected three-person/community logo direction.
    let loopRect = CGRect(x: w * 0.28, y: w * 0.25, width: w * 0.44, height: w * 0.44)
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(w * 0.115)
    if let loopGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [coral.cgColor, lilac.cgColor, blue.cgColor] as CFArray,
        locations: [0, 0.52, 1]
    ) {
        ctx.addEllipse(in: loopRect)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(loopGradient,
                               start: CGPoint(x: loopRect.minX, y: loopRect.maxY),
                               end: CGPoint(x: loopRect.maxX, y: loopRect.minY),
                               options: [])
    }
    ctx.restoreGState()

    // Three heads.
    fillCircle(ctx, x: w * 0.34, y: w * 0.68, radius: w * 0.075, color: coral)
    fillCircle(ctx, x: w * 0.50, y: w * 0.74, radius: w * 0.084, color: lilac)
    fillCircle(ctx, x: w * 0.66, y: w * 0.66, radius: w * 0.070, color: blue)

    // Side shoulders / arms for the friendly people silhouette.
    drawCapsule(ctx,
                rect: CGRect(x: w * 0.25, y: w * 0.48, width: w * 0.27, height: w * 0.095),
                angle: -.48,
                color: coral)
    drawCapsule(ctx,
                rect: CGRect(x: w * 0.51, y: w * 0.46, width: w * 0.27, height: w * 0.090),
                angle: .50,
                color: blue)

    // Subtle white center cutout gives the loop depth and keeps the mark clean at small sizes.
    fillCircle(ctx, x: w * 0.50, y: w * 0.48, radius: w * 0.090, color: white.withAlphaComponent(0.96))

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Icon", code: 3)
    }
    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
}

for spec in specs {
    try render(size: spec.pixels, to: outDir + "/" + spec.name)
}
print("Generated Coral Luxe MyPicsTube AppIcon assets in \(outDir)")
