#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate-app-icon.swift OUTPUT_ICONSET\n".utf8))
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true)

let representations: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1_024),
]

for representation in representations {
    let bitmap = try renderIcon(pixels: representation.pixels)
    let destination = outputDirectory.appendingPathComponent(representation.name)
    try bitmap.write(to: destination)
}

func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        throw IconGenerationError.couldNotCreateBitmap
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let size = CGFloat(pixels)
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill(using: .copy)

    let inset = size * 0.075
    let tileRect = canvas.insetBy(dx: inset, dy: inset)
    let tile = NSBezierPath(
        roundedRect: tileRect,
        xRadius: size * 0.22,
        yRadius: size * 0.22)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedRed: 0.02, green: 0.12, blue: 0.28, alpha: 0.46)
    shadow.shadowBlurRadius = size * 0.075
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.025)
    shadow.set()
    NSColor(calibratedRed: 0.02, green: 0.36, blue: 0.82, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.03, green: 0.78, blue: 0.94, alpha: 1),
        NSColor(calibratedRed: 0.02, green: 0.43, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.27, green: 0.16, blue: 0.72, alpha: 1),
    ])
    gradient?.draw(in: tile, angle: -45)

    let highlight = NSBezierPath(
        roundedRect: tileRect.insetBy(dx: size * 0.012, dy: size * 0.012),
        xRadius: size * 0.205,
        yRadius: size * 0.205)
    NSColor.white.withAlphaComponent(0.2).setStroke()
    highlight.lineWidth = max(1, size * 0.012)
    highlight.stroke()

    let heights: [CGFloat] = [0.24, 0.40, 0.58, 0.72, 0.58, 0.40, 0.24]
    let barWidth = size * 0.048
    let spacing = size * 0.085
    let centerX = size / 2
    let centerY = size / 2

    NSGraphicsContext.saveGraphicsState()
    let waveformShadow = NSShadow()
    waveformShadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
    waveformShadow.shadowBlurRadius = size * 0.018
    waveformShadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    waveformShadow.set()
    NSColor.white.setFill()

    for (index, heightRatio) in heights.enumerated() {
        let height = size * heightRatio
        let x = centerX + CGFloat(index - heights.count / 2) * spacing - barWidth / 2
        let bar = NSBezierPath(
            roundedRect: NSRect(
                x: x,
                y: centerY - height / 2,
                width: barWidth,
                height: height),
            xRadius: barWidth / 2,
            yRadius: barWidth / 2)
        bar.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    context.flushGraphics()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconGenerationError.couldNotEncodePNG
    }
    return data
}

enum IconGenerationError: Error {
    case couldNotCreateBitmap
    case couldNotEncodePNG
}
