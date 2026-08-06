import ApplicationServices
import Cocoa

struct ContextTicket: Hashable, Sendable {
    fileprivate let id: UUID
    let sessionID: Int
}

protocol DictationContextProviding: AnyObject {
    func begin(target: NSRunningApplication, sessionID: Int) -> ContextTicket
    func resolve(_ ticket: ContextTicket, rawTranscript: String) -> PolishContext
    func discard(_ ticket: ContextTicket)
}

/// Takes one bounded Accessibility snapshot when a dictation begins. It never polls,
/// never screenshots, never logs text, and never makes the dictation wait: an unfinished
/// or unsupported capture resolves to `.empty`, which is exactly today's behavior.
final class AXContextProvider: DictationContextProviding {
    private struct Entry {
        var snapshot: WindowContextSnapshot?
        var finished: Bool
    }

    private let captureQueue = DispatchQueue(
        label: "talktype.context-capture",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func begin(target: NSRunningApplication, sessionID: Int) -> ContextTicket {
        let ticket = ContextTicket(id: UUID(), sessionID: sessionID)
        lock.lock()
        // DictationManager only permits one active dictation. Dropping an abandoned
        // entry here makes the memory bound independent of how long the app has run.
        entries.removeAll(keepingCapacity: true)
        entries[ticket.id] = Entry(snapshot: nil, finished: false)
        lock.unlock()

        let pid = target.processIdentifier
        let appName = target.localizedName ?? target.bundleIdentifier ?? "Unknown"
        captureQueue.async { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            let snapshot = Self.capture(pid: pid, appName: appName)
            let elapsed = ProcessInfo.processInfo.systemUptime - started

            guard let self = self else { return }
            self.lock.lock()
            if self.entries[ticket.id] != nil {
                self.entries[ticket.id] = Entry(snapshot: snapshot, finished: true)
            }
            self.lock.unlock()

            let blocks = snapshot?.blocks.count ?? 0
            Log.write("[context] capture blocks=\(blocks) ms=\(Int(elapsed * 1_000))")
        }
        return ticket
    }

    func resolve(_ ticket: ContextTicket, rawTranscript: String) -> PolishContext {
        lock.lock()
        let entry = entries.removeValue(forKey: ticket.id)
        lock.unlock()
        guard let entry = entry, entry.finished, let snapshot = entry.snapshot else {
            return .empty
        }
        return ContextSelector.resolve(snapshot: snapshot, rawTranscript: rawTranscript)
    }

    func discard(_ ticket: ContextTicket) {
        lock.lock()
        entries.removeValue(forKey: ticket.id)
        lock.unlock()
    }

    // MARK: - One-shot capture

    private struct Node {
        let element: AXUIElement
        let depth: Int
    }

    private static func capture(pid: pid_t, appName: String) -> WindowContextSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.03)

        guard let focused = elementAttribute(app, kAXFocusedUIElementAttribute as String),
              !isSecure(focused),
              let window = elementAttribute(app, kAXFocusedWindowAttribute as String),
              let focusFrame = frame(of: focused),
              let windowFrame = frame(of: window)
        else { return nil }

        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        var pending = [Node(element: window, depth: 0)]
        var cursor = 0
        var visited: Set<CFHashCode> = []
        var blocks: [WindowTextBlock] = []
        var capturedCharacters = 0
        var visualOrder = 0

        while cursor < pending.count,
              visited.count < 120,
              capturedCharacters < 8_000,
              ProcessInfo.processInfo.systemUptime < deadline {
            let node = pending[cursor]
            cursor += 1
            let identity = CFHash(node.element)
            guard visited.insert(identity).inserted else { continue }

            AXUIElementSetMessagingTimeout(node.element, 0.03)
            if boolAttribute(node.element, kAXHiddenAttribute as String) == true { continue }
            if isSecure(node.element) { continue }

            let role = stringAttribute(node.element, kAXRoleAttribute as String) ?? ""
            let nodeFrame = frame(of: node.element)
            if !CFEqual(node.element, focused),
               let nodeFrame = nodeFrame,
               nodeFrame.intersects(windowFrame),
               let text = readableText(of: node.element, role: role) {
                let bounded = String(text.suffix(2_000))
                capturedCharacters += bounded.count
                blocks.append(WindowTextBlock(
                    text: bounded,
                    proximity: proximity(from: nodeFrame, to: focusFrame),
                    visualOrder: visualOrder
                ))
                visualOrder += 1
            }

            guard node.depth < 14 else { continue }
            let visibleChildren = elementArrayAttribute(
                node.element,
                kAXVisibleChildrenAttribute as String
            )
            let children = visibleChildren.isEmpty
                ? elementArrayAttribute(node.element, kAXChildrenAttribute as String)
                : visibleChildren
            for child in children {
                pending.append(Node(element: child, depth: node.depth + 1))
            }
        }

        guard !blocks.isEmpty else { return nil }
        return WindowContextSnapshot(activeApp: appName, blocks: blocks)
    }

    private static func readableText(of element: AXUIElement, role: String) -> String? {
        let readableRoles: Set<String> = [
            "AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink",
        ]
        guard readableRoles.contains(role) else { return nil }

        for attribute in [
            kAXValueAttribute as String,
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
        ] {
            if let text = stringAttribute(element, attribute)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               text.count >= 2 {
                return text
            }
        }
        return nil
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as String) ?? ""
        return role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    private static func proximity(from frame: CGRect?, to focus: CGRect?) -> Double {
        guard let frame = frame, let focus = focus else { return 10_000 }
        let horizontal = max(0, max(focus.minX - frame.maxX, frame.minX - focus.maxX))
        let vertical = max(0, max(focus.minY - frame.maxY, frame.minY - focus.maxY))
        return Double(hypot(horizontal, vertical))
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute as String),
              let sizeValue = attribute(element, kAXSizeAttribute as String),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        let positionAX = positionValue as! AXValue
        let sizeAX = sizeValue as! AXValue
        guard AXValueGetValue(positionAX, .cgPoint, &position),
              AXValueGetValue(sizeAX, .cgSize, &size),
              size.width > 0, size.height > 0
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func elementArrayAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == CFArrayGetTypeID()
        else { return [] }
        return (value as? [Any])?.compactMap { item in
            let object = item as CFTypeRef
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return (object as! AXUIElement)
        } ?? []
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        attribute(element, name) as? Bool
    }
}
