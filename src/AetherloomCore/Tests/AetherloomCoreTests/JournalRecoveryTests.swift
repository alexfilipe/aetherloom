import Foundation
import Testing
@testable import AetherloomCore

@Test func runJournalFinishedRunsAreHiddenAndFinishIsIdempotent() async throws {
    let store = InMemoryRunJournalStore()
    let syncSetID = journalUUID("000000000101")
    let runID = journalUUID("000000000102")

    try await store.begin(runID: runID, syncSetID: syncSetID, fingerprint: PlanFingerprint(rawValue: "journal"))
    try await store.append(.runFinished(outcome: .succeeded, occurredAt: journalDate, detail: nil), runID: runID)
    try await store.append(.runFinished(outcome: .succeeded, occurredAt: journalDate, detail: nil), runID: runID)

    #expect(try await store.unfinishedRun(for: syncSetID) == nil)
}

@Test func recoveryMarksPendingTrashIntentOnlyAfterProviderTruthConfirmsTrash() async throws {
    let baseRecords = InMemoryBaseRecordStore()
    let journal = InMemoryRunJournalStore()
    let stores = EngineStores(
        baseRecords: baseRecords,
        journal: journal,
        conflicts: InMemoryConflictStore(),
        adviceCache: InMemoryAdviceCacheStore(),
        activity: InMemoryActivityStore(),
        locations: InMemoryLocationRegistry()
    )
    let provider = FakeStorageProvider(locationID: .oneDrive)
    let item = await provider.putFile(path: "/PendingTrash.txt", contents: Data("trash".utf8), modifiedAt: journalDate)
    try await provider.trash(item)
    let trash = Operation(
        id: OperationID(journalUUID("000000000103")),
        location: .oneDrive,
        kind: .trash(itemRef: ItemRef(item)),
        precondition: .versionMatches(item.version)
    )
    let runID = journalUUID("000000000104")
    let syncSetID = journalUUID("000000000105")
    try await journal.begin(runID: runID, syncSetID: syncSetID, fingerprint: PlanFingerprint(rawValue: "trash"))
    try await journal.append(.intent(trash), runID: runID)
    let replay = try #require(try await journal.unfinishedRun(for: syncSetID))

    let report = try await RunRecovery(
        providers: [.oneDrive: provider],
        stores: stores,
        environment: ExecutionEnvironment(now: { journalDate }, makeID: { journalUUID("000000000106") })
    ).recover(replay)
    let record = try #require(try await baseRecords.records(for: syncSetID).first)

    #expect(report.reconciledOperations == [trash.id])
    #expect(record.tombstone?.deletedAt == journalDate)
}

@Test func recoveryKeepsJournalUnfinishedWhileIndeterminateMutationRuns() async throws {
    let journal = InMemoryRunJournalStore()
    let stores = recoveryStores(journal: journal)
    let provider = ScriptedIndeterminateRecoveryProvider(
        locationID: .oneDrive,
        state: .inFlight,
        recoveryResult: .failure(
            .unavailable(provider: .oneDrive, reason: "still running")
        )
    )
    let operation = Operation(
        id: OperationID(journalUUID("000000000201")),
        location: .oneDrive,
        kind: .makeFolder(at: "/Pending"),
        precondition: .pathAbsent
    )
    let receipt = ProviderMutationReceipt(
        id: journalUUID("000000000202"),
        provider: .oneDrive,
        kind: .makeFolder,
        affectedPaths: ["/Pending"],
        startedAt: journalDate
    )
    let runID = journalUUID("000000000203")
    let syncSetID = journalUUID("000000000204")
    try await journal.begin(
        runID: runID,
        syncSetID: syncSetID,
        fingerprint: PlanFingerprint(rawValue: "indeterminate")
    )
    try await journal.append(.intent(operation), runID: runID)
    try await journal.append(
        .mutationIndeterminate(
            operationID: operation.id,
            receipt: receipt,
            occurredAt: journalDate
        ),
        runID: runID
    )
    let replay = try #require(try await journal.unfinishedRun(for: syncSetID))

    await #expect(
        throws: RunRecoveryError.indeterminateMutationStillRunning(
            operationID: operation.id,
            receiptID: receipt.id
        )
    ) {
        _ = try await RunRecovery(
            providers: [.oneDrive: provider],
            stores: stores
        ).recover(replay)
    }

    #expect(try await journal.unfinishedRun(for: syncSetID) != nil)
    #expect(await provider.recoveryProbeCount() == 0)
    #expect(await provider.finishCount() == 0)
}

