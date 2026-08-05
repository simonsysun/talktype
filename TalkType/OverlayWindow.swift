import Cocoa

/// NSPanel host for the floating overlay. Does not steal focus.
final class OverlayWindow {
    private let panel: NSPanel
    private let hostingView: OverlayHostingView
    private var hideTimer: Timer?
    private var visible = false
    private var lastLevelSent: TimeInterval = 0
    static let popOutDuration: TimeInterval = OverlayHostingView.fadeOutDuration

    var isVisible: Bool { visible }

    init() {
        let frame = NSRect(origin: .zero, size: OverlayHostingView.panelSize)

        let style: NSWindow.StyleMask = [.nonactivatingPanel, .titled, .fullSizeContentView]
        panel = NSPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        // The pill draws its own soft centred glow; a window drop shadow would fight it.
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.alphaValue = 1.0
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // Fixed dark, so the pill looks the same whichever appearance the desktop is in.
        // A vibrant appearance is only valid inside a visual effect view; darkAqua is the
        // supported way to give the whole panel a dark appearance.
        panel.appearance = NSAppearance(named: .darkAqua)

        hostingView = OverlayHostingView(frame: frame)
        panel.contentView = hostingView
    }

    func show() {
        visible = true

        onMain {
            self.hideTimer?.invalidate()
            self.hideTimer = nil

            self.reposition()
            self.panel.orderFrontRegardless()
            self.hostingView.setState(.recording)
            self.hostingView.appear()
        }
    }

    func hide() {
        guard visible else { return }
        visible = false

        onMain {
            self.hostingView.disappear()

            self.hideTimer?.invalidate()
            self.hideTimer = Timer.scheduledTimer(withTimeInterval: Self.popOutDuration, repeats: false) { [weak self] _ in
                self?.panel.orderOut(nil)
                self?.hideTimer = nil
            }
        }
    }

    func setState(_ state: OverlayState) {
        onMain {
            self.hostingView.setState(state)
        }
    }

    func updateAudioLevel(_ level: Float) {
        let clamped = max(0, min(1, level))
        onMain {
            guard self.visible else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastLevelSent >= 1.0 / 45.0 else { return }
            self.lastLevelSent = now
            self.hostingView.updateLevel(clamped)
        }
    }

    /// Sits low and centred, just clear of the Dock. High enough on screen and it lands in
    /// the middle of whatever you are reading; this keeps it out of the way while still
    /// being where the eye can find it.
    private static let bottomInset: CGFloat = 38

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let x = area.origin.x + (area.size.width - panel.frame.width) / 2
        // The window is larger than the pill by the glow margin on every side. Subtract it
        // so the pill itself, not the transparent padding, sits `bottomInset` above the edge.
        let y = area.origin.y + Self.bottomInset - OverlayHostingView.glowMargin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

enum OverlayState {
    case recording
    case processing
}

// MARK: - Overlay view

/// A small glass pill with a row of bars.
///
/// Deliberately quiet: it fades in, it moves only while you are actually speaking, and it
/// fades out. There is no idle animation and no spring — an indicator that fidgets on its
/// own draws the eye away from the thing you are dictating into, which is the one place it
/// should never be.
final class OverlayHostingView: NSView {
    private let pill: PillView
    private var barLayers: [CALayer] = []
    private var state: OverlayState = .recording

    // Layout
    private static let barCount = profile.count
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 4
    private static let barHeight: CGFloat = 13
    private static let sidePadding: CGFloat = 11

    private static let contentWidth =
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap

    /// Transparent room around the pill for the glow to spill into. A window clips at its
    /// own edge, so with the panel sized to the pill exactly there is nowhere for a halo to
    /// be drawn and the glow simply does not exist.
    static let glowMargin: CGFloat = 18

    private static let pillSize = NSSize(width: contentWidth + sidePadding * 2, height: 22)
    static let panelSize = NSSize(width: pillSize.width + glowMargin * 2,
                                  height: pillSize.height + glowMargin * 2)

    /// Height at silence, as a fraction of `barHeight` — a row of short even ticks. Even,
    /// not shaped: a frozen waveform looks like something stopped working, a level row
    /// looks like it is waiting.
    private static let restScale: Float = 0.24

    /// How each bar shares the growth: a soft hump, peaking left of centre. Symmetric read
    /// as a drawn triangle rather than a heard voice; fully jagged read as noise.
    private static let profile: [Float] = [0.42, 0.72, 0.95, 1.00, 0.80, 0.58, 0.38]

    /// Bars rise a little faster than they fall, so the row leans forward like a voice
    /// instead of lagging behind it.
    private static let attack: Float = 0.4
    private static let release: Float = 0.7

