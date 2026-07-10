import AetherloomCore
@testable import AetherloomBridge
import Foundation
import Testing

@Suite("Bridge preferences")
struct BridgePreferencesTests {
    @Test("threshold defaults round-trip as core values")
    func thresholdDefaultsRoundTrip() async throws {
        let (preferences, suiteName) = makePreferences()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let thresholds = SafetyThresholds(
            massDeleteAbsolute: 17,
            massDeleteRatio: 0.17,
            massEditAbsolute: 41,
            massEditRatio: 0.41
        )

        #expect(await preferences.defaultSafetyThresholds() == SafetyThresholds())
        try await preferences.setDefaultSafetyThresholds(thresholds)
        #expect(await preferences.defaultSafetyThresholds() == thresholds)
        #expect(await preferences.settingsForNewSyncSet().thresholds == thresholds)
    }

    @Test("new drafts consume current defaults without changing existing sets")
    func newDraftsConsumeDefaultsWithoutChangingExistingSets() async throws {
        let (preferences, suiteName) = makePreferences()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let session = DemoEngineSession(
            environment: EngineEnvironment(
                now: { Date(timeIntervalSince1970: 1_800_000_000) },
                makeID: UUID.init
            )
        )
        _ = try await session.bootstrap()
        let existingSettings = try #require(
            await session.syncSetStates().first { $0.id == DemoWorld.documentsID }
        ).syncSet.settings
        let thresholds = SafetyThresholds(
            massDeleteAbsolute: 8,
            massDeleteRatio: 0.08,
            massEditAbsolute: 16,
            massEditRatio: 0.16
        )
        try await preferences.setDefaultSafetyThresholds(thresholds)

        let draft = await preferences.makeSyncSetDraft(
            name: "Preferences Test",
            locationIDs: [.iCloudDrive, .googleDrive]
        )
        let created = try await session.createSyncSet(draft)

        #expect(draft.settings.thresholds == thresholds)
        #expect(created.syncSet.settings.thresholds == thresholds)
        let existingAfter = try #require(
            await session.syncSetStates().first { $0.id == DemoWorld.documentsID }
        )
        #expect(existingAfter.syncSet.settings == existingSettings)
    }

    private func makePreferences() -> (BridgePreferences, String) {
        let suiteName = "AetherloomBridgeTests.\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        return (BridgePreferences(suiteName: suiteName), suiteName)
    }
}