@Test func recoveryDoesNotClearIndeterminateStateWhenTruthProbeFails() async throws {
    let journal = InMemoryRunJournalStore()
    let stores = recoveryStores(journal: journal)
    let providerError = ProviderError.unavailable(
        provider: .oneDrive,
        reason: "provider offline"
    )
    let provider = ScriptedIndeterminateRecoveryProvider(
        locationID: .oneDrive,
        state: .quiescent(.succeeded),
        recoveryResult: .failure(providerError)
    )
    let operation = Operation(
        id: OperationID(journalUUID("000000000205")),
        location: .oneDrive,
        kind: .makeFolder(at: "/Uncertain"),
        precondition: .pathAbsent
    )
    let receipt = ProviderMutationReceipt(
        id: journalUUID("000000000206"),
        provider: .oneDrive,
        kind: .makeFolder,
        affectedPaths: ["/Uncertain"],
        startedAt: journalDate
    )
    let runID = journalUUID("000000000207")
    let syncSetID = journalUUID("000000000208")
    try await journal.begin(
        runID: runID,
        syncSetID: syncSetID,
        fingerprint: PlanFingerprint(rawValue: "unavailable-recovery")
    )
    try await journal.append(.intent(operation), runID: runID)
    try await journal.append(
        .mutationIndeterminate(
            operationID: operation.id,
            receipt: receipt,
            occurredAt: journalDate
        ),
        runID: runID
    )
    let replay = try #require(try await journal.unfinishedRun(for: syncSetID))

    await #expect(
        throws: RunRecoveryError.providerTruthUnavailable(
            operationID: operation.id,
            detail: String(describing: providerError)
        )
    ) {
        _ = try await RunRecovery(
            providers: [.oneDrive: provider],
            stores: stores
        ).recover(replay)
    }

    #expect(try await journal.unfinishedRun(for: syncSetID) != nil)
    #expect(await provider.recoveryProbeCount() == 1)
    #expect(await provider.finishCount() == 0)
}

@Test func recoveryDoesNotClearPendingIntentWhenProviderTruthIsUnavailable() async throws {
    let journal = InMemoryRunJournalStore()
    let stores = recoveryStores(journal: journal)
    let provider = FakeStorageProvider(locationID: .oneDrive)
    await provider.setAvailability(
        .unavailable(.volumeUnreachable(detail: "provider offline"))
    )
    let operation = Operation(
        id: OperationID(journalUUID("000000000209")),
        location: .oneDrive,
        kind: .makeFolder(at: "/Unknown"),
        precondition: .pathAbsent
    )
    let runID = journalUUID("000000000210")
    let syncSetID = journalUUID("000000000211")
    try await journal.begin(
        runID: runID,
        syncSetID: syncSetID,
        fingerprint: PlanFingerprint(rawValue: "pending-unavailable")
    )
    try await journal.append(.intent(operation), runID: runID)
    let replay = try #require(try await journal.unfinishedRun(for: syncSetID))

    await #expect(throws: RunRecoveryError.self) {
        _ = try await RunRecovery(
            providers: [.oneDrive: provider],
            stores: stores
        ).recover(replay)
    }

    #expect(try await journal.unfinishedRun(for: syncSetID) != nil)
}

