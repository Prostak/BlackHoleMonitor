import SwiftUI

struct ContentView: View {
    @ObservedObject var model: BridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Serial Keyboard Bridge")
                .font(.title2.weight(.semibold))

            HStack {
                Text("Port")
                    .frame(width: 40, alignment: .leading)
                TextField("/dev/cu.usbserial-0001", text: $model.serialPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isConnected)

                Button(model.isConnected ? "Disconnect" : "Connect") {
                    if model.isConnected {
                        model.disconnect()
                    } else {
                        model.connect()
                    }
                }
            }

            HStack {
                Button(model.keyboardMonitorRunning ? "Stop Keyboard Monitor" : "Start Keyboard Monitor") {
                    if model.keyboardMonitorRunning {
                        model.stopKeyboardMonitor()
                    } else {
                        model.startKeyboardMonitor()
                    }
                }

                Button("Input Monitoring Settings…") {
                    model.openInputMonitoringSettings()
                }

                Spacer()

                Button("Send `") {
                    model.sendBacktick()
                }
                .disabled(!model.isConnected)
            }

            Text("Log")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.logLines.count) { count in
                    guard count > 0 else { return }
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
            .frame(maxHeight: .infinity)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
        .onDisappear {
            model.stopKeyboardMonitor()
            model.disconnect()
        }
    }
}
