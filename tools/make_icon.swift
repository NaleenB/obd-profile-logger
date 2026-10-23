#!/usr/bin/env swift
// Renders the app icon at 1024×1024.
//
// Kept as a script, not a checked-in binary blob alone: the mark should be
// reproducible and adjustable without a design tool.
//
// Design: a gauge against a dark field with the arc broken at a threshold tick.
// It reads as "measured against limits", which is the whole premise — the app
// reports values against factory ranges and heuristics, and never confuses the
// two. Two colours only, so it survives 16×16.

import AppKit
import CoreGraphics

let size = 1024
let scale = CGFloat(size) / 1024.0

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("no context") }

// Background: near-black with a subtle cool gradient.
let bg = CGGradient(
    colorsSpace: space,
    colors: [rgb(0x16202A), rgb(0x0A0F14)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    bg,
    start: CGPoint(x: 0, y: CGFloat(size)),
    end: CGPoint(x: 0, y: 0),
    options: []
)

let centre = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
let radius: CGFloat = 330 * scale
let stroke: CGFloat = 62 * scale

// Gauge arc: 270°, open at the bottom.
let startAngle = CGFloat.pi * 0.75
let endAngle = CGFloat.pi * 2.25

func arc(from: CGFloat, to: CGFloat, colour: CGColor, width: CGFloat) {
    ctx.setStrokeColor(colour)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.addArc(center: centre, radius: radius,
               startAngle: from, endAngle: to, clockwise: false)
    ctx.strokePath()
}

// Track, then the measured portion, then a threshold tick in amber.
arc(from: startAngle, to: endAngle, colour: rgb(0x2A3B47), width: stroke)
arc(from: startAngle, to: startAngle + (endAngle - startAngle) * 0.62,
    colour: rgb(0x2DD4BF), width: stroke)

let tickAngle = startAngle + (endAngle - startAngle) * 0.82
let tickInner = radius - stroke * 0.95
let tickOuter = radius + stroke * 0.95
ctx.setStrokeColor(rgb(0xF59E0B))
ctx.setLineWidth(26 * scale)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: centre.x + cos(tickAngle) * tickInner,
                     y: centre.y + sin(tickAngle) * tickInner))
ctx.addLine(to: CGPoint(x: centre.x + cos(tickAngle) * tickOuter,
                        y: centre.y + sin(tickAngle) * tickOuter))
ctx.strokePath()

// Needle, pointing just past the end of the measured arc.
let needleAngle = startAngle + (endAngle - startAngle) * 0.52
let needleLength = radius - stroke * 0.75
ctx.setStrokeColor(rgb(0xF2F6F8))
ctx.setLineWidth(56 * scale)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: centre.x + cos(needleAngle) * stroke * 0.35,
                     y: centre.y + sin(needleAngle) * stroke * 0.35))
ctx.addLine(to: CGPoint(x: centre.x + cos(needleAngle) * needleLength,
                        y: centre.y + sin(needleAngle) * needleLength))
ctx.strokePath()

// Hub.
let hub = 78 * scale
ctx.setFillColor(rgb(0xF2F6F8))
ctx.fillEllipse(in: CGRect(x: centre.x - hub / 2, y: centre.y - hub / 2,
                           width: hub, height: hub))
ctx.setFillColor(rgb(0x0A0F14))
ctx.fillEllipse(in: CGRect(x: centre.x - hub * 0.28, y: centre.y - hub * 0.28,
                           width: hub * 0.56, height: hub * 0.56))

guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("no png")
}

let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon-1024.png"
try data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
