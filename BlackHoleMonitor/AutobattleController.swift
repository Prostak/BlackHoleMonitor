import Foundation

enum AutobattlePhase: String {
    case idle
    case red
    case gray
    case sentA
    case waitingTwoSeconds
    case noWindow
    case paused
}

struct TripleBeepScoreEntry: Identifiable {
    let id = UUID()
    let date: Date
    /// TM scores of the consecutive absent polls that fired the beep (oldest → newest).
    let missScores: [Double]
    var summary: String {
        let scores = missScores.map { String(format: "%.2f", $0) }.joined(separator: " → ")
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "\(formatter.string(from: date))  miss \(scores)"
    }
}

@MainActor
final class AutobattleController: ObservableObject {
    static let pollIntervalSeconds: TimeInterval = 1.0
    static let redWithoutGrayDelaySeconds: TimeInterval = 2.0
    /// Consecutive absent polls after gray/red before declaring battle ended.
    /// 1 is enough now that Elgato TM is stable (was 2 to ride out flicker).
    static let battleEndAbsentPolls = 1
    /// In-memory polls kept around a triple-beep so each saved event has context.
    static let tripleBeepContextPolls = 8
    static let recentBeepScoreLimit = 10
    /// Rolling window for Template card TM min–max.
    static let recentTMWindowSeconds: TimeInterval = 10

    @Published private(set) var phase: AutobattlePhase = .idle
    @Published private(set) var statusText = "Autobattle: off"
    @Published private(set) var lastAppearance: AutobattleAppearance = .absent
    @Published private(set) var isPaused = false
    @Published private(set) var isWatching = false
    /// Last triple-beep miss-score chains (newest first) for threshold tuning.
    @Published private(set) var recentBeepScores: [TripleBeepScoreEntry] = []
    /// TM min–max over the last ~10s (e.g. "0.72–0.86"), for Template preview.
    @Published private(set) var recentTMRangeLabel = "—"
    /// Bumps when last-A / last-triple-beep preview images should reload.
    @Published private(set) var previewTick: Int = 0

    private var watchTask: Task<Void, Never>?
    private var isEnabled = false
    private var awaitingGrayAfterSend = false
    private var redAgainDeadline: Date?
    private var sendInFlight = false
    /// True after gray/red seen this battle — cleared when button stays gone.
    private var buttonWasPresent = false
    private var consecutiveAbsentPolls = 0
    /// Rolling polls leading into a triple-beep (disk write only on the beep itself).
    private var tripleBeepContext: [AutobattleDetector.HistoryFrame] = []
    /// True after we lost app focus while watching — next become-active pauses for Continue.
    private var wasInactiveWhileWatching = false
    private var recentTMScores: [(date: Date, score: Double)] = []

    var onSendA: (() async -> Bool)?
    var onPreviewArtifactsChanged: (() -> Void)?

    func start() {
        stop()
        isEnabled = true
        isWatching = true
        isPaused = false
        wasInactiveWhileWatching = false
        awaitingGrayAfterSend = false
        redAgainDeadline = nil
        sendInFlight = false
        buttonWasPresent = false
        consecutiveAbsentPolls = 0
        tripleBeepContext.removeAll()
        recentTMScores.removeAll()
        recentTMRangeLabel = "—"
        phase = .idle
        statusText = "Autobattle: watching (search)…"
        startPollingLoop()
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        isEnabled = false
        isWatching = false
        isPaused = false
        wasInactiveWhileWatching = false
        awaitingGrayAfterSend = false
        redAgainDeadline = nil
        sendInFlight = false
        buttonWasPresent = false
        consecutiveAbsentPolls = 0
        tripleBeepContext.removeAll()
        recentTMScores.removeAll()
        recentTMRangeLabel = "—"
        phase = .idle
        statusText = "Autobattle: off"
    }

    func pauseAwaitingContinue(reason: String = "paused — press Continue") {
        guard isEnabled else { return }
        isPaused = true
        sendInFlight = false
        awaitingGrayAfterSend = false
        redAgainDeadline = nil
        consecutiveAbsentPolls = 0
        phase = .paused
        statusText = "Autobattle: \(reason)"
        // Keep watchTask alive but tick() no-ops while paused.
    }

    func continueWatching() {
        guard isEnabled else { return }
        isPaused = false
        wasInactiveWhileWatching = false
        awaitingGrayAfterSend = false
        redAgainDeadline = nil
        sendInFlight = false
        consecutiveAbsentPolls = 0
        // Keep tripleBeepContext — false ends often happen right after Continue.
        phase = .idle
        statusText = AutobattleDetector.hasButtonLock
            ? "Autobattle: watching (locked)…"
            : "Autobattle: watching (search)…"
        if watchTask == nil {
            startPollingLoop()
        }
    }

    func noteAppDidResignActive() {
        guard isEnabled, !isPaused else { return }
        wasInactiveWhileWatching = true
    }

    func noteAppDidBecomeActive() {
        guard isEnabled, wasInactiveWhileWatching, !isPaused else { return }
        wasInactiveWhileWatching = false
        pauseAwaitingContinue(reason: "focus returned — press Continue")
    }

