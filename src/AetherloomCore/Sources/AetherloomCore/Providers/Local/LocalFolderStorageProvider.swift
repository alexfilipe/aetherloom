import Foundation

public actor LocalFolderStorageProvider: IndeterminateMutationRecovering {
    public static let expectedVolumeIdentityConfigurationKey = "expectedVolumeIdentity"

    /// Records the persistent volume UUID at enrollment time. The returned
    /// location must be saved by the caller before constructing a provider;
    /// `make` never adopts an identity from whichever volume happens to be
    /// mounted later at the same path.
    public static func locationByRecordingVolumeIdentity(
        _ location: SyncLocation,
        rootURL: URL,
        volumes: any VolumeInspecting = SystemVolumeInspector(),
        deadlines: ProviderDeadlines = ProviderDeadlines()
    ) async throws -> SyncLocation {
        let identityResult = await withProviderDeadline(
            nanoseconds: deadlines.probeNanoseconds,
            clock: deadlines.clock
        ) {
            await volumes.volumeIdentity(for: rootURL)
        }
        let identity: String
        switch identityResult {
        case let .value(value?):
            identity = value
        case .value(nil):
            throw ProviderError.unsupported(
                provider: location.id,
                reason: "The selected volume does not provide a persistent identity and cannot be enrolled safely."
            )
        case .timedOut:
            throw ProviderError.unavailable(
                provider: location.id,
                reason: "Volume identity inspection timed out."
            )
        }
        var configured = location
        configured.configuration[expectedVolumeIdentityConfigurationKey] = identity
        return configured
    }

    public nonisolated let locationID: LocationID
    public nonisolated let capabilities: ProviderCapabilities

    private let rootURL: URL
    private let volumes: any VolumeInspecting
    private let expectedVolumeIdentity: String?
    private let deadlines: ProviderDeadlines
    private let fetching: any LocalFetchPerforming
    private let nativeTrash: any LocalNativeTrashPerforming
    private let relocation: any LocalRelocationPerforming
    private let quarantine: any LocalQuarantinePerforming
    private let mutationHook: any LocalMutationStarting
    private let trashReceiptPersistence: any LocalTrashReceiptPersisting
    private let mutations: LocalMutationCoordinator
    private let mutationArtifacts: LocalMutationArtifacts
    private let ownedCanonicalRootURL: URL?
    private let rootOwnershipIssue: String?
    private let quarantineTimestamp: String

    public static func make(
        location: SyncLocation,
        rootURL: URL,
        volumes: any VolumeInspecting = SystemVolumeInspector(),
        deadlines: ProviderDeadlines = ProviderDeadlines()
    ) async -> LocalFolderStorageProvider {
        let expectedVolumeIdentity = location.configuration[
            expectedVolumeIdentityConfigurationKey
        ]
        let ownership = await rootOwnership(
            rootURL: rootURL,
            expectedVolumeIdentity: expectedVolumeIdentity,
            registry: .shared
        )
        let properties = await ownedProperties(
            rootURL: rootURL,
            volumes: volumes,
            deadlines: deadlines,
            ownership: ownership
        )
        let isNAS = location.kind == .nasFolder
        let capabilities = ProviderCapabilities(
            hasNativeTrash: isNAS ? false : properties?.supportsNativeTrash ?? false,
            hasStableItemIDs: false,
            hasContentHashes: false,
            hasChangeHints: false,
            supportsVersionCheckedStore: false,
            isCaseSensitive: isNAS ? nil : properties?.isCaseSensitive
        )
        return LocalFolderStorageProvider(
            location: location,
            rootURL: rootURL,
            volumes: volumes,
            expectedVolumeIdentity: expectedVolumeIdentity,
            deadlines: deadlines,
            capabilities: capabilities,
            fetching: SystemLocalFetchPerformer(),
            nativeTrash: SystemLocalNativeTrashPerformer(),
            relocation: SystemLocalRelocationPerformer(),
            quarantine: SystemLocalQuarantinePerformer(),
            mutationHook: NoOpLocalMutationHook(),
            trashReceiptPersistence: AtomicLocalTrashReceiptPersister(),
            ownership: ownership
        )
    }

    static func make(
        location: SyncLocation,
        rootURL: URL,
        volumes: any VolumeInspecting,
        deadlines: ProviderDeadlines = ProviderDeadlines(),
        fetching: any LocalFetchPerforming = SystemLocalFetchPerformer(),
        nativeTrash: any LocalNativeTrashPerforming = SystemLocalNativeTrashPerformer(),
        relocation: any LocalRelocationPerforming = SystemLocalRelocationPerformer(),
        quarantine: any LocalQuarantinePerforming = SystemLocalQuarantinePerformer(),
        mutationHook: any LocalMutationStarting = NoOpLocalMutationHook(),
        trashReceiptPersistence: any LocalTrashReceiptPersisting = AtomicLocalTrashReceiptPersister(),
        registry: LocalRootIORegistry = .shared
    ) async -> LocalFolderStorageProvider {
        let expectedVolumeIdentity = location.configuration[
            expectedVolumeIdentityConfigurationKey
        ]
        let ownership = await rootOwnership(
            rootURL: rootURL,
            expectedVolumeIdentity: expectedVolumeIdentity,
            registry: registry
        )
        let properties = await ownedProperties(
            rootURL: rootURL,
            volumes: volumes,
            deadlines: deadlines,
            ownership: ownership
        )
        let isNAS = location.kind == .nasFolder
        return LocalFolderStorageProvider(
            location: location,
            rootURL: rootURL,
            volumes: volumes,
            expectedVolumeIdentity: expectedVolumeIdentity,
            deadlines: deadlines,
            capabilities: ProviderCapabilities(
                hasNativeTrash: isNAS ? false : properties?.supportsNativeTrash ?? false,
                hasStableItemIDs: false,
                hasContentHashes: false,
                hasChangeHints: false,
                supportsVersionCheckedStore: false,
                isCaseSensitive: isNAS ? nil : properties?.isCaseSensitive
            ),
            fetching: fetching,
            nativeTrash: nativeTrash,
            relocation: relocation,
            quarantine: quarantine,
            mutationHook: mutationHook,
            trashReceiptPersistence: trashReceiptPersistence,
            ownership: ownership
        )
    }

    private static func rootOwnership(
        rootURL: URL,
        expectedVolumeIdentity: String?,
        registry: LocalRootIORegistry
    ) async -> LocalRootOwnership {
        let configuredRootPath = rootURL.standardizedFileURL.path
        let resolvedCanonicalRootPath = resolvedExistingRootPath(rootURL)
        return await registry.ownership(
            configuredRootPath: configuredRootPath,
            resolvedCanonicalRootPath: resolvedCanonicalRootPath,
            expectedVolumeIdentity: expectedVolumeIdentity,
            unresolvedCanonicalRootPathHint: resolvedCanonicalRootPath == nil
                ? unresolvedRootPathHint(rootURL)
                : nil
        )
    }

    private static func ownedProperties(
        rootURL: URL,
        volumes: any VolumeInspecting,
        deadlines: ProviderDeadlines,
        ownership: LocalRootOwnership
    ) async -> VolumeProperties? {
        guard ownership.admissionIssue == nil else { return nil }
        let result: LocalOwnedReadResult<VolumeProperties?> = await ownership
            .mutations.performRead(
                nanoseconds: deadlines.probeNanoseconds,
                clock: deadlines.clock
            ) {
                guard let canonicalRootPath = ownership.canonicalRootPath,
                      resolvedExistingRootPath(rootURL) == canonicalRootPath else {
                    return nil
                }
                return await volumes.properties(for: rootURL)
            }
        switch result {
        case let .completed(properties):
            return properties
        case .blocked, .timedOut, .cancelled:
            return nil
        }
    }

    private init(
        location: SyncLocation,
        rootURL: URL,
        volumes: any VolumeInspecting,
        expectedVolumeIdentity: String?,
        deadlines: ProviderDeadlines,
        capabilities: ProviderCapabilities,
        fetching: any LocalFetchPerforming,
        nativeTrash: any LocalNativeTrashPerforming,
        relocation: any LocalRelocationPerforming,
        quarantine: any LocalQuarantinePerforming,
        mutationHook: any LocalMutationStarting,
        trashReceiptPersistence: any LocalTrashReceiptPersisting,
        ownership: LocalRootOwnership
    ) {
        self.locationID = location.id
        self.capabilities = capabilities
        self.rootURL = rootURL
        self.volumes = volumes
        self.expectedVolumeIdentity = expectedVolumeIdentity
        self.deadlines = deadlines
        self.fetching = fetching
        self.nativeTrash = nativeTrash
        self.relocation = relocation
        self.quarantine = quarantine
        self.mutationHook = mutationHook
        self.trashReceiptPersistence = trashReceiptPersistence
        self.mutations = ownership.mutations
        self.mutationArtifacts = ownership.artifacts
        self.ownedCanonicalRootURL = ownership.canonicalRootPath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        self.rootOwnershipIssue = ownership.admissionIssue
        self.quarantineTimestamp = Self.timestampString(for: deadlines.now())
    }

    public func checkAvailability() async -> LocationAvailability {
        if let rootOwnershipIssue {
            return .unavailable(.unknown(detail: rootOwnershipIssue))
        }
        let context = readContext()
        let result = await mutations.performRead(
            nanoseconds: deadlines.probeNanoseconds,
            clock: deadlines.clock
        ) {
            await context.checkAvailability()
        }
        switch result {
        case let .completed(availability):
            return availability
        case let .blocked(receipt):
            return .unavailable(
                .unknown(
                    detail: receipt.map {
                        "Filesystem mutation \($0.id.uuidString) is still awaiting reconciliation."
                    } ?? "Filesystem recovery is still in progress."
                )
            )
        case .timedOut:
            return .unavailable(
                .volumeUnreachable(detail: "Filesystem availability inspection timed out.")
            )
        case .cancelled:
            return .unavailable(
                .unknown(detail: "Filesystem availability inspection was cancelled.")
            )
        }
    }

    public func scan(_ scope: SyncScope) async -> LocationSnapshot {
        if let rootOwnershipIssue {
            return snapshot(
                scope: scope,
                status: .unavailable(
                    reason: .unknown(detail: rootOwnershipIssue)
                )
            )
        }
        let context = readContext()
        let result = await mutations.performRead(
            nanoseconds: deadlines.scanNanoseconds,
            clock: deadlines.clock
        ) {
            await context.scan(scope)
        }
        switch result {
        case let .completed(snapshot):
            return snapshot
        case let .blocked(receipt):
            return snapshot(
                scope: scope,
                status: .unavailable(
                    reason: .unknown(
                        detail: receipt.map {
                            "Filesystem mutation \($0.id.uuidString) is still awaiting reconciliation."
                        } ?? "Filesystem recovery is still in progress."
                    )
                )
            )
        case .timedOut:
            return snapshot(
                scope: scope,
                status: .incomplete(reason: "Filesystem scan timed out.")
            )
        case .cancelled:
            return snapshot(
                scope: scope,
                status: .incomplete(reason: "Filesystem scan was cancelled.")
            )
        }
    }

    public func changedSubtrees(
        in _: SyncScope,
        since _: ChangeCursor?
    ) async throws -> ChangeHint {
        ChangeHint(changedRoots: [], nextCursor: nil, isComplete: false)
    }

    public func fetch(_ observation: ItemObservation, to stagingURL: URL) async throws {
        try requireRootOwnership(for: observation.path)
        if observation.isPlaceholder {
            throw ProviderError.placeholderOnly(provider: locationID, path: observation.path)
        }
        let receipt = mutationReceipt(kind: .fetch, paths: [observation.path])
        let context = mutationContext()
        let result: LocalMutationDeadlineResult<Void> = await mutations.perform(
            receipt: receipt,
            expectedVolumeIdentity: expectedVolumeIdentity,
            nanoseconds: deadlines.ioNanoseconds,
            clock: deadlines.clock,
            startedAt: deadlines.now
        ) { startedReceipt in
            await context.fetch(
                observation,
                to: stagingURL,
                receipt: startedReceipt
            )
        }
        _ = try await resolveMutation(result, path: observation.path)
    }

    public func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        try requireRootOwnership(for: observation.path)
        let context = readContext()
        let result = await mutations.performRead(
            nanoseconds: deadlines.probeNanoseconds,
            clock: deadlines.clock
        ) {
            await context.currentState(of: observation)
        }
        switch result {
        case let .completed(.success(current)):
            return current
        case let .completed(.failure(error)):
            throw error
        case let .blocked(receipt):
            throw ProviderError.unavailable(
                provider: locationID,
                reason: receipt.map {
                    "Filesystem mutation \($0.id.uuidString) is still awaiting reconciliation."
                } ?? "Filesystem recovery is still in progress."
            )
        case .timedOut:
            throw ProviderError.unavailable(
                provider: locationID,
                reason: "Filesystem metadata read timed out."
            )
        case .cancelled:
            throw ProviderError.unavailable(
                provider: locationID,
                reason: "Filesystem metadata read was cancelled."
            )
        }
    }

    public func store(
        from stagingURL: URL,
        at path: SyncPath,
        options: StoreOptions
    ) async throws -> ItemObservation {
        try requireRootOwnership(for: path)
        let receipt = mutationReceipt(kind: .store, paths: [path])
        let context = mutationContext()
        return try await resolveMutation(
            await mutations.perform(
                receipt: receipt,
                expectedVolumeIdentity: expectedVolumeIdentity,
                nanoseconds: deadlines.ioNanoseconds,
                clock: deadlines.clock,
                startedAt: deadlines.now
            ) { startedReceipt in
                await context.store(
                    from: stagingURL,
                    at: path,
                    options: options,
                    receipt: startedReceipt
                )
            },
            path: path
        )
    }

    public func makeFolder(at path: SyncPath) async throws -> ItemObservation {
        try requireRootOwnership(for: path)
        let receipt = mutationReceipt(kind: .makeFolder, paths: [path])
        let context = mutationContext()
        return try await resolveMutation(
            await mutations.perform(
                receipt: receipt,
                expectedVolumeIdentity: expectedVolumeIdentity,
                nanoseconds: deadlines.ioNanoseconds,
                clock: deadlines.clock,
                startedAt: deadlines.now
            ) { startedReceipt in
                await context.makeFolder(at: path, receipt: startedReceipt)
            },
            path: path
        )
    }

    public func relocate(
        _ observation: ItemObservation,
        to newPath: SyncPath
    ) async throws -> ItemObservation {
        try requireRootOwnership(for: observation.path)
        let receipt = mutationReceipt(
            kind: .relocate,
            paths: [observation.path, newPath]
        )
        let context = mutationContext()
        return try await resolveMutation(
            await mutations.perform(
                receipt: receipt,
                expectedVolumeIdentity: expectedVolumeIdentity,
                nanoseconds: deadlines.ioNanoseconds,
                clock: deadlines.clock,
                startedAt: deadlines.now
            ) { startedReceipt in
                await context.relocate(
                    observation,
                    to: newPath,
                    receipt: startedReceipt
                )
            },
            path: newPath
        )
    }

    public func trash(_ observation: ItemObservation) async throws {
        try requireRootOwnership(for: observation.path)
        let receipt = mutationReceipt(kind: .trash, paths: [observation.path])
        let context = mutationContext()
        let result: LocalMutationDeadlineResult<Void> = await mutations.perform(
            receipt: receipt,
            expectedVolumeIdentity: expectedVolumeIdentity,
            nanoseconds: deadlines.ioNanoseconds,
            clock: deadlines.clock,
            startedAt: deadlines.now
        ) { startedReceipt in
            await context.trash(observation, receipt: startedReceipt)
        }
        _ = try await resolveMutation(result, path: observation.path)
    }

    func recoveryURL(for path: SyncPath) async -> URL? {
        await mutationArtifacts.recoveryURL(for: path)
    }

    public func indeterminateMutationState(
        for receipt: ProviderMutationReceipt
    ) async -> ProviderIndeterminateMutationState {
        guard rootOwnershipIssue == nil,
              receipt.provider == locationID,
              receiptBelongsToOwnedRoot(receipt) else {
            return .inFlight
        }
        return await mutations.state(for: receipt)
    }

    public func beginIndeterminateMutationRecovery(
        for receipt: ProviderMutationReceipt
    ) async -> ProviderMutationRecoveryClaimResult {
        guard rootOwnershipIssue == nil,
              receipt.provider == locationID else {
            return .inFlight
        }
        guard receiptBelongsToOwnedRoot(receipt),
              await currentRootMatchesOwnedIdentity() else {
            await mutations.retainUnclaimableRecoveryBarrier(
                for: receipt,
                expectedVolumeIdentity: expectedVolumeIdentity
            )
            return .inFlight
        }
        return await mutations.beginRecovery(
            for: receipt,
            expectedVolumeIdentity: expectedVolumeIdentity
        )
    }

    public func indeterminateMutationReceipt() async -> ProviderMutationReceipt? {
        guard rootOwnershipIssue == nil else { return nil }
        guard let receipt = await mutations.indeterminateReceipt(),
              receipt.provider == locationID,
              receiptBelongsToOwnedRoot(receipt) else {
            return nil
        }
        return receipt
    }

    public func currentStateForRecovery(
        of observation: ItemObservation,
        claim: ProviderMutationRecoveryClaim
    ) async throws -> ItemObservation {
        try requireRootOwnership(for: observation.path)
        guard receiptBelongsToOwnedRoot(claim.receipt),
              await currentRootMatchesOwnedIdentity() else {
            throw ProviderError.unavailable(
                provider: locationID,
                reason: "The recovery receipt does not belong to the current physical root."
            )
        }
        let context = readContext()
        let result = await mutations.performRecoveryRead(
            claim: claim,
            nanoseconds: deadlines.probeNanoseconds,
            clock: deadlines.clock
        ) {
            await context.currentState(of: observation)
        }
        switch result {
        case let .completed(.success(current)):
            return current
        case let .completed(.failure(error)):
            throw error
        case let .blocked(blockingReceipt):
            throw ProviderError.unavailable(
                provider: locationID,
                reason: blockingReceipt.map {
                    "Filesystem mutation \($0.id.uuidString) prevents this recovery probe."
                } ?? "A filesystem read or recovery owner prevents this recovery probe."
            )
        case .timedOut:
            throw ProviderError.unavailable(
                provider: locationID,
                reason: "Filesystem recovery probe timed out."
            )
        case .cancelled:
            throw ProviderError.unavailable(
                provider: locationID,
                reason: "Filesystem recovery probe was cancelled."
            )
        }
    }

    public func canPerformRecoveryRead(
        with claim: ProviderMutationRecoveryClaim
    ) async -> Bool {
        guard rootOwnershipIssue == nil,
              receiptBelongsToOwnedRoot(claim.receipt),
              await currentRootMatchesOwnedIdentity() else {
            return false
        }
        return await mutations.ownsRecoveryClaim(
            claim,
            expectedVolumeIdentity: expectedVolumeIdentity
        )
    }

    public func finishIndeterminateMutationRecovery(
        _ claim: ProviderMutationRecoveryClaim
    ) async {
        guard rootOwnershipIssue == nil,
              claim.receipt.provider == locationID,
              receiptBelongsToOwnedRoot(claim.receipt),
              await currentRootMatchesOwnedIdentity() else {
            return
        }
        await mutations.finishRecovery(claim)
    }

    public func abandonIndeterminateMutationRecovery(
        _ claim: ProviderMutationRecoveryClaim
    ) async {
        guard rootOwnershipIssue == nil,
              claim.receipt.provider == locationID,
              receiptBelongsToOwnedRoot(claim.receipt) else {
            return
        }
        await mutations.abandonRecovery(claim)
    }

    private func requireRootOwnership(for _: SyncPath) throws {
        if let rootOwnershipIssue {
            throw ProviderError.unavailable(
                provider: locationID,
                reason: rootOwnershipIssue
            )
        }
        guard ownedRootIdentity != nil else {
            throw ProviderError.unavailable(
                provider: locationID,
                reason: "The physical root identity is unavailable."
            )
        }
    }

    private func mutationReceipt(
        kind: ProviderMutationKind,
        paths: [SyncPath]
    ) -> ProviderMutationReceipt {
        ProviderMutationReceipt(
            id: deadlines.makeMutationID(),
            provider: locationID,
            kind: kind,
            affectedPaths: paths,
            startedAt: deadlines.now(),
            correlation: ProviderMutationExecutionContext.correlation,
            rootIdentity: ownedRootIdentity
        )
    }

    private var ownedRootIdentity: ProviderMutationRootIdentity? {
        guard let canonicalRootPath = ownedCanonicalRootURL?
            .standardizedFileURL.path,
              let expectedVolumeIdentity else {
            return nil
        }
        return ProviderMutationRootIdentity(
            canonicalRootPath: canonicalRootPath,
            volumeIdentity: expectedVolumeIdentity
        )
    }

    private func receiptBelongsToOwnedRoot(
        _ receipt: ProviderMutationReceipt
    ) -> Bool {
        guard let ownedRootIdentity else { return false }
        return receipt.rootIdentity == ownedRootIdentity
    }

    private func currentRootMatchesOwnedIdentity() async -> Bool {
        guard let ownedRootIdentity,
              Self.resolvedExistingRootPath(rootURL)
                == ownedRootIdentity.canonicalRootPath else {
            return false
        }
        let currentVolumeIdentity = await volumes.volumeIdentity(for: rootURL)
        guard currentVolumeIdentity == ownedRootIdentity.volumeIdentity else {
            return false
        }
        return Self.resolvedExistingRootPath(rootURL)
            == ownedRootIdentity.canonicalRootPath
    }

    private func mutationContext() -> MutationContext {
        MutationContext(
            locationID: locationID,
            capabilities: capabilities,
            rootURL: rootURL,
            ownedCanonicalRootURL: ownedCanonicalRootURL,
            volumes: volumes,
            expectedVolumeIdentity: expectedVolumeIdentity,
            deadlines: deadlines,
            fetching: fetching,
            nativeTrash: nativeTrash,
            relocation: relocation,
            quarantine: quarantine,
            hook: mutationHook,
            trashReceiptPersistence: trashReceiptPersistence,
            artifacts: mutationArtifacts,
            quarantineTimestamp: quarantineTimestamp
        )
    }

    private func readContext() -> ReadContext {
        ReadContext(
            locationID: locationID,
            capabilities: capabilities,
            rootURL: rootURL,
            ownedCanonicalRootURL: ownedCanonicalRootURL,
            volumes: volumes,
            expectedVolumeIdentity: expectedVolumeIdentity,
            nativeTrash: nativeTrash,
            quarantine: quarantine
        )
    }

    private func resolveMutation<Value: Sendable>(
        _ result: LocalMutationDeadlineResult<Value>,
        path: SyncPath
    ) async throws -> Value {
        switch result {
        case let .completed(.success(value)):
            return value
        case let .completed(.failure(error)):
            throw error
        case .deadlineExpiredBeforeStart:
            throw ProviderError.mutationDeadlineExpiredBeforeStart(
                provider: locationID,
                path: path
            )
        case let .indeterminate(receipt):
            throw ProviderError.mutationIndeterminate(receipt)
        }
    }

    private static func filesHaveEqualBytes(_ first: URL, _ second: URL) throws -> Bool {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        let firstValues = try first.resourceValues(forKeys: keys)
        let secondValues = try second.resourceValues(forKeys: keys)
        guard firstValues.isRegularFile == true,
              secondValues.isRegularFile == true,
              firstValues.fileSize == secondValues.fileSize else {
            return false
        }
        let firstHandle = try FileHandle(forReadingFrom: first)
        let secondHandle = try FileHandle(forReadingFrom: second)
        defer {
            try? firstHandle.close()
            try? secondHandle.close()
        }
        let chunkSize = 1_048_576
        while true {
            let firstChunk: Data
            let secondChunk: Data
            if #available(macOS 10.15.4, *) {
                firstChunk = try firstHandle.read(upToCount: chunkSize) ?? Data()
                secondChunk = try secondHandle.read(upToCount: chunkSize) ?? Data()
            } else {
                firstChunk = firstHandle.readData(ofLength: chunkSize)
                secondChunk = secondHandle.readData(ofLength: chunkSize)
            }
            guard firstChunk == secondChunk else { return false }
            if firstChunk.isEmpty {
                return true
            }
        }
    }

    private static func recoveredTrashObservation(
        receipt: LocalTrashReceipt,
        expected: ItemObservation,
        locationID: LocationID,
        canonicalRoot: URL,
        nativeTrash: any LocalNativeTrashPerforming,
        quarantine: any LocalQuarantinePerforming
    ) throws -> ItemObservation? {
        func unavailable(_ detail: String) -> ProviderError {
            .unavailable(provider: locationID, reason: detail)
        }

        guard receipt.committedAt != nil || receipt.isLegacy else {
            throw unavailable(
                "Trash outcome is prepared but lacks committed recoverable-trash proof."
            )
        }
        guard let recoveryPath = receipt.recoveryPath else {
            if receipt.isLegacy {
                throw unavailable(
                    "Legacy trash evidence has no exact recoverable artifact path."
                )
            }
            return nil
        }

        let recoveryURL = URL(fileURLWithPath: recoveryPath)
        if receipt.method == .quarantine {
            let trashRoot = canonicalRoot
                .appendingPathComponent(".aetherloom", isDirectory: true)
                .appendingPathComponent("trash", isDirectory: true)
            guard let checked = canonicalizingExistingAncestors(recoveryURL),
                  contains(checked, in: trashRoot) else {
                if receipt.isLegacy {
                    throw unavailable(
                        "Legacy quarantine evidence is not bound to the owned trash root."
                    )
                }
                return nil
            }
        }

        let artifactState: LocalRecoveryArtifactState
        switch receipt.method {
        case .nativeTrash:
            artifactState = nativeTrash.artifactState(at: recoveryURL)
        case .quarantine:
            artifactState = quarantine.artifactState(at: recoveryURL)
        }
        switch artifactState {
        case .present:
            break
        case .missing:
            if receipt.isLegacy {
                throw unavailable(
                    "Legacy trash artifact is missing and cannot authorize recovery."
                )
            }
            return nil
        case let .unavailable(detail):
            throw unavailable(
                "Recoverable trash artifact could not be inspected: \(detail)"
            )
        }

        let recovered: ItemObservation
        do {
            recovered = try observation(
                locationID: locationID,
                url: recoveryURL,
                path: expected.path
            )
        } catch {
            throw unavailable(
                "Recoverable trash artifact metadata could not be inspected."
            )
        }
        guard recovered.kind == receipt.observation.kind,
              recovered.version.isSameVersion(as: receipt.observation.version)
        else {
            if receipt.isLegacy {
                throw unavailable(
                    "Legacy trash artifact does not match the intended item."
                )
            }
            return nil
        }

        var result = receipt.observation
        result.isTrashed = true
        return result
    }

    private static func equivalentTrees(_ source: URL, _ destination: URL) throws -> Bool {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        let sourceValues = try source.resourceValues(forKeys: keys)
        let destinationValues = try destination.resourceValues(forKeys: keys)
        if sourceValues.isSymbolicLink == true
            || destinationValues.isSymbolicLink == true {
            guard sourceValues.isSymbolicLink == destinationValues.isSymbolicLink else {
                return false
            }
            return try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
                == FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
        }
        if sourceValues.isDirectory == true
            || destinationValues.isDirectory == true {
            guard sourceValues.isDirectory == destinationValues.isDirectory else {
                return false
            }
            let sourceNames = try FileManager.default.contentsOfDirectory(
                atPath: source.path
            ).sorted()
            let destinationNames = try FileManager.default.contentsOfDirectory(
                atPath: destination.path
            ).sorted()
            guard sourceNames == destinationNames else { return false }
            for name in sourceNames {
                guard try equivalentTrees(
                    source.appendingPathComponent(name),
                    destination.appendingPathComponent(name)
                ) else {
                    return false
                }
            }
            return true
        }
        guard sourceValues.isRegularFile == true,
              destinationValues.isRegularFile == true,
              sourceValues.fileSize == destinationValues.fileSize else {
            return false
        }
        return try Data(contentsOf: source) == Data(contentsOf: destination)
    }

    private func snapshot(
        scope: SyncScope,
        status: ScanStatus
    ) -> LocationSnapshot {
        LocationSnapshot(
            location: locationID,
            scope: scope,
            observations: [],
            status: status
        )
    }

    private static func enumerate(
        locationID: LocationID,
        rootURL: URL,
        rootPath: SyncPath,
        isCaseSensitive: Bool?
    ) -> LocalScanResult {
        let canonicalPath = try? rootURL.resourceValues(
            forKeys: [.canonicalPathKey]
        ).canonicalPath
        let enumerationRoot = canonicalPath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? rootURL
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isSymbolicLinkKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        var errors: [String] = []
        guard let enumerator = FileManager.default.enumerator(
            at: enumerationRoot,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                errors.append("\(url.path): \(error)")
                return true
            }
        ) else {
            return LocalScanResult(
                observations: [],
                errors: ["Could not enumerate \(enumerationRoot.path)."]
            )
        }

        var observations: [ItemObservation] = []
        for case let url as URL in enumerator {
            guard let path = observedPath(
                for: url,
                under: enumerationRoot,
                rootPath: rootPath
            ) else {
                errors.append("Could not resolve observed path \(url.path).")
                continue
            }
            if isInternal(path, isCaseSensitive: isCaseSensitive) {
                enumerator.skipDescendants()
                continue
            }
            do {
                observations.append(
                    try observation(locationID: locationID, url: url, path: path)
                )
            } catch {
                errors.append("\(url.path): \(error)")
            }
        }
        return LocalScanResult(
            observations: observations.sorted { $0.path < $1.path },
            errors: errors
        )
    }

    private static func observation(
        locationID: LocationID,
        url: URL,
        path: SyncPath
    ) throws -> ItemObservation {
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let values = try freshURL.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .isSymbolicLinkKey,
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
            ]
        )
        let kind: ItemKind
        if values.isSymbolicLink == true {
            kind = .symlink(
                target: try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            )
        } else if values.isDirectory == true {
            kind = .folder
        } else {
            kind = .file
        }
        let isPlaceholder = values.isUbiquitousItem == true
            && values.ubiquitousItemDownloadingStatus == .notDownloaded
        let revisionToken: String?
        switch kind {
        case let .symlink(target):
            revisionToken = "local-symlink-" + CanonicalCoding.sha256Hex(target)
        case .file, .folder:
            revisionToken = nil
        }
        return ItemObservation(
            location: locationID,
            itemID: nil,
            path: path,
            kind: kind,
            version: ItemVersion(
                size: values.fileSize.map(Int64.init),
                modifiedAt: canonicalModifiedAt(values.contentModificationDate),
                revisionToken: revisionToken
            ),
            isPlaceholder: isPlaceholder,
            isTrashed: false
        )
    }

    private static func canonicalModifiedAt(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private static func observedPath(
        for url: URL,
        under rootURL: URL,
        rootPath: SyncPath
    ) -> SyncPath? {
        let base = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard url.path.hasPrefix(base) else { return nil }
        let relative = String(url.path.dropFirst(base.count))
        guard !relative.isEmpty else { return rootPath }
        return relative.split(separator: "/", omittingEmptySubsequences: true)
            .reduce(rootPath) { $0.appending(String($1)) }
    }

    private static func isInternal(
        _ path: SyncPath,
        isCaseSensitive: Bool?
    ) -> Bool {
        guard let first = path.components.first else { return false }
        if isCaseSensitive == true {
            return first == ".aetherloom"
        }
        return first.caseInsensitiveCompare(".aetherloom") == .orderedSame
    }

    private static func canonicalizingExistingAncestors(_ url: URL) -> URL? {
        var candidate = url
        var missingComponents: [String] = []

        while !FileManager.default.fileExists(atPath: candidate.path) {
            guard candidate.path != "/" else { return nil }
            missingComponents.insert(candidate.lastPathComponent, at: 0)
            candidate.deleteLastPathComponent()
        }
        return missingComponents.reduce(
            candidate.resolvingSymlinksInPath().standardizedFileURL
        ) {
            $0.appendingPathComponent($1)
        }
    }

    private static func resolvedExistingRootPath(_ url: URL) -> String? {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return nil
        }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func unresolvedRootPathHint(_ url: URL) -> String? {
        if let target = try? FileManager.default.destinationOfSymbolicLink(
            atPath: url.path
        ) {
            let destination: URL
            if target.hasPrefix("/") {
                destination = URL(fileURLWithPath: target, isDirectory: true)
            } else {
                destination = url.deletingLastPathComponent()
                    .appendingPathComponent(target, isDirectory: true)
            }
            return canonicalizingExistingAncestors(destination)?
                .standardizedFileURL.path
        }
        return canonicalizingExistingAncestors(url)?.standardizedFileURL.path
    }

    static func contains(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if rootPath == "/" {
            return path.hasPrefix("/")
        }
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func timestampString(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }

    /// Immutable, Sendable read surface used inside coordinator-owned detached
    /// tasks. Keeping the complete compound read here ensures a caller timeout
    /// cannot free the root lease while Foundation is still producing truth.
    private struct ReadContext: Sendable {
        let locationID: LocationID
        let capabilities: ProviderCapabilities
        let rootURL: URL
        let ownedCanonicalRootURL: URL?
        let volumes: any VolumeInspecting
        let expectedVolumeIdentity: String?
        let nativeTrash: any LocalNativeTrashPerforming
        let quarantine: any LocalQuarantinePerforming

        func checkAvailability() async -> LocationAvailability {
            guard currentOwnedCanonicalRoot() != nil else {
                return .unavailable(
                    .unknown(
                        detail: "The configured local root no longer resolves to its enrolled directory."
                    )
                )
            }
            switch await volumes.mountState(for: rootURL) {
            case let .notMounted(detail):
                return .unavailable(.volumeNotMounted(detail: detail))
            case let .indeterminate(detail):
                return .unavailable(.unknown(detail: detail))
            case .mounted:
                break
            }

            if let unavailable = await exactRootIdentityUnavailability() {
                return .unavailable(unavailable)
            }

            switch await volumes.responsiveness(for: rootURL) {
            case let .unreachable(detail):
                return .unavailable(.volumeUnreachable(detail: detail))
            case .responsive:
                break
            }

            if let unavailable = await exactRootIdentityUnavailability() {
                return .unavailable(unavailable)
            }

            return await availabilityForDirectory(rootURL)
        }

        func scan(_ scope: SyncScope) async -> LocationSnapshot {
            if case let .unavailable(reason) = await checkAvailability() {
                return snapshot(scope: scope, status: .unavailable(reason: reason))
            }
            guard let scopeURL = resolvedURL(
                for: scope.rootPath,
                followingFinalSymlink: true
            ) else {
                return snapshot(
                    scope: scope,
                    status: .incomplete(reason: "Scope path escapes the selected root.")
                )
            }
            if scope.rootPath != .root,
               case let .unavailable(reason) = await availabilityForDirectory(scopeURL) {
                return snapshot(scope: scope, status: .unavailable(reason: reason))
            }

            let result = LocalFolderStorageProvider.enumerate(
                locationID: locationID,
                rootURL: scopeURL,
                rootPath: scope.rootPath,
                isCaseSensitive: capabilities.isCaseSensitive
            )
            if case let .unavailable(reason) = await checkAvailability() {
                return snapshot(scope: scope, status: .unavailable(reason: reason))
            }
            if scope.rootPath != .root,
               case let .unavailable(reason) = await availabilityForDirectory(scopeURL) {
                return snapshot(scope: scope, status: .unavailable(reason: reason))
            }
            return LocationSnapshot(
                location: locationID,
                scope: scope,
                observations: result.observations,
                status: result.errors.isEmpty
                    ? .complete
                    : .incomplete(reason: result.errors.joined(separator: " | "))
            )
        }

        func currentState(
            of observation: ItemObservation
        ) async -> Result<ItemObservation, ProviderError> {
            do {
                if case let .unavailable(reason) = await checkAvailability() {
                    throw ProviderError.unavailable(
                        provider: locationID,
                        reason: reason.detail
                    )
                }
                guard observation.location == locationID,
                      let url = resolvedURL(
                          for: observation.path,
                          followingFinalSymlink: false
                      ),
                      !isInternalPath(observation.path) else {
                    throw ProviderError.itemUnavailable(
                        provider: locationID,
                        path: observation.path
                    )
                }

                do {
                    return .success(
                        try LocalFolderStorageProvider.observation(
                            locationID: locationID,
                            url: url,
                            path: observation.path
                        )
                    )
                } catch {
                    let failure = LocalFileFailure(error)
                    if case let .unavailable(reason) = await checkAvailability() {
                        throw ProviderError.unavailable(
                            provider: locationID,
                            reason: reason.detail
                        )
                    }
                    let isAbsent = failure.isMissingFile || confirmsAbsence(of: url)
                    if isAbsent {
                        if let trashed = try trashedObservation(from: observation) {
                            return .success(trashed)
                        }
                        throw ProviderError.notFound(
                            provider: locationID,
                            path: observation.path
                        )
                    }
                    throw ProviderError.itemUnavailable(
                        provider: locationID,
                        path: observation.path
                    )
                }
            } catch let error as ProviderError {
                return .failure(error)
            } catch {
                return .failure(
                    .itemUnavailable(provider: locationID, path: observation.path)
                )
            }
        }

        private func availabilityForDirectory(_ url: URL) async -> LocationAvailability {
            let directoryState = await volumes.directoryState(at: url)
            if let unavailable = await exactRootIdentityUnavailability() {
                return .unavailable(unavailable)
            }
            switch directoryState {
            case .missing:
                return await availabilityAfterConfirmedMissingDirectory()
            case let .unknown(detail):
                return .unavailable(.unknown(detail: detail))
            case .present(isReadable: false):
                return .unavailable(.unknown(detail: "The selected folder is not readable."))
            case .present(isReadable: true):
                return .available
            }
        }

        private func availabilityAfterConfirmedMissingDirectory() async -> LocationAvailability {
            switch await volumes.mountState(for: rootURL) {
            case let .notMounted(detail):
                return .unavailable(.volumeNotMounted(detail: detail))
            case let .indeterminate(detail):
                return .unavailable(.unknown(detail: detail))
            case .mounted:
                break
            }
            if let unavailable = await exactRootIdentityUnavailability() {
                return .unavailable(unavailable)
            }
            switch await volumes.responsiveness(for: rootURL) {
            case let .unreachable(detail):
                return .unavailable(.volumeUnreachable(detail: detail))
            case .responsive:
                break
            }
            if let unavailable = await exactRootIdentityUnavailability() {
                return .unavailable(unavailable)
            }
            return .unavailable(
                .scopeMissing(detail: "The selected folder is missing.")
            )
        }

        func exactRootIdentityUnavailability() async -> LocationUnavailabilityReason? {
            guard currentOwnedCanonicalRoot() != nil else {
                return .unknown(
                    detail: "The configured local root no longer resolves to its enrolled directory."
                )
            }
            guard let expectedVolumeIdentity else {
                return .unknown(
                    detail: "The selected volume identity could not be recorded safely."
                )
            }
            let currentIdentity = await volumes.volumeIdentity(for: rootURL)
            guard currentOwnedCanonicalRoot() != nil else {
                return .unknown(
                    detail: "The configured local root no longer resolves to its enrolled directory."
                )
            }
            switch currentIdentity {
            case nil:
                return .volumeNotMounted(
                    detail: "The selected volume is no longer mounted."
                )
            case let currentIdentity? where currentIdentity != expectedVolumeIdentity:
                return .volumeNotMounted(
                    detail: "The selected volume was replaced by a different volume."
                )
            case .some:
                return nil
            }
        }

        private func confirmsAbsence(of url: URL) -> Bool {
            guard let names = try? FileManager.default.contentsOfDirectory(
                atPath: url.deletingLastPathComponent().path
            ) else {
                return false
            }
            if capabilities.isCaseSensitive == true {
                return !names.contains(url.lastPathComponent)
            }
            return !names.contains {
                $0.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame
            }
        }

        private func trashedObservation(
            from expected: ItemObservation
        ) throws -> ItemObservation? {
            guard let canonicalRoot = currentOwnedCanonicalRoot() else {
                return nil
            }
            let directory = canonicalRoot
                .appendingPathComponent(".aetherloom", isDirectory: true)
                .appendingPathComponent("trash-receipts", isDirectory: true)
            guard let checked = LocalFolderStorageProvider
                .canonicalizingExistingAncestors(directory),
                  LocalFolderStorageProvider.contains(checked, in: canonicalRoot) else {
                return nil
            }
            let encoded = try CanonicalCoding.encoder().encode(
                LocalTrashReceiptKey(
                    location: expected.location,
                    path: expected.path,
                    kind: expected.kind
                )
            )
            let receiptURL = checked.appendingPathComponent(
                CanonicalCoding.sha256Hex(encoded) + ".json",
                isDirectory: false
            )
            guard filesystemEntryExists(at: receiptURL) else { return nil }
            let receipt = try CanonicalCoding.decoder().decode(
                LocalTrashReceipt.self,
                from: Data(contentsOf: receiptURL)
            )
            guard receipt.observation.location == locationID,
                  receipt.observation.path == expected.path,
                  receipt.observation.kind == expected.kind,
                  receipt.observation.version.isSameVersion(as: expected.version) else {
                return nil
            }
            return try LocalFolderStorageProvider.recoveredTrashObservation(
                receipt: receipt,
                expected: expected,
                locationID: locationID,
                canonicalRoot: canonicalRoot,
                nativeTrash: nativeTrash,
                quarantine: quarantine
            )
        }

        private func resolvedURL(
            for path: SyncPath,
            followingFinalSymlink: Bool
        ) -> URL? {
            guard !path.components.contains(where: { $0 == "." || $0 == ".." }),
                  let canonicalRoot = currentOwnedCanonicalRoot() else {
                return nil
            }
            let candidate = path.components.reduce(canonicalRoot) { partial, component in
                partial.appendingPathComponent(component, isDirectory: false)
            }
            let checked: URL?
            if followingFinalSymlink || path.isRoot {
                checked = LocalFolderStorageProvider
                    .canonicalizingExistingAncestors(candidate)
            } else {
                checked = LocalFolderStorageProvider.canonicalizingExistingAncestors(
                    candidate.deletingLastPathComponent()
                )?.appendingPathComponent(candidate.lastPathComponent)
            }
            guard let checked,
                  LocalFolderStorageProvider.contains(checked, in: canonicalRoot) else {
                return nil
            }
            return checked
        }

        private func currentOwnedCanonicalRoot() -> URL? {
            guard let ownedCanonicalRootURL,
                  LocalFolderStorageProvider.resolvedExistingRootPath(rootURL)
                    == ownedCanonicalRootURL.standardizedFileURL.path else {
                return nil
            }
            return ownedCanonicalRootURL
        }

        private func isInternalPath(_ path: SyncPath) -> Bool {
            LocalFolderStorageProvider.isInternal(
                path,
                isCaseSensitive: capabilities.isCaseSensitive
            )
        }

        private func snapshot(
            scope: SyncScope,
            status: ScanStatus
        ) -> LocationSnapshot {
            LocationSnapshot(
                location: locationID,
                scope: scope,
                observations: [],
                status: status
            )
        }

        private func filesystemEntryExists(at url: URL) -> Bool {
            if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
                return true
            }
            return (try? FileManager.default.destinationOfSymbolicLink(
                atPath: url.path
            )) != nil
        }
    }

    private struct MutationContext: Sendable {
        let locationID: LocationID
        let capabilities: ProviderCapabilities
        let rootURL: URL
        let ownedCanonicalRootURL: URL?
        let volumes: any VolumeInspecting
        let expectedVolumeIdentity: String?
        let deadlines: ProviderDeadlines
        let fetching: any LocalFetchPerforming
        let nativeTrash: any LocalNativeTrashPerforming
        let relocation: any LocalRelocationPerforming
        let quarantine: any LocalQuarantinePerforming
        let hook: any LocalMutationStarting
        let trashReceiptPersistence: any LocalTrashReceiptPersisting
        let artifacts: LocalMutationArtifacts
        let quarantineTimestamp: String

        func fetch(
            _ expected: ItemObservation,
            to stagingURL: URL,
            receipt: ProviderMutationReceipt
        ) async -> Result<Void, ProviderError> {
            do {
                try await requireAvailable()
                try hook.beforeMutation(receipt)
                try await requireAvailable()
                let current = try matchingCurrentState(of: expected)
                if current.isPlaceholder {
                    throw ProviderError.placeholderOnly(
                        provider: locationID,
                        path: expected.path
                    )
                }
                guard current.kind == .file,
                      let sourceURL = resolvedURL(
                          for: current.path,
                          followingFinalSymlink: true
                      ) else {
                    throw ProviderError.itemUnavailable(
                        provider: locationID,
                        path: expected.path
                    )
                }
                try await requireCurrentRootIdentity()
                try fetching.copyItem(at: sourceURL, to: stagingURL)
                try await requireAvailable()
                _ = try matchingCurrentState(of: expected)
                guard try LocalFolderStorageProvider.filesHaveEqualBytes(
                    sourceURL,
                    stagingURL
                ) else {
                    throw ProviderError.preconditionFailed(
                        provider: locationID,
                        path: expected.path
                    )
                }
                _ = try matchingCurrentState(of: expected)
                return .success(())
            } catch let error as ProviderError {
                return .failure(error)
            } catch {
                if case let .unavailable(reason) = await availability() {
                    return .failure(
                        .unavailable(provider: locationID, reason: reason.detail)
                    )
                }
                return .failure(
                    .itemUnavailable(provider: locationID, path: expected.path)
                )
            }
        }

        func store(
            from stagingURL: URL,
            at path: SyncPath,
            options: StoreOptions,
            receipt: ProviderMutationReceipt
        ) async -> Result<ItemObservation, ProviderError> {
            var physicalCommitMayHaveApplied = false
            do {
                try await requireAvailable()
                try hook.beforeMutation(receipt)
                try await requireAvailable()
                guard !path.isRoot,
                      !isInternalPath(path),
                      let destination = resolvedURL(
                          for: path,
                          followingFinalSymlink: false
                      ) else {
                    throw ProviderError.itemUnavailable(provider: locationID, path: path)
                }

                let existing = try existingEntry(at: path)
                switch options.overwrite {
                case .neverOverwrite:
                    if let existing {
                        guard existing.observation.kind == .file else {
                            throw ProviderError.itemAlreadyExists(
                                provider: locationID,
                                path: path
                            )
                        }
                        if try LocalFolderStorageProvider.filesHaveEqualBytes(
                            stagingURL,
                            existing.url
                        ) {
                            return .success(existing.observation)
                        }
                        throw ProviderError.itemAlreadyExists(
                            provider: locationID,
                            path: path
                        )
                    }
                case let .ifVersionMatches(expected):
                    guard let existing,
                          existing.observation.kind == .file,
                          existing.observation.version.isSameVersion(as: expected) else {
                        throw ProviderError.preconditionFailed(
                            provider: locationID,
                            path: path
                        )
                    }
                }

                let replacementTarget = existing?.url ?? destination
                try await requireCurrentRootIdentity()
                let replacementDirectory = try FileManager.default.url(
                    for: .itemReplacementDirectory,
                    in: .userDomainMask,
                    appropriateFor: replacementTarget,
                    create: true
                )
                let temporary = replacementDirectory.appendingPathComponent(
                    receipt.id.uuidString
                )
                defer {
                    // The temporary is provider-created scratch, not user
                    // content. Cleanup stays inside the owned operation so it
                    // can never race a late copy/replace after the deadline.
                    try? FileManager.default.removeItem(at: temporary)
                }
                try await requireCurrentRootIdentity()
                try FileManager.default.copyItem(at: stagingURL, to: temporary)
                try await requireAvailable()
                let committedURL: URL
                let committedPath: SyncPath
                if let existing {
                    try await requireCurrentRootIdentity()
                    physicalCommitMayHaveApplied = true
                    _ = try FileManager.default.replaceItemAt(
                        existing.url,
                        withItemAt: temporary,
                        backupItemName: nil,
                        options: [.usingNewMetadataOnly]
                    )
                    committedURL = existing.url
                    committedPath = existing.observation.path
                } else {
                    try await requireCurrentRootIdentity()
                    physicalCommitMayHaveApplied = true
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    committedURL = destination
                    committedPath = path
                }
                try hook.afterPhysicalCommit(receipt)
                try await requireAvailable()
                return .success(
                    try LocalFolderStorageProvider.observation(
                        locationID: locationID,
                        url: committedURL,
                        path: committedPath
                    )
                )
            } catch let error as ProviderError {
                return .failure(
                    physicalCommitMayHaveApplied
                        ? .mutationIndeterminate(receipt)
                        : error
                )
            } catch {
                return .failure(
                    physicalCommitMayHaveApplied
                        ? .mutationIndeterminate(receipt)
                        : .itemUnavailable(provider: locationID, path: path)
                )
            }
        }

        func makeFolder(
            at path: SyncPath,
            receipt: ProviderMutationReceipt
        ) async -> Result<ItemObservation, ProviderError> {
            var physicalCommitMayHaveApplied = false
            do {
                try await requireAvailable()
                try hook.beforeMutation(receipt)
                try await requireAvailable()
                guard !path.isRoot,
                      !isInternalPath(path),
                      let destination = resolvedURL(
                          for: path,
                          followingFinalSymlink: false
                      ) else {
                    throw ProviderError.itemUnavailable(provider: locationID, path: path)
                }
                if let existing = try existingEntry(at: path) {
                    if existing.observation.kind == .folder {
                        return .success(existing.observation)
                    }
                    throw ProviderError.itemAlreadyExists(provider: locationID, path: path)
                }
                try await requireCurrentRootIdentity()
                physicalCommitMayHaveApplied = true
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
                try hook.afterPhysicalCommit(receipt)
                try await requireAvailable()
                return .success(
                    try LocalFolderStorageProvider.observation(
                        locationID: locationID,
                        url: destination,
                        path: path
                    )
                )
            } catch let error as ProviderError {
                return .failure(
                    physicalCommitMayHaveApplied
                        ? .mutationIndeterminate(receipt)
                        : error
                )
            } catch {
                return .failure(
                    physicalCommitMayHaveApplied
                        ? .mutationIndeterminate(receipt)
                        : .itemUnavailable(provider: locationID, path: path)
                )
            }
        }

        func relocate(
            _ expected: ItemObservation,
            to newPath: SyncPath,
            receipt: ProviderMutationReceipt
        ) async -> Result<ItemObservation, ProviderError> {
            var physicalCommitMayHaveApplied = false
            do {
                try await requireAvailable()
                try hook.beforeMutation(receipt)
                try await requireAvailable()
                if expected.path == newPath {
                    return .success(try matchingCurrentState(of: expected))
                }
                guard !newPath.isRoot,
                      !isInternalPath(newPath),
                      let destination = resolvedURL(
                          for: newPath,
                          followingFinalSymlink: false
                      ),
                      let initialSource = resolvedURL(
                          for: expected.path,
                          followingFinalSymlink: false
                      ) else {
                    throw ProviderError.itemUnavailable(provider: locationID, path: newPath)
                }
                let isSameVolume = try await sameVolume(
                    initialSource,
                    destination.deletingLastPathComponent()
                )
                try await requireAvailable()
                let current = try matchingCurrentState(of: expected)
                guard let source = resolvedURL(
                    for: current.path,
                    followingFinalSymlink: false
                ) else {
                    throw ProviderError.itemUnavailable(
                        provider: locationID,
                        path: current.path
                    )
                }
                if try existingEntry(at: newPath) != nil {
                    throw ProviderError.itemAlreadyExists(
                        provider: locationID,
                        path: newPath
                    )
                }

                if isSameVolume {
                    try await requireCurrentRootIdentity()
                    physicalCommitMayHaveApplied = true
                    try FileManager.default.moveItem(at: source, to: destination)
                    try hook.afterPhysicalCommit(receipt)
                } else {
                    try await requireCurrentRootIdentity()
                    physicalCommitMayHaveApplied = true
                    do {
                        try relocation.copyItem(at: source, to: destination)
                    } catch {
                        try await restoreUnappliedCrossVolumeRelocation(
                            source: current,
                            destination: destination,
                            destinationPath: newPath,
                            mutationReceipt: receipt
                        )
                        physicalCommitMayHaveApplied = false
                        throw error
                    }
                    try await requireAvailable()
                    try hook.afterPhysicalCommit(receipt)
                    guard try LocalFolderStorageProvider.equivalentTrees(
                        source,
                        destination
                    ) else {
                        throw ProviderError.itemUnavailable(
                            provider: locationID,
                            path: newPath
                        )
                    }
                    try await requireCurrentRootIdentity()
                    do {
                        try relocation.beforeSourceTrash(at: source)
                        try await requireCurrentRootIdentity()
                        try await trashCurrent(
                            current,
                            source: source,
                            mutationReceipt: receipt
                        )
                        try hook.afterPhysicalCommit(receipt)
                    } catch {
                        try await restoreUnappliedCrossVolumeRelocation(
                            source: current,
                            destination: destination,
                            destinationPath: newPath,
                            mutationReceipt: receipt
                        )
                        physicalCommitMayHaveApplied = false
                        throw error
                    }
                }
                try await requireAvailable()
                return .success(
                    try LocalFolderStorageProvider.observation(
                        locationID: locationID,
                        url: destination,
                        path: newPath
                    )
                )
            } catch let error as ProviderError {
                return .failure(
                    physicalCommitMayHaveApplied
                        ? .mutationIndeterminate(receipt)
                        : error
                )
            } catch {
                return .failure(
                    physicalCommitMayHaveApplied
                        ? .mutationIndeterminate(receipt)
                        : .itemUnavailable(
                            provider: locationID,
                            path: expected.path
                        )
                )
            }
        }

        func trash(
            _ expected: ItemObservation,
            receipt: ProviderMutationReceipt
        ) async -> Result<Void, ProviderError> {
            var physicalCommitApplied = false
            do {
                try await requireAvailable()
                try hook.beforeMutation(receipt)
                try await requireAvailable()
                if let existing = try existingEntry(at: expected.path) {
                    guard existing.observation.kind == expected.kind,
                          existing.observation.version.isSameVersion(as: expected.version) else {
                        throw ProviderError.preconditionFailed(
                            provider: locationID,
                            path: expected.path
                        )
                    }
                    try await requireCurrentRootIdentity()
                    try await trashCurrent(
                        existing.observation,
                        source: existing.url,
                        mutationReceipt: receipt
                    )
                    physicalCommitApplied = true
                    try await requireAvailable()
                    return .success(())
                }
                guard let trashed = try trashedObservation(from: expected),
                      trashed.isTrashed else {
                    throw ProviderError.preconditionFailed(
                        provider: locationID,
                        path: expected.path
                    )
                }
                return .success(())
            } catch let error as ProviderError {
                return .failure(
                    physicalCommitApplied
                        ? .mutationIndeterminate(receipt)
                        : error
                )
            } catch {
                return .failure(
                    physicalCommitApplied
                        ? .mutationIndeterminate(receipt)
                        : .itemUnavailable(
                            provider: locationID,
                            path: expected.path
                        )
                )
            }
        }

        private func matchingCurrentState(
            of expected: ItemObservation
        ) throws -> ItemObservation {
            guard expected.location == locationID,
                  let existing = try existingEntry(at: expected.path),
                  existing.observation.kind == expected.kind,
                  existing.observation.version.isSameVersion(as: expected.version) else {
                throw ProviderError.preconditionFailed(
                    provider: locationID,
                    path: expected.path
                )
            }
            return existing.observation
        }

        private func trashCurrent(
            _ current: ItemObservation,
            source: URL,
            mutationReceipt: ProviderMutationReceipt
        ) async throws {
            try await requireCurrentRootIdentity()
            let immediatelyCurrent: ItemObservation
            do {
                immediatelyCurrent = try LocalFolderStorageProvider.observation(
                    locationID: locationID,
                    url: source,
                    path: current.path
                )
            } catch {
                throw ProviderError.preconditionFailed(
                    provider: locationID,
                    path: current.path
                )
            }
            guard immediatelyCurrent.kind == current.kind,
                  immediatelyCurrent.version.isSameVersion(as: current.version) else {
                throw ProviderError.preconditionFailed(
                    provider: locationID,
                    path: current.path
                )
            }

            if capabilities.hasNativeTrash {
                var trashReceipt = LocalTrashReceipt(
                    observation: immediatelyCurrent,
                    method: .nativeTrash,
                    recoveryPath: nil,
                    startedAt: deadlines.now(),
                    committedAt: nil
                )
                try await requireCurrentRootIdentity()
                try persistTrashReceipt(trashReceipt)
                let resultingURL: URL?
                let nativeTrashFailed: Bool
                do {
                    try await requireCurrentRootIdentity()
                    resultingURL = try nativeTrash.trashItem(at: source)
                    nativeTrashFailed = false
                } catch {
                    resultingURL = nil
                    nativeTrashFailed = true
                }
                do {
                    try await requireCurrentRootIdentity()
                } catch {
                    throw ProviderError.mutationIndeterminate(mutationReceipt)
                }
                let remainingSource: LocalExistingEntry?
                do {
                    remainingSource = try existingEntry(at: current.path)
                } catch {
                    // Native trash was already attempted. If its result cannot
                    // be inspected, ordinary failure is not safe evidence that
                    // the source stayed in place.
                    throw ProviderError.mutationIndeterminate(mutationReceipt)
                }
                if let remainingSource {
                    guard remainingSource.observation.kind == current.kind,
                          remainingSource.observation.version.isSameVersion(
                              as: current.version
                          ),
                          nativeTrashFailed else {
                        throw ProviderError.mutationIndeterminate(mutationReceipt)
                    }
                } else {
                    guard !nativeTrashFailed,
                          let resultingURL else {
                        throw ProviderError.mutationIndeterminate(mutationReceipt)
                    }
                    switch nativeTrash.artifactState(at: resultingURL) {
                    case .present:
                        break
                    case .missing, .unavailable:
                        throw ProviderError.mutationIndeterminate(mutationReceipt)
                    }
                    await artifacts.recordRecovery(
                        resultingURL,
                        for: current.path
                    )
                    do {
                        try await requireCurrentRootIdentity()
                    } catch {
                        throw ProviderError.mutationIndeterminate(mutationReceipt)
                    }
                    trashReceipt.recoveryPath = resultingURL.path
                    trashReceipt.committedAt = deadlines.now()
                    try persistCommittedTrashReceipt(
                        trashReceipt,
                        mutationReceipt: mutationReceipt,
                        retryOnce: true
                    )
                    return
                }
            }

            try await requireCurrentRootIdentity()
            let recoveryURL = try quarantineDestinationURL(
                originalPath: current.path
            )
            var quarantineReceipt = LocalTrashReceipt(
                observation: immediatelyCurrent,
                method: .quarantine,
                recoveryPath: recoveryURL.path,
                startedAt: deadlines.now(),
                committedAt: nil
            )
            try await requireCurrentRootIdentity()
            try persistTrashReceipt(quarantineReceipt)
            do {
                try await requireCurrentRootIdentity()
                try quarantine.moveItem(at: source, to: recoveryURL)
            } catch let moveError {
                do {
                    try await requireCurrentRootIdentity()
                } catch {
                    throw ProviderError.mutationIndeterminate(mutationReceipt)
                }
                let remainingSource: LocalExistingEntry?
                do {
                    remainingSource = try existingEntry(at: current.path)
                } catch {
                    throw ProviderError.mutationIndeterminate(mutationReceipt)
                }
                if let remainingSource {
                    guard remainingSource.observation.kind == current.kind,
                          remainingSource.observation.version.isSameVersion(
                              as: current.version
                          ) else {
                        throw ProviderError.mutationIndeterminate(mutationReceipt)
                    }
                    throw moveError
                }
                switch quarantine.artifactState(at: recoveryURL) {
                case .present:
                    break
                case .missing, .unavailable:
                    throw ProviderError.mutationIndeterminate(mutationReceipt)
                }
            }
            do {
                try await requireCurrentRootIdentity()
            } catch {
                throw ProviderError.mutationIndeterminate(mutationReceipt)
            }
            quarantineReceipt.committedAt = deadlines.now()
            try persistCommittedTrashReceipt(
                quarantineReceipt,
                mutationReceipt: mutationReceipt
            )
            await artifacts.recordRecovery(recoveryURL, for: current.path)
        }

        private func existingEntry(at path: SyncPath) throws -> LocalExistingEntry? {
            guard !path.isRoot,
                  !isInternalPath(path),
                  let parent = resolvedURL(
                      for: path.parent,
                      followingFinalSymlink: true
                  ) else {
                throw ProviderError.itemUnavailable(provider: locationID, path: path)
            }
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            } catch {
                if LocalFileFailure(error).isMissingFile {
                    return nil
                }
                throw ProviderError.itemUnavailable(provider: locationID, path: path)
            }
            let actualName: String?
            if capabilities.isCaseSensitive == true {
                actualName = names.first { $0 == path.name }
            } else {
                actualName = names.first {
                    $0.caseInsensitiveCompare(path.name) == .orderedSame
                }
            }
            guard let actualName else { return nil }
            let actualPath = path.parent.appending(actualName)
            let url = parent.appendingPathComponent(actualName, isDirectory: false)
            do {
                return LocalExistingEntry(
                    url: url,
                    observation: try LocalFolderStorageProvider.observation(
                        locationID: locationID,
                        url: url,
                        path: actualPath
                    )
                )
            } catch {
                throw ProviderError.itemUnavailable(provider: locationID, path: path)
            }
        }

        private func sameVolume(
            _ source: URL,
            _ destinationParent: URL
        ) async throws -> Bool {
            guard let sourceIdentity = await volumes.volumeIdentity(for: source) else {
                throw ProviderError.unavailable(
                    provider: locationID,
                    reason: "A volume identity could not be determined before relocation."
                )
            }
            try await requireCurrentRootIdentity()
            guard let destinationIdentity = await volumes.volumeIdentity(
                for: destinationParent
            ) else {
                throw ProviderError.unavailable(
                    provider: locationID,
                    reason: "A volume identity could not be determined before relocation."
                )
            }
            try await requireCurrentRootIdentity()
            return sourceIdentity == destinationIdentity
        }

        private func requireAvailable() async throws {
            if case let .unavailable(reason) = await availability() {
                throw ProviderError.unavailable(
                    provider: locationID,
                    reason: reason.detail
                )
            }
        }

        private func requireCurrentRootIdentity() async throws {
            let context = ReadContext(
                locationID: locationID,
                capabilities: capabilities,
                rootURL: rootURL,
                ownedCanonicalRootURL: ownedCanonicalRootURL,
                volumes: volumes,
                expectedVolumeIdentity: expectedVolumeIdentity,
                nativeTrash: nativeTrash,
                quarantine: quarantine
            )
            if let reason = await context.exactRootIdentityUnavailability() {
                throw ProviderError.unavailable(
                    provider: locationID,
                    reason: reason.detail
                )
            }
        }

        private func availability() async -> LocationAvailability {
            await ReadContext(
                locationID: locationID,
                capabilities: capabilities,
                rootURL: rootURL,
                ownedCanonicalRootURL: ownedCanonicalRootURL,
                volumes: volumes,
                expectedVolumeIdentity: expectedVolumeIdentity,
                nativeTrash: nativeTrash,
                quarantine: quarantine
            ).checkAvailability()
        }

        private func resolvedURL(
            for path: SyncPath,
            followingFinalSymlink: Bool
        ) -> URL? {
            guard !path.components.contains(where: { $0 == "." || $0 == ".." }),
                  let canonicalRoot = currentOwnedCanonicalRoot() else {
                return nil
            }
            let candidate = path.components.reduce(canonicalRoot) { partial, component in
                partial.appendingPathComponent(component, isDirectory: false)
            }
            let checked: URL?
            if followingFinalSymlink || path.isRoot {
                checked = LocalFolderStorageProvider
                    .canonicalizingExistingAncestors(candidate)
            } else {
                checked = LocalFolderStorageProvider.canonicalizingExistingAncestors(
                    candidate.deletingLastPathComponent()
                )?.appendingPathComponent(candidate.lastPathComponent)
            }
            guard let checked,
                  LocalFolderStorageProvider.contains(checked, in: canonicalRoot) else {
                return nil
            }
            return checked
        }

        private func currentOwnedCanonicalRoot() -> URL? {
            guard let ownedCanonicalRootURL,
                  LocalFolderStorageProvider.resolvedExistingRootPath(rootURL)
                    == ownedCanonicalRootURL.standardizedFileURL.path else {
                return nil
            }
            return ownedCanonicalRootURL
        }

        private func isInternalPath(_ path: SyncPath) -> Bool {
            LocalFolderStorageProvider.isInternal(
                path,
                isCaseSensitive: capabilities.isCaseSensitive
            )
        }

        private func persistTrashReceipt(_ receipt: LocalTrashReceipt) throws {
            let directory = try trashReceiptDirectory(create: true)
            let receiptURL = directory.appendingPathComponent(
                try trashReceiptFilename(for: receipt.observation),
                isDirectory: false
            )
            try trashReceiptPersistence.persist(
                CanonicalCoding.encoder().encode(receipt),
                at: receiptURL
            )
        }

        private func persistCommittedTrashReceipt(
            _ receipt: LocalTrashReceipt,
            mutationReceipt: ProviderMutationReceipt,
            retryOnce: Bool = false
        ) throws {
            if retryOnce {
                do {
                    try persistTrashReceipt(receipt)
                    return
                } catch {
                    // Retry once. If that also fails, the physical mutation
                    // has already happened and must remain indeterminate.
                }
            }
            do {
                try persistTrashReceipt(receipt)
            } catch {
                throw ProviderError.mutationIndeterminate(mutationReceipt)
            }
        }

        private func trashedObservation(
            from expected: ItemObservation
        ) throws -> ItemObservation? {
            let directory = try trashReceiptDirectory(create: false)
            let receiptURL = directory.appendingPathComponent(
                try trashReceiptFilename(for: expected),
                isDirectory: false
            )
            guard filesystemEntryExists(at: receiptURL) else { return nil }
            let receipt = try CanonicalCoding.decoder().decode(
                LocalTrashReceipt.self,
                from: Data(contentsOf: receiptURL)
            )
            guard receipt.observation.location == locationID,
                  receipt.observation.path == expected.path,
                  receipt.observation.kind == expected.kind,
                  receipt.observation.version.isSameVersion(as: expected.version) else {
                return nil
            }
            guard let canonicalRoot = currentOwnedCanonicalRoot() else {
                throw ProviderError.unavailable(
                    provider: locationID,
                    reason: "The configured local root is unavailable."
                )
            }
            return try LocalFolderStorageProvider.recoveredTrashObservation(
                receipt: receipt,
                expected: expected,
                locationID: locationID,
                canonicalRoot: canonicalRoot,
                nativeTrash: nativeTrash,
                quarantine: quarantine
            )
        }

        private func trashReceiptFilename(
            for observation: ItemObservation
        ) throws -> String {
            let encoded = try CanonicalCoding.encoder().encode(
                LocalTrashReceiptKey(
                    location: observation.location,
                    path: observation.path,
                    kind: observation.kind
                )
            )
            return CanonicalCoding.sha256Hex(encoded) + ".json"
        }

        private func trashReceiptDirectory(create: Bool) throws -> URL {
            guard let canonicalRoot = currentOwnedCanonicalRoot() else {
                throw ProviderError.itemUnavailable(provider: locationID, path: .root)
            }
            let directory = canonicalRoot
                .appendingPathComponent(".aetherloom", isDirectory: true)
                .appendingPathComponent("trash-receipts", isDirectory: true)
            guard let checkedBeforeCreate = LocalFolderStorageProvider
                .canonicalizingExistingAncestors(directory),
                  LocalFolderStorageProvider.contains(
                      checkedBeforeCreate,
                      in: canonicalRoot
                  ) else {
                throw ProviderError.itemUnavailable(provider: locationID, path: .root)
            }
            if create {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
            guard let checked = LocalFolderStorageProvider
                .canonicalizingExistingAncestors(directory),
                  LocalFolderStorageProvider.contains(checked, in: canonicalRoot) else {
                throw ProviderError.itemUnavailable(provider: locationID, path: .root)
            }
            return checked
        }

        /// Rolls an interrupted cross-volume copy back to a provably unapplied
        /// state. An ordinary failure is safe only while the exact source is
        /// still live and the attempted destination is positively absent or
        /// preserved in a positively verified quarantine artifact. Any
        /// inspection or cleanup ambiguity retains the operation receipt.
        private func restoreUnappliedCrossVolumeRelocation(
            source: ItemObservation,
            destination: URL,
            destinationPath: SyncPath,
            mutationReceipt: ProviderMutationReceipt
        ) async throws {
            try await requireCurrentRootIdentity()
            do {
                _ = try matchingCurrentState(of: source)
            } catch {
                throw ProviderError.mutationIndeterminate(mutationReceipt)
            }

            switch relocation.artifactState(at: destination) {
            case .missing:
                return
            case .unavailable:
                throw ProviderError.mutationIndeterminate(mutationReceipt)
            case .present:
                break
            }

            try await requireCurrentRootIdentity()
            let recovery = try quarantineDestinationURL(
                originalPath: destinationPath
            )
            do {
                try await requireCurrentRootIdentity()
                try relocation.moveItemToRecovery(
                    at: destination,
                    to: recovery
                )
            } catch {
                // A move can throw after applying. Endpoint inspection below
                // decides whether cleanup is safely complete.
            }

            guard case .missing = relocation.artifactState(at: destination),
                  case .present = relocation.artifactState(at: recovery) else {
                throw ProviderError.mutationIndeterminate(mutationReceipt)
            }
            do {
                _ = try matchingCurrentState(of: source)
            } catch {
                throw ProviderError.mutationIndeterminate(mutationReceipt)
            }
            await artifacts.recordRecovery(recovery, for: destinationPath)
        }

        private func quarantineDestinationURL(
            originalPath: SyncPath
        ) throws -> URL {
            guard let canonicalRoot = currentOwnedCanonicalRoot() else {
                throw ProviderError.itemUnavailable(
                    provider: locationID,
                    path: originalPath
                )
            }
            let trashRoot = canonicalRoot
                .appendingPathComponent(".aetherloom", isDirectory: true)
                .appendingPathComponent("trash", isDirectory: true)
                .appendingPathComponent(quarantineTimestamp, isDirectory: true)
            let destinationParent = originalPath.parent.components.reduce(trashRoot) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
            guard let checkedBeforeCreate = LocalFolderStorageProvider
                .canonicalizingExistingAncestors(destinationParent),
                  LocalFolderStorageProvider.contains(
                      checkedBeforeCreate,
                      in: canonicalRoot
                  ) else {
                throw ProviderError.itemUnavailable(
                    provider: locationID,
                    path: originalPath
                )
            }
            try FileManager.default.createDirectory(
                at: destinationParent,
                withIntermediateDirectories: true
            )
            guard let checkedParent = LocalFolderStorageProvider
                .canonicalizingExistingAncestors(destinationParent),
                  LocalFolderStorageProvider.contains(checkedParent, in: canonicalRoot) else {
                throw ProviderError.itemUnavailable(
                    provider: locationID,
                    path: originalPath
                )
            }
            return uniqueQuarantineURL(
                in: checkedParent,
                originalName: originalPath.name
            )
        }

        private func uniqueQuarantineURL(
            in parent: URL,
            originalName: String
        ) -> URL {
            let initial = parent.appendingPathComponent(originalName)
            guard !FileManager.default.fileExists(atPath: initial.path) else {
                let name = originalName as NSString
                let stem = name.deletingPathExtension
                let pathExtension = name.pathExtension
                var suffix = 2
                while true {
                    let candidateName = pathExtension.isEmpty
                        ? "\(stem) \(suffix)"
                        : "\(stem) \(suffix).\(pathExtension)"
                    let candidate = parent.appendingPathComponent(candidateName)
                    if !FileManager.default.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                    suffix += 1
                }
            }
            return initial
        }

        private func filesystemEntryExists(at url: URL) -> Bool {
            if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
                return true
            }
            return (try? FileManager.default.destinationOfSymbolicLink(
                atPath: url.path
            )) != nil
        }
    }
}

