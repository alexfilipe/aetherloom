import AetherloomCore
@testable import AetherloomBridge
import Foundation
import Testing

@Suite("Demo engine session")
struct DemoEngineSessionTests {
    @Test("standard app session completes bootstrap")
    func standardAppSessionCompletesBootstrap() async throws {
        let session = DemoEngineSession.standard()
        let snapshot = try await session.bootstrap()
        let activity = await session.activity(matching: ActivityQuery(limit: 100))

        #expect(snapshot.syncSets.count == 4)
        #expect(snapshot.locations.count == 5)
        #expect(!activity.isEmpty)
    }

    @Test("bootstrap produces a neutral internally consistent demo baseline")
    func bootstrapProducesNeutralBaseline() async throws {
        let session = makeSession()
        let snapshot = try await session.bootstrap()

        #expect(snapshot.syncSets.count == 4)
        #expect(snapshot.locations.count == 5)
        #expect(snapshot.openConflictCount == 0)
        #expect(snapshot.status == .allInSync)
        #expect(try await session.openConflicts(in: nil).isEmpty)

        let states = Dictionary(uniqueKeysWithValues: snapshot.syncSets.map { ($0.id, $0) })
        #expect(states[DemoWorld.documentsID]?.trackedItemCount == 39)
        #expect(states[DemoWorld.projectsID]?.trackedItemCount == 60)
        #expect(states[DemoWorld.photosArchiveID]?.trackedItemCount == 25)
        #expect(states[DemoWorld.wholeDriveMirrorID]?.isPaused == true)

        for syncSetID in [DemoWorld.documentsID, DemoWorld.projectsID, DemoWorld.photosArchiveID] {
            let preparation = try #require(await session.lastPreparation(for: syncSetID))
            #expect(preparation.preview.sections.allSatisfy { $0.entries.isEmpty })
            #expect(preparation.preview.holds.isEmpty)
            #expect(preparation.preview.refusals.isEmpty)
        }

        let locations = Dictionary(uniqueKeysWithValues: snapshot.locations.map { ($0.id, $0) })
        #expect(locations[.nasFolder]?.availability == .available)
        let baselineOneDrive = try #require(locations[.oneDrive])
        guard case .unavailable(.networkUnreachable) = baselineOneDrive.availability else {
            Issue.record("OneDrive should retain the baseline unreachable state")
            return
        }
    }

    @Test("bootstrap is deterministic at the display-neutral digest level")
    func bootstrapIsDeterministic() async throws {
        let first = makeSession()
        let second = makeSession()
        let firstSnapshot = try await first.bootstrap()
        let secondSnapshot = try await second.bootstrap()

        #expect(firstSnapshot.syncSets.map(\.trackedItemCount) == secondSnapshot.syncSets.map(\.trackedItemCount))
        for syncSetID in [DemoWorld.documentsID, DemoWorld.projectsID, DemoWorld.photosArchiveID] {
            let lhs = try #require(await first.lastPreparation(for: syncSetID))
            let rhs = try #require(await second.lastPreparation(for: syncSetID))
            #expect(sectionCounts(lhs) == sectionCounts(rhs))
            #expect(lhs.preview.holds.map { String(describing: $0.reason) } == rhs.preview.holds.map { String(describing: $0.reason) })
            #expect(lhs.preview.refusals.map(\.message) == rhs.preview.refusals.map(\.message))
        }
    }

    @Test("mass-deletion demo is a visible non-approvable hold with no execution")
    func massDeletionIsNonApprovableAndDoesNotExecute() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()
        await session.scenarioControls.makeMassDeletion()
        #expect(await session.lastPreparation(for: DemoWorld.projectsID) == nil)
        let preparation = try await session.prepare(syncSetID: DemoWorld.projectsID)
        let plan = try #require(preparation.outcome.planValue)
        let display = previewDisplay(for: preparation, locations: await session.locationStates())

        #expect(preparation.preview.headline == "Paused for safety")
        #expect(preparation.preview.holds.contains { reasonIsMassDeletion($0.reason) })
        #expect(display.approvalRequirement == nil)
        #expect(plan.gate.permitsApproval == false)
        await session.clearProviderCalls()

