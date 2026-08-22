import AppKit
import Combine
import Foundation

@MainActor
final class BridgeModel: ObservableObject {
    @Published var serialPath = "/dev/cu.usbserial-0001"
    @Published var isConnected = false
    @Published var keyboardMonitorRunning = false
    @Published var logLines: [String] = []

    private let serial = SerialPort()
    private let keyboard = KeyboardMonitor()

    func connect() {
        disconnect()

        do {
            serial.onReceive = { [weak self] data in
                Task { @MainActor in
                    self?.appendSerialReceive(data)
                }
            }
            try serial.open(path: serialPath)
            isConnected = true
            append("Connected to \(serialPath) @ 115200")
        } catch {
            append("Connect failed: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        serial.onReceive = nil
        serial.close()
        isConnected = false
    }

    func startKeyboardMonitor() {
        keyboard.onKeyDown = { [weak self] character, keyCode in
            Task { @MainActor in
                self?.appendKeyboard(character, keyCode: keyCode)
            }
        }
        keyboard.onBacktick = { [weak self] in
            Task { @MainActor in
                self?.sendBacktick()
            }
        }

        if keyboard.start() {
            keyboardMonitorRunning = true
            append("Keyboard monitor started")
        } else {
            keyboardMonitorRunning = false
            append("Keyboard monitor failed — grant Input Monitoring in System Settings")
        }
    }

    func stopKeyboardMonitor() {
        keyboard.stop()
        keyboardMonitorRunning = false
        append("Keyboard monitor stopped")
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func sendBacktick() {
        sendToSerial("`")
    }

    private func sendToSerial(_ text: String) {
        guard isConnected else {
            append("Serial not connected — skipped send `\(text)`")
            return
        }

        guard let data = text.data(using: .utf8) else { return }

        do {
            try serial.write(data)
            append("→ serial: `\(text)` (\(data.count) byte\(data.count == 1 ? "" : "s"))")
        } catch {
            append("Send failed: \(error.localizedDescription)")
        }
    }

    private func appendKeyboard(_ character: String, keyCode: UInt16) {
        let visible = character
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\t", with: "⇥")
        append("⌨ keyCode \(keyCode): `\(visible)`")
    }

    private func appendSerialReceive(_ data: Data) {
        let text = String(data: data, encoding: .utf8) ?? data.map { String(format: "%02X", $0) }.joined(separator: " ")
        append("← serial: `\(text)`")
    }

    private func append(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        logLines.append("[\(stamp)] \(line)")
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
