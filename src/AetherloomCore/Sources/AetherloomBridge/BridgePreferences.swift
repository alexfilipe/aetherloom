import AetherloomCore
import Foundation

public actor BridgePreferences {
    private static let safetyThresholdsKey = "aetherloom.bridge.default-safety-thresholds"

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public init(suiteName: String) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func defaultSafetyThresholds() -> SafetyThresholds {
        guard let data = defaults.data(forKey: Self.safetyThresholdsKey),
              let thresholds = try? decoder.decode(SafetyThresholds.self, from: data)
        else {
            return SafetyThresholds()
        }
        return thresholds
    }

    public func setDefaultSafetyThresholds(_ thresholds: SafetyThresholds) throws {
        defaults.set(try encoder.encode(thresholds), forKey: Self.safetyThresholdsKey)
    }

    public func settingsForNewSyncSet() -> SyncSettings {
        SyncSettings(thresholds: defaultSafetyThresholds())
    }

    public func makeSyncSetDraft(
        name: String,
        locationIDs: [LocationID],
        mode: SyncMode = .balancedMirror
    ) -> SyncSetDraft {
        SyncSetDraft(
            name: name,
            locationIDs: locationIDs,
            mode: mode,
            settings: settingsForNewSyncSet()
        )
    }
}
