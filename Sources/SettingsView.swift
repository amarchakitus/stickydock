import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    var onClose: () -> Void
    @State private var copiedDebugInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "dock.rectangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("StickyDock").font(.title2.bold())
                    Text("Keep the Dock on the display you choose.")
                        .foregroundStyle(.secondary)
                }
            }

            if !state.hasAccessibility {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Accessibility permission needed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.headline)
                        Text("StickyDock needs Accessibility access to stop the cursor from pulling the Dock onto other displays. Enable StickyDock in System Settings → Privacy & Security → Accessibility. It starts working automatically once allowed.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Accessibility Settings") { state.openAccessibilitySettings() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }

            GroupBox("Dock display") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Keep Dock on:", selection: $state.targetUUID) {
                        ForEach(state.displays) { d in
                            Text(label(for: d)).tag(d.id)
                        }
                        if !state.targetConnected && !state.targetUUID.isEmpty {
                            Text("\(state.targetName.isEmpty ? "Saved display" : state.targetName) (disconnected)")
                                .tag(state.targetUUID)
                        }
                    }
                    Toggle("Lock the Dock to this display", isOn: $state.enabled)
                    Toggle("Keep hot corners working on other displays", isOn: $state.allowHotCorners)
                        .help("Leaves the corners of blocked edges reachable. Pushing hard into a corner may occasionally move the Dock.")

                    if !state.targetConnected && !state.targetUUID.isEmpty {
                        Text("That display is disconnected. The Dock is kept on the main display until it's reconnected, then it moves back automatically.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Text("Dock is currently on: \(state.currentDockName)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Move Dock Now") { state.moveNow() }
                            .disabled(!state.hasAccessibility)
                    }
                }
                .padding(4)
            }

            GroupBox("Background") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show icon in Dock", isOn: $state.showInDock)
                    Toggle("Show icon in menu bar", isOn: $state.showInMenuBar)
                    Toggle("Launch at login", isOn: Binding(
                        get: { state.launchAtLogin },
                        set: { state.setLaunchAtLogin($0) }
                    ))
                    if let msg = state.loginMessage {
                        Text(msg).font(.caption).foregroundStyle(.orange)
                    }
                    if !state.showInDock && !state.showInMenuBar {
                        Label("StickyDock will be invisible while it runs. To get back here, open StickyDock again from Applications or Spotlight.",
                              systemImage: "eye.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("StickyDock keeps running after you close this window. To bring it back, open StickyDock again (Finder, Spotlight, or Launchpad).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack(spacing: 12) {
                Text("v\(AppState.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("GitHub", destination: AppState.repoURL)
                    .font(.caption)
                Button(copiedDebugInfo ? "Copied!" : "Copy Debug Info") {
                    state.copyDebugInfo()
                    copiedDebugInfo = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedDebugInfo = false }
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Copies your setup details to paste into a GitHub issue.")
                Spacer()
                Button("Close Window") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Quit StickyDock") { NSApp.terminate(nil) }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func label(for d: DisplayInfo) -> String {
        let size = "\(Int(d.bounds.width))×\(Int(d.bounds.height))"
        return d.isMain ? "\(d.name) — \(size) (main)" : "\(d.name) — \(size)"
    }
}