@Test(arguments: RelocateRecoveryScenario.allCases)
func relocateRecoveryRequiresTwoEndpointVersionProof(
    scenario: RelocateRecoveryScenario
) async throws {
    let journal = InMemoryRunJournalStore()
    let baseRecords = InMemoryBaseRecordStore()
    let stores = EngineStores(
        baseRecords: baseRecords,
        journal: journal,
        conflicts: InMemoryConflictStore(),
        adviceCache: InMemoryAdviceCacheStore(),
        activity: InMemoryActivityStore(),
        locations: InMemoryLocationRegistry()
    )
    let sourcePath: SyncPath = "/Before.txt"
    let destinationPath: SyncPath = "/After.txt"
    let expectedVersion = ItemVersion(contentHash: "expected-content")
    let expected = ItemObservation(
        location: .oneDrive,
        path: sourcePath,
        kind: .file,
        version: expectedVersion
    )
    let operation = Operation(
        id: OperationID(journalUUID("000000000301")),
        location: .oneDrive,
        kind: .relocate(itemRef: ItemRef(expected), to: destinationPath),
        precondition: .versionMatches(expectedVersion)
    )
    let receipt = ProviderMutationReceipt(
        id: journalUUID("000000000302"),
        provider: .oneDrive,
        kind: .relocate,
        affectedPaths: [sourcePath, destinationPath],
        startedAt: journalDate
    )
    let provider = PathScriptedRelocateRecoveryProvider(
        locationID: .oneDrive,
        results: scenario.results(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            expectedVersion: expectedVersion
        )
    )
    let runID = journalUUID("000000000303")
    let syncSetID = journalUUID("000000000304")
    try await journal.begin(
        runID: runID,
        syncSetID: syncSetID,
        fingerprint: PlanFingerprint(rawValue: "relocate-\(scenario.rawValue)")
    )
    try await journal.append(.intent(operation), runID: runID)
    try await journal.append(
        .mutationIndeterminate(
            operationID: operation.id,
            receipt: receipt,
            occurredAt: journalDate
        ),
        runID: runID
    )
    let replay = try #require(try await journal.unfinishedRun(for: syncSetID))
    let recovery = RunRecovery(
        providers: [.oneDrive: provider],
        stores: stores,
        environment: ExecutionEnvironment(
            now: { journalDate },
            makeID: { journalUUID("000000000305") }
        )
    )

    if scenario.shouldReconcile {
        let report = try await recovery.recover(replay)
        #expect(report.reconciledOperations == [operation.id])
        #expect(await provider.finishCount() == 1)
        let record = try #require(
            try await baseRecords.records(for: syncSetID).first
        )
        #expect(record.path == destinationPath)
        #expect(record.kind == .file)
        #expect(record.version == expectedVersion)
        #expect(try await journal.unfinishedRun(for: syncSetID) == nil)
    } else {
        await #expect(throws: RunRecoveryError.self) {
            _ = try await recovery.recover(replay)
        }
        #expect(await provider.finishCount() == 0)
        #expect(try await baseRecords.records(for: syncSetID) == [])
        #expect(try await journal.unfinishedRun(for: syncSetID) != nil)
    }
    #expect(await provider.probedPaths() == [destinationPath, sourcePath])
}

private func recoveryStores(journal: any RunJournalStore) -> EngineStores {
    EngineStores(
        baseRecords: InMemoryBaseRecordStore(),
        journal: journal,
        conflicts: InMemoryConflictStore(),
        adviceCache: InMemoryAdviceCacheStore(),
        activity: InMemoryActivityStore(),
        locations: InMemoryLocationRegistry()
    )
}

