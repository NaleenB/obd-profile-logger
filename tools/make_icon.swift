#!/usr/bin/env swift
// Renders the app icon at 1024×1024.
//
// Kept as a script so the mark is reproducible and adjustable without a design
// tool. Concept: a piston and connecting rod — the part that turns combustion
// into motion, and the part whose wear this app exists to catch early.
//
// Drawing order matters: the rod goes down first so it emerges from behind the
// piston rather than crossing it, which is what keeps the silhouette clean at
// 16×16.

import AppKit
import CoreGraphics

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let ink = rgb(0x0A0F14)
let field = rgb(0x16202A)
let teal = rgb(0x2DD4BF)
let paper = rgb(0xF2F6F8)

guard let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("no context") }

// Background.
let gradient = CGGradient(colorsSpace: space,
                          colors: [field, ink] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: CGFloat(size)),
                       end: CGPoint(x: 0, y: 0),
                       options: [])

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// 1. Connecting rod, behind everything.
ctx.setStrokeColor(paper)
ctx.setLineWidth(78)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 540, y: 470))
ctx.addLine(to: CGPoint(x: 420, y: 236))
ctx.strokePath()

// Big end.
ctx.setFillColor(paper)
ctx.fillEllipse(in: CGRect(x: 348, y: 152, width: 156, height: 156))
ctx.setFillColor(ink)
ctx.fillEllipse(in: CGRect(x: 386, y: 190, width: 80, height: 80))

// 2. Piston crown.
let crown = CGRect(x: 348, y: 566, width: 396, height: 214)
ctx.addPath(rounded(crown, 44))
ctx.setFillColor(teal)
ctx.fillPath()

// Ring grooves.
ctx.setFillColor(ink)
for y in stride(from: CGFloat(604), through: 668, by: 32) {
    ctx.fill(CGRect(x: 348, y: y, width: 396, height: 14))
}

// 3. Skirt, tapering down to the pin boss.
let skirt = CGMutablePath()
skirt.move(to: CGPoint(x: 380, y: 566))
skirt.addLine(to: CGPoint(x: 380, y: 470))
skirt.addQuadCurve(to: CGPoint(x: 432, y: 414),
                   control: CGPoint(x: 380, y: 414))
skirt.addLine(to: CGPoint(x: 660, y: 414))
skirt.addQuadCurve(to: CGPoint(x: 712, y: 470),
                   control: CGPoint(x: 712, y: 414))
skirt.addLine(to: CGPoint(x: 712, y: 566))
skirt.closeSubpath()
ctx.addPath(skirt)
ctx.setFillColor(teal)
ctx.fillPath()

// 4. Gudgeon pin, punched through the boss.
ctx.setFillColor(ink)
ctx.fillEllipse(in: CGRect(x: 470, y: 438, width: 152, height: 152))
ctx.setFillColor(paper)
ctx.fillEllipse(in: CGRect(x: 508, y: 476, width: 76, height: 76))

guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("no png")
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
try data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
