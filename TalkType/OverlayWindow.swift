import Cocoa

/// NSPanel host for the floating overlay. Does not steal focus.
final class OverlayWindow {
    private let panel: NSPanel
    private let hostingView: OverlayHostingView
    private var hideTimer: Timer?
    private var visible = false
    private var lastLevelSent: TimeInterval = 0
    static let popOutDuration: TimeInterval = OverlayHostingView.popOutDuration

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

// MARK: - Native overlay view using Core Animation

final class OverlayHostingView: NSView {
    private let blurView: NSVisualEffectView
    private var barLayers: [CALayer] = []
    private var dotLayers: [CALayer] = []
    private var state: OverlayState = .recording

    // Layout. The pill is sized from its contents plus `sidePadding`, rather than being
    // a fixed box the bars float inside — the previous 140x42 left 36pt of dead space on
    // each side of a 68pt waveform, which read as a large empty slab.
    private static let barCount = 9
    private static let barWidth: CGFloat = 3.5
    private static let barGap: CGFloat = 3
    private static let barHeight: CGFloat = 16
    private static let sidePadding: CGFloat = 13

    private static let contentWidth =
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
    static let panelSize = NSSize(width: contentWidth + sidePadding * 2, height: 30)

    private let barMultipliers: [CGFloat]

    /// Tallest a bar is allowed to grow, as a multiple of `barHeight`.
    private static let maxBarScale: Float = 1.5
    /// Height at silence. Matches the top of the idle animation so the bars grow out of
    /// their resting motion instead of jumping when speech starts. Tall enough that the
    /// resting state still reads as a waveform rather than a row of dots.
    private static let idleTopScale: Float = 0.46

    // Animation state
    private var surfaceLevel: Float = 0
    private var idleAnimating = false

    override init(frame: NSRect) {
        let mid = CGFloat(Self.barCount - 1) / 2.0
        barMultipliers = (0..<Self.barCount).map { i in
            let dist = abs(CGFloat(i) - mid) / mid
            // Shallow taper. A steeper one drew a perfect triangle whenever the audio
            // was steady, which read as an icon rather than a level meter.
            return 1.0 - dist * 0.28
        }

        blurView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = frame.height / 2
        blurView.layer?.masksToBounds = true
        blurView.layer?.borderWidth = 0.5
        blurView.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor

        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = .clear

        // Subtle shadow matching macOS floating panels
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowRadius = 9

        addSubview(blurView)
        setupBars()
        setupDots()

        // Start hidden
        alphaValue = 0
        layer?.transform = CATransform3DMakeScale(0.75, 0.75, 1)
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
            bar.backgroundColor = NSColor(white: 1, alpha: 0.82).cgColor
            bar.opacity = 0.72
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.transform = CATransform3DMakeScale(1, CGFloat(Self.idleTopScale), 1)
            blurView.layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    private func setupDots() {
        let dotSize: CGFloat = 3.5
        let dotGap: CGFloat = 5
        let totalWidth = 3 * dotSize + 2 * dotGap
        let startX = (bounds.width - totalWidth) / 2

        for i in 0..<3 {
            let dot = CALayer()
            let x = startX + CGFloat(i) * (dotSize + dotGap)
            dot.frame = CGRect(x: x, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)
            dot.cornerRadius = dotSize / 2
            dot.backgroundColor = NSColor(white: 1, alpha: 0.9).cgColor
            dot.isHidden = true
            blurView.layer?.addSublayer(dot)
            dotLayers.append(dot)
        }
    }

    func setState(_ newState: OverlayState) {
        state = newState
        stopIdleAnimations()
        surfaceLevel = 0

        switch newState {
        case .recording:
            barLayers.forEach { $0.isHidden = false }
            dotLayers.forEach { $0.isHidden = true }
            stopDotAnimations()
            startIdleAnimations()
        case .processing:
            barLayers.forEach { $0.isHidden = true }
            dotLayers.forEach { $0.isHidden = false }
            startDotAnimations()
        }
    }

    static let popOutDuration: TimeInterval = 0.16

    /// Rises into place from just below, the direction it would come from given where it
    /// sits. Scale alone read as a pop; a short slide reads as the panel arriving.
    private static let riseDistance: CGFloat = 10

    func appear() {
        layer?.removeAnimation(forKey: "disappear")

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1.0)
            self.animator().alphaValue = 1
        }

        let rise = CASpringAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -Self.riseDistance
        rise.toValue = 0
        rise.mass = 0.7
        rise.stiffness = 300
        rise.damping = 22          // barely any overshoot: this is a tool, not a toy
        rise.duration = rise.settlingDuration

        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.86
        grow.toValue = 1.0
        grow.mass = 0.7
        grow.stiffness = 300
        grow.damping = 20
        grow.duration = grow.settlingDuration

