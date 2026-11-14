import Foundation

/// `Task.sleep(for:)` / `Duration` need macOS 13+; this works on macOS 12.
enum CompatSleep {
    static func seconds(_ value: Double) async {
        let clamped = max(0, value)
        let nanoseconds = UInt64(clamped * 1_000_000_000.0)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
