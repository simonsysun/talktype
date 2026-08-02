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
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.alphaValue = 1.0
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // Fixed dark, so the pill looks the same whichever appearance the desktop is in.
        // Following the system meant white bars on a light pill in Light Mode.
        panel.appearance = NSAppearance(named: .vibrantDark)

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
        let y = area.origin.y + Self.bottomInset
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

/// A small dark pill with a row of bars.
///
/// Deliberately quiet: it fades in, it moves only while you are actually speaking, and it
/// fades out. There is no idle animation and no spring — an indicator that fidgets on its
/// own draws the eye away from the thing you are dictating into, which is the one place it
/// should never be.
final class OverlayHostingView: NSView {
    private let blurView: NSVisualEffectView
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
    static let panelSize = NSSize(width: contentWidth + sidePadding * 2, height: 22)

    /// Height at silence, as a fraction of `barHeight` — a row of short even ticks. Even,
    /// not shaped: a frozen waveform looks like something stopped working, a level row
    /// looks like it is waiting.
    private static let restScale: Float = 0.24

    /// How each bar shares the growth: a soft hump, peaking left of centre. Symmetric read
    /// as a drawn triangle rather than a heard voice; fully jagged read as noise.
    private static let profile: [Float] = [0.42, 0.72, 0.95, 1.00, 0.80, 0.58, 0.38]

    private var level: Float = 0

    override init(frame: NSRect) {
        blurView = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        // AppKit normally creates the layer on `wantsLayer`, but not in every context, and
        // when it does not the bars are added to nothing and the pill comes up empty.
        if blurView.layer == nil { blurView.layer = CALayer() }
        blurView.layer?.cornerRadius = frame.height / 2
        blurView.layer?.masksToBounds = true

        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = .clear
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.10
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 5

        addSubview(blurView)
        setupBars()

        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupBars() {
        let startX = (bounds.width - Self.contentWidth) / 2

        for i in 0..<Self.barCount {
            let bar = CALayer()
            let x = startX + CGFloat(i) * (Self.barWidth + Self.barGap)
            bar.frame = CGRect(x: x, y: (bounds.height - Self.barHeight) / 2,
                               width: Self.barWidth, height: Self.barHeight)
            bar.cornerRadius = Self.barWidth / 2
            bar.backgroundColor = NSColor(white: 1, alpha: 0.85).cgColor
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.transform = CATransform3DMakeScale(1, CGFloat(Self.restScale), 1)
            blurView.layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    /// Read-only view of the bar geometry, for rendering previews outside the app.
    var barGeometry: [(x: CGFloat, width: CGFloat, height: CGFloat)] {
        barLayers.map { ($0.frame.origin.x, $0.bounds.width, $0.bounds.height * $0.transform.m22) }
    }

    func setState(_ newState: OverlayState) {
        state = newState
        level = 0
        settleBars(animated: newState == .processing)

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
        // ordinary speech uses most of the range instead of hovering near the floor.
        let boosted = powf(input, 0.62)
        level = level * 0.65 + boosted * 0.35

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.07)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        for (i, bar) in barLayers.enumerated() {
            bar.transform = CATransform3DMakeScale(1, CGFloat(scale(forBar: i, at: level)), 1)
        }
        CATransaction.commit()
    }

    private func scale(forBar i: Int, at level: Float) -> Float {
        Self.restScale + (1 - Self.restScale) * Self.profile[i] * level
    }

    private func settleBars(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(0.18) }
        barLayers.forEach { $0.transform = CATransform3DMakeScale(1, CGFloat(Self.restScale), 1) }
        CATransaction.commit()
    }

    // MARK: - Processing

    /// One slow breath of the whole pill. Transcribing takes well under a second, so this
    /// only has to say "still here" — a second distinct animation would be noise.
    private func startBreathing() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.55
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        blurView.layer?.add(pulse, forKey: "breathe")
    }

    private func stopBreathing() {
        blurView.layer?.removeAnimation(forKey: "breathe")
    }
}