    /// A rise should read as a wave travelling along the row rather than one block. The
    /// stagger is baked into each bar's easing rather than delaying its start: levels arrive
    /// on the audio tap's schedule, not ours, and a delayed start stalls outright whenever
    /// the next level lands before the delay elapses. Easing keeps the wave inside the one
    /// animation, so it looks the same however fast the callbacks come.
    private static let barDuration: TimeInterval = 0.07
    private static let waveLead: Float = 0.55
    private static let barTiming: [CAMediaTimingFunction] = (0..<barCount).map { i in
        let lead = waveLead * Float(i) / Float(max(barCount - 1, 1))
        return CAMediaTimingFunction(controlPoints: lead, 0, 0.7, 1)
    }

    /// A quiet, fixed lift. Animating a blur boundary next to Liquid Glass makes the edge
    /// itself look unstable, so voice activity belongs to the bars alone.
    private static let glowRadius: CGFloat = 6.5
    private static let glowOpacity: Float = 0.10

    /// How far the glow ring reaches past the pill before the blur softens it.
    private static let glowSpread: CGFloat = 8

    private var level: Float = 0

    override init(frame: NSRect) {
        pill = PillView(frame: NSRect(x: Self.glowMargin, y: Self.glowMargin,
                                      width: Self.pillSize.width, height: Self.pillSize.height))
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = .clear
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Self.glowOpacity
        layer?.shadowOffset = .zero
        layer?.shadowRadius = Self.glowRadius
        // Spelled out rather than derived from the layer's contents: the pill is a system
        // material composited outside our layer tree, so there is no reliable alpha for
        // Core Animation to infer a shape from, and inferring one every frame is expensive.
        layer?.shadowPath = Self.glowPath(around: pill.frame)

        addSubview(pill)
        setupBars()

        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupBars() {
        let contentBounds = pill.contentBounds
        let startX = contentBounds.midX - Self.contentWidth / 2

        for i in 0..<Self.barCount {
            let bar = CALayer()
            let x = startX + CGFloat(i) * (Self.barWidth + Self.barGap)
            bar.frame = CGRect(x: x, y: contentBounds.midY - Self.barHeight / 2,
                               width: Self.barWidth, height: Self.barHeight)
            bar.cornerRadius = Self.barWidth / 2
            bar.backgroundColor = NSColor(white: 1, alpha: 0.85).cgColor
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.transform = CATransform3DMakeScale(1, CGFloat(Self.restScale), 1)
            pill.contentLayer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    func setState(_ newState: OverlayState) {
        state = newState
        level = 0
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        settleBars(animated: newState == .processing && !reduceMotion)

        switch newState {
        case .recording:
            stopBreathing()
        case .processing:
            startBreathing()
        }
    }

    // MARK: - Appearance

    static let fadeInDuration: TimeInterval = 0.14
    static let fadeOutDuration: TimeInterval = 0.12

    func appear() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeInDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    func disappear() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeOutDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }
    }

    // MARK: - Level

    func updateLevel(_ input: Float) {
        guard state == .recording else { return }

        // Smoothed so the row reads as a voice rather than as noise, and biased upward so
        // ordinary speech uses most of the range instead of hovering near the floor. The
        // attack is faster than the release, so bars snap up with each syllable and fall
        // back with a natural trailing edge.
        let boosted = powf(input, 0.62)
        if boosted >= level {
            level = level * (1 - Self.attack) + boosted * Self.attack
        } else {
            level = level * (1 - Self.release) + boosted * Self.release
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        for (i, bar) in barLayers.enumerated() {
            let target = CGFloat(scale(forBar: i, at: level))

            if !reduceMotion {
                // Always leaves from wherever the bar actually is, so a level arriving
                // mid-flight just retargets the bar rather than stranding it.
                let anim = CABasicAnimation(keyPath: "transform.scale.y")
                anim.fromValue = bar.presentation()?.transform.m22 ?? bar.transform.m22
                anim.toValue = target
                anim.duration = Self.barDuration
                anim.timingFunction = Self.barTiming[i]
                bar.add(anim, forKey: "level")
            }

            // The model value moves without an animation of its own; the explicit one above
            // is the only animation on this property, so the two cannot fight over it.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.transform = CATransform3DMakeScale(1, target, 1)
            CATransaction.commit()
        }

    }

    private func scale(forBar i: Int, at level: Float) -> Float {
        Self.restScale + (1 - Self.restScale) * Self.profile[i] * level
    }

    private func settleBars(animated: Bool) {
        let rest = CATransform3DMakeScale(1, CGFloat(Self.restScale), 1)

        for bar in barLayers {
            let from = bar.presentation()?.transform ?? bar.transform
            bar.removeAllAnimations()

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.transform = rest
            CATransaction.commit()

            guard animated else { continue }
            let settle = CABasicAnimation(keyPath: "transform")
            settle.fromValue = from
            settle.toValue = rest
            settle.duration = 0.18
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(settle, forKey: "settle")
        }
    }

    /// The glow is a ring rather than a filled pill. A shadow is drawn behind its layer, and
    /// the pill is translucent, so a solid one would show straight through and dull the
    /// material it is meant to lift. Punching the pill back out keeps the halo outside it.
    private static func glowPath(around pill: CGRect) -> CGPath {
        let radius = pill.height / 2
        let outer = pill.insetBy(dx: -glowSpread, dy: -glowSpread)

        let path = CGMutablePath()
        path.addRoundedRect(in: outer,
                            cornerWidth: radius + glowSpread, cornerHeight: radius + glowSpread)
        // A capsule is symmetric about its vertical centre, so mirroring it leaves the shape
        // untouched while reversing its winding. That makes this subpath a hole under the
        // non-zero winding rule used by CALayer.shadowPath.
        let mirrored = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * pill.midX, ty: 0)
        path.addRoundedRect(in: pill, cornerWidth: radius, cornerHeight: radius,
                            transform: mirrored)
        return path
    }

    // MARK: - Processing

    /// One slow breath of the bars. Transcribing takes well under a second, so this
    /// only has to say "still here" — a second distinct animation would be noise.
    /// Held opacity under Reduce Motion. Dropping the breath entirely would leave the pill
    /// looking exactly as it does while recording, which reads as a hang rather than as
    /// work in progress; a state that is simply dimmer says the same thing without moving.
    private static let processingDimmed: Float = 0.7

    private func startBreathing() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setBarOpacity(Self.processingDimmed)
            return
        }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        barLayers.forEach { $0.add(pulse, forKey: "breathe") }
    }