private struct LocalScanResult: Sendable {
    var observations: [ItemObservation]
    var errors: [String]
}

private struct LocalExistingEntry: Sendable {
    var url: URL
    var observation: ItemObservation
}

private struct LocalTrashReceipt: Codable, Hashable, Sendable {
    private static let currentSchemaVersion = 2

    enum Method: String, Codable, Hashable, Sendable {
        case nativeTrash
        case quarantine
    }

    var observation: ItemObservation
    var method: Method
    var recoveryPath: String?
    var startedAt: Date
    /// Nil means only the write-ahead intent was persisted. Prepared receipts
    /// are never accepted as evidence that user content reached trash.
    var committedAt: Date?

    private var schemaVersion: Int

    var isLegacy: Bool {
        schemaVersion < Self.currentSchemaVersion
    }

    init(
        observation: ItemObservation,
        method: Method,
        recoveryPath: String?,
        startedAt: Date,
        committedAt: Date?
    ) {
        self.observation = observation
        self.method = method
        self.recoveryPath = recoveryPath
        self.startedAt = startedAt
        self.committedAt = committedAt
        self.schemaVersion = Self.currentSchemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case observation
        case method
        case recoveryPath
        case startedAt
        case committedAt
        case schemaVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        observation = try container.decode(
            ItemObservation.self,
            forKey: .observation
        )
        method = try container.decode(Method.self, forKey: .method)
        recoveryPath = try container.decodeIfPresent(
            String.self,
            forKey: .recoveryPath
        )
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        committedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .committedAt
        )
        schemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? 1
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(observation, forKey: .observation)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(recoveryPath, forKey: .recoveryPath)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(committedAt, forKey: .committedAt)
        try container.encode(schemaVersion, forKey: .schemaVersion)
    }
}

