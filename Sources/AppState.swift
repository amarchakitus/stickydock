import AppKit
import ServiceManagement

/// User preferences and UI-facing state, persisted in UserDefaults.
final class AppState: ObservableObject {
    static let shared = AppState()
    static let repoURL = URL(string: "https://github.com/amarchakitus/stickydock")!
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    private let defaults = UserDefaults.standard
    private let locker = DockLocker.shared

    var onAppearanceChange: (() -> Void)?

    @Published var displays: [DisplayInfo] = []
    @Published var currentDockName = "Unknown"
    @Published var hasAccessibility = false
    @Published var launchAtLogin = false
    @Published var loginMessage: String?

    @Published var targetUUID: String {
        didSet {
            guard targetUUID != oldValue else { return }
            defaults.set(targetUUID, forKey: "targetUUID")
            if let d = displays.first(where: { $0.id == targetUUID }) { targetName = d.name }
            locker.targetUUID = targetUUID
        }
    }
    @Published var targetName: String {
        didSet { defaults.set(targetName, forKey: "targetName") }
    }
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "enabled"); locker.enabled = enabled }
    }
    @Published var showInDock: Bool {
        didSet { defaults.set(showInDock, forKey: "showInDock"); onAppearanceChange?() }
    }
    @Published var showInMenuBar: Bool {
        didSet { defaults.set(showInMenuBar, forKey: "showInMenuBar"); onAppearanceChange?() }
    }
    @Published var allowHotCorners: Bool {
        didSet { defaults.set(allowHotCorners, forKey: "allowHotCorners"); locker.allowHotCorners = allowHotCorners }
    }

    var targetConnected: Bool { displays.contains { $0.id == targetUUID } }

    private init() {
        defaults.register(defaults: ["enabled": true, "showInDock": true, "showInMenuBar": true])
        targetUUID = defaults.string(forKey: "targetUUID") ?? ""
        targetName = defaults.string(forKey: "targetName") ?? ""
        enabled = defaults.bool(forKey: "enabled")
        showInDock = defaults.bool(forKey: "showInDock")
        showInMenuBar = defaults.bool(forKey: "showInMenuBar")
        allowHotCorners = defaults.bool(forKey: "allowHotCorners")

        locker.enabled = enabled
        locker.allowHotCorners = allowHotCorners
        locker.targetUUID = targetUUID.isEmpty ? nil : targetUUID
        locker.onChange = { [weak self] in self?.sync() }
    }

    func sync() {
        displays = locker.displays
        hasAccessibility = locker.hasAccessibility && locker.isTapActive
        let dockID = locker.currentDockDisplayID()
        currentDockName = displays.first { $0.displayID == dockID }?.name ?? "Unknown (Dock may be hidden)"
        launchAtLogin = SMAppService.mainApp.status == .enabled

        // First run: default to wherever the Dock is now, else the main display.
        if targetUUID.isEmpty, let initial = displays.first(where: { $0.displayID == dockID })
            ?? displays.first(where: { $0.isMain }) {
            targetUUID = initial.id
        }
    }

    func moveNow() {
        locker.moveDockNow()
    }

    func setLaunchAtLogin(_ on: Bool) {
        loginMessage = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginMessage = error.localizedDescription
        }
        if SMAppService.mainApp.status == .requiresApproval {
            loginMessage = "Approve StickyDock in System Settings → General → Login Items."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Plain-text environment summary for bug reports.
    func debugInfo() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let dockID = locker.currentDockDisplayID()
        var lines = [
            "StickyDock \(Self.version) (\(arch))",
            "macOS \(os)",
            "Accessibility trusted: \(locker.hasAccessibility), event tap active: \(locker.isTapActive)",
            "Lock enabled: \(enabled), hot corners allowed: \(allowHotCorners)",
            "Dock position: \(locker.edge.rawValue), autohide: \(locker.dockAutohides)",
            "Target: \(targetName), connected: \(targetConnected), locking to: \(locker.target?.name ?? "none")",
            "Displays:",
        ]
        for d in displays {
            var tags: [String] = []
            if d.isMain { tags.append("main") }
            if d.displayID == dockID { tags.append("has Dock") }
            if d.id == targetUUID { tags.append("target") }
            let b = d.bounds
            lines.append("  - \(d.name): origin (\(Int(b.minX)), \(Int(b.minY))), size \(Int(b.width))x\(Int(b.height))\(tags.isEmpty ? "" : " [" + tags.joined(separator: ", ") + "]")")
        }
        return lines.joined(separator: "\n")
    }

    func copyDebugInfo() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(debugInfo(), forType: .string)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