        let attemptedApproval = PlanApproval(
            planFingerprint: plan.fingerprint,
            approvedAt: preparation.preview.generatedAt,
            acknowledgedTrashCount: plan.approvalTrashCount,
            acknowledgedConflictCount: plan.approvalConflictCount
        )
        #expect(attemptedApproval.validate(against: plan, at: preparation.preview.generatedAt) == .rejected(.safetyHoldNotApprovable))
        let summary = try await session.execute(preparation, approval: attemptedApproval)
        #expect(summary.outcome == .held)
        #expect(summary.appliedOperations.isEmpty)
        let calls = await session.providerCallLogs().values.flatMap { $0 }
        #expect(calls.allSatisfy { !mutationOperations.contains($0.operation) })
    }

    @Test("expired approvals are rejected without provider mutations")
    func expiredApprovalIsRejected() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()
        await session.scenarioControls.makeConflict()
        let preparation = try await session.prepare(syncSetID: DemoWorld.documentsID)
        let plan = try #require(preparation.outcome.planValue)
        await session.clearProviderCalls()

        let approval = makeApproval(
            ApprovalRequirement(
                fingerprint: plan.fingerprint,
                trashCount: plan.approvalTrashCount,
                conflictCount: plan.approvalConflictCount
            ),
            at: preparation.preview.generatedAt.addingTimeInterval(-3_600)
        )
        do {
            _ = try await session.execute(preparation, approval: approval)
            Issue.record("Expected the expired approval to fail")
        } catch {
            #expect(error is EngineSessionError)
        }

        let calls = await session.providerCallLogs().values.flatMap { $0 }
        #expect(calls.allSatisfy { !mutationOperations.contains($0.operation) })
    }

    @Test("conflict demo control invalidates the baseline and creates one visible conflict")
    func conflictControlCreatesOneConflict() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()
        await session.scenarioControls.makeConflict()
        #expect(await session.lastPreparation(for: DemoWorld.documentsID) == nil)
        let preparation = try await session.prepare(syncSetID: DemoWorld.documentsID)
        let conflicts = try await session.openConflicts(in: DemoWorld.documentsID)

        #expect(conflicts.count == 1)
        #expect(conflicts.first?.path == "/Documents/Notes/Meeting.txt")
        #expect(preparation.preview.conflicts.count == 1)
        #expect(preparation.preview.holds.contains { reasonIsConflict($0.reason) })
    }

    @Test("pause blocks preparation and resume restores it")
    func pauseBlocksPreparation() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()
        await session.setPaused(true, syncSetID: DemoWorld.documentsID)

        do {
            _ = try await session.prepare(syncSetID: DemoWorld.documentsID)
            Issue.record("Expected paused preparation to fail")
        } catch let error as EngineSessionError {
            #expect(error == .syncSetPaused(DemoWorld.documentsID))
        }

        await session.setPaused(false, syncSetID: DemoWorld.documentsID)
        _ = try await session.prepare(syncSetID: DemoWorld.documentsID)
    }

    @Test("suggestions toggle rebuilds advisory composition for the next prepare")
    func suggestionsToggleControlsNextPreparation() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()
        await session.scenarioControls.makeConflict()
        let initial = try await session.prepare(syncSetID: DemoWorld.documentsID)
        #expect(!initial.advice.isEmpty)
        #expect(await session.suggestionsEnabled())

        await session.clearProviderCalls()
        try await session.setSuggestionsEnabled(false)
        #expect(await session.suggestionsEnabled() == false)
        #expect(await session.lastPreparation(for: DemoWorld.documentsID) == nil)
        #expect(await session.advice(for: initial.advice.map(\.conflictID)).isEmpty)
        #expect(await session.providerCallLogs().values.allSatisfy(\.isEmpty))

        let withoutSuggestions = try await session.prepare(syncSetID: DemoWorld.documentsID)
        #expect(withoutSuggestions.advice.isEmpty)
        #expect(withoutSuggestions.preview.advice.isEmpty)

        try await session.setSuggestionsEnabled(true)
        #expect(await session.suggestionsEnabled())
        #expect(await session.lastPreparation(for: DemoWorld.documentsID) == nil)
        let restored = try await session.prepare(syncSetID: DemoWorld.documentsID)
        #expect(!restored.advice.isEmpty)
        #expect(!restored.preview.advice.isEmpty)
    }

    @Test("mode and settings changes reach the next real plan")
    func configurationChangesReachNextPlan() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()
        await session.scenarioControls.makeMassDeletion()

        let noDeletes = SyncSettings(
            thresholds: SafetyThresholds(
                massDeleteAbsolute: 31,
                massDeleteRatio: 0.51,
                massEditAbsolute: 50,
                massEditRatio: 0.5
            )
        )
        try await session.updateSyncSet(
            mode: .noDeletePropagation,
            settings: noDeletes,
            syncSetID: DemoWorld.projectsID
        )
        #expect(await session.lastPreparation(for: DemoWorld.projectsID) == nil)

        let modePreparation = try await session.prepare(syncSetID: DemoWorld.projectsID)
        #expect(modePreparation.preview.sections.first(where: { $0.kind == .movesToTrash })?.entries.isEmpty == true)
        #expect(!modePreparation.preview.holds.contains { reasonIsMassDeletion($0.reason) })

        try await session.updateSyncSet(
            mode: .balancedMirror,
            settings: noDeletes,
            syncSetID: DemoWorld.projectsID
        )
        let thresholdPreparation = try await session.prepare(syncSetID: DemoWorld.projectsID)
        #expect(thresholdPreparation.preview.sections.first(where: { $0.kind == .movesToTrash })?.entries.count == 30)
        #expect(!thresholdPreparation.preview.holds.contains { reasonIsMassDeletion($0.reason) })

        let state = try #require(await session.syncSetStates().first { $0.id == DemoWorld.projectsID })
        #expect(state.syncSet.mode == .balancedMirror)
        #expect(state.syncSet.settings == noDeletes)
    }

    @Test("deleting a sync set purges bridge state without touching providers")
    func deletingSyncSetDoesNotMutateProviders() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()
        #expect(try await session.baseRecordCount(for: DemoWorld.projectsID) == 60)
        await session.clearProviderCalls()
        var events = session.events.makeAsyncIterator()

        try await session.deleteSyncSet(DemoWorld.projectsID)

        #expect(await session.syncSetStates().allSatisfy { $0.id != DemoWorld.projectsID })
        #expect(await session.lastPreparation(for: DemoWorld.projectsID) == nil)
        #expect(try await session.baseRecordCount(for: DemoWorld.projectsID) == 0)
        #expect(await events.next() == .syncSetChanged(DemoWorld.projectsID))
        let calls = await session.providerCallLogs().values.flatMap { $0 }
        #expect(calls.isEmpty)

        do {
            _ = try await session.prepare(syncSetID: DemoWorld.projectsID)
            Issue.record("Expected the deleted sync set to be missing")
        } catch let error as EngineSessionError {
            #expect(error == .syncSetNotFound(DemoWorld.projectsID))
        }
    }

    @Test("conflict resolution is recorded and make-canonical converges on the next run")
    func conflictResolutionConvergesOnNextRun() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()
        await session.scenarioControls.makeConflict()
        _ = try await session.prepare(syncSetID: DemoWorld.documentsID)
        let conflict = try #require(try await session.openConflicts(in: DemoWorld.documentsID).first)
        try await session.resolveConflict(id: conflict.id, as: .makeCanonical(.iCloudDrive))

        let record = try #require(try await session.resolvedConflicts(in: DemoWorld.documentsID).first)
        #expect(record.conflict == conflict)
        #expect(record.resolution == .makeCanonical(.iCloudDrive))

        let preparation = try await session.prepare(syncSetID: DemoWorld.documentsID)
        let plan = try #require(preparation.outcome.planValue)
        let approval = plan.gate.isClear ? nil : makeApproval(
            ApprovalRequirement(
                fingerprint: plan.fingerprint,
                trashCount: plan.approvalTrashCount,
                conflictCount: plan.approvalConflictCount
            ),
            at: preparation.preview.generatedAt
        )
        let summary = try await session.execute(preparation, approval: approval)
        #expect(summary.outcome == .completed)

        let hashes = await [.iCloudDrive, .googleDrive, .localFolder].asyncCompactMap { locationID in
            await session.providerItems(at: locationID).first { $0.path == "/Documents/Notes/Meeting.txt" }?.contentHash
        }
        #expect(Set(hashes).count == 1)
        #expect(try await session.openConflicts(in: DemoWorld.documentsID).isEmpty)
    }

    @Test("resolved conflict records are exposed as real store data")
    func resolvedConflictRecordsAreExposed() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()
        await session.scenarioControls.makeConflict()
        _ = try await session.prepare(syncSetID: DemoWorld.documentsID)
        let conflict = try #require(try await session.openConflicts(in: DemoWorld.documentsID).first)

        try await session.resolveConflict(id: conflict.id, as: .preserveAll)

        let scoped = try await session.resolvedConflicts(in: DemoWorld.documentsID)
        let all = try await session.resolvedConflicts(in: nil)
        let record = try #require(scoped.first(where: { $0.id == conflict.id }))
        #expect(record.conflict == conflict)
        #expect(record.resolution == .preserveAll)
        #expect(all.contains(record))
        #expect(try await session.openConflicts(in: DemoWorld.documentsID).allSatisfy { $0.id != conflict.id })
    }

    @Test("events multicast to independent subscribers")
    func eventsAreMulticast() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()
        var first = session.events.makeAsyncIterator()
        var second = session.events.makeAsyncIterator()

        await session.setPaused(true, syncSetID: DemoWorld.documentsID)
        let firstEvent = await first.next()
        let secondEvent = await second.next()
        #expect(firstEvent == .syncSetChanged(DemoWorld.documentsID))
        #expect(secondEvent == .syncSetChanged(DemoWorld.documentsID))
    }

    @Test("NAS and OneDrive toggles transition and reset restores the intentional baseline")
    func availabilityControlsAndReset() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()
        let controls = session.scenarioControls

        await expectProviderControls(
            session,
            oneDriveIsReachable: false,
            oneDriveActionTitle: "Make OneDrive Reachable",
            nasIsMounted: true,
            nasActionTitle: "Unmount NAS “Tank”"
        )

        await controls.setNASMounted(false)
        #expect(await session.lastPreparation(for: DemoWorld.photosArchiveID) == nil)
        try await scanUnpausedSyncSets(session)
        await expectProviderControls(
            session,
            oneDriveIsReachable: false,
            oneDriveActionTitle: "Make OneDrive Reachable",
            nasIsMounted: false,
            nasActionTitle: "Mount NAS “Tank”"
        )

        await controls.setNASMounted(true)
        try await scanUnpausedSyncSets(session)
        await expectProviderControls(
            session,
            oneDriveIsReachable: false,
            oneDriveActionTitle: "Make OneDrive Reachable",
            nasIsMounted: true,
            nasActionTitle: "Unmount NAS “Tank”"
        )

        await controls.setOneDriveReachable(true)
        try await scanUnpausedSyncSets(session)
        await expectProviderControls(
            session,
            oneDriveIsReachable: true,
            oneDriveActionTitle: "Make OneDrive Unreachable",
            nasIsMounted: true,
            nasActionTitle: "Unmount NAS “Tank”"
        )

        await controls.setOneDriveReachable(false)
        try await scanUnpausedSyncSets(session)
        await expectProviderControls(
            session,
            oneDriveIsReachable: false,
            oneDriveActionTitle: "Make OneDrive Reachable",
            nasIsMounted: true,
            nasActionTitle: "Unmount NAS “Tank”"
        )

        await controls.setOneDriveReachable(true)
        await controls.setNASMounted(false)

        try await controls.reset()
        await expectProviderControls(
            session,
            oneDriveIsReachable: false,
            oneDriveActionTitle: "Make OneDrive Reachable",
            nasIsMounted: true,
            nasActionTitle: "Unmount NAS “Tank”"
        )
        let snapshot = await session.workspace()
        #expect(snapshot.openConflictCount == 0)
        #expect(snapshot.status == .allInSync)
    }

    @Test("repeated provider toggle and reset cycles keep cards and commands consistent")
    func repeatedProviderToggleAndResetCyclesStayConsistent() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()

        for _ in 0 ..< 2 {
            await session.scenarioControls.setOneDriveReachable(true)
            await session.scenarioControls.setNASMounted(false)
            try await scanUnpausedSyncSets(session)
            await expectProviderControls(
                session,
                oneDriveIsReachable: true,
                oneDriveActionTitle: "Make OneDrive Unreachable",
                nasIsMounted: false,
                nasActionTitle: "Mount NAS “Tank”"
            )

            try await session.scenarioControls.reset()
            await expectProviderControls(
                session,
                oneDriveIsReachable: false,
                oneDriveActionTitle: "Make OneDrive Reachable",
                nasIsMounted: true,
                nasActionTitle: "Unmount NAS “Tank”"
            )
        }
    }

    @Test("unfinished journal runs recover on the next prepare")
    func interruptedRunRecovers() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()
        try await session.scenarioControls.simulateInterruptedRun()
        #expect(await session.lastPreparation(for: DemoWorld.documentsID) == nil)
        await session.clearProviderCalls()
        let preparation = try await session.prepare(syncSetID: DemoWorld.documentsID)

        let activity = await session.activity(matching: ActivityQuery(categories: [.safety], limit: 500))
        #expect(activity.contains { $0.message == ActivityMessageCatalog.recoveryPerformed })
        #expect(preparation.preview.sections.allSatisfy { $0.entries.isEmpty })
        #expect(preparation.preview.holds.isEmpty)
        let calls = await session.providerCallLogs().values.flatMap { $0 }
        #expect(calls.allSatisfy { !mutationOperations.contains($0.operation) })
    }

    @Test("reset and scenario cycles do not accumulate stale state")
    func resetCyclesDoNotAccumulateState() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()

        for _ in 0 ..< 2 {
            await session.scenarioControls.makeConflict()
            _ = try await session.prepare(syncSetID: DemoWorld.documentsID)
            #expect(try await session.openConflicts(in: nil).count == 1)

            await session.scenarioControls.makeMassDeletion()
            _ = try await session.prepare(syncSetID: DemoWorld.projectsID)
            try await session.scenarioControls.simulateInterruptedRun()

            try await session.scenarioControls.reset()
            let snapshot = await session.workspace()
            #expect(snapshot.openConflictCount == 0)
            #expect(snapshot.status == .allInSync)
            #expect(await session.locationStates().first { $0.id == .nasFolder }?.availability == .available)
            for syncSetID in [DemoWorld.documentsID, DemoWorld.projectsID, DemoWorld.photosArchiveID] {
                let preparation = try #require(await session.lastPreparation(for: syncSetID))
                #expect(preparation.preview.sections.allSatisfy { $0.entries.isEmpty })
                #expect(preparation.preview.holds.isEmpty)
                #expect(preparation.preview.refusals.isEmpty)
            }
            let activity = await session.activity(matching: ActivityQuery(limit: 500))
            #expect(!activity.contains { $0.message == ActivityMessageCatalog.recoveryPerformed })
        }
    }

    @Test("read paths never mutate fake providers")
    func readPathsDoNotMutateProviders() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()
        await session.clearProviderCalls()

        _ = await session.workspace()
        _ = await session.syncSetStates()
        _ = await session.locationStates()
        let conflicts = try await session.openConflicts(in: nil)
        _ = try await session.resolvedConflicts(in: nil)
        _ = await session.advice(for: conflicts.map(\.id))
        _ = await session.activity(matching: ActivityQuery(limit: 20))
        _ = await session.lastPreparation(for: DemoWorld.documentsID)

        let calls = await session.providerCallLogs().values.flatMap { $0 }
        #expect(calls.allSatisfy { !mutationOperations.contains($0.operation) })
    }

    @Test("cancelling prepare does not leave the orchestrator stuck")
    func cancellationRecovers() async throws {
        let session = makeSession()
        _ = try await session.bootstrap()
        await session.setProviderLatency(2_000_000_000)
        let task = Task {
            try await session.prepare(syncSetID: DemoWorld.documentsID)
        }
        await Task.yield()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected preparation cancellation")
        } catch {
            #expect(error is EngineSessionError)
        }

        await session.setProviderLatency(0)
        _ = try await session.prepare(syncSetID: DemoWorld.documentsID)
    }

    @Test("bridge sources do not import UI frameworks")
    func bridgeHasNoUIFrameworkImports() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appendingPathComponent("Sources/AetherloomBridge", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
        var violations: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            if source.contains("import SwiftUI") || source.contains("import AppKit") {
                violations.append(fileURL.lastPathComponent)
            }
        }
        #expect(violations.isEmpty)
    }
}

