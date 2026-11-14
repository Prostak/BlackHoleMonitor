import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AutobattleAppearance: String {
    case absent
    case red
    case gray
    case noWindow
}

enum AutobattleCaptureSource: String, CaseIterable, Identifiable {
    case camera
    case screenSharing

    var id: String { rawValue }

    var label: String {
        switch self {
        case .camera: return "Elgato camera"
        case .screenSharing: return "Screen Sharing"
        }
    }
}

struct AutobattleSampleStats {
    var yellowRatio: Double = 0
    var redRatio: Double = 0
    var grayRatio: Double = 0
    var brightGoldRatio: Double = 0
    var maxMaroonRow: Double = 0
    var maxGrayRow: Double = 0
    var recognizedText: String = ""
    var ocrConfidence: Float = 0
    var roi: CGRect = .null
    var windowSize: CGSize = .zero
    var appearance: AutobattleAppearance = .absent
    /// True when sampling the locked button crop instead of the wide search strip.
    var usingLockedROI: Bool = false
    /// "TM" template match, "fill" while locked, or empty.
    var detectMethod: String = ""

    var summary: String {
        let text = recognizedText.isEmpty ? "—" : recognizedText
        let mode = usingLockedROI ? "locked" : "search"
        let method = detectMethod.isEmpty ? "—" : detectMethod
        return String(
            format: "%@ · %@ · %@ \"%@\" (%.2f) · Y %.0f%% R %.0f%% G %.0f%% · ROI (%.0f,%.0f %.0f×%.0f)",
            appearance.rawValue,
            mode,
            method,
            text,
            ocrConfidence,
            yellowRatio * 100,
            redRatio * 100,
            grayRatio * 100,
            roi.origin.x, roi.origin.y, roi.width, roi.height
        )
    }
}

struct AutobattleFrameSample {
    let stats: AutobattleSampleStats
    let image: CGImage?
}

struct AutobattleDebugSnapshot {
    let savedURLs: [URL]
    let stats: AutobattleSampleStats
    let message: String
}

enum AutobattleDetector {
    static let ownerBundleID = "com.apple.ScreenSharing"
    private static let captureSourceKey = "autobattleCaptureSource"

    /// Default: Elgato / USB capture camera (not Screen Sharing window).
    static var captureSource: AutobattleCaptureSource {
        get {
            if let raw = UserDefaults.standard.string(forKey: captureSourceKey),
               let value = AutobattleCaptureSource(rawValue: raw) {
                return value
            }
            return .camera
        }
        set {
            let previousRaw = UserDefaults.standard.string(forKey: captureSourceKey)
            let previous = previousRaw.flatMap(AutobattleCaptureSource.init(rawValue:)) ?? .camera
            UserDefaults.standard.set(newValue.rawValue, forKey: captureSourceKey)
            guard previous != newValue else { return }
            resetButtonLock()
            invalidateTextTemplateCache()
            if newValue == .camera {
                _ = prepareCameraCapture()
            } else {
                AutobattleCameraCapture.shared.stop()
            }
        }
    }

    static var missingSourceMessage: String {
        switch captureSource {
        case .camera:
            if let err = AutobattleCameraCapture.shared.lastError, !err.isEmpty {
                return "camera unavailable · \(err)"
            }
            return "camera unavailable (Elgato)"
        case .screenSharing:
            return "Screen Sharing window not found"
        }
    }

    /// Bottom-center strip for Autobattle text template match (until first lock) — Screen Sharing.
    static let roiXStart = 0.40
    static let roiXEnd = 0.60
    static let roiYStart = 0.84
    static let roiYEnd = 0.93

    /// Calibrated Elgato Autobattle button on 1920×1080 (GIMP: 962,986–1051,1003).
    static let cameraButtonNormRect = CGRect(
        x: 0.50104167,
        y: 0.91296296,
        width: 0.04687500,
        height: 0.01666667
    )
    /// Extra search margin around the calibrated button (camera only).
    static let cameraSearchPadX: CGFloat = 0.04
    static let cameraSearchPadY: CGFloat = 0.025

    /// Padding around TM text for the locked crop (keep small — exclude wood/background).
    static let lockPadX: CGFloat = 0.28
    static let lockPadY: CGFloat = 1.35
    static let lockMinWidthFraction: CGFloat = 0.065
    static let lockMinHeightFraction: CGFloat = 0.026

    /// Pad around TM text for fill — enough for maroon body, not outer wood.
    static let fillBodyPadX: CGFloat = 0.20
    static let fillBodyPadY: CGFloat = 1.6

    /// TM_CCOEFF_NORMED hard hit. Live Elgato button during battle is ~0.92–0.99.
    static let defaultTemplateMatchConfidence: Double = 0.90
    /// Locked near-miss → keep button via fill (must stay ≤ hard).
    static let defaultTemplateSoftMatchConfidence: Double = 0.85
    private static let hardTMKey = "autobattleTemplateHardTM"
    private static let softTMKey = "autobattleTemplateSoftTM"
    private static let tmDefaultsVersionKey = "autobattleTMDefaultsVersion"
    private static let tmDefaultsVersion = 4

