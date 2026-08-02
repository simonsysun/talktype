import Cocoa

// Generates the TalkType app icon: the same waveform that appears in the menu bar and
// in the dictation overlay, so the three places the product shows itself all carry one
// mark. Drawn programmatically so every size is a clean render rather than a resample.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

/// Bar profile: tall in the middle, tapering out, with enough variation that it reads as
/// a voice rather than a bar chart.
///
/// Small sizes get a shorter, bolder profile. Nine bars at 16pt merge into a smear —
/// the detail has to drop out before the mark stops being legible.
let profileLarge: [CGFloat] = [0.34, 0.52, 0.78, 1.00, 0.66, 0.90, 0.72, 0.46, 0.30]
let profileSmall: [CGFloat] = [0.45, 0.80, 1.00, 0.70, 0.40]

func profile(for size: CGFloat) -> [CGFloat] { size <= 48 ? profileSmall : profileLarge }

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
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

    // macOS icons leave a margin inside the canvas; the artwork occupies the middle ~82%.
    // At small sizes the margin costs more than it buys, so it tightens.
    let inset = size * (size <= 48 ? 0.045 : 0.09)
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    // Apple's squircle is close to a 22.5% corner radius on the artwork box.
    let radius = plate.width * 0.225
    let squircle = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    // Warm gradient, carried over from the previous icon so the app still looks like
    // itself in a Dock full of apps — only the mark inside it changes.
    cg.saveGState()
    squircle.addClip()
    let gradient = NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.98, green: 0.72, blue: 0.60, alpha: 1), 0.0),
        (NSColor(srgbRed: 0.93, green: 0.54, blue: 0.44, alpha: 1), 0.55),
        (NSColor(srgbRed: 0.85, green: 0.42, blue: 0.38, alpha: 1), 1.0))!
    gradient.draw(in: plate, angle: -70)

    // A soft highlight across the top third, the way physical objects catch light.
    if let sheen = NSGradient(colorsAndLocations:
        (NSColor(white: 1, alpha: 0.22), 0.0),
        (NSColor(white: 1, alpha: 0.0), 1.0)) {
        sheen.draw(in: CGRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2), angle: -90)
    }
    cg.restoreGState()

    // Waveform, matching the overlay's bar proportions.
    let profile = profile(for: size)
    let count = CGFloat(profile.count)
    let barW = plate.width * (size <= 48 ? 0.105 : 0.052)
    let gap = barW * (size <= 48 ? 0.75 : 0.85)
    let totalW = count * barW + (count - 1) * gap
    let startX = plate.midX - totalW / 2
    let maxH = plate.height * 0.46

    NSColor(white: 1, alpha: 0.97).setFill()
    for (i, p) in profile.enumerated() {
        let h = max(barW, maxH * p)
        let x = startX + CGFloat(i) * (barW + gap)
        let bar = NSBezierPath(
            roundedRect: CGRect(x: x, y: plate.midY - h / 2, width: barW, height: h),
            xRadius: barW / 2, yRadius: barW / 2)
        bar.fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = drawIcon(size: CGFloat(size))
    let url = URL(fileURLWithPath: "\(outDir)/icon_\(size).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote icon_\(size).png")
}
