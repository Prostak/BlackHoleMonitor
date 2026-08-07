import Foundation

enum InputDefaults {
    static let blackHoleUID = "BlackHole2ch_UID"
    static let blackHoleName = "BlackHole 2ch"
    static let blackHoleGraphMaxRMS: Float = 0.12
    static let blackHoleThresholdRMS: Float = 0.039_810_717 * 0.72

    static func isBlackHole(uid: String, name: String?) -> Bool {
        uid == blackHoleUID || name == blackHoleName
    }
}

enum ThresholdStore {
    static let defaultsKey = "triggerThresholdsByInputUID"
    static let defaultThresholdRMS: Float = 0.04

    static func threshold(for uid: String, deviceName: String? = nil) -> Float {
        guard !uid.isEmpty else {
            return defaultThreshold(for: deviceName)
        }
        if let stored = UserDefaults.standard.dictionary(forKey: defaultsKey)?[uid] as? Double {
            return Float(stored)
        }
        let name = InputDefaults.isBlackHole(uid: uid, name: deviceName) ? InputDefaults.blackHoleName : deviceName
        return defaultThreshold(for: name)
    }

    static func defaultThreshold(for deviceName: String?) -> Float {
        if deviceName == InputDefaults.blackHoleName {
            return InputDefaults.blackHoleThresholdRMS
        }
        return defaultThresholdRMS
    }

    static func save(uid: String, rms: Float) {
        guard !uid.isEmpty else { return }
        var dict = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        dict[uid] = Double(rms)
        UserDefaults.standard.set(dict, forKey: defaultsKey)
    }
}

enum GraphScaleStore {
    static let peakKey = "peakRMSByInputUID"
    static let scaleKey = "graphMaxRMSByInputUID"
    static let defaultGraphMax: Float = 0.12
    static let absoluteGraphMax: Float = 1.0
    static let minimumGraphMax: Float = 0.008

    static func peakRMS(for uid: String) -> Float {
        guard !uid.isEmpty else { return 0 }
        return Float(UserDefaults.standard.dictionary(forKey: peakKey)?[uid] as? Double ?? 0)
    }

    static func graphMaxRMS(for uid: String, deviceName: String? = nil) -> Float {
        guard !uid.isEmpty else {
            return defaultGraphMax(for: deviceName)
        }
        if let stored = UserDefaults.standard.dictionary(forKey: scaleKey)?[uid] as? Double {
            return Float(stored)
        }
        let peak = peakRMS(for: uid)
        if peak > 0 {
            return graphMaxRMS(forPeak: peak)
        }
        let name = InputDefaults.isBlackHole(uid: uid, name: deviceName) ? InputDefaults.blackHoleName : deviceName
        return defaultGraphMax(for: name)
    }

    static func defaultGraphMax(for deviceName: String?) -> Float {
        if deviceName == InputDefaults.blackHoleName {
            return InputDefaults.blackHoleGraphMaxRMS
        }
        return defaultGraphMax
    }

    static func graphMaxRMS(forPeak peak: Float) -> Float {
        guard peak > 0 else { return defaultGraphMax }
        let target = peak * 2
        if target >= absoluteGraphMax {
            return absoluteGraphMax
        }
        return max(target, minimumGraphMax)
    }

    @discardableResult
    static func recordPeak(uid: String, peak: Float, deviceName: String? = nil) -> Float {
        guard !uid.isEmpty, peak > 0 else { return graphMaxRMS(for: uid, deviceName: deviceName) }

        var peakDict = UserDefaults.standard.dictionary(forKey: peakKey) ?? [:]
        let previousPeak = Float(peakDict[uid] as? Double ?? 0)
        guard peak > previousPeak else {
            return graphMaxRMS(for: uid, deviceName: deviceName)
        }

        peakDict[uid] = Double(peak)
        UserDefaults.standard.set(peakDict, forKey: peakKey)

        let newScale = graphMaxRMS(forPeak: peak)
        var scaleDict = UserDefaults.standard.dictionary(forKey: scaleKey) ?? [:]
        scaleDict[uid] = Double(newScale)
        UserDefaults.standard.set(scaleDict, forKey: scaleKey)
        return newScale
    }
}