    private func startPollingLoop() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                await CompatSleep.seconds(Self.pollIntervalSeconds)
            }
        }
    }

    private func tick() async {
        guard isEnabled, !isPaused, !sendInFlight else { return }

        let frame = await Task.detached(priority: .userInitiated) {
            AutobattleDetector.sampleFrame()
        }.value

        let stats = frame.stats
        let appearance = stats.appearance
        lastAppearance = appearance
        // Template card: TM min–max over the last ~10s (every poll with video).
        if appearance != .noWindow {
            rememberRecentTMScore(Double(stats.ocrConfidence))
        }

        switch appearance {
        case .noWindow:
            awaitingGrayAfterSend = false
            redAgainDeadline = nil
            consecutiveAbsentPolls = 0
            phase = .noWindow
            statusText = "Autobattle: no video"
            return

        case .absent:
            awaitingGrayAfterSend = false
            redAgainDeadline = nil
            if buttonWasPresent {
                consecutiveAbsentPolls += 1
                let absentNote = consecutiveAbsentPolls >= Self.battleEndAbsentPolls
                    ? "BATTLE_END"
                    : "absent-\(consecutiveAbsentPolls)/\(Self.battleEndAbsentPolls)"
                rememberContext(frame: frame, note: absentNote)
                if consecutiveAbsentPolls >= Self.battleEndAbsentPolls {
                    let missScores = tripleBeepContext
                        .suffix(Self.battleEndAbsentPolls)
                        .map { Double($0.stats.ocrConfidence) }
                    recordBeepScores(missScores)
                    AutobattleDetector.saveLastTripleBeepScoreLabel(missScores: missScores)
                    buttonWasPresent = false
                    consecutiveAbsentPolls = 0
                    _ = AutobattleDetector.saveTripleBeepEvent(frames: tripleBeepContext)
                    tripleBeepContext.removeAll()
                    bumpPreviewTick()
                    TriggerBeep.shared.playTriple(amplitude: 0.45)
                    phase = .idle
                    statusText = "Autobattle: battle ended"
                    return
                }
                phase = .idle
                statusText = "Autobattle: watching"
                return
            }
            consecutiveAbsentPolls = 0
            tripleBeepContext.removeAll()
            phase = .idle
            statusText = "Autobattle: watching"
            return

        case .gray:
            consecutiveAbsentPolls = 0
            buttonWasPresent = true
            redAgainDeadline = nil
            if awaitingGrayAfterSend {
                awaitingGrayAfterSend = false
            }
            rememberContext(frame: frame, note: "gray")
            phase = .gray
            statusText = "Autobattle: gray"
            return

        case .red:
            consecutiveAbsentPolls = 0
            buttonWasPresent = true
            phase = .red
            if awaitingGrayAfterSend {
                if redAgainDeadline == nil {
                    redAgainDeadline = Date().addingTimeInterval(Self.redWithoutGrayDelaySeconds)
                    rememberContext(frame: frame, note: "red-wait")
                    phase = .waitingTwoSeconds
                    statusText = "Autobattle: waiting…"
                    return
                }
                if Date() < redAgainDeadline! {
                    rememberContext(frame: frame, note: "red-wait")
                    phase = .waitingTwoSeconds
                    statusText = "Autobattle: waiting…"
                    return
                }
                redAgainDeadline = nil
                awaitingGrayAfterSend = false
                rememberContext(frame: frame, note: "red-send")
                await sendA(frame: frame)
                return
            }

            redAgainDeadline = nil
            rememberContext(frame: frame, note: "red-send")
            await sendA(frame: frame)
        }
    }

    private func rememberContext(frame: AutobattleFrameSample, note: String) {
        guard let image = frame.image else { return }
        tripleBeepContext.append(
            AutobattleDetector.HistoryFrame(
                image: image,
                stats: frame.stats,
                note: note,
                date: Date()
            )
        )
        if tripleBeepContext.count > Self.tripleBeepContextPolls {
            tripleBeepContext.removeFirst(tripleBeepContext.count - Self.tripleBeepContextPolls)
        }
    }

    private func recordBeepScores(_ missScores: [Double]) {
        guard !missScores.isEmpty else { return }
        recentBeepScores.insert(TripleBeepScoreEntry(date: Date(), missScores: missScores), at: 0)
        if recentBeepScores.count > Self.recentBeepScoreLimit {
            recentBeepScores = Array(recentBeepScores.prefix(Self.recentBeepScoreLimit))
        }
    }

    /// Rolling min–max of TM scores for the Template card (last ~10s).
    private func rememberRecentTMScore(_ score: Double) {
        let now = Date()
        recentTMScores.append((date: now, score: score))
        recentTMScores.removeAll { now.timeIntervalSince($0.date) > Self.recentTMWindowSeconds }
        guard let lo = recentTMScores.map(\.score).min(),
              let hi = recentTMScores.map(\.score).max() else {
            recentTMRangeLabel = "—"
            return
        }
        // Always show a range so the 10s window is obvious (even if min≈max).
        let next = String(format: "%.2f–%.2f", lo, hi)
        if next != recentTMRangeLabel {
            recentTMRangeLabel = next
        }
    }

    private func sendA(frame: AutobattleFrameSample) async {
        guard !sendInFlight, !isPaused else { return }
        sendInFlight = true
        phase = .sentA
        statusText = "Autobattle: sending A…"

        if let image = frame.image {
            _ = AutobattleDetector.saveLastTrigger(image: image, stats: frame.stats)
            bumpPreviewTick()
        }

        let sent = await onSendA?() ?? false
        sendInFlight = false
        guard !isPaused else { return }

        if sent {
            awaitingGrayAfterSend = true
            redAgainDeadline = nil
            phase = .sentA
            statusText = "Autobattle: sent A"
        } else {
            awaitingGrayAfterSend = false
            redAgainDeadline = nil
            phase = .red
            statusText = "Autobattle: send failed"
        }
    }

    private func bumpPreviewTick() {
        previewTick &+= 1
        onPreviewArtifactsChanged?()
    }
}
