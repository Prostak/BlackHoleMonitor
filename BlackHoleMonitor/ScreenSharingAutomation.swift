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
    private static let appURL = URL(fileURLWithPath: "/System/Applications/Utilities/Screen Sharing.app")

    @discardableResult
    static func focusAndTypeBacktick() async -> Bool {
        guard await ensureScreenSharingFocused() else {
            return false
        }

        try? await Task.sleep(for: .seconds(activationDelaySeconds))
        return await sendBacktick()
    }

    @discardableResult
    static func typeBacktick() async -> Bool {
        await sendBacktick()
    }

    @discardableResult
    static func focusWaitTypeBacktickAndReturn() async -> Bool {
        guard await ensureScreenSharingFocused() else {
            return false
        }

        try? await Task.sleep(for: .seconds(activationDelaySeconds))
        guard await sendBacktick() else {
            await activateSelf()
            return false
        }

        try? await Task.sleep(for: .seconds(keepaliveSettleDelaySeconds))
        await activateSelf()
        return true
    }

    @discardableResult
    static func refocusWaitAndTypeSecondBacktick() async -> Bool {
        guard await ensureScreenSharingFocused() else {
            return false
        }

        try? await Task.sleep(for: .seconds(secondFocusSettleDelaySeconds))
        return await sendBacktick()
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

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        return await withCheckedContinuation { continuation in
            workspace.openApplication(at: appURL, configuration: configuration) { app, error in
                if let error {
                    NSLog("Failed to launch Screen Sharing: \(error.localizedDescription)")
                }
                continuation.resume(returning: app != nil && error == nil)
            }
        }
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
    private static func sendBacktick() async -> Bool {
        await MainActor.run {
            switchToEnglishKeyboard()
        }
        try? await Task.sleep(for: .seconds(layoutSwitchDelaySeconds))
        return await MainActor.run {
            postBacktickKeyEvent()
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
    private static func postBacktickKeyEvent() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: backtickKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: backtickKeyCode, keyDown: false) else {
            return false
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
