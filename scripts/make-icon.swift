#!/usr/bin/env swift
//
// Generates LeanSpeedo's app icon (a speedometer on a blue squircle) at every
// size the asset catalog needs, rendering the vector art fresh at each size.
//
//   swift scripts/make-icon.swift LeanSpeedo/Assets.xcassets/AppIcon.appiconset
//

import AppKit

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "LeanSpeedo/Assets.xcassets/AppIcon.appiconset"

let deepBlue = NSColor(srgbRed: 0.09, green: 0.30, blue: 0.83, alpha: 1)
let brightBlue = NSColor(srgbRed: 0.32, green: 0.62, blue: 1.00, alpha: 1)

func drawIcon(px: Int) -> Data {
    let n = CGFloat(px)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("no bitmap rep") }
    rep.size = NSSize(width: n, height: n)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext
    let s = n / 1024.0

    // Squircle background with a soft drop shadow.
    let inset = 100.0 * s
    let side = n - inset * 2
    let radius = side * 0.2237
    let shape = CGPath(roundedRect: CGRect(x: inset, y: inset, width: side, height: side),
                       cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * s), blur: 42 * s,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(deepBlue.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [brightBlue.cgColor, deepBlue.cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: n), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    // Gauge geometry.
    let center = CGPoint(x: n / 2, y: n / 2 - 24 * s)
    let r = 300.0 * s
    let startAngle = CGFloat.pi * 1.22
    let endAngle = -CGFloat.pi * 0.22   // swept clockwise over the top

    ctx.setLineCap(.round)
    ctx.setLineWidth(48 * s)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    ctx.addArc(center: center, radius: r, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    ctx.strokePath()

    // Ticks (kept clear of the arc ends).
    let ticks = 6
    for i in 0...ticks {
        let f = CGFloat(i) / CGFloat(ticks)
        let a = startAngle + (0.08 + 0.84 * f) * (endAngle - startAngle)
        let outer = CGPoint(x: center.x + cos(a) * (r - 62 * s), y: center.y + sin(a) * (r - 62 * s))
        let inner = CGPoint(x: center.x + cos(a) * (r - 108 * s), y: center.y + sin(a) * (r - 108 * s))
        ctx.setLineWidth((i % 3 == 0 ? 20 : 12) * s)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.75).cgColor)
        ctx.move(to: inner)
        ctx.addLine(to: outer)
        ctx.strokePath()
    }

    // Needle, reading near the top of the scale.
    let needleAngle = startAngle + 0.82 * (endAngle - startAngle)
    let tip = CGPoint(x: center.x + cos(needleAngle) * (r - 26 * s),
                      y: center.y + sin(needleAngle) * (r - 26 * s))
    let tail = CGPoint(x: center.x - cos(needleAngle) * 72 * s,
                       y: center.y - sin(needleAngle) * 72 * s)
    ctx.setLineCap(.round)
    ctx.setLineWidth(36 * s)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.move(to: tail)
    ctx.addLine(to: tip)
    ctx.strokePath()

    // Hub.
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - 48 * s, y: center.y - 48 * s, width: 96 * s, height: 96 * s))
    ctx.setFillColor(deepBlue.cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - 22 * s, y: center.y - 22 * s, width: 44 * s, height: 44 * s))

    gctx.flushGraphics()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
    return png
}

let entries: [(name: String, px: Int)] = [
    ("icon_16", 16), ("icon_16@2x", 32),
    ("icon_32", 32), ("icon_32@2x", 64),
    ("icon_128", 128), ("icon_128@2x", 256),
    ("icon_256", 256), ("icon_256@2x", 512),
    ("icon_512", 512), ("icon_512@2x", 1024),
]

for entry in entries {
    let url = URL(fileURLWithPath: "\(outDir)/\(entry.name).png")
    try drawIcon(px: entry.px).write(to: url)
    print("wrote \(url.lastPathComponent) (\(entry.px)px)")
}