    static var templateMatchConfidence: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: hardTMKey) as? Double
            return min(max(stored ?? defaultTemplateMatchConfidence, 0.50), 0.95)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 0.50), 0.95), forKey: hardTMKey)
        }
    }

    static var templateSoftMatchConfidence: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: softTMKey) as? Double
            let soft = min(max(stored ?? defaultTemplateSoftMatchConfidence, 0.40), 0.90)
            return min(soft, templateMatchConfidence)
        }
        set {
            let clamped = min(max(newValue, 0.40), 0.90)
            UserDefaults.standard.set(clamped, forKey: softTMKey)
        }
    }

    /// Apply new TM defaults once when the app ships a retune (keeps hard=0.90 soft=0.85).
    static func migrateTMDefaultsIfNeeded() {
        let current = UserDefaults.standard.integer(forKey: tmDefaultsVersionKey)
        guard current < tmDefaultsVersion else { return }
        templateMatchConfidence = defaultTemplateMatchConfidence
        templateSoftMatchConfidence = defaultTemplateSoftMatchConfidence
        UserDefaults.standard.set(tmDefaultsVersion, forKey: tmDefaultsVersionKey)
    }

    static let templateScales: [CGFloat] = [0.85, 0.90, 0.95, 1.0, 1.05, 1.10, 1.15]

    static let lastTriggerPrefix = "last-trigger"
    static let debugPrefix = "debug"
    /// Last N triple-beep (battle-end) events for false-positive review.
    static let tripleBeepHistoryFolderName = "triple-beeps"
    static let tripleBeepHistoryLimit = 10
    static let bundledTemplateName = "AutobattleTextTemplate"
    static let bundledElgatoTemplateName = "AutobattleTextTemplateElgato"

    struct HistoryFrame {
        let image: CGImage
        let stats: AutobattleSampleStats
        let note: String
        let date: Date
    }

    /// Active TM template resource name for the current capture source.
    static var activeTemplateResourceName: String {
        captureSource == .camera ? bundledElgatoTemplateName : bundledTemplateName
    }

    /// Locked button rect in window-normalized coords (origin top-left).
    /// Cleared only via Clear Lock (or Stop/Start in controller if wired).
    private struct ButtonLock {
        var normRect: CGRect
        var windowWidth: Int
        var windowHeight: Int
    }

    private struct GrayImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private struct TemplateHit {
        let score: Double
        /// Top-left pixel rect of the matched template inside the search crop.
        let rectInCrop: CGRect
    }

    private static var buttonLock: ButtonLock?
    private static let lockQueue = DispatchQueue(label: "com.local.Bhm12.autobattle.lock")
    /// Bundled grayscale text template (loaded once per source).
    private static var textTemplate: GrayImage?
    private static var templateLoadAttempted = false
    private static var loadedTemplateResourceName: String?

    static func resetButtonLock() {
        lockQueue.sync { buttonLock = nil }
        // Camera: re-seed the calibrated button rect on next sample.
    }

    /// Install the GIMP-calibrated Autobattle rect (camera only).
    static func installCameraButtonLock(imageWidth: Int, imageHeight: Int) {
        installLock(
            normRect: cameraButtonNormRect,
            windowWidth: imageWidth,
            windowHeight: imageHeight
        )
    }

    static func invalidateTextTemplateCache() {
        textTemplate = nil
        templateLoadAttempted = false
        loadedTemplateResourceName = nil
    }

    static func activeTemplateURL() -> URL? {
        Bundle.main.url(forResource: activeTemplateResourceName, withExtension: "png")
    }

    static func activeTemplateNSImage() -> NSImage? {
        guard let url = activeTemplateURL() else { return nil }
        return NSImage(contentsOf: url)
    }

    static func lastTriggerROIPreviewURL() -> URL? {
        let url = debugFolderURL().appendingPathComponent("\(lastTriggerPrefix)-roi.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Short TM label for the Last A preview (e.g. "TM 0.86").
    static func lastTriggerScoreLabel() -> String? {
        readScoreLabel(named: "\(lastTriggerPrefix)-score.txt")
    }

    /// Short TM label for the last triple-beep preview (e.g. "miss 0.71→0.68").
    static func lastTripleBeepScoreLabel() -> String? {
        readScoreLabel(named: "last-triple-beep-score.txt")
    }

    private static func readScoreLabel(named fileName: String) -> String? {
        let url = debugFolderURL().appendingPathComponent(fileName)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    private static func writeScoreLabel(named fileName: String, text: String) {
        let folder = debugFolderURL()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func lastTripleBeepROIPreviewURL() -> URL? {
        guard let newest = newestTripleBeepEventFolder(),
              let files = try? FileManager.default.contentsOfDirectory(at: newest, includingPropertiesForKeys: nil) else {
            return nil
        }
        if let end = files.first(where: { $0.lastPathComponent.contains("BATTLE_END") && $0.pathExtension == "png" }) {
            return end
        }
        return files
            .filter { $0.lastPathComponent.hasSuffix("-roi.png") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

    private static func newestTripleBeepEventFolder() -> URL? {
        let root = tripleBeepHistoryFolderURL()
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return dirs.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        .first
    }

    static var hasButtonLock: Bool {
        lockQueue.sync { buttonLock != nil }
    }

    static func sample() -> AutobattleAppearance {
        sampleFrame().stats.appearance
    }

    static func sampleDetailed() -> AutobattleSampleStats {
        sampleFrame().stats
    }

    @discardableResult
    static func prepareCameraCapture() -> Bool {
        AutobattleCameraCapture.shared.start()
    }

    static func shutdownCaptureSource() {
        AutobattleCameraCapture.shared.stop()
    }

    static func sampleFrame() -> AutobattleFrameSample {
        guard let image = captureSourceImage() else {
            return AutobattleFrameSample(stats: AutobattleSampleStats(appearance: .noWindow), image: nil)
        }

        // Camera: always watch the calibrated button rect (no wood / yellow chrome).
        if captureSource == .camera, !hasButtonLock {
            installCameraButtonLock(imageWidth: image.width, imageHeight: image.height)
        }

        // Crop lock from the same full image used for search.
        if let lock = currentLockMatching(windowPixelSize: CGSize(width: image.width, height: image.height)),
           let lockedImage = cropNorm(image, normRect: lock.normRect) {
            let stats = classifyLocked(
                image: lockedImage,
                normRect: lock.normRect,
                windowPixelSize: CGSize(width: image.width, height: image.height)
            )
            return AutobattleFrameSample(stats: stats, image: lockedImage)
        }

        return AutobattleFrameSample(stats: classifySearch(image: image), image: image)
    }

    private static func captureSourceImage() -> CGImage? {
        switch captureSource {
        case .camera:
            // Never start AVCaptureSession here — tick runs off the main thread and
            // racing startRunning() aborts (see crash in AutobattleCameraCapture.start).
            // AudioLevelMonitor.requestCameraAndStartCapture owns session lifetime.
            return AutobattleCameraCapture.shared.latestFrame(maxAge: 5)
        case .screenSharing:
            guard let window = findScreenSharingWindow() else { return nil }
            return captureFullWindow(window.id)
        }
    }

    static func captureDebugSnapshot() -> AutobattleDebugSnapshot {
        // Always grab the true full source frame for calibration (not only the locked crop).
        guard let full = captureSourceImage() else {
            return AutobattleDebugSnapshot(
                savedURLs: [],
                stats: AutobattleSampleStats(appearance: .noWindow),
                message: "No frame · \(missingSourceMessage)"
            )
        }
        let frame = sampleFrame()
        var stats = frame.stats
        if stats.windowSize == .zero {
            stats.windowSize = CGSize(width: full.width, height: full.height)
        }
        return overwriteSnapshot(image: full, stats: stats, prefix: debugPrefix)
    }

    @discardableResult
    static func saveLastTrigger(image: CGImage, stats: AutobattleSampleStats) -> AutobattleDebugSnapshot {
        let snap = overwriteSnapshot(image: image, stats: stats, prefix: lastTriggerPrefix)
        writeScoreLabel(
            named: "\(lastTriggerPrefix)-score.txt",
            text: String(format: "TM %.2f", Double(stats.ocrConfidence))
        )
        return snap
    }

    static func saveLastTripleBeepScoreLabel(missScores: [Double]) {
        guard !missScores.isEmpty else { return }
        let joined = missScores.map { String(format: "%.2f", $0) }.joined(separator: "→")
        writeScoreLabel(named: "last-triple-beep-score.txt", text: "miss \(joined)")
    }

    /// Saves one triple-beep event folder (leading polls + end frame). Keeps last `tripleBeepHistoryLimit`.
    @discardableResult
    static func saveTripleBeepEvent(frames: [HistoryFrame]) -> URL? {
        guard !frames.isEmpty else { return nil }
        let root = tripleBeepHistoryFolderURL()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let eventFolder = root.appendingPathComponent(stamp, isDirectory: true)
        do {
            try fm.createDirectory(at: eventFolder, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        var indexLines: [String] = ["triple-beep event · \(frames.count) frames"]
        for (i, frame) in frames.enumerated() {
            let seq = String(format: "%02d", i)
            let appearance = frame.stats.appearance.rawValue
            let tag = frame.note.isEmpty ? appearance : "\(appearance)-\(frame.note)"
            let base = "\(seq)-\(tag)"

            let localROI: CGRect
            if frame.stats.usingLockedROI
                || frame.stats.roi.isNull
                || frame.stats.roi.maxX > CGFloat(frame.image.width) + 1
                || frame.stats.roi.maxY > CGFloat(frame.image.height) + 1 {
                localROI = CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height)
            } else {
                localROI = frame.stats.roi.integral
            }

            if let roiImage = frame.image.cropping(to: localROI) {
                _ = savePNG(roiImage, to: eventFolder.appendingPathComponent("\(base)-roi.png"))
            } else {
                _ = savePNG(frame.image, to: eventFolder.appendingPathComponent("\(base)-full.png"))
            }

            var body = frame.stats.summary
            if !frame.note.isEmpty {
                body += "\nnote: \(frame.note)"
            }
            body += "\n\(ISO8601DateFormatter().string(from: frame.date))\n"
            let statsURL = eventFolder.appendingPathComponent("\(base)-stats.txt")
            try? body.write(to: statsURL, atomically: true, encoding: .utf8)
            indexLines.append("\(base) · \(frame.stats.summary)")
        }

        let indexURL = eventFolder.appendingPathComponent("index.txt")
        try? (indexLines.joined(separator: "\n") + "\n").write(to: indexURL, atomically: true, encoding: .utf8)

        pruneTripleBeepHistory(keeping: tripleBeepHistoryLimit)
        return eventFolder
    }

    private static func tripleBeepHistoryFolderURL() -> URL {
        debugFolderURL().appendingPathComponent(tripleBeepHistoryFolderName, isDirectory: true)
    }

    private static func pruneTripleBeepHistory(keeping limit: Int) {
        let root = tripleBeepHistoryFolderURL()
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let eventDirs = dirs.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }

        guard eventDirs.count > limit else { return }
        for stale in eventDirs.dropFirst(limit) {
            try? fm.removeItem(at: stale)
        }
    }

    private static func overwriteSnapshot(
        image: CGImage,
        stats: AutobattleSampleStats,
        prefix: String
    ) -> AutobattleDebugSnapshot {
        let folder = debugFolderURL()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return AutobattleDebugSnapshot(
                savedURLs: [],
                stats: stats,
                message: "Could not create debug folder: \(error.localizedDescription)"
            )
        }

        var urls: [URL] = []
        let fullURL = folder.appendingPathComponent("\(prefix)-full.png")
        if savePNG(image, to: fullURL) {
            urls.append(fullURL)
        }

        // Locked frames pass the button crop only — stats.roi is still window-absolute.
        let localROI: CGRect
        if stats.usingLockedROI
            || stats.roi.isNull
            || stats.roi.maxX > CGFloat(image.width) + 1
            || stats.roi.maxY > CGFloat(image.height) + 1 {
            localROI = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        } else {
            localROI = stats.roi.integral
        }

        if let roiImage = image.cropping(to: localROI) {
            let roiURL = folder.appendingPathComponent("\(prefix)-roi.png")
            if savePNG(roiImage, to: roiURL) {
                urls.append(roiURL)
            }
        }

        if !stats.usingLockedROI, !stats.roi.isNull,
           let marked = drawROIOutline(on: image, roi: stats.roi) {
            let markedURL = folder.appendingPathComponent("\(prefix)-marked.png")
            if savePNG(marked, to: markedURL) {
                urls.append(markedURL)
            }
        }

        let statsURL = folder.appendingPathComponent("\(prefix)-stats.txt")
        let stamped = "\(stats.summary)\n\(ISO8601DateFormatter().string(from: Date()))\n"
        try? stamped.write(to: statsURL, atomically: true, encoding: .utf8)
        urls.append(statsURL)

        let message: String
        if urls.isEmpty {
            message = "Snapshot write failed"
        } else {
            message = "Updated \(prefix)-* → \(folder.path) · \(stats.summary)"
        }
        return AutobattleDebugSnapshot(savedURLs: urls, stats: stats, message: message)
    }

    private struct ScreenSharingWindow {
        let id: CGWindowID
        /// Quartz screen bounds (origin bottom-left).
        let screenBounds: CGRect
        let pixelSize: CGSize
    }

    static func findScreenSharingWindowID() -> CGWindowID? {
        findScreenSharingWindow()?.id
    }

    private static func findScreenSharingWindow() -> ScreenSharingWindow? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else {
            return nil
        }

        var best: (ScreenSharingWindow, Int)?

        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = info[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }

            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t
            let isScreenSharing: Bool = {
                if ownerName == "Screen Sharing" { return true }
                guard let ownerPID,
                      let app = NSRunningApplication(processIdentifier: ownerPID) else {
                    return false
                }
                return app.bundleIdentifier == ownerBundleID
            }()
            guard isScreenSharing else { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 400, bounds.height >= 300 else {
                continue
            }

            let area = Int(bounds.width * bounds.height)
            let window = ScreenSharingWindow(
                id: number,
                screenBounds: bounds,
                pixelSize: CGSize(width: bounds.width, height: bounds.height)
            )
            if best == nil || area > best!.1 {
                best = (window, area)
            }
        }

        return best?.0
    }

    private static func captureFullWindow(_ windowID: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .bestResolution]
        )
    }

    private static func cropNorm(_ image: CGImage, normRect: CGRect) -> CGImage? {
        let rect = CGRect(
            x: normRect.minX * CGFloat(image.width),
            y: normRect.minY * CGFloat(image.height),
            width: normRect.width * CGFloat(image.width),
            height: normRect.height * CGFloat(image.height)
        ).integral
        guard rect.width >= 4, rect.height >= 4,
              rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= CGFloat(image.width) + 1,
              rect.maxY <= CGFloat(image.height) + 1 else { return nil }
        return image.cropping(to: rect)
    }

    private static func currentLockMatching(windowPixelSize: CGSize) -> ButtonLock? {
        lockQueue.sync {
            guard let lock = buttonLock else { return nil }
            let w = Int(windowPixelSize.width.rounded())
            let h = Int(windowPixelSize.height.rounded())
            // Size mismatch: skip locked path this frame, but keep the lock for Clear Lock only.
            if abs(lock.windowWidth - w) > 2 || abs(lock.windowHeight - h) > 2 {
                return nil
            }
            return lock
        }
    }

    private static func installLock(normRect: CGRect, windowWidth: Int, windowHeight: Int) {
        let clamped = CGRect(
            x: max(0, min(1, normRect.minX)),
            y: max(0, min(1, normRect.minY)),
            width: max(0.01, min(1 - max(0, normRect.minX), normRect.width)),
            height: max(0.01, min(1 - max(0, normRect.minY), normRect.height))
        )
        lockQueue.sync {
            buttonLock = ButtonLock(
                normRect: clamped,
                windowWidth: windowWidth,
                windowHeight: windowHeight
            )
        }
    }

    /// Wide-strip search via template match only (no OCR — idle frames stay cheap).
    private static func classifySearch(image: CGImage) -> AutobattleSampleStats {
        let width = image.width
        let height = image.height
        var stats = AutobattleSampleStats(
            windowSize: CGSize(width: width, height: height),
            appearance: .absent,
            usingLockedROI: false
        )
        guard width > 16, height > 16 else { return stats }

        let band = searchBandNorm()
        let x0 = max(0, Int(Double(width) * band.x0))
        let x1 = min(width, Int(Double(width) * band.x1))
        let y0 = max(0, Int(Double(height) * band.y0))
        let y1 = min(height, Int(Double(height) * band.y1))
        let roiWidth = x1 - x0
        let roiHeight = y1 - y0
        guard roiWidth > 4, roiHeight > 4 else { return stats }

        let roi = CGRect(x: x0, y: y0, width: roiWidth, height: roiHeight)
        stats.roi = roi

        guard let cropped = image.cropping(to: roi.integral) else { return stats }

        guard let tm = matchTextTemplate(in: cropped) else {
            stats.appearance = .absent
            stats.detectMethod = "TM"
            // Best score below threshold (surfaced for Debug snap status).
            if let best = bestTemplateScore(in: cropped) {
                stats.ocrConfidence = Float(best)
                stats.recognizedText = String(format: "miss %.2f", best)
            }
            return stats
        }

        stats.detectMethod = "TM"
        stats.recognizedText = "Autobattle"
        stats.ocrConfidence = Float(tm.score)

        // Camera: lock the calibrated button rect, not a padded TM box (avoids yellow chrome).
        if captureSource == .camera {
            installLock(
                normRect: cameraButtonNormRect,
                windowWidth: width,
                windowHeight: height
            )
            let buttonPixel = CGRect(
                x: cameraButtonNormRect.minX * CGFloat(width),
                y: cameraButtonNormRect.minY * CGFloat(height),
                width: cameraButtonNormRect.width * CGFloat(width),
                height: cameraButtonNormRect.height * CGFloat(height)
            ).integral
            stats.roi = buttonPixel
            if let buttonCrop = image.cropping(to: buttonPixel) {
                let inset = CGRect(x: 1, y: 1, width: max(1, buttonCrop.width - 2), height: max(1, buttonCrop.height - 2))
                applyFillAndAppearance(stats: &stats, image: buttonCrop, sampleRect: inset, requireText: true)
                stats.usingLockedROI = true
                stats.detectMethod = "TM+fill"
            }
            return stats
        }

        return finishSearchHit(
            stats: &stats,
            cropped: cropped,
            windowWidth: width,
            windowHeight: height,
            cropOrigin: CGPoint(x: x0, y: y0),
            textRectInCrop: tm.rectInCrop,
            requireText: true
        )
    }

    private static func searchBandNorm() -> (x0: Double, x1: Double, y0: Double, y1: Double) {
        switch captureSource {
        case .camera:
            let b = cameraButtonNormRect
            return (
                max(0, Double(b.minX - cameraSearchPadX)),
                min(1, Double(b.maxX + cameraSearchPadX)),
                max(0, Double(b.minY - cameraSearchPadY)),
                min(1, Double(b.maxY + cameraSearchPadY))
            )
        case .screenSharing:
            return (roiXStart, roiXEnd, roiYStart, roiYEnd)
        }
    }

    private static func finishSearchHit(
        stats: inout AutobattleSampleStats,
        cropped: CGImage,
        windowWidth: Int,
        windowHeight: Int,
        cropOrigin: CGPoint,
        textRectInCrop: CGRect,
        requireText: Bool
    ) -> AutobattleSampleStats {
        let padX = textRectInCrop.width * lockPadX
        let padY = textRectInCrop.height * lockPadY
        var buttonInCrop = CGRect(
            x: textRectInCrop.minX - padX,
            y: textRectInCrop.minY - padY,
            width: textRectInCrop.width + 2 * padX,
            height: textRectInCrop.height + 2 * padY
        )
        var buttonInWindow = CGRect(
            x: cropOrigin.x + buttonInCrop.minX,
            y: cropOrigin.y + buttonInCrop.minY,
            width: buttonInCrop.width,
            height: buttonInCrop.height
        )

        let minW = CGFloat(windowWidth) * lockMinWidthFraction
        let minH = CGFloat(windowHeight) * lockMinHeightFraction
        if buttonInWindow.width < minW || buttonInWindow.height < minH {
            let cx = buttonInWindow.midX
            let cy = buttonInWindow.midY
            let newW = max(buttonInWindow.width, minW)
            let newH = max(buttonInWindow.height, minH)
            buttonInWindow = CGRect(x: cx - newW / 2, y: cy - newH / 2, width: newW, height: newH)
                .intersection(CGRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
            buttonInCrop = CGRect(
                x: buttonInWindow.minX - cropOrigin.x,
                y: buttonInWindow.minY - cropOrigin.y,
                width: buttonInWindow.width,
                height: buttonInWindow.height
            )
        }

        let norm = CGRect(
            x: buttonInWindow.minX / CGFloat(windowWidth),
            y: buttonInWindow.minY / CGFloat(windowHeight),
            width: buttonInWindow.width / CGFloat(windowWidth),
            height: buttonInWindow.height / CGFloat(windowHeight)
        )
        installLock(normRect: norm, windowWidth: windowWidth, windowHeight: windowHeight)
        stats.roi = buttonInWindow.integral

        let body = buttonBodyRect(around: textRectInCrop, imageWidth: cropped.width, imageHeight: cropped.height)
        applyFillAndAppearance(stats: &stats, image: cropped, sampleRect: body, requireText: requireText)
        return stats
    }

    /// Rect around TM text for fill only — button face, not outer bronze / wood.
    private static func buttonBodyRect(around text: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let padX = max(2, text.width * fillBodyPadX)
        let padY = max(2, text.height * fillBodyPadY)
        let rect = CGRect(
            x: text.minX - padX,
            y: text.minY - padY,
            width: text.width + 2 * padX,
            height: text.height + 2 * padY
        )
        return rect.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)).integral
    }

    /// Locked crop: TM must still see Autobattle text; fill only chooses red vs gray.
    /// Color alone never authorizes a hit (avoids FP after a stale lock).
    private static func classifyLocked(
        image: CGImage,
        normRect: CGRect,
        windowPixelSize: CGSize
    ) -> AutobattleSampleStats {
        let width = image.width
        let height = image.height
        var stats = AutobattleSampleStats(
            windowSize: windowPixelSize,
            appearance: .absent,
            usingLockedROI: true,
            detectMethod: "TM"
        )
        guard width > 4, height > 4 else { return stats }

        stats.roi = CGRect(
            x: normRect.minX * windowPixelSize.width,
            y: normRect.minY * windowPixelSize.height,
            width: normRect.width * windowPixelSize.width,
            height: normRect.height * windowPixelSize.height
        ).integral

        if let tm = matchTextTemplate(in: image) {
            stats.recognizedText = "Autobattle"
            stats.ocrConfidence = Float(tm.score)
            stats.detectMethod = "TM+fill"
        } else {
            let best = bestTemplateScore(in: image)
            if let best, best >= templateSoftMatchConfidence {
                // Near-miss while locked: keep button present, classify by fill (avoids false battle-end).
                stats.recognizedText = "Autobattle~"
                stats.ocrConfidence = Float(best)
                stats.detectMethod = "TM~fill"
            } else {
                if let best {
                    stats.ocrConfidence = Float(best)
                    stats.recognizedText = String(format: "miss %.2f", best)
                }
                stats.detectMethod = "TM"
                // True miss / UI changed — ignore maroon/gray noise on hotbar etc.
                return stats
            }
        }

        // Locked crop is already the button — sample almost the whole frame (body pad was undersampling).
        let inset = CGRect(x: 1, y: 1, width: max(1, width - 2), height: max(1, height - 2))
        applyFillAndAppearance(stats: &stats, image: image, sampleRect: inset, requireText: true)
        return stats
    }

    private static func applyFillAndAppearance(
        stats: inout AutobattleSampleStats,
        image: CGImage,
        sampleRect: CGRect,
        requireText: Bool
    ) {
        let fill = sampleButtonFill(in: image, rect: sampleRect)
        stats.redRatio = fill.maroonRatio
        stats.grayRatio = fill.grayRatio
        stats.yellowRatio = fill.goldRatio
        stats.brightGoldRatio = fill.goldRatio
        stats.maxMaroonRow = fill.maroonRatio
        stats.maxGrayRow = fill.grayRatio

        // Active: warm gold/beige letters (and usually maroon body). Disabled: gray letters, no gold.
        // Gold threshold is low — live letters are often ~150,110,70 (not bright yellow).
        // Maroon backup: TM already confirmed the word; maroon>gray separates red vs gray button.
        if fill.goldRatio >= 0.008 {
            stats.appearance = .red
        } else if fill.maroonRatio >= 0.20 && fill.maroonRatio >= fill.grayRatio * 0.85 {
            stats.appearance = .red
        } else if requireText || fill.grayRatio >= 0.08 {
            stats.appearance = .gray
        } else {
            stats.appearance = .absent
        }
    }

    // MARK: - Template match (Two_Helmets-style)

    private static func ensureTextTemplate() -> GrayImage? {
        let name = activeTemplateResourceName
        if let textTemplate, loadedTemplateResourceName == name {
            return textTemplate
        }
        if templateLoadAttempted, loadedTemplateResourceName == name {
            return textTemplate
        }
        templateLoadAttempted = true
        loadedTemplateResourceName = name
        textTemplate = nil
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let cg = loadCGImage(url),
           let gray = toGray(cg),
           gray.width >= 8, gray.height >= 4 {
            textTemplate = gray
            return gray
        }
        // Camera template missing — fall back to Screen Sharing template.
        if name != bundledTemplateName,
           let url = Bundle.main.url(forResource: bundledTemplateName, withExtension: "png"),
           let cg = loadCGImage(url),
           let gray = toGray(cg),
           gray.width >= 8, gray.height >= 4 {
            textTemplate = gray
            return gray
        }
        return nil
    }

    private static func matchTextTemplate(in crop: CGImage) -> TemplateHit? {
        guard let (bestScore, bestRect) = bestTemplateMatch(in: crop) else { return nil }
        guard bestScore >= templateMatchConfidence, !bestRect.isNull else { return nil }
        return TemplateHit(score: bestScore, rectInCrop: bestRect)
    }

    private static func bestTemplateScore(in crop: CGImage) -> Double? {
        bestTemplateMatch(in: crop)?.score
    }

    private static func bestTemplateMatch(in crop: CGImage) -> (score: Double, rect: CGRect)? {
        guard let tmpl = ensureTextTemplate(),
              let hay = toGray(crop),
              hay.width > tmpl.width, hay.height > tmpl.height else {
            return nil
        }

        var bestScore = -1.0
        var bestRect = CGRect.null

        for scale in templateScales {
            let tw = max(8, Int((CGFloat(tmpl.width) * scale).rounded()))
            let th = max(4, Int((CGFloat(tmpl.height) * scale).rounded()))
            guard tw < hay.width, th < hay.height else { continue }
            let scaled: GrayImage
            if abs(scale - 1) < 0.001 {
                scaled = tmpl
            } else if let s = resizeGray(tmpl, width: tw, height: th) {
                scaled = s
            } else {
                continue
            }
            let result = matchTemplate(hay: hay, tmpl: scaled)
            if result.score > bestScore {
                bestScore = result.score
                bestRect = CGRect(x: result.x, y: result.y, width: scaled.width, height: scaled.height)
            }
        }

        guard bestScore >= 0, !bestRect.isNull else { return nil }
        return (bestScore, bestRect)
    }

    private static func toGray(_ image: CGImage) -> GrayImage? {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var gray = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let o = i * 4
            let r = Int(rgba[o]), g = Int(rgba[o + 1]), b = Int(rgba[o + 2])
            gray[i] = UInt8((r * 30 + g * 59 + b * 11) / 100)
        }
        return GrayImage(width: w, height: h, pixels: gray)
    }

    private static func resizeGray(_ img: GrayImage, width: Int, height: Int) -> GrayImage? {
        guard let provider = CGDataProvider(data: Data(img.pixels) as CFData),
              let cg = CGImage(
                width: img.width, height: img.height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: img.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        var out = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(
            data: &out, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return GrayImage(width: width, height: height, pixels: out)
    }

    /// TM_CCOEFF_NORMED.
    private static func matchTemplate(hay: GrayImage, tmpl: GrayImage) -> (score: Double, x: Int, y: Int) {
        let tw = tmpl.width, th = tmpl.height
        let hw = hay.width, hh = hay.height
        guard tw <= hw, th <= hh else { return (0, 0, 0) }

        var tMean = 0.0
        for p in tmpl.pixels { tMean += Double(p) }
        tMean /= Double(tw * th)

        var tVar = 0.0
        var tCentered = [Double](repeating: 0, count: tw * th)
        for i in 0..<(tw * th) {
            let v = Double(tmpl.pixels[i]) - tMean
            tCentered[i] = v
            tVar += v * v
        }
        if tVar < 1e-6 { return (0, 0, 0) }

        var best = -1.0
        var bestX = 0, bestY = 0
        let n = Double(tw * th)

        for y in 0...(hh - th) {
            for x in 0...(hw - tw) {
                var sum = 0.0, sumSq = 0.0, cross = 0.0
                for ty in 0..<th {
                    let hayRow = (y + ty) * hw + x
                    let tRow = ty * tw
                    for tx in 0..<tw {
                        let hv = Double(hay.pixels[hayRow + tx])
                        sum += hv
                        sumSq += hv * hv
                        cross += hv * tCentered[tRow + tx]
                    }
                }
                let hVar = sumSq - (sum * sum) / n
                if hVar < 1e-6 { continue }
                let score = cross / sqrt(hVar * tVar)
                if score > best {
                    best = score
                    bestX = x
                    bestY = y
                }
            }
        }
        return (best, bestX, bestY)
    }

    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: - Fill sampling

    private struct FillSample {
        let maroonRatio: Double
        let grayRatio: Double
        let goldRatio: Double
    }

    private static func sampleButtonFill(in image: CGImage, rect: CGRect) -> FillSample {
        let x0 = max(0, Int(rect.minX))
        let y0 = max(0, Int(rect.minY))
        let w = max(1, min(image.width - x0, Int(rect.width)))
        let h = max(1, min(image.height - y0, Int(rect.height)))
        guard let cropped = image.cropping(to: CGRect(x: x0, y: y0, width: w, height: h)) else {
            return FillSample(maroonRatio: 0, grayRatio: 0, goldRatio: 0)
        }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return FillSample(maroonRatio: 0, grayRatio: 0, goldRatio: 0)
        }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))

        var maroon = 0
        var gray = 0
        var gold = 0
        var count = 0
        let step = max(1, min(w, h) / 40)
        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) {
                let o = y * bytesPerRow + x * 4
                let r = Double(pixels[o])
                let g = Double(pixels[o + 1])
                let b = Double(pixels[o + 2])
                count += 1
                if isBrightGold(r: r, g: g, b: b) {
                    gold += 1
                } else if isMaroonButton(r: r, g: g, b: b) {
                    maroon += 1
                } else if isGrayButton(r: r, g: g, b: b) {
                    gray += 1
                }
            }
        }
        let denom = Double(max(count, 1))
        return FillSample(
            maroonRatio: Double(maroon) / denom,
            grayRatio: Double(gray) / denom,
            goldRatio: Double(gold) / denom
        )
    }

    private static func isBrightGold(r: Double, g: Double, b: Double) -> Bool {
        // Active Autobattle letters — often muted beige/gold, not saturated yellow.
        r > 135 && g > 95 && b < 125 && (r - b) > 45 && g > b + 5
    }

    private static func isMaroonButton(r: Double, g: Double, b: Double) -> Bool {
        // Dark red button face (Screen Sharing softens colors).
        r > 55 && r < 190 && g < 115 && b < 110 && (r - g) > 12 && (r - b) > 15 && r > g && r > b
    }

    private static func isGrayButton(r: Double, g: Double, b: Double) -> Bool {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        // Includes darker charcoal disabled-button fill.
        return maxC < 160 && minC > 18 && (maxC - minC) < 40 && maxC > 35
    }

    private static func debugFolderURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlackHoleMonitor-Debug", isDirectory: true)
    }

    private static func savePNG(_ image: CGImage, to url: URL) -> Bool {
        // Normalize to 8-bit sRGB RGBA so Preview can crop/edit (raw camera buffers often can't).
        let writable = previewEditableImage(from: image) ?? image
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, writable, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        clearQuarantineAttribute(at: url)
        return true
    }

    /// Flatten any camera/window buffer into a Preview-editable sRGB PNG source.
    private static func previewEditableImage(from image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func clearQuarantineAttribute(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-d", "com.apple.quarantine", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func drawROIOutline(on image: CGImage, roi: CGRect) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Draw without CTM flip; convert top-left ROI into bottom-left context space.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let ctxROI = CGRect(
            x: roi.minX,
            y: CGFloat(height) - roi.maxY,
            width: roi.width,
            height: roi.height
        )
        context.setStrokeColor(red: 0, green: 1, blue: 0.2, alpha: 1)
        context.setLineWidth(max(3, CGFloat(width) / 900))
        context.stroke(ctxROI.insetBy(dx: -2, dy: -2))
        return context.makeImage()
    }
}
