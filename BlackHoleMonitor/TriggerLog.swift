import Foundation

enum TriggerLogReason: String {
    case sound = "sound"
    case ping = "ping"
    case castWait = "cast-wait"
}

enum TriggerLog {
    private static let fileName = "trigger.log"

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("BlackHoleMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static func reset() {
        let url = fileURL
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    static func write(reason: TriggerLogReason) {
        let stamp = timestampFormatter.string(from: Date())
        let line = "\(stamp)\t\(reason.rawValue)\n"
        let url = fileURL

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