private actor ScriptedIndeterminateRecoveryProvider:
    IndeterminateMutationRecovering
{
    nonisolated let locationID: LocationID
    nonisolated let capabilities = ProviderCapabilities.fullFidelity

    private let scriptedState: ProviderIndeterminateMutationState
    private let recoveryResult: Result<ItemObservation, ProviderError>
    private var probes = 0
    private var finishes = 0

    init(
        locationID: LocationID,
        state: ProviderIndeterminateMutationState,
        recoveryResult: Result<ItemObservation, ProviderError>
    ) {
        self.locationID = locationID
        self.scriptedState = state
        self.recoveryResult = recoveryResult
    }

    func checkAvailability() async -> LocationAvailability { .available }
    func scan(_ scope: SyncScope) async -> LocationSnapshot {
        LocationSnapshot(location: locationID, scope: scope, observations: [], status: .complete)
    }
    func changedSubtrees(in _: SyncScope, since _: ChangeCursor?) async throws -> ChangeHint {
        ChangeHint(changedRoots: [], isComplete: false)
    }
    func fetch(_: ItemObservation, to _: URL) async throws {
        throw ProviderError.unsupported(provider: locationID, reason: "test")
    }
    func store(from _: URL, at path: SyncPath, options _: StoreOptions) async throws -> ItemObservation {
        throw ProviderError.unsupported(provider: locationID, reason: path.rawValue)
    }
    func makeFolder(at path: SyncPath) async throws -> ItemObservation {
        throw ProviderError.unsupported(provider: locationID, reason: path.rawValue)
    }
    func relocate(_ observation: ItemObservation, to _: SyncPath) async throws -> ItemObservation {
        throw ProviderError.unsupported(provider: locationID, reason: observation.path.rawValue)
    }
    func trash(_ observation: ItemObservation) async throws {
        throw ProviderError.unsupported(provider: locationID, reason: observation.path.rawValue)
    }
    func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        throw ProviderError.unavailable(provider: locationID, reason: observation.path.rawValue)
    }
    func indeterminateMutationState(
        for _: ProviderMutationReceipt
    ) async -> ProviderIndeterminateMutationState {
        scriptedState
    }
    func currentStateForRecovery(
        of _: ItemObservation,
        receipt _: ProviderMutationReceipt
    ) async throws -> ItemObservation {
        probes += 1
        return try recoveryResult.get()
    }
    func finishIndeterminateMutationRecovery(for _: ProviderMutationReceipt) async {
        finishes += 1
    }
    func recoveryProbeCount() -> Int { probes }
    func finishCount() -> Int { finishes }
}

enum RelocateRecoveryScenario: String, CaseIterable, Sendable {
    case sameVolumeDestinationOnly
    case crossVolumeSourceTrashed
    case copyBeforeTrashBothPresent
    case unrelatedDestination
    case wrongDestinationKind
    case sourceUnavailable
    case destinationUnavailable
    case insufficientVersionEvidence

    var shouldReconcile: Bool {
        self == .sameVolumeDestinationOnly || self == .crossVolumeSourceTrashed
    }

    func results(
        sourcePath: SyncPath,
        destinationPath: SyncPath,
        expectedVersion: ItemVersion
    ) -> [SyncPath: Result<ItemObservation?, ProviderError>] {
        let source = ItemObservation(
            location: .oneDrive,
            path: sourcePath,
            kind: .file,
            version: expectedVersion
        )
        let destination = ItemObservation(
            location: .oneDrive,
            path: destinationPath,
            kind: .file,
            version: expectedVersion
        )
        switch self {
        case .sameVolumeDestinationOnly:
            return [sourcePath: .success(nil), destinationPath: .success(destination)]
        case .crossVolumeSourceTrashed:
            var trashed = source
            trashed.isTrashed = true
            return [sourcePath: .success(trashed), destinationPath: .success(destination)]
        case .copyBeforeTrashBothPresent:
            return [sourcePath: .success(source), destinationPath: .success(destination)]
        case .unrelatedDestination:
            var unrelated = destination
            unrelated.version = ItemVersion(contentHash: "unrelated")
            return [sourcePath: .success(source), destinationPath: .success(unrelated)]
        case .wrongDestinationKind:
            var folder = destination
            folder.kind = .folder
            return [sourcePath: .success(nil), destinationPath: .success(folder)]
        case .sourceUnavailable:
            return [
                sourcePath: .failure(
                    .unavailable(provider: .oneDrive, reason: "source unavailable")
                ),
                destinationPath: .success(destination),
            ]
        case .destinationUnavailable:
            return [
                sourcePath: .success(source),
                destinationPath: .failure(
                    .unavailable(provider: .oneDrive, reason: "destination unavailable")
                ),
            ]
        case .insufficientVersionEvidence:
            var unknown = destination
            unknown.version = ItemVersion()
            return [sourcePath: .success(nil), destinationPath: .success(unknown)]
        }
    }
}

