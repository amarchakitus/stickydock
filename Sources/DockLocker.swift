import AppKit
import ApplicationServices

struct DisplayInfo: Identifiable, Hashable {
    let id: String              // persistent display UUID
    let displayID: CGDirectDisplayID
    let name: String
    let bounds: CGRect          // global CG coordinates (top-left origin)
    let isMain: Bool
}

enum DockEdge: String {
    case bottom, left, right
}

/// Keeps the Dock on one display.
///
/// macOS has no API for choosing the Dock's display; the Dock follows the cursor
/// when it is pushed against the Dock edge of a display. So we (1) stop the cursor
/// just short of that edge on every other display, and (2) if the Dock still ends up
/// elsewhere (e.g. after displays change), push the cursor against the target
/// display's edge to pull it back.
final class DockLocker {
    static let shared = DockLocker()

    var onChange: (() -> Void)?

    var enabled = true {
        didSet { refresh(); scheduleEnforce(after: 0.3) }
    }
    var targetUUID: String? {
        didSet { failedNudges = 0; refresh(); scheduleEnforce(after: 0.3) }
    }
    /// Leave the corners of blocked edges reachable so hot corners keep working.
    var allowHotCorners = false

    private(set) var displays: [DisplayInfo] = []
    private(set) var edge: DockEdge = .bottom
    /// The display we are currently locking to: the chosen one, or the main display if it's disconnected.
    private(set) var target: DisplayInfo?

    var hasAccessibility: Bool { AXIsProcessTrusted() }
    var isTapActive: Bool { tap != nil }

    private var tap: CFMachPort?
    private var isNudging = false
    private var lastNudge = Date.distantPast
    private var failedNudges = 0
    private var pollTimer: Timer?
    private var enforceWork: DispatchWorkItem?
    private var guardedBounds: [CGRect] = []
    private var allBounds: [CGRect] = []

    private let edgeMargin: CGFloat = 2
    private let cornerZone: CGFloat = 6
    private let maxAutoNudges = 3

    var dockAutohides: Bool {
        CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool ?? false
    }