    private func stopBreathing() {
        barLayers.forEach { $0.removeAnimation(forKey: "breathe") }
        setBarOpacity(1)
    }

    private func setBarOpacity(_ value: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayers.forEach { $0.opacity = value }
        CATransaction.commit()
    }
}

// MARK: - Pill material

/// The pill's body. On macOS 26+ this is Apple's native Liquid Glass
/// (`NSGlassEffectView`), which supplies the blur, edge highlight and refraction
/// itself. On older systems we hand-roll the same idea: a blur material inset a hair
/// from the edge, with a hairline highlight drawn around it.
private final class PillView: NSView {
    private let material: NSView
    private let stroke: CAShapeLayer?

    override init(frame: NSRect) {
        // Everything inside the pill is laid out in the pill's own coordinate space. `frame`
        // places the pill within its parent, so only its size means anything here.
        let box = NSRect(origin: .zero, size: frame.size)
        let radius = box.height / 2

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: box)
            glass.style = .regular
            glass.cornerRadius = radius
            material = glass
            stroke = nil
        } else {
            let inset: CGFloat = 0.75
            let blur = NSVisualEffectView(frame: box.insetBy(dx: inset, dy: inset))
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            // AppKit normally creates the layer on `wantsLayer`, but not in every context,
            // and when it does not the bars are added to nothing and the pill comes up empty.
            if blur.layer == nil { blur.layer = CALayer() }
            blur.layer?.cornerRadius = max(radius - inset, 1)
            blur.layer?.masksToBounds = true
            material = blur

            // Half a point inside the edge: a 1pt line centred on the boundary itself puts
            // half its width outside the pill, where the window clips it away, leaving a
            // fainter and softer edge than intended.
            let hairline = CAShapeLayer()
            hairline.fillColor = nil
            hairline.strokeColor = NSColor(white: 1, alpha: 0.12).cgColor
            hairline.lineWidth = 1
            hairline.path = CGPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
                                   cornerWidth: radius - 0.5, cornerHeight: radius - 0.5,
                                   transform: nil)
            stroke = hairline
        }

        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear

        addSubview(material)
        if let stroke = stroke { layer?.addSublayer(stroke) }

        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            let content = NSView(frame: box)
            content.wantsLayer = true
            if content.layer == nil { content.layer = CALayer() }
            glass.contentView = content
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The coordinate space the bars are laid out in.
    var contentBounds: CGRect {
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            return glass.contentView?.bounds ?? bounds
        }
        return material.bounds
    }

    /// Layer the bars live in.
    var contentLayer: CALayer? {
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            return glass.contentView?.layer
        }
        return material.layer
    }
}