private actor PathScriptedRelocateRecoveryProvider:
    IndeterminateMutationRecovering
{
    nonisolated let locationID: LocationID
    nonisolated let capabilities = ProviderCapabilities.fullFidelity

    private let results: [SyncPath: Result<ItemObservation?, ProviderError>]
    private var probes: [SyncPath] = []
    private var finishes = 0

    init(
        locationID: LocationID,
        results: [SyncPath: Result<ItemObservation?, ProviderError>]
    ) {
        self.locationID = locationID
        self.results = results
    }

    func checkAvailability() async -> LocationAvailability { .available }
    func scan(_ scope: SyncScope) async -> LocationSnapshot {
        LocationSnapshot(
            location: locationID,
            scope: scope,
            observations: [],
            status: .complete
        )
    }
    func changedSubtrees(in _: SyncScope, since _: ChangeCursor?) async throws -> ChangeHint {
        ChangeHint(changedRoots: [], isComplete: false)
    }
    func fetch(_: ItemObservation, to _: URL) async throws {
        throw ProviderError.unsupported(provider: locationID, reason: "test")
    }
    func store(
        from _: URL,
        at path: SyncPath,
        options _: StoreOptions
    ) async throws -> ItemObservation {
        throw ProviderError.unsupported(provider: locationID, reason: path.rawValue)
    }
    func makeFolder(at path: SyncPath) async throws -> ItemObservation {
        throw ProviderError.unsupported(provider: locationID, reason: path.rawValue)
    }
    func relocate(
        _ observation: ItemObservation,
        to _: SyncPath
    ) async throws -> ItemObservation {
        throw ProviderError.unsupported(
            provider: locationID,
            reason: observation.path.rawValue
        )
    }
    func trash(_ observation: ItemObservation) async throws {
        throw ProviderError.unsupported(
            provider: locationID,
            reason: observation.path.rawValue
        )
    }
    func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        throw ProviderError.unavailable(
            provider: locationID,
            reason: observation.path.rawValue
        )
    }
    func indeterminateMutationState(
        for _: ProviderMutationReceipt
    ) async -> ProviderIndeterminateMutationState {
        .quiescent(.succeeded)
    }
    func currentStateForRecovery(
        of observation: ItemObservation,
        receipt _: ProviderMutationReceipt
    ) async throws -> ItemObservation {
        probes.append(observation.path)
        guard let result = results[observation.path] else {
            throw ProviderError.notFound(
                provider: locationID,
                path: observation.path
            )
        }
        guard let current = try result.get() else {
            throw ProviderError.notFound(
                provider: locationID,
                path: observation.path
            )
        }
        return current
    }
    func finishIndeterminateMutationRecovery(for _: ProviderMutationReceipt) async {
        finishes += 1
    }
    func probedPaths() -> [SyncPath] { probes }
    func finishCount() -> Int { finishes }
}

private func journalUUID(_ suffix: String) -> UUID {
    UUID(uuidString: "93000000-0000-0000-0000-\(suffix)")!
}

private let journalDate = Date(timeIntervalSince1970: 1_770_000_000)
