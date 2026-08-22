#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Sources/Resources/Assets.xcassets/SnapLoopBrandMark.imageset/SnapLoopBrandMark.png")
let output = root.appendingPathComponent("Sources/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

guard let sourceImage = NSImage(contentsOf: source) else {
    fputs("Missing production SnapLoop brand asset at \(source.path)\n", stderr)
    exit(1)
}

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

func renderPNG(pixels: Int) throws -> Data {
    let side = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high
    sourceImage.draw(
        in: NSRect(x: 0, y: 0, width: side, height: side),
        from: NSRect(origin: .zero, size: sourceImage.size),
        operation: .copy,
        fraction: 1
    )

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [.compressionFactor: 0.92]) else {
        throw NSError(domain: "SnapLoopIconGenerator", code: 1)
    }
    return png
}

for spec in specs {
    let data = try renderPNG(pixels: spec.pixels)
    try data.write(to: output.appendingPathComponent(spec.filename), options: .atomic)
    print("Generated \(spec.filename)")
}

print("SnapLoop icons generated from the production brand asset: \(source.path)")
