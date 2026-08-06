import SwiftUI

@main
struct BlackHoleMonitorApp: App {
    @StateObject private var monitor = AudioLevelMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor)
                .frame(minWidth: 520, minHeight: 360)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
