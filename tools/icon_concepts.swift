#!/usr/bin/env swift
// Renders icon concepts for the app and a comparison sheet.
//
// Usage: swift tools/icon_concepts.swift <output-directory>
// Writes a.png, b.png, c.png, d.png (1024×1024) plus sheet.png.

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
let amber = rgb(0xF59E0B)
let paper = rgb(0xF2F6F8)
let track = rgb(0x2A3B47)

func makeContext(_ side: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: side, height: side,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fatalError("context") }
    return ctx
}

func background(_ ctx: CGContext, _ side: Int) {
    let gradient = CGGradient(colorsSpace: space,
                              colors: [field, ink] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: CGFloat(side)),
                           end: CGPoint(x: 0, y: 0),
                           options: [])
}

func rounded(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - A. Engine block, top view, one cylinder highlighted

func conceptA() -> CGImage {
    let ctx = makeContext(size)
    background(ctx, size)

    let body = CGRect(x: 232, y: 190, width: 560, height: 644)
    ctx.addPath(rounded(ctx, body, 110))
    ctx.setStrokeColor(teal)
    ctx.setLineWidth(30)
    ctx.strokePath()

    // Four bores. The third is highlighted: one cylinder under scrutiny.
    let xs: [CGFloat] = [286, 406, 526, 646]
    for (index, x) in xs.enumerated() {
        let bore = CGRect(x: x, y: 330, width: 92, height: 360)
        let path = rounded(ctx, bore, 40)
        if index == 2 {
            ctx.addPath(path)
            ctx.setFillColor(amber)
            ctx.fillPath()
        } else {
            ctx.addPath(path)
            ctx.setFillColor(track)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(teal)
            ctx.setLineWidth(14)
            ctx.strokePath()
        }
    }

    // Cam cover hint.
    ctx.setStrokeColor(track)
    ctx.setLineWidth(18)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 286, y: 250))
    ctx.addLine(to: CGPoint(x: 738, y: 250))
    ctx.strokePath()
    return ctx.makeImage()!
}

// MARK: - B. Piston and connecting rod

func conceptB() -> CGImage {
    let ctx = makeContext(size)
    background(ctx, size)

    // Crown and skirt.
    let crown = CGRect(x: 322, y: 560, width: 380, height: 210)
    ctx.addPath(rounded(ctx, crown, 40))
    ctx.setFillColor(teal)
    ctx.fillPath()

    ctx.setFillColor(ink)
    for y in stride(from: CGFloat(596), through: 660, by: 32) {
        ctx.fill(CGRect(x: 322, y: y, width: 380, height: 12))
    }

    // Skirt.
    let skirt = CGMutablePath()
    skirt.move(to: CGPoint(x: 352, y: 560))
    skirt.addLine(to: CGPoint(x: 352, y: 470))
    skirt.addQuadCurve(to: CGPoint(x: 400, y: 420),
                       control: CGPoint(x: 352, y: 420))
    skirt.addLine(to: CGPoint(x: 624, y: 420))
    skirt.addQuadCurve(to: CGPoint(x: 672, y: 470),
                       control: CGPoint(x: 672, y: 420))
    skirt.addLine(to: CGPoint(x: 672, y: 560))
    skirt.closeSubpath()
    ctx.addPath(skirt)
    ctx.setFillColor(teal)
    ctx.fillPath()

    // Pin.
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: 452, y: 470, width: 120, height: 120))
    ctx.setFillColor(paper)
    ctx.fillEllipse(in: CGRect(x: 486, y: 504, width: 52, height: 52))

    // Rod down to the crank.
    ctx.setStrokeColor(paper)
    ctx.setLineWidth(64)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 512, y: 470))
    ctx.addLine(to: CGPoint(x: 440, y: 250))
    ctx.strokePath()

    ctx.setFillColor(paper)
    ctx.fillEllipse(in: CGRect(x: 380, y: 190, width: 120, height: 120))
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: 410, y: 220, width: 60, height: 60))
    return ctx.makeImage()!
}

// MARK: - C. Exhaust with soot upstream, clean downstream