    func start() {
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.failedNudges = 0
            self.refresh()
            self.scheduleEnforce(after: 1.5)
        }
        refresh()
        installTapIfPossible()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        scheduleEnforce(after: 1)
    }

    // MARK: - State

    func refresh() {
        edge = Self.readDockEdge()
        let mainID = CGMainDisplayID()
        displays = NSScreen.screens.compactMap { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(num.uint32Value)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let uuidString = CFUUIDCreateString(nil, uuid) as String? else { return nil }
            return DisplayInfo(id: uuidString, displayID: id, name: screen.localizedName,
                               bounds: CGDisplayBounds(id), isMain: id == mainID)
        }
        target = displays.first { $0.id == targetUUID } ?? displays.first { $0.isMain } ?? displays.first
        allBounds = displays.map(\.bounds)
        guardedBounds = displays.filter { $0.displayID != target?.displayID }.map(\.bounds)
        onChange?()
    }

    private func tick() {
        installTapIfPossible()
        let newEdge = Self.readDockEdge()
        if newEdge != edge { refresh() }
        enforce()
        onChange?()
    }

    private static func readDockEdge() -> DockEdge {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String
        return DockEdge(rawValue: value ?? "bottom") ?? .bottom
    }

    /// The display the Dock is on, inferred from which screen's visible frame is inset on the Dock edge.
    func currentDockDisplayID() -> CGDirectDisplayID? {
        for screen in NSScreen.screens {
            let f = screen.frame, v = screen.visibleFrame
            let hasDock: Bool
            switch edge {
            case .bottom: hasDock = v.minY > f.minY
            case .left: hasDock = v.minX > f.minX
            case .right: hasDock = v.maxX < f.maxX
            }
            if hasDock, let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                return CGDirectDisplayID(num.uint32Value)
            }
        }
        return nil
    }

    // MARK: - Cursor guard

    private func installTapIfPossible() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, _ in
            DockLocker.shared.handle(type: type, event: event)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                             options: .defaultTap, eventsOfInterest: mask,
                                             callback: callback, userInfo: nil) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        onChange?()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard enabled, !isNudging, target != nil else { return Unmanaged.passUnretained(event) }

        let loc = event.location
        guard let b = guardedBounds.first(where: { $0.contains(loc) }) else {
            return Unmanaged.passUnretained(event)
        }

        if allowHotCorners {
            let nearCorner: Bool
            switch edge {
            case .bottom: nearCorner = loc.x < b.minX + cornerZone || loc.x > b.maxX - cornerZone
            case .left, .right: nearCorner = loc.y < b.minY + cornerZone || loc.y > b.maxY - cornerZone
            }
            if nearCorner { return Unmanaged.passUnretained(event) }
        }

        // Only block edges that are an outer boundary (no other display on the other side).
        var p = loc
        switch edge {
        case .bottom:
            let limit = b.maxY - 1 - edgeMargin
            if loc.y > limit, !isCovered(CGPoint(x: loc.x, y: b.maxY + 0.5)) { p.y = limit }
        case .left:
            let limit = b.minX + edgeMargin
            if loc.x < limit, !isCovered(CGPoint(x: b.minX - 0.5, y: loc.y)) { p.x = limit }
        case .right:
            let limit = b.maxX - 1 - edgeMargin
            if loc.x > limit, !isCovered(CGPoint(x: b.maxX + 0.5, y: loc.y)) { p.x = limit }
        }

        if p != loc {
            event.location = p
            event.setIntegerValueField(edge == .bottom ? .mouseEventDeltaY : .mouseEventDeltaX, value: 0)
            CGWarpMouseCursorPosition(p)
            CGAssociateMouseAndMouseCursorPosition(1) // cancels the post-warp input freeze
        }
        return Unmanaged.passUnretained(event)
    }

    private func isCovered(_ point: CGPoint) -> Bool {
        allBounds.contains { $0.contains(point) }
    }

    // MARK: - Moving the Dock

    private func scheduleEnforce(after delay: TimeInterval) {
        enforceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.enforce() }
        enforceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func enforce() {
        guard enabled, let target, displays.count > 1, !isNudging,
              failedNudges < maxAutoNudges,
              Date().timeIntervalSince(lastNudge) > 5,
              let current = currentDockDisplayID(), current != target.displayID else { return }
        moveDock(to: target)
    }

    /// Manually move the Dock to the target display now.
    func moveDockNow() {
        failedNudges = 0
        refresh()
        if let target { moveDock(to: target) }
    }

    private func moveDock(to display: DisplayInfo) {
        guard !isNudging, AXIsProcessTrusted() else { return }
        // Don't hijack the cursor mid-drag.
        if NSEvent.pressedMouseButtons != 0 {
            scheduleEnforce(after: 1)
            return
        }
        isNudging = true
        lastNudge = Date()

        let original = CGEvent(source: nil)?.location ?? CGPoint(x: display.bounds.midX, y: display.bounds.midY)
        let b = display.bounds
        let edgePoint: CGPoint
        let dir: CGVector
        switch edge {
        case .bottom: edgePoint = CGPoint(x: b.midX, y: b.maxY - 1); dir = CGVector(dx: 0, dy: 1)
        case .left: edgePoint = CGPoint(x: b.minX, y: b.midY); dir = CGVector(dx: -1, dy: 0)
        case .right: edgePoint = CGPoint(x: b.maxX - 1, y: b.midY); dir = CGVector(dx: 1, dy: 0)
        }

        // Approach the edge, then keep pushing against it.
        var steps: [(CGPoint, CGVector)] = []
        for i in stride(from: 40, through: 0, by: -4) {
            let p = CGPoint(x: edgePoint.x - dir.dx * CGFloat(i), y: edgePoint.y - dir.dy * CGFloat(i))
            steps.append((p, CGVector(dx: dir.dx * 4, dy: dir.dy * 4)))
        }
        for _ in 0..<40 {
            steps.append((edgePoint, CGVector(dx: dir.dx * 6, dy: dir.dy * 6)))
        }

        CGWarpMouseCursorPosition(steps[0].0)
        CGAssociateMouseAndMouseCursorPosition(1)
        postMoves(steps, index: 0) { [weak self] in
            guard let self else { return }
            CGWarpMouseCursorPosition(original)
            CGAssociateMouseAndMouseCursorPosition(1)
            self.isNudging = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if self.currentDockDisplayID() == display.displayID {
                    self.failedNudges = 0
                } else {
                    self.failedNudges += 1
                }
                self.onChange?()
            }
        }
    }

    private func postMoves(_ steps: [(CGPoint, CGVector)], index: Int, completion: @escaping () -> Void) {
        guard index < steps.count else { completion(); return }
        let (point, delta) = steps[index]
        if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: point, mouseButton: .left) {
            e.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.dx))
            e.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.dy))
            e.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.postMoves(steps, index: index + 1, completion: completion)
        }
    }
}
