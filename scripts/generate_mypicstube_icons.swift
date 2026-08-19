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

    ctx.setFillColor(ivory.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: w))

    // Subtle Coral Luxe halo.
    if let halo = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [coral.withAlphaComponent(0.16).cgColor, lilac.withAlphaComponent(0.08).cgColor, blue.withAlphaComponent(0.03).cgColor] as CFArray,
        locations: [0, 0.58, 1]
    ) {
        ctx.drawRadialGradient(
            halo,
            startCenter: CGPoint(x: w * 0.50, y: w * 0.50), startRadius: 0,
            endCenter: CGPoint(x: w * 0.50, y: w * 0.50), endRadius: w * 0.46,
            options: []
        )
    }

    // Camera body.
    let cameraRect = CGRect(x: w * 0.20, y: w * 0.26, width: w * 0.60, height: w * 0.48)
    let bodyPath = CGPath(
        roundedRect: cameraRect,
        cornerWidth: w * 0.115,
        cornerHeight: w * 0.115,
        transform: nil
    )
    ctx.addPath(bodyPath)
    ctx.setFillColor(white.withAlphaComponent(0.98).cgColor)
    ctx.fillPath()

    // Coral camera outline.
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(coral.cgColor)
    ctx.setLineWidth(w * 0.045)
    ctx.strokePath()

    // Camera top ridge.
    let ridge = CGRect(x: w * 0.27, y: w * 0.70, width: w * 0.24, height: w * 0.075)
    let ridgePath = CGPath(roundedRect: ridge, cornerWidth: w * 0.03, cornerHeight: w * 0.03, transform: nil)
    ctx.addPath(ridgePath)
    ctx.setFillColor(coral.cgColor)
    ctx.fillPath()

    // Lens: coral -> lilac -> blue, keeping the reference's bright youthful camera feel.
    if let lensGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [coral.cgColor, lilac.cgColor, blue.cgColor] as CFArray,
        locations: [0, 0.54, 1]
    ) {
        let lensRect = CGRect(x: w * 0.34, y: w * 0.34, width: w * 0.32, height: w * 0.32)
        ctx.saveGState()
        ctx.addEllipse(in: lensRect)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            lensGradient,
            start: CGPoint(x: lensRect.minX, y: lensRect.maxY),
            end: CGPoint(x: lensRect.maxX, y: lensRect.minY),
            options: []
        )
        ctx.restoreGState()

        ctx.setStrokeColor(coralDeep.withAlphaComponent(0.70).cgColor)
        ctx.setLineWidth(w * 0.020)
        ctx.strokeEllipse(in: lensRect)
    }

    // Blue status dot.
    ctx.setFillColor(blue.cgColor)
    ctx.fillEllipse(in: CGRect(x: w * 0.68, y: w * 0.59, width: w * 0.075, height: w * 0.075))

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Icon", code: 3)
    }
    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
}

for spec in specs {
    try render(size: spec.pixels, to: outDir + "/" + spec.name)
}
print("Generated Coral Luxe camera-view MyPicsRoom AppIcon assets in \(outDir)")
