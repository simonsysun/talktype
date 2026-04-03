import Cocoa

/// NSPanel host for the floating overlay. Does not steal focus.
final class OverlayWindow {
    private let panel: NSPanel
    private let hostingView: OverlayHostingView
    private var hideTimer: Timer?
    private var visible = false
    private var lastLevelSent: TimeInterval = 0
    private static let popOutDuration: TimeInterval = 0.16

    var isVisible: Bool { visible }

    init() {
        let frame = NSRect(x: 0, y: 0, width: 140, height: 42)

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

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let x = area.origin.x + (area.size.width - panel.frame.width) / 2
        let y = area.origin.y + 80
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
    private let pillLayer = CALayer()
    private let blurView: NSVisualEffectView
    private var barLayers: [CALayer] = []
    private var dotLayers: [CALayer] = []
    private var state: OverlayState = .recording

    // Bar layout
    private let barCount = 9
    private let barWidth: CGFloat = 4
    private let barGap: CGFloat = 4
    private let barHeight: CGFloat = 21
    private let barMultipliers: [CGFloat]

    // Animation state
    private var smoothedLevel: Float = 0
    private var surfaceLevel: Float = 0
    private var idleAnimationTimers: [Timer] = []

    override init(frame: NSRect) {
        let mid = CGFloat(8) / 2.0 // (barCount - 1) / 2
        barMultipliers = (0..<9).map { i in
            let dist = abs(CGFloat(i) - mid) / mid
            return 1.0 - dist * 0.50
        }

        blurView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = frame.height / 2
        blurView.layer?.masksToBounds = true
        blurView.layer?.borderWidth = 0.5
        blurView.layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor

        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = .clear

        // Subtle shadow matching macOS floating panels
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.shadowRadius = 12

        addSubview(blurView)
        setupBars()
        setupDots()

        // Start hidden
        alphaValue = 0
        layer?.transform = CATransform3DMakeScale(0.75, 0.75, 1)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupBars() {
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let startX = (bounds.width - totalWidth) / 2

        for i in 0..<barCount {
            let bar = CALayer()
            let x = startX + CGFloat(i) * (barWidth + barGap)
            bar.frame = CGRect(x: x, y: (bounds.height - barHeight) / 2, width: barWidth, height: barHeight)
            bar.cornerRadius = barWidth / 2
            bar.backgroundColor = NSColor(white: 1, alpha: 0.82).cgColor
            bar.opacity = 0.72
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.transform = CATransform3DMakeScale(1, 0.16, 1)
            blurView.layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    private func setupDots() {
        let dotSize: CGFloat = 4
        let dotGap: CGFloat = 6
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
        smoothedLevel = 0
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

    func appear() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1.0)
            self.animator().alphaValue = 1
        }
        // Spring animation for natural pop-in
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.7
        spring.toValue = 1.0
        spring.mass = 0.8
        spring.stiffness = 260
        spring.damping = 14
        spring.initialVelocity = 6
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        layer?.add(spring, forKey: "appear")
        layer?.transform = CATransform3DIdentity
    }

    func disappear() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 0.3)
            self.animator().alphaValue = 0
        }
        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = 0.88
        scaleAnim.duration = 0.14
        scaleAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 0.3)
        scaleAnim.fillMode = .forwards
        scaleAnim.isRemovedOnCompletion = false
        layer?.add(scaleAnim, forKey: "disappear")
        layer?.transform = CATransform3DMakeScale(0.88, 0.88, 1)
    }

    func updateLevel(_ level: Float) {
        guard state == .recording else { return }

        stopIdleAnimations()
        let boosted = powf(level, 0.62)
        smoothedLevel = smoothedLevel * 0.52 + level * 0.48
        surfaceLevel = surfaceLevel * 0.72 + boosted * 0.28

        // Use short implicit animation for fluid bar movement
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.06)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))

        for (i, bar) in barLayers.enumerated() {
            let profile = Float(barMultipliers[i])
            let floor: Float = 0.18 + profile * 0.06
            let peak: Float = 0.42 + boosted * (0.92 + profile * 0.42)
            let scale = max(0.12, min(1.46, floor + peak * profile))
            let opacity = max(0.68, min(0.98, 0.72 + boosted * 0.2 + profile * 0.04))

            bar.transform = CATransform3DMakeScale(1, CGFloat(scale), 1)
            bar.opacity = opacity
        }

        // Update border brightness with level
        let border = 0.42 + surfaceLevel * 0.12
        blurView.layer?.borderColor = NSColor(white: 1, alpha: CGFloat(border)).cgColor

        CATransaction.commit()
    }

    // MARK: - Idle animations

    private func startIdleAnimations() {
        let delays: [TimeInterval] = [0, 0.06, 0.14, 0.03, 0.10, 0.08, 0.16, 0.05, 0.12]
        let durations: [TimeInterval] = [0.78, 0.68, 0.84, 0.72, 0.90, 0.74, 0.82, 0.70, 0.76]

        for (i, bar) in barLayers.enumerated() {
            let delay = i < delays.count ? delays[i] : 0
            let dur = i < durations.count ? durations[i] : 0.75
            let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                guard self != nil else { return }

                let anim = CABasicAnimation(keyPath: "transform.scale.y")
                anim.fromValue = 0.14
                anim.toValue = 0.36
                anim.duration = dur
                anim.autoreverses = true
                anim.repeatCount = .infinity
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(anim, forKey: "idle")
            }
            idleAnimationTimers.append(timer)
        }
    }

    private func stopIdleAnimations() {
        idleAnimationTimers.forEach { $0.invalidate() }
        idleAnimationTimers.removeAll()
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
