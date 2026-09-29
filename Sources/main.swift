import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static let showNotification = Notification.Name("io.github.amarchakitus.stickydock.show")

    private let state = AppState.shared
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var lastShowRequest = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If another copy is already running, ask it to show its window and exit.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .contains(where: { $0 != NSRunningApplication.current }) {
            DistributedNotificationCenter.default().postNotificationName(
                Self.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleShowRequest), name: Self.showNotification, object: nil)

        let launchedAtLogin = Self.launchedAsLoginItem()
        buildMainMenu()
        state.onAppearanceChange = { [weak self] in self?.applyAppearance() }
        DockLocker.shared.start()
        state.sync()
        applyAppearance()
        if !launchedAtLogin { showSettings() }
    }

    // Opening the app again while it's running (Finder, Spotlight, Dock click).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Any process can post the distributed "show" notification, so rate-limit it
    /// to stop it being used to repeatedly steal focus.
    @objc private func handleShowRequest() {
        guard Date().timeIntervalSince(lastShowRequest) > 2 else { return }
        lastShowRequest = Date()
        showSettings()
    }

    @objc func showSettings() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(state: state) { [weak self] in
                self?.window?.close()
            })
            let w = NSWindow(contentViewController: controller)
            w.title = "StickyDock"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        state.sync()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // The background poll no longer syncs the UI, so pick up changes made elsewhere
    // (e.g. Login Items or Accessibility in System Settings) when the user comes back.
    func windowDidBecomeKey(_ notification: Notification) {
        state.sync()
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: AppState.repoURL.absoluteString,
            attributes: [.link: AppState.repoURL, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func moveNow() {
        state.moveNow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func applyAppearance() {
        let wasVisible = window?.isVisible == true
        NSApp.setActivationPolicy(state.showInDock ? .regular : .accessory)

        if state.showInMenuBar {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "StickyDock")
                let menu = NSMenu()
                menu.addItem(withTitle: "About StickyDock", action: #selector(showAbout), keyEquivalent: "").target = self
                menu.addItem(withTitle: "StickyDock Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
                menu.addItem(withTitle: "Move Dock Now", action: #selector(moveNow), keyEquivalent: "").target = self
                menu.addItem(.separator())
                menu.addItem(withTitle: "Quit StickyDock", action: #selector(quit), keyEquivalent: "q").target = self
                item.menu = menu
                statusItem = item
            }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }

        // Changing activation policy can push our window behind others; bring it back.
        if wasVisible {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                self.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About StickyDock", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide StickyDock", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit StickyDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
