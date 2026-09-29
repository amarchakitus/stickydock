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
    var hasTap: Bool { tap != nil }
    var isTapActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var isNudging = false
    private var lastNudge = Date.distantPast
    private var failedNudges = 0
    private var lastDockID: CGDirectDisplayID?
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
        pollTimer?.tolerance = 1 // let macOS coalesce this wakeup with others
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
        updateTapState()
        onChange?()
    }

    private func tick() {
        if tap != nil {
            if !AXIsProcessTrusted() {
                // Permission revoked while running: drop the tap rather than leave a dead filter on HID input.
                removeTap()
            } else {
                updateTapState()
            }
        }
        installTapIfPossible()
        let newEdge = Self.readDockEdge()
        if newEdge != edge { refresh() }
        enforce()
        // Only notify the UI when something it shows changed; syncing is comparatively expensive.
        let dockID = currentDockDisplayID()
        if dockID != lastDockID {
            lastDockID = dockID
            onChange?()
        }
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
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, _ in
            DockLocker.shared.handle(type: type, event: event)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                             options: .defaultTap, eventsOfInterest: mask,
                                             callback: callback, userInfo: nil) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tap = newTap
        tapSource = source
        updateTapState()
        onChange?()
    }

    private func removeTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        tapSource = nil
        onChange?()
    }

    /// The tap only has work to do when there's an edge to guard or a nudge in progress
    /// (to swallow clicks). Otherwise keep it disabled so mouse events don't wake us.
    private var tapNeeded: Bool { isNudging || (enabled && !guardedBounds.isEmpty) }

    private func updateTapState() {
        guard let tap, CGEvent.tapIsEnabled(tap: tap) != tapNeeded else { return }
        CGEvent.tapEnable(tap: tap, enable: tapNeeded)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            updateTapState()
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            // While we're pulling the Dock over, the cursor sits where the Dock appears;
            // swallow clicks so they can't launch whatever app slides in under it.
            return isNudging ? nil : Unmanaged.passUnretained(event)
        default:
            break
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
              CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved) > 1,
              let current = currentDockDisplayID(), current != target.displayID else { return }
        moveDock(to: target)
    }

    /// Manually move the Dock to the target display now.
    func moveDockNow() {
        failedNudges = 0
        refresh()
        guard let target, currentDockDisplayID() != target.displayID else { return }
        moveDock(to: target)
    }

    /// Pulls the Dock over by pushing the cursor against the display's Dock edge.
    ///
    /// Measured on macOS 27: the Dock ignores a cursor that just appears on the edge (it has to
    /// arrive moving), commits to moving after ~0.2-0.27 s of pushing, and only reports the move
    /// (via the screens' visible frames) at ~0.6 s. So push briefly, hand the cursor back, and
    /// only if the Dock didn't come over, retry pushing until it's seen to arrive.
    private func moveDock(to display: DisplayInfo, retry: Bool = false) {
        guard !isNudging, AXIsProcessTrusted() else { return }
        // Don't hijack the cursor mid-drag.
        if NSEvent.pressedMouseButtons != 0 {
            scheduleEnforce(after: 1)
            return
        }
        isNudging = true
        updateTapState()
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

        // Two short steps onto the edge, then keep pushing against it.
        var steps: [(CGPoint, CGVector)] = [8, 4].map { i in
            (CGPoint(x: edgePoint.x - dir.dx * i, y: edgePoint.y - dir.dy * i), CGVector(dx: dir.dx * 4, dy: dir.dy * 4))
        }
        let pushes = retry ? 75 : 17 // 20 ms apart: ~1.5 s (stopping early once the Dock arrives) or ~0.35 s
        steps += Array(repeating: (edgePoint, CGVector(dx: dir.dx * 6, dy: dir.dy * 6)), count: pushes)
        let arrived = { [weak self] in self?.currentDockDisplayID() == display.displayID }

        // Hide the cursor while it's away. This only takes effect while we're the active app
        // (e.g. using the settings window), which is when the user is watching.
        CGDisplayHideCursor(CGMainDisplayID())
        CGWarpMouseCursorPosition(steps[0].0)
        CGAssociateMouseAndMouseCursorPosition(1)
        postMoves(steps, index: 0, stopEarly: retry ? arrived : nil) { [weak self] in
            guard let self else { return }
            CGWarpMouseCursorPosition(original)
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())
            self.isNudging = false
            self.updateTapState()
            self.waitUntil(arrived, timeout: 1.0) { success in
                if success {
                    self.failedNudges = 0
                } else if !retry {
                    self.moveDock(to: display, retry: true)
                    return
                } else {
                    self.failedNudges += 1
                }
                self.onChange?()
            }
        }
    }

    private func postMoves(_ steps: [(CGPoint, CGVector)], index: Int, stopEarly: (() -> Bool)?,
                           completion: @escaping () -> Void) {
        guard index < steps.count, stopEarly?() != true else { completion(); return }
        let (point, delta) = steps[index]
        if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: point, mouseButton: .left) {
            e.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.dx))
            e.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.dy))
            e.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.postMoves(steps, index: index + 1, stopEarly: stopEarly, completion: completion)
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval,
                           completion: @escaping (Bool) -> Void) {
        if condition() { completion(true); return }
        guard timeout > 0 else { completion(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitUntil(condition, timeout: timeout - 0.1, completion: completion)
        }
    }
}
