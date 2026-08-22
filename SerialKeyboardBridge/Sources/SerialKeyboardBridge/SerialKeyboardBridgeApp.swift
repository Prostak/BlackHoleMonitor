import SwiftUI

@main
struct SerialKeyboardBridgeApp: App {
    @StateObject private var model = BridgeModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
