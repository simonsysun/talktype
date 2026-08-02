import Cocoa

// Generates the TalkType app icon.
//
// The mark is the same waveform that appears in the menu bar and in the dictation
// overlay, so the three places the product shows itself carry one symbol. Drawn in code
// rather than exported from a design tool so every size is a clean render, and so the
// icon can be adjusted by changing a number instead of being redrawn.
//
//   swiftc -O -o gen generate-icon.swift
//   ./gen ../../TalkType/Assets.xcassets/AppIcon.appiconset
//
// Deep blue-black plate, white mark, no accent colour. Chosen over warmer and more
// colourful directions because a monochrome mark on a near-black plate has nothing in it
// to date — no gradient fashion, no brand hue to regret later.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

/// Uneven on purpose: a symmetric taper draws a tidy triangle, which reads as a chart
/// rather than a voice. Small sizes get a shorter, bolder profile — nine bars at 16pt
/// merge into a smear, so detail has to drop out before the mark stops being legible.
let profileLarge: [CGFloat] = [0.34, 0.52, 0.78, 1.00, 0.66, 0.90, 0.72, 0.46, 0.30]
let profileSmall: [CGFloat] = [0.45, 0.80, 1.00, 0.70, 0.40]

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let small = size <= 48
    let profile = small ? profileSmall : profileLarge

    let px = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.setAllowsAntialiasing(true)
    cg.interpolationQuality = .high

    // macOS leaves a margin inside the canvas. At small sizes it costs more than it buys.
    let inset = size * (small ? 0.045 : 0.09)
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = plate.width * 0.225          // close to Apple's squircle
    let squircle = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    cg.saveGState()
    squircle.addClip()

    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.13, green: 0.16, blue: 0.24, alpha: 1), 0.0),
        (NSColor(srgbRed: 0.05, green: 0.06, blue: 0.11, alpha: 1), 1.0))!
        .draw(in: plate, angle: -75)

    // A highlight across the top half, the way a physical object catches light.
    if let sheen = NSGradient(colorsAndLocations:
        (NSColor(white: 1, alpha: 0.10), 0.0),
        (NSColor(white: 1, alpha: 0.0), 1.0)) {
        sheen.draw(in: CGRect(x: plate.minX, y: plate.midY,
                              width: plate.width, height: plate.height / 2), angle: -90)
    }

    // Waveform
    let count = CGFloat(profile.count)
    let barW = plate.width * (small ? 0.105 : 0.052)
    let gap = barW * (small ? 0.75 : 0.85)
    let totalW = count * barW + (count - 1) * gap
    let startX = plate.midX - totalW / 2
    let maxH = plate.height * 0.46

    let bars = NSBezierPath()
    for (i, p) in profile.enumerated() {
        let h = max(barW, maxH * p)
        let x = startX + CGFloat(i) * (barW + gap)
        bars.append(NSBezierPath(
            roundedRect: CGRect(x: x, y: plate.midY - h / 2, width: barW, height: h),
            xRadius: barW / 2, yRadius: barW / 2))
    }
    cg.saveGState()
    bars.addClip()
    NSGradient(colorsAndLocations:
        (NSColor(white: 1.00, alpha: 1), 0.0),
        (NSColor(white: 0.86, alpha: 1), 1.0))!
        .draw(in: CGRect(x: startX, y: plate.midY - maxH / 2, width: totalW, height: maxH), angle: -90)
    cg.restoreGState()
    cg.restoreGState()

    // Rim light along the edge so the plate reads as an object rather than a hole.
    cg.saveGState()
    squircle.addClip()
    NSColor(white: 1, alpha: 0.12).setStroke()
    let rim = NSBezierPath(roundedRect: plate.insetBy(dx: 0.5, dy: 0.5),
                           xRadius: radius, yRadius: radius)
    rim.lineWidth = max(1, size / 256)
    rim.stroke()
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = drawIcon(size: CGFloat(size))
    let url = URL(fileURLWithPath: "\(outDir)/icon_\(size).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote icon_\(size).png")
}