private struct LocalTrashReceiptKey: Codable, Hashable, Sendable {
    var location: LocationID
    var path: SyncPath
    var kind: ItemKind
}

private struct LocalFileFailure: Sendable {
    var domain: String
    var code: Int
    var detail: String

    init(_ error: any Error) {
        let cocoaError = error as NSError
        self.domain = cocoaError.domain
        self.code = cocoaError.code
        self.detail = String(describing: error)
    }

    var isMissingFile: Bool {
        domain == NSCocoaErrorDomain
            && (code == NSFileNoSuchFileError || code == NSFileReadNoSuchFileError)
    }
}

actor LocalMutationArtifacts {
    private var recoveryURLsByPath: [SyncPath: URL] = [:]

    func recordRecovery(_ url: URL, for path: SyncPath) {
        recoveryURLsByPath[path] = url
    }

    func recoveryURL(for path: SyncPath) -> URL? {
        recoveryURLsByPath[path]
    }
}

protocol LocalMutationStarting: Sendable {
    func beforeMutation(_ receipt: ProviderMutationReceipt) throws
    func afterPhysicalCommit(_ receipt: ProviderMutationReceipt) throws
}

extension LocalMutationStarting {
    func afterPhysicalCommit(_: ProviderMutationReceipt) throws {}
}