func conceptC() -> CGImage {
    let ctx = makeContext(size)
    background(ctx, size)

    // Pipe.
    let pipe = CGRect(x: 130, y: 452, width: 470, height: 132)
    ctx.addPath(rounded(ctx, pipe, 66))
    ctx.setStrokeColor(track)
    ctx.setLineWidth(34)
    ctx.strokePath()

    // Soot particles inside the pipe.
    let dots: [(CGFloat, CGFloat, CGFloat)] = [
        (196, 500, 26), (256, 534, 20), (312, 486, 30),
        (372, 528, 22), (430, 496, 26), (486, 532, 18)
    ]
    for (x, y, r) in dots {
        ctx.setFillColor(amber)
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
    }

    // Outlet plume: clean, widening.
    ctx.setStrokeColor(teal)
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    let plume: [CGFloat] = [482, 518, 554]
    for (index, y) in plume.enumerated() {
        let startX: CGFloat = 640
        let endX: CGFloat = 790 + CGFloat(index) * 40
        ctx.move(to: CGPoint(x: startX, y: y))
        ctx.addLine(to: CGPoint(x: endX, y: y))
        ctx.strokePath()
    }
    return ctx.makeImage()!
}

// MARK: - D. Gauge (current icon)

func conceptD() -> CGImage {
    let ctx = makeContext(size)
    background(ctx, size)

    let centre = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 330
    let stroke: CGFloat = 62
    let start = CGFloat.pi * 0.75
    let end = CGFloat.pi * 2.25

    func arc(from: CGFloat, to: CGFloat, colour: CGColor) {
        ctx.setStrokeColor(colour)
        ctx.setLineWidth(stroke)
        ctx.setLineCap(.round)
        ctx.addArc(center: centre, radius: radius, startAngle: from, endAngle: to, clockwise: false)
        ctx.strokePath()
    }

    arc(from: start, to: end, colour: track)
    arc(from: start, to: start + (end - start) * 0.62, colour: teal)

    let tick = start + (end - start) * 0.82
    ctx.setStrokeColor(amber)
    ctx.setLineWidth(26)
    ctx.move(to: CGPoint(x: centre.x + cos(tick) * (radius - 60),
                         y: centre.y + sin(tick) * (radius - 60)))
    ctx.addLine(to: CGPoint(x: centre.x + cos(tick) * (radius + 60),
                            y: centre.y + sin(tick) * (radius + 60)))
    ctx.strokePath()

    let needle = start + (end - start) * 0.52
    ctx.setStrokeColor(paper)
    ctx.setLineWidth(56)
    ctx.move(to: CGPoint(x: centre.x + cos(needle) * 22,
                         y: centre.y + sin(needle) * 22))
    ctx.addLine(to: CGPoint(x: centre.x + cos(needle) * (radius - 46),
                            y: centre.y + sin(needle) * (radius - 46)))
    ctx.strokePath()

    ctx.setFillColor(paper)
    ctx.fillEllipse(in: CGRect(x: centre.x - 39, y: centre.y - 39, width: 78, height: 78))
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: centre.x - 22, y: centre.y - 22, width: 44, height: 44))
    return ctx.makeImage()!
}

// MARK: - Output

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"

func write(_ image: CGImage, to name: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    print("wrote \(name)")
}

let images: [(String, CGImage)] = [
    ("a", conceptA()), ("b", conceptB()), ("c", conceptC()), ("d", conceptD())
]
for (name, image) in images { write(image, to: "\(name).png") }

// Contact sheet: 2×2, each tile 512, with a caption strip.
let tile = 512, gap = 28, label = 64
let sheetSide = tile * 2 + gap * 3
let sheetHeight = (tile + label) * 2 + gap * 3
let sheet = makeContext(sheetSide)
let sheetCtx = sheet
sheetCtx.setFillColor(rgb(0x07111A))
sheetCtx.fill(CGRect(x: 0, y: 0, width: sheetSide, height: sheetHeight))

let nsctx = NSGraphicsContext(cgContext: sheetCtx, flipped: false)
NSGraphicsContext.current = nsctx

for (index, entry) in images.enumerated() {
    let col = index % 2, row = index / 2
    let x = gap + col * (tile + gap)
    let y = sheetHeight - (gap + (row + 1) * (tile + label) + row * gap)
    sheetCtx.draw(entry.1, in: CGRect(x: x, y: y + label, width: tile, height: tile))

    let caption = entry.0.uppercased()
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1)
    ]
    NSString(string: caption).draw(at: NSPoint(x: x, y: y + 10), withAttributes: attributes)
}

let sheetImage = sheetCtx.makeImage()!
let rep = NSBitmapImageRep(cgImage: sheetImage)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: "\(outDir)/sheet.png"))
print("wrote sheet.png")