        let group = CAAnimationGroup()
        group.animations = [rise, grow]
        group.duration = max(rise.duration, grow.duration)
        layer?.add(group, forKey: "appear")
        layer?.transform = CATransform3DIdentity
    }

    func disappear() {
        layer?.removeAnimation(forKey: "appear")

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.popOutDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 0.4)
            self.animator().alphaValue = 0
        }

        // Sinks back the way it came, and only slightly — leaving is meant to be
        // unnoticeable, not a performance.
        let sink = CABasicAnimation(keyPath: "transform.translation.y")
        sink.fromValue = 0
        sink.toValue = -Self.riseDistance * 0.6

        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1.0
        shrink.toValue = 0.92

        let group = CAAnimationGroup()
        group.animations = [sink, shrink]
        group.duration = Self.popOutDuration
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 0.4)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer?.add(group, forKey: "disappear")
    }

    func updateLevel(_ level: Float) {
        guard state == .recording else { return }

        stopIdleAnimations()
        let boosted = powf(level, 0.62)
        surfaceLevel = surfaceLevel * 0.72 + boosted * 0.28

        // Use short implicit animation for fluid bar movement
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.06)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))

        for (i, bar) in barLayers.enumerated() {
            // Each bar spans its whole range across the whole input range. The previous
            // curve summed a floor and a peak term and then clamped, which pinned the
            // centre bars at maximum from level 0.45 upward — the loudest 55% of speech
            // drew an identical, flat-topped picture.
            let profile = Float(barMultipliers[i])
            let rest = Self.idleTopScale * profile
            let scale = rest + (Self.maxBarScale - rest) * profile * boosted
            let opacity = max(0.68, min(0.98, 0.72 + boosted * 0.2 + profile * 0.04))

            bar.transform = CATransform3DMakeScale(1, CGFloat(scale), 1)
            bar.opacity = opacity
        }

        // Update border brightness with level
        let border = 0.16 + surfaceLevel * 0.10
        blurView.layer?.borderColor = NSColor(white: 1, alpha: CGFloat(border)).cgColor

        CATransaction.commit()
    }

    // MARK: - Idle animations

    /// Staggering via `beginTime` rather than a Timer per bar. The Timer version
    /// allocated and invalidated nine timers on every level update, at up to 45 Hz,
    /// and matched neither `startDotAnimations` nor Core Animation's own clock.
    private func startIdleAnimations() {
        guard !idleAnimating else { return }
        idleAnimating = true

        let delays: [TimeInterval] = [0, 0.06, 0.14, 0.03, 0.10, 0.08, 0.16, 0.05, 0.12]
        let durations: [TimeInterval] = [0.78, 0.68, 0.84, 0.72, 0.90, 0.74, 0.82, 0.70, 0.76]
        let now = CACurrentMediaTime()

        for (i, bar) in barLayers.enumerated() {
            let anim = CABasicAnimation(keyPath: "transform.scale.y")
            anim.fromValue = 0.14
            anim.toValue = Self.idleTopScale
            anim.duration = i < durations.count ? durations[i] : 0.75
            anim.beginTime = now + (i < delays.count ? delays[i] : 0)
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(anim, forKey: "idle")
        }
    }

    private func stopIdleAnimations() {
        guard idleAnimating else { return }
        idleAnimating = false
        barLayers.forEach { $0.removeAnimation(forKey: "idle") }
    }

    // MARK: - Dot animations

    private func startDotAnimations() {
        let delays: [TimeInterval] = [0, 0.14, 0.28]
        for (i, dot) in dotLayers.enumerated() {
            let delay = i < delays.count ? delays[i] : 0

            let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
            scaleAnim.fromValue = 1.0
            scaleAnim.toValue = 1.45
            scaleAnim.duration = 0.62
            scaleAnim.autoreverses = true
            scaleAnim.repeatCount = .infinity
            scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scaleAnim.beginTime = CACurrentMediaTime() + delay

            let opacityAnim = CABasicAnimation(keyPath: "opacity")
            opacityAnim.fromValue = 0.4
            opacityAnim.toValue = 1.0
            opacityAnim.duration = 0.62
            opacityAnim.autoreverses = true
            opacityAnim.repeatCount = .infinity
            opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            opacityAnim.beginTime = CACurrentMediaTime() + delay

            dot.add(scaleAnim, forKey: "pulse_scale")
            dot.add(opacityAnim, forKey: "pulse_opacity")
        }
    }

    private func stopDotAnimations() {
        dotLayers.forEach {
            $0.removeAnimation(forKey: "pulse_scale")
            $0.removeAnimation(forKey: "pulse_opacity")
        }
    }
}