struct NoOpLocalMutationHook: LocalMutationStarting {
    func beforeMutation(_: ProviderMutationReceipt) throws {}
}

protocol LocalFetchPerforming: Sendable {
    func copyItem(at source: URL, to destination: URL) throws
}

struct SystemLocalFetchPerformer: LocalFetchPerforming {
    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

protocol LocalNativeTrashPerforming: Sendable {
    func trashItem(at url: URL) throws -> URL?
    func artifactState(at url: URL) -> LocalRecoveryArtifactState
}

extension LocalNativeTrashPerforming {
    func artifactState(at url: URL) -> LocalRecoveryArtifactState {
        SystemLocalRecoveryArtifactInspector.state(at: url)
    }
}

protocol LocalTrashReceiptPersisting: Sendable {
    func persist(_ data: Data, at url: URL) throws
}

enum LocalRecoveryArtifactState: Sendable {
    case present
    case missing
    case unavailable(detail: String)
}

protocol LocalQuarantinePerforming: Sendable {
    func moveItem(at source: URL, to destination: URL) throws
    func artifactState(at url: URL) -> LocalRecoveryArtifactState
}

struct AtomicLocalTrashReceiptPersister: LocalTrashReceiptPersisting {
    func persist(_ data: Data, at url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

struct SystemLocalNativeTrashPerformer: LocalNativeTrashPerforming {
    func trashItem(at url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(
            at: url,
            resultingItemURL: &resultingURL
        )
        return resultingURL as URL?
    }
}

struct SystemLocalQuarantinePerformer: LocalQuarantinePerforming {
    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func artifactState(at url: URL) -> LocalRecoveryArtifactState {
        SystemLocalRecoveryArtifactInspector.state(at: url)
    }
}

private enum SystemLocalRecoveryArtifactInspector {
    static func state(at url: URL) -> LocalRecoveryArtifactState {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return .present
        } catch {
            guard LocalFileFailure(error).isMissingFile else {
                return .unavailable(detail: String(describing: error))
            }
        }
        do {
            _ = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            return .present
        } catch {
            return LocalFileFailure(error).isMissingFile
                ? .missing
                : .unavailable(detail: String(describing: error))
        }
    }
}

protocol LocalRelocationPerforming: Sendable {
    func copyItem(at source: URL, to destination: URL) throws
    func beforeSourceTrash(at source: URL) throws
    func moveItemToRecovery(at source: URL, to destination: URL) throws
    func artifactState(at url: URL) -> LocalRecoveryArtifactState
}

extension LocalRelocationPerforming {
    func moveItemToRecovery(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func artifactState(at url: URL) -> LocalRecoveryArtifactState {
        SystemLocalRecoveryArtifactInspector.state(at: url)
    }
}

struct SystemLocalRelocationPerformer: LocalRelocationPerforming {
    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func beforeSourceTrash(at _: URL) throws {}
}
