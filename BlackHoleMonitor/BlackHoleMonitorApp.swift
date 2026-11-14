import AppKit
import SwiftUI

@main
struct BlackHoleMonitorApp: App {
    @StateObject private var monitor = AudioLevelMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor)
                .frame(minWidth: 560, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(replacing: .appInfo) {
                Button("About Bhm_12") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Bhm_12",
                        .applicationVersion: "1.0",
                    ])
                }
            }

            CommandGroup(after: .appInfo) {
                Button("Settings…") {
                    monitor.openSystemSettings()
                }
                .keyboardShortcut(",")
            }

            CommandGroup(replacing: .appVisibility) {
                Button("Hide Bhm_12") {
                    NSApplication.shared.hide(nil)
                }
                .keyboardShortcut("h")

                Button("Hide Others") {
                    NSApplication.shared.hideOtherApplications(nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .option])

                Button("Show All") {
                    NSApplication.shared.unhideAllApplications(nil)
                }
            }

            CommandGroup(replacing: .appTermination) {
                Button("Quit Bhm_12") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }

            CommandGroup(replacing: .sidebar) {}

            CommandGroup(replacing: .toolbar) {}

            CommandMenu("Window") {
                Button("Minimize") {
                    NSApplication.shared.keyWindow?.miniaturize(nil)
                }
                .keyboardShortcut("m")

                Button("Zoom") {
                    NSApplication.shared.keyWindow?.zoom(nil)
                }

                Divider()

                Button("Bring All to Front") {
                    NSApplication.shared.arrangeInFront(nil)
                }
            }

            CommandMenu("Help") {
                Button("Bhm_12 Help") {
                    if let url = URL(string: "https://existential.audio/blackhole/") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