private let mutationOperations: Set<FakeProviderOperation> = [.store, .makeFolder, .relocate, .trash]

private func makeSession() -> DemoEngineSession {
    let sequence = DeterministicSequence()
    return DemoEngineSession(
        environment: EngineEnvironment(now: sequence.now, makeID: sequence.makeID),
        providerLatencyNanoseconds: 0
    )
}

private func sectionCounts(_ preparation: SyncPreparation) -> [PreviewSectionKind: Int] {
    Dictionary(uniqueKeysWithValues: preparation.preview.sections.map { ($0.kind, $0.entries.count) })
}

private func reasonIsConflict(_ reason: HoldReason) -> Bool {
    if case .conflicts = reason { return true }
    return false
}

private func reasonIsDeletionReview(_ reason: HoldReason) -> Bool {
    if case .deletionsNeedReview = reason { return true }
    return false
}

private func reasonIsMassDeletion(_ reason: HoldReason) -> Bool {
    if case .massDeletion = reason { return true }
    return false
}

private func scanUnpausedSyncSets(_ session: DemoEngineSession) async throws {
    let states = await session.syncSetStates()
    for state in states where !state.isPaused {
        _ = try await session.prepare(syncSetID: state.id)
    }
    _ = await session.workspace()
}

private func expectProviderControls(
    _ session: DemoEngineSession,
    oneDriveIsReachable: Bool,
    oneDriveActionTitle: String,
    nasIsMounted: Bool,
    nasActionTitle: String
) async {
    let workspace = await session.workspace()
    let display = DemoProviderControlDisplay(locations: workspace.locations)
    let oneDriveCardIsAvailable = workspace.locations.first {
        $0.location.kind == .oneDrive
    }?.availability == .available
    let nasCardIsAvailable = workspace.locations.first {
        $0.location.kind == .nasFolder
    }?.availability == .available

    #expect(oneDriveCardIsAvailable == display.oneDriveIsReachable)
    #expect(nasCardIsAvailable == display.nasIsMounted)
    #expect(display.oneDriveIsReachable == oneDriveIsReachable)
    #expect(display.oneDriveActionTitle == oneDriveActionTitle)
    #expect(display.nasIsMounted == nasIsMounted)
    #expect(display.nasActionTitle == nasActionTitle)
}

private final class DeterministicSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var tick = 0
    private let epoch = Date(timeIntervalSince1970: 1_783_000_000)

    func now() -> Date {
        lock.withLock {
            defer { tick += 1 }
            return epoch.addingTimeInterval(TimeInterval(tick))
        }
    }

    func makeID() -> UUID {
        lock.withLock {
            tick += 1
            let suffix = String(format: "%012llx", UInt64(tick))
            return UUID(uuidString: "20000000-0000-0000-0000-\(suffix)")!
        }
    }
}

private extension Array where Element: Sendable {
    func asyncCompactMap<T: Sendable>(
        _ transform: @Sendable (Element) async -> T?
    ) async -> [T] {
        var result: [T] = []
        for element in self {
            if let value = await transform(element) {
                result.append(value)
            }
        }
        return result
    }
}
