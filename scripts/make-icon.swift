#!/usr/bin/env swift
// Renders the TokenTally app icon into TokenTally/Assets.xcassets/AppIcon.appiconset.
// Usage (from the repo root): swift scripts/make-icon.swift
import AppKit

let outputDir = URL(fileURLWithPath: "TokenTally/Assets.xcassets/AppIcon.appiconset")

func renderMaster(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // macOS icon grid: 824pt body inside a 1024pt canvas, ~185pt corner radius.
    let scale = size / 1024
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale)

    // Soft drop shadow under the body.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.shadowBlurRadius = 20 * scale
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Orange gradient background.
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.27, green: 0.85, blue: 0.47, alpha: 1),
        ending: NSColor(calibratedRed: 0.05, green: 0.52, blue: 0.36, alpha: 1)
    )!
    gradient.draw(in: shape, angle: -90)

    // White bar chart glyph, centred.
    let config = NSImage.SymbolConfiguration(pointSize: 400 * scale, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let symbolSize = symbol.size
    let symbolRect = NSRect(
        x: body.midX - symbolSize.width / 2,
        y: body.midY - symbolSize.height / 2,
        width: symbolSize.width,
        height: symbolSize.height
    )
    symbol.draw(in: symbolRect)

    return rep
}

func resized(_ master: NSBitmapImageRep, to pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let master = renderMaster(size: 1024)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try resized(master, to: pixels).write(to: outputDir.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDir.appendingPathComponent("Contents.json"))

let catalogContents = outputDir.deletingLastPathComponent().appendingPathComponent("Contents.json")
try #"{"info":{"author":"xcode","version":1}}"#.data(using: .utf8)!.write(to: catalogContents)
print("Wrote \(images.count) icon sizes to \(outputDir.path)")
