#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Generates algobuddy.icns from code, so the icon is reproducible from source
// and reviewable in a diff rather than being an opaque binary nobody can
// regenerate:
//
//     swift Tools/make-icon.swift     ->  Resources/algobuddy.icns
//
// Note: macOS 26 app icons are properly authored in Icon Composer as layered
// artwork that picks up Liquid Glass specular highlights and refraction. This
// is the legacy .icns path, correct and complete, but a polished release should
// re-cut the icon in Icon Composer.

/// The squircle occupies 824/1024 of the canvas, centred, the standard macOS
/// proportion since Big Sur. Baking the rounded shape in (rather than drawing
/// full-bleed) means it looks right whether or not the system masks it.
let shapeRatio: CGFloat = 824.0 / 1024.0
let cornerRatio: CGFloat = 0.2247

/// The standalone Algorand "A" mark, traced from the public community logo
/// artwork. The mark is expressed as geometry rather than a bundled bitmap so
/// it remains sharp at every .icns size. Its shape is a trademark of Algorand;
/// algobuddy is an independent, community-built monitoring application.
///
/// Reference: https://commons.wikimedia.org/wiki/File:Algorand_logo.svg
func algorandMark(centre: CGPoint, height: CGFloat) -> CGPath {
    // The source logo mark occupies x=164.7...404.2 and y=173.7...413.7.
    // Core Graphics' raster context is vertically opposite SVG's coordinates,
    // so the y-axis is intentionally inverted while placing each point.
    let sourceCentre = CGPoint(x: 284.45, y: 293.7)
    let scale = height / 240
    let sourcePoints: [CGPoint] = [
        CGPoint(x: 404.2, y: 413.6), CGPoint(x: 366.7, y: 413.6),
        CGPoint(x: 342.3, y: 322.9), CGPoint(x: 289.8, y: 413.6),
        CGPoint(x: 247.9, y: 413.6), CGPoint(x: 328.9, y: 273.2),
        CGPoint(x: 315.9, y: 224.4), CGPoint(x: 206.6, y: 413.7),
        CGPoint(x: 164.7, y: 413.7), CGPoint(x: 303.2, y: 173.7),
        CGPoint(x: 339.9, y: 173.7), CGPoint(x: 356.0, y: 233.3),
        CGPoint(x: 393.9, y: 233.3), CGPoint(x: 368.0, y: 278.3),
    ]

    let path = CGMutablePath()
    for (index, source) in sourcePoints.enumerated() {
        let point = CGPoint(
            x: centre.x + (source.x - sourceCentre.x) * scale,
            y: centre.y - (source.y - sourceCentre.y) * scale)
        if index == 0 {
            path.move(to: point)
        } else {
            path.addLine(to: point)
        }
    }
    path.closeSubpath()
    return path
}

func render(size: CGFloat) -> Data {
    let pixels = Int(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard
        let ctx = CGContext(
            data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("could not create context") }

    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let side = size * shapeRatio
    let origin = (size - side) / 2
    let body = CGRect(x: origin, y: origin, width: side, height: side)
    let radius = side * cornerRatio
    ctx.saveGState()
    ctx.addPath(
        CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()

    // A single flat black background preserves Algorand's monochrome character
    // and keeps the mark from changing character with the icon's rendered size.
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(body)

    let centre = CGPoint(x: size / 2, y: size / 2)

    // The official mark remains unmodified and centred. It is white rather than
    // teal, so the Algorand relationship is immediate even at 16 pt.
    ctx.setLineCap(.round)
    ctx.setFillColor(CGColor(srgbRed: 0.965, green: 0.985, blue: 0.975, alpha: 1))
    ctx.addPath(algorandMark(centre: centre, height: size * 0.510))
    ctx.fillPath()
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { fatalError("could not make image") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode png")
    }
    return png
}

// MARK: - Emit the iconset

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/algobuddy.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, size) in variants {
    try render(size: size).write(to: iconset.appendingPathComponent(name))
}

let output = root.appendingPathComponent("Resources/algobuddy.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(task.terminationStatus) }

print("wrote \(output.path)")
