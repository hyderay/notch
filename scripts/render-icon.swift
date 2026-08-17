#!/usr/bin/env swift
import AppKit
import Foundation

/// Draws the Notch app icon at 1024² and writes PNG + .icns.
///
/// A dark squircle with a hardware-notch silhouette at the top and a mint
/// status dot — readable at 16px, no text.

let size: CGFloat = 1024
let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)

func drawIcon(in rect: CGRect) {
    let radius = rect.width * 0.223
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    squircle.addClip()

    NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
    squircle.fill()

    // Top sheen.
    let sheen = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(
        colors: [
            NSColor(calibratedWhite: 1, alpha: 0.10),
            NSColor(calibratedWhite: 1, alpha: 0.00),
        ]
    )?.draw(in: sheen, angle: -90)

    // Notch fused to the top edge.
    let notchWidth = rect.width * 0.42
    let notchHeight = rect.height * 0.13
    let notch = CGRect(
        x: rect.midX - notchWidth / 2,
        y: rect.minY - 4,
        width: notchWidth,
        height: notchHeight + 4
    )
    let notchPath = NSBezierPath(roundedRect: notch, xRadius: notchHeight * 0.42, yRadius: notchHeight * 0.42)
    NSColor.black.setFill()
    notchPath.fill()

    // Hairline on the bottom of the notch.
    let lip = NSBezierPath()
    lip.lineWidth = 3
    NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
    let lipY = notch.maxY - 2
    lip.move(to: CGPoint(x: notch.minX + 18, y: lipY))
    lip.line(to: CGPoint(x: notch.maxX - 18, y: lipY))
    lip.stroke()

    // Status light — left side of the notch.
    let dotR: CGFloat = rect.width * 0.028
    let dot = CGRect(
        x: notch.minX + notchWidth * 0.18 - dotR,
        y: notch.midY + 6 - dotR,
        width: dotR * 2,
        height: dotR * 2
    )
    NSColor(calibratedRed: 0.22, green: 0.92, blue: 0.72, alpha: 0.35).setFill()
    NSBezierPath(ovalIn: dot.insetBy(dx: -6, dy: -6)).fill()
    NSColor(calibratedRed: 0.18, green: 0.86, blue: 0.66, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot).fill()

    // Small timer pill on the right — not pause bars.
    NSColor(calibratedWhite: 1, alpha: 0.90).setFill()
    let pillW = rect.width * 0.055
    let pillH = rect.width * 0.018
    let pill = CGRect(
        x: notch.maxX - notchWidth * 0.18 - pillW,
        y: notch.midY + 4 - pillH / 2,
        width: pillW,
        height: pillH
    )
    NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2).fill()
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
    drawIcon(in: rect)
    return true
}

func pngData(_ image: NSImage) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(image.size.width),
        pixelsHigh: Int(image.size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(origin: .zero, size: image.size),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let resources = outputDir
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let pngURL = resources.appendingPathComponent("AppIcon.png")
try pngData(image).write(to: pngURL)

let iconset = resources.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

for (name, pixels) in variants {
    let scaled = NSImage(size: NSSize(width: pixels, height: pixels), flipped: true) { rect in
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        return true
    }
    let url = iconset.appendingPathComponent("\(name).png")
    try pngData(scaled).write(to: url)
}

let icns = resources.appendingPathComponent("AppIcon.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    fputs("iconutil failed\n", stderr)
    exit(1)
}

print("wrote \(pngURL.path)")
print("wrote \(icns.path)")
