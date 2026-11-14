import AppKit
import ApplicationServices
import Carbon
import Foundation

enum ScreenSharingAutomation {
    static let bundleIdentifier = "com.apple.ScreenSharing"
    static let applicationName = "Screen Sharing"
    static let activationDelaySeconds: TimeInterval = 0.2
    static let layoutSwitchDelaySeconds: TimeInterval = 0.05
    static let secondFocusSettleDelaySeconds: TimeInterval = 0.5
    static let postSecondKeyReturnDelaySeconds: TimeInterval = 0.5
    static let keepaliveSettleDelaySeconds: TimeInterval = 0.5
    static let secondBacktickBaseDelaySeconds: TimeInterval = 1.15
    static let secondBacktickOffsetMinimum: TimeInterval = -0.21
    static let secondBacktickOffsetMaximum: TimeInterval = 1.2

    private static let backtickKeyCode: CGKeyCode = 50
    private static let aKeyCode: CGKeyCode = 0

    /// Monterey keeps Screen Sharing under CoreServices; newer macOS under Utilities.
    private static let appPathCandidates = [
        "/System/Library/CoreServices/Applications/Screen Sharing.app",
        "/System/Applications/Utilities/Screen Sharing.app",
        "/Applications/Utilities/Screen Sharing.app",
    ]

    @discardableResult
    static func focusAndTypeBacktick() async -> Bool {
        guard await ensureScreenSharingFocused() else {
            return false
        }

        await CompatSleep.seconds(activationDelaySeconds)
        return await sendKey(backtickKeyCode)
    }

    @discardableResult
    static func typeBacktick() async -> Bool {
        await sendKey(backtickKeyCode)
    }

    @discardableResult
    static func focusAndTypeA() async -> Bool {
        guard await ensureScreenSharingFocused() else {
            return false
        }

        await CompatSleep.seconds(activationDelaySeconds)
        return await sendKey(aKeyCode)
    }

    @discardableResult
    static func focusWaitTypeBacktickAndReturn() async -> Bool {
        guard await ensureScreenSharingFocused() else {
            return false
        }

        await CompatSleep.seconds(activationDelaySeconds)
        guard await sendKey(backtickKeyCode) else {
            await activateSelf()
            return false
        }

        await CompatSleep.seconds(keepaliveSettleDelaySeconds)
        await activateSelf()
        return true
    }

    @discardableResult
    static func refocusWaitAndTypeSecondBacktick() async -> Bool {
        guard await ensureScreenSharingFocused() else {
            return false
        }

        await CompatSleep.seconds(secondFocusSettleDelaySeconds)
        return await sendKey(backtickKeyCode)
    }

    @MainActor
    static func ensureScreenSharingFocused() async -> Bool {
        await activateScreenSharing()
    }

    static func secondBacktickDelay() -> TimeInterval {
        secondBacktickBaseDelaySeconds + triangularRandomOffset()
    }

    @MainActor
    static func activateSelf() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @MainActor
    private static func activateScreenSharing() async -> Bool {
        let workspace = NSWorkspace.shared

        if let app = workspace.runningApplications.first(where: { app in
            app.bundleIdentifier == bundleIdentifier || app.localizedName == applicationName
        }) {
            return app.activate(options: [.activateIgnoringOtherApps])
        }

        guard let appURL = resolveScreenSharingURL() else {
            NSLog("Screen Sharing.app not found (bundle %@)", bundleIdentifier)
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        return await withCheckedContinuation { continuation in
            workspace.openApplication(at: appURL, configuration: configuration) { app, error in
                if let error {
                    NSLog("Failed to launch Screen Sharing at %@: %@", appURL.path, error.localizedDescription)
                }
                continuation.resume(returning: app != nil && error == nil)
            }
        }
    }

    /// Prefer Launch Services lookup; never open a missing hardcoded path (shows "file can't be found").
    private static func resolveScreenSharingURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }

        for path in appPathCandidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private static func triangularRandomOffset() -> TimeInterval {
        let minimum = secondBacktickOffsetMinimum
        let maximum = secondBacktickOffsetMaximum
        let mode: TimeInterval = 0
        let uniform = Double.random(in: 0...1)
        let relativeMode = (mode - minimum) / (maximum - minimum)

        if uniform < relativeMode {
            return minimum + sqrt(uniform * (maximum - minimum) * (mode - minimum))
        }

        return maximum - sqrt((1 - uniform) * (maximum - minimum) * (maximum - mode))
    }

    @discardableResult
    private static func sendKey(_ keyCode: CGKeyCode) async -> Bool {
        await MainActor.run {
            switchToEnglishKeyboard()
        }
        await CompatSleep.seconds(layoutSwitchDelaySeconds)
        return await MainActor.run {
            postKeyEvent(keyCode)
        }
    }

    @MainActor
    private static func switchToEnglishKeyboard() {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else {
            return
        }

        let count = CFArrayGetCount(sourceList)
        for index in 0..<count {
            let value = CFArrayGetValueAtIndex(sourceList, index)
            let source = unsafeBitCast(value, to: TISInputSource.self)
            guard let sourceIDPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
                continue
            }
            let sourceID = Unmanaged<CFString>.fromOpaque(sourceIDPointer).takeUnretainedValue() as String
            if sourceID.hasPrefix("com.apple.keylayout.ABC") || sourceID == "com.apple.keylayout.US" {
                TISSelectInputSource(source)
                return
            }
        }
    }

    @MainActor
    private static func postKeyEvent(_ keyCode: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
