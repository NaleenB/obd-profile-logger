#!/usr/bin/env swift
// Renders the app icon. Usage:
//
//   swift tools/make_icon.swift <output.png> [small]
//
// Concept: a piston and connecting rod — the part that turns combustion into
// motion, and the part whose wear this app exists to catch early.
//
// There are deliberately two cuts of the same mark:
//
//   detailed (default) — ring grooves, hollow big end, gudgeon pin
//   small              — bolder, fewer shapes, no grooves, solid big end
//
// A 16 px tile cannot render three grooves as anything but mud, so the smallest
// sizes use a simplified silhouette. Editing one cut does not change the other;
// regenerate both with tools/build_icons.sh.
//
// Drawing order matters in both: the rod is drawn first so it emerges from
// behind the piston rather than crossing it.

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

let arguments = CommandLine.arguments
let small = arguments.contains("small")

guard let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("no context") }

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

if small {
    // --- Simplified cut -------------------------------------------------

    ctx.setStrokeColor(paper)
    ctx.setLineWidth(120)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 540, y: 500))
    ctx.addLine(to: CGPoint(x: 400, y: 250))
    ctx.strokePath()

    // Solid big end: a hole disappears at this size.
    ctx.setFillColor(paper)
    ctx.fillEllipse(in: CGRect(x: 258, y: 96, width: 230, height: 230))

    // Piston: one block, no grooves.
    let crown = CGRect(x: 316, y: 566, width: 420, height: 236)
    ctx.addPath(rounded(crown, 62))
    ctx.setFillColor(teal)
    ctx.fillPath()

    let skirt = CGMutablePath()
    skirt.move(to: CGPoint(x: 352, y: 566))
    skirt.addLine(to: CGPoint(x: 352, y: 470))
    skirt.addQuadCurve(to: CGPoint(x: 412, y: 404),
                       control: CGPoint(x: 352, y: 404))
    skirt.addLine(to: CGPoint(x: 700, y: 404))
    skirt.addQuadCurve(to: CGPoint(x: 760, y: 470),
                       control: CGPoint(x: 760, y: 404))
    skirt.addLine(to: CGPoint(x: 760, y: 566))
    skirt.closeSubpath()
    ctx.addPath(skirt)
    ctx.setFillColor(teal)
    ctx.fillPath()

    // One gudgeon pin, oversized so it survives.
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: 458, y: 442, width: 188, height: 188))
    ctx.setFillColor(paper)
    ctx.fillEllipse(in: CGRect(x: 508, y: 492, width: 88, height: 88))

} else {
    // --- Detailed cut ---------------------------------------------------

    ctx.setStrokeColor(paper)
    ctx.setLineWidth(78)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 540, y: 470))
    ctx.addLine(to: CGPoint(x: 420, y: 236))
    ctx.strokePath()

    ctx.setFillColor(paper)
    ctx.fillEllipse(in: CGRect(x: 348, y: 152, width: 156, height: 156))
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: 386, y: 190, width: 80, height: 80))

    let crown = CGRect(x: 348, y: 566, width: 396, height: 214)
    ctx.addPath(rounded(crown, 44))
    ctx.setFillColor(teal)
    ctx.fillPath()

    ctx.setFillColor(ink)
    for y in stride(from: CGFloat(604), through: 668, by: 32) {
        ctx.fill(CGRect(x: 348, y: y, width: 396, height: 14))
    }

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

    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: 470, y: 438, width: 152, height: 152))
    ctx.setFillColor(paper)
    ctx.fillEllipse(in: CGRect(x: 508, y: 476, width: 76, height: 76))
}

guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("no png")
}

let out = arguments.count > 1 && !arguments[1].hasPrefix("--")
    ? arguments[1]
    : "AppIcon-1024.png"
try data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)\(small ? " (small cut)" : "")")
