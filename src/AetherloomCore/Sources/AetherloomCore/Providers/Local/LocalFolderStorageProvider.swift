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
    private let mutationHook: any LocalMutationStarting
    private let mutations: LocalMutationCoordinator
    private let mutationArtifacts: LocalMutationArtifacts
    private let quarantineTimestamp: String

    public static func make(
        location: SyncLocation,
        rootURL: URL,
        volumes: any VolumeInspecting = SystemVolumeInspector(),
        deadlines: ProviderDeadlines = ProviderDeadlines()
    ) async -> LocalFolderStorageProvider {
        let propertyResult = await withProviderDeadline(
            nanoseconds: deadlines.probeNanoseconds,
            clock: deadlines.clock
        ) {
            await volumes.properties(for: rootURL)
        }
        let properties: VolumeProperties?
        switch propertyResult {
        case let .value(value):
            properties = value
        case .timedOut:
            properties = nil
        }
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
            expectedVolumeIdentity: location.configuration[
                expectedVolumeIdentityConfigurationKey
            ],
            deadlines: deadlines,
            capabilities: capabilities,
            fetching: SystemLocalFetchPerformer(),
            nativeTrash: SystemLocalNativeTrashPerformer(),
            relocation: SystemLocalRelocationPerformer(),
            mutationHook: NoOpLocalMutationHook(),
            mutations: LocalMutationCoordinator()
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
        mutationHook: any LocalMutationStarting = NoOpLocalMutationHook(),
        mutations: LocalMutationCoordinator = LocalMutationCoordinator()
    ) async -> LocalFolderStorageProvider {
        let propertyResult = await withProviderDeadline(
            nanoseconds: deadlines.probeNanoseconds,
            clock: deadlines.clock
        ) {
            await volumes.properties(for: rootURL)
        }
        let properties: VolumeProperties?
        switch propertyResult {
        case let .value(value):
            properties = value
        case .timedOut:
            properties = nil
        }
        let isNAS = location.kind == .nasFolder
        return LocalFolderStorageProvider(
            location: location,
            rootURL: rootURL,
            volumes: volumes,
            expectedVolumeIdentity: location.configuration[
                expectedVolumeIdentityConfigurationKey
            ],
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
            mutationHook: mutationHook,
            mutations: mutations
        )
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
        mutationHook: any LocalMutationStarting,
        mutations: LocalMutationCoordinator
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
        self.mutationHook = mutationHook
        self.mutations = mutations
        self.mutationArtifacts = LocalMutationArtifacts()
        self.quarantineTimestamp = Self.timestampString(for: deadlines.now())
    }

    public func checkAvailability() async -> LocationAvailability {
        if let receipt = await mutations.barrierReceipt() {
            return .unavailable(
                .unknown(
                    detail: "Filesystem mutation \(receipt.id.uuidString) is still awaiting reconciliation."
                )
            )
        }
        return await checkAvailabilityIgnoringMutationBarrier()
    }

    private func checkAvailabilityIgnoringMutationBarrier() async -> LocationAvailability {
        switch await probe({ await self.volumes.mountState(for: self.rootURL) }) {
        case .timedOut:
            return .unavailable(.volumeUnreachable(detail: "Volume mount inspection timed out."))
        case let .value(.notMounted(detail)):
            return .unavailable(.volumeNotMounted(detail: detail))
        case let .value(.indeterminate(detail)):
            return .unavailable(.unknown(detail: detail))
        case .value(.mounted):
            break
        }

        if let unavailable = await volumeIdentityUnavailability() {
            return .unavailable(unavailable)
        }

        switch await probe({ await self.volumes.responsiveness(for: self.rootURL) }) {
        case .timedOut:
            return .unavailable(.volumeUnreachable(detail: "Volume responsiveness probe timed out."))
        case let .value(.unreachable(detail)):
            return .unavailable(.volumeUnreachable(detail: detail))
        case .value(.responsive):
            break
        }

        return await availabilityForDirectory(rootURL)
    }

    public func scan(_ scope: SyncScope) async -> LocationSnapshot {
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
        if scope.rootPath != .root {
            let scopeAvailability = await availabilityForDirectory(scopeURL)
            if case let .unavailable(reason) = scopeAvailability {
                return snapshot(scope: scope, status: .unavailable(reason: reason))
            }
        }

        let locationID = self.locationID
        let isCaseSensitive = capabilities.isCaseSensitive
        let result = await withProviderDeadline(
            nanoseconds: deadlines.scanNanoseconds,
            clock: deadlines.clock
        ) {
            Self.enumerate(
                locationID: locationID,
                rootURL: scopeURL,
                rootPath: scope.rootPath,
                isCaseSensitive: isCaseSensitive
            )
        }
        switch result {
        case .timedOut:
            return snapshot(
                scope: scope,
                status: .incomplete(reason: "Filesystem scan timed out.")
            )
        case let .value(scan):
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
                observations: scan.observations,
                status: scan.errors.isEmpty
                    ? .complete
                    : .incomplete(reason: scan.errors.joined(separator: " | "))
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
        if observation.isPlaceholder {
            throw ProviderError.placeholderOnly(provider: locationID, path: observation.path)
        }
        let current = try await matchingCurrentState(of: observation)
        if current.isPlaceholder {
            throw ProviderError.placeholderOnly(provider: locationID, path: observation.path)
        }
        guard current.kind == .file,
              let sourceURL = resolvedURL(
                  for: current.path,
                  followingFinalSymlink: true
              ) else {
            throw ProviderError.itemUnavailable(provider: locationID, path: observation.path)
        }
        let fetching = self.fetching
        let receipt = mutationReceipt(kind: .fetch, paths: [observation.path])
        let hook = mutationHook
        let copyResult: LocalMutationDeadlineResult<Void> = await mutations.perform(
            receipt: receipt,
            nanoseconds: deadlines.ioNanoseconds,
            clock: deadlines.clock,
            startedAt: deadlines.now
        ) { startedReceipt in
            do {
                try hook.beforeMutation(startedReceipt)
                try fetching.copyItem(at: sourceURL, to: stagingURL)
                return .success(())
            } catch {
                return .failure(
                    .itemUnavailable(
                        provider: observation.location,
                        path: observation.path
                    )
                )
            }
        }
        switch copyResult {
        case .completed(.success):
            break
        case .completed(.failure):
            if case let .unavailable(reason) = await checkAvailability() {
                throw ProviderError.unavailable(
                    provider: locationID,
                    reason: reason.detail
                )
            }
            throw ProviderError.itemUnavailable(
                provider: locationID,
                path: observation.path
            )
        case .deadlineExpiredBeforeStart:
            throw ProviderError.mutationDeadlineExpiredBeforeStart(
                provider: locationID,
                path: observation.path
            )
        case let .indeterminate(receipt):
            throw ProviderError.mutationIndeterminate(receipt)
        }

        let afterCopy = try await matchingCurrentState(of: observation)
        guard afterCopy.version.isSameVersion(as: observation.version) else {
            throw ProviderError.preconditionFailed(
                provider: locationID,
                path: observation.path
            )
        }
        let verification = await withProviderDeadline(
            nanoseconds: deadlines.ioNanoseconds,
            clock: deadlines.clock
        ) {
            do {
                return LocalByteComparisonResult.equal(
                    try Self.filesHaveEqualBytes(sourceURL, stagingURL)
                )
            } catch {
                return .failed
            }
        }
        switch verification {
        case .timedOut:
            throw ProviderError.unavailable(
                provider: locationID,
                reason: "Filesystem fetch verification timed out."
            )
        case .value(.equal(true)):
            break
        case .value(.equal(false)), .value(.failed):
            throw ProviderError.preconditionFailed(
                provider: locationID,
                path: observation.path
            )
        }
        _ = try await matchingCurrentState(of: observation)
    }

    public func currentState(of observation: ItemObservation) async throws -> ItemObservation {
        if let receipt = await mutations.barrierReceipt() {
            throw ProviderError.unavailable(
                provider: locationID,
                reason: "Filesystem mutation \(receipt.id.uuidString) is still awaiting reconciliation."
            )
        }
        return try await currentStateIgnoringMutationBarrier(of: observation)
    }

    private func currentStateIgnoringMutationBarrier(
        of observation: ItemObservation
    ) async throws -> ItemObservation {
        if case let .unavailable(reason) = await checkAvailabilityIgnoringMutationBarrier() {
            throw ProviderError.unavailable(provider: locationID, reason: reason.detail)
        }
        guard observation.location == locationID,
              let url = resolvedURL(
                  for: observation.path,
                  followingFinalSymlink: false
              ),
              !isInternalPath(observation.path) else {
            throw ProviderError.itemUnavailable(provider: locationID, path: observation.path)
        }

        let readResult = await withProviderDeadline(
            nanoseconds: deadlines.probeNanoseconds,
            clock: deadlines.clock
        ) {
            do {
                return LocalObservationReadResult.observation(
                    try Self.observation(
                        locationID: self.locationID,
                        url: url,
                        path: observation.path
                    )
                )
            } catch {
                return .failed(LocalFileFailure(error))
            }
        }
        switch readResult {
        case .timedOut:
            throw ProviderError.unavailable(
                provider: locationID,
                reason: "Filesystem metadata read timed out."
            )
        case let .value(.observation(current)):
            return current
        case let .value(.failed(failure)):
            if case let .unavailable(reason) = await checkAvailabilityIgnoringMutationBarrier() {
                throw ProviderError.unavailable(provider: locationID, reason: reason.detail)
            }
            let isAbsent = failure.isMissingFile
                ? true
                : await confirmsAbsence(of: url)
            if isAbsent {
                do {
                    if let trashed = try trashedObservation(from: observation) {
                        return trashed
                    }
                } catch {
                    throw ProviderError.itemUnavailable(
                        provider: locationID,
                        path: observation.path
                    )
                }
                throw ProviderError.notFound(provider: locationID, path: observation.path)
            }
            throw ProviderError.itemUnavailable(provider: locationID, path: observation.path)
        }
    }

    public func store(
        from stagingURL: URL,
        at path: SyncPath,
        options: StoreOptions
    ) async throws -> ItemObservation {
        try await requireAvailableBeforeEnqueue()
        let receipt = mutationReceipt(kind: .store, paths: [path])
        let context = mutationContext()
        return try await resolveMutation(
            await mutations.perform(
                receipt: receipt,
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
        try await requireAvailableBeforeEnqueue()
        let receipt = mutationReceipt(kind: .makeFolder, paths: [path])
        let context = mutationContext()
        return try await resolveMutation(
            await mutations.perform(
                receipt: receipt,
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
        try await requireAvailableBeforeEnqueue()
        let receipt = mutationReceipt(
            kind: .relocate,
            paths: [observation.path, newPath]
        )
        let context = mutationContext()
        return try await resolveMutation(
            await mutations.perform(
                receipt: receipt,
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
        try await requireAvailableBeforeEnqueue()
        let receipt = mutationReceipt(kind: .trash, paths: [observation.path])
        let context = mutationContext()
        let result: LocalMutationDeadlineResult<Void> = await mutations.perform(
            receipt: receipt,
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
        await mutations.state(for: receipt)
    }

    public func indeterminateMutationReceipt() async -> ProviderMutationReceipt? {
        await mutations.indeterminateReceipt()
    }

    public func currentStateForRecovery(
        of observation: ItemObservation,
        receipt: ProviderMutationReceipt
    ) async throws -> ItemObservation {
        guard receipt.provider == locationID else {
            throw ProviderError.preconditionFailed(
                provider: locationID,
                path: observation.path
            )
        }
        guard case .inFlight = await mutations.state(for: receipt) else {
            return try await currentStateIgnoringMutationBarrier(of: observation)
        }
        throw ProviderError.unavailable(
            provider: locationID,
            reason: "Filesystem mutation \(receipt.id.uuidString) is still running."
        )
    }

    public func finishIndeterminateMutationRecovery(
        for receipt: ProviderMutationReceipt
    ) async {
        await mutations.finishRecovery(for: receipt)
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
            startedAt: deadlines.now()
        )
    }

    private func mutationContext() -> MutationContext {
        MutationContext(
            locationID: locationID,
            capabilities: capabilities,
            rootURL: rootURL,
            volumes: volumes,
            deadlines: deadlines,
            nativeTrash: nativeTrash,
            relocation: relocation,
            hook: mutationHook,
            artifacts: mutationArtifacts,
            quarantineTimestamp: quarantineTimestamp
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

    private func trashedObservation(
        from expected: ItemObservation
    ) throws -> ItemObservation? {
        guard let receipt = try loadTrashReceipt(for: expected),
              receipt.observation.location == locationID,
              receipt.observation.path == expected.path,
              receipt.observation.kind == expected.kind,
              receipt.observation.version.isSameVersion(as: expected.version) else {
            return nil
        }
        if receipt.method == .quarantine {
            guard let recoveryPath = receipt.recoveryPath,
                  filesystemEntryExists(at: URL(fileURLWithPath: recoveryPath)) else {
                return nil
            }
        } else if let recoveryPath = receipt.recoveryPath,
                  !filesystemEntryExists(at: URL(fileURLWithPath: recoveryPath)) {
            return nil
        }
        var observation = receipt.observation
        observation.isTrashed = true
        return observation
    }

    private func loadTrashReceipt(
        for observation: ItemObservation
    ) throws -> LocalTrashReceipt? {
        let directory = try trashReceiptDirectory(create: false)
        let receiptURL = directory.appendingPathComponent(
            try trashReceiptFilename(for: observation),
            isDirectory: false
        )
        guard filesystemEntryExists(at: receiptURL) else { return nil }
        return try CanonicalCoding.decoder().decode(
            LocalTrashReceipt.self,
            from: Data(contentsOf: receiptURL)
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
        guard let canonicalRoot = Self.canonicalizingExistingAncestors(rootURL) else {
            throw ProviderError.itemUnavailable(provider: locationID, path: .root)
        }
        let directory = canonicalRoot
            .appendingPathComponent(".aetherloom", isDirectory: true)
            .appendingPathComponent("trash-receipts", isDirectory: true)
        guard let checkedBeforeCreate = Self.canonicalizingExistingAncestors(directory),
              Self.contains(checkedBeforeCreate, in: canonicalRoot) else {
            throw ProviderError.itemUnavailable(provider: locationID, path: .root)
        }
        if create {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        guard let checked = Self.canonicalizingExistingAncestors(directory),
              Self.contains(checked, in: canonicalRoot) else {
            throw ProviderError.itemUnavailable(provider: locationID, path: .root)
        }
        return checked
    }

    private func filesystemEntryExists(at url: URL) -> Bool {
        if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
            return true
        }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func requireAvailableIgnoringMutationBarrier() async throws {
        if case let .unavailable(reason) = await checkAvailabilityIgnoringMutationBarrier() {
            throw ProviderError.unavailable(
                provider: locationID,
                reason: reason.detail
            )
        }
    }

    /// A mutation already owned by the coordinator is itself the availability
    /// barrier. Do not run volume or path probes beside it; enqueue first and
    /// let recovery release the root only after the late result is reconciled.
    private func requireAvailableBeforeEnqueue() async throws {
        guard await mutations.barrierReceipt() == nil else { return }
        try await requireAvailableIgnoringMutationBarrier()
    }

    private func matchingCurrentState(
        of observation: ItemObservation
    ) async throws -> ItemObservation {
        guard observation.location == locationID else {
            throw ProviderError.preconditionFailed(
                provider: locationID,
                path: observation.path
            )
        }
        let current: ItemObservation
        do {
            current = try await currentState(of: observation)
        } catch ProviderError.notFound {
            throw ProviderError.preconditionFailed(
                provider: locationID,
                path: observation.path
            )
        }
        guard current.kind == observation.kind,
              current.version.isSameVersion(as: observation.version) else {
            throw ProviderError.preconditionFailed(
                provider: locationID,
                path: observation.path
            )
        }
        return current
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

    private func probe<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) async -> ProviderDeadlineResult<Value> {
        await withProviderDeadline(
            nanoseconds: deadlines.probeNanoseconds,
            clock: deadlines.clock,
            operation: operation
        )
    }

    private func availabilityForDirectory(_ url: URL) async -> LocationAvailability {
        switch await probe({ await self.volumes.directoryState(at: url) }) {
        case .timedOut:
            return .unavailable(.volumeUnreachable(detail: "Directory inspection timed out."))
        case .value(.missing):
            return await availabilityAfterConfirmedMissingDirectory()
        case let .value(.unknown(detail)):
            return .unavailable(.unknown(detail: detail))
        case .value(.present(isReadable: false)):
            return .unavailable(.unknown(detail: "The selected folder is not readable."))
        case .value(.present(isReadable: true)):
            return .available
        }
    }

    private func availabilityAfterConfirmedMissingDirectory() async -> LocationAvailability {
        switch await probe({ await self.volumes.mountState(for: self.rootURL) }) {
        case .timedOut:
            return .unavailable(.volumeUnreachable(detail: "Volume mount inspection timed out."))
        case let .value(.notMounted(detail)):
            return .unavailable(.volumeNotMounted(detail: detail))
        case let .value(.indeterminate(detail)):
            return .unavailable(.unknown(detail: detail))
        case .value(.mounted):
            break
        }

        if let unavailable = await volumeIdentityUnavailability() {
            return .unavailable(unavailable)
        }

        switch await probe({ await self.volumes.responsiveness(for: self.rootURL) }) {
        case .timedOut:
            return .unavailable(.volumeUnreachable(detail: "Volume responsiveness probe timed out."))
        case let .value(.unreachable(detail)):
            return .unavailable(.volumeUnreachable(detail: detail))
        case .value(.responsive):
            return .unavailable(
                .scopeMissing(detail: "The selected folder is missing.")
            )
        }
    }

    private func volumeIdentityUnavailability() async -> LocationUnavailabilityReason? {
        guard let expectedVolumeIdentity else {
            return .unknown(
                detail: "The selected volume identity could not be recorded safely."
            )
        }
        switch await probe({ await self.volumes.volumeIdentity(for: self.rootURL) }) {
        case .timedOut:
            return .volumeUnreachable(detail: "Volume identity inspection timed out.")
        case .value(nil):
            return .volumeNotMounted(detail: "The selected volume is no longer mounted.")
        case let .value(currentIdentity?) where currentIdentity != expectedVolumeIdentity:
            return .volumeNotMounted(
                detail: "The selected volume was replaced by a different volume."
            )
        case .value:
            return nil
        }
    }

    private func confirmsAbsence(of url: URL) async -> Bool {
        let result = await withProviderDeadline(
            nanoseconds: deadlines.probeNanoseconds,
            clock: deadlines.clock
        ) {
            do {
                let children = try FileManager.default.contentsOfDirectory(
                    atPath: url.deletingLastPathComponent().path
                )
                return LocalDirectoryMembershipResult.children(children)
            } catch {
                return .failed
            }
        }
        guard case let .value(.children(names)) = result else {
            return false
        }
        if capabilities.isCaseSensitive == true {
            return !names.contains(url.lastPathComponent)
        }
        return !names.contains {
            $0.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame
        }
    }

    private func resolvedURL(
        for path: SyncPath,
        followingFinalSymlink: Bool
    ) -> URL? {
        guard !path.components.contains(where: { $0 == "." || $0 == ".." }) else {
            return nil
        }
        guard let canonicalRoot = Self.canonicalizingExistingAncestors(rootURL) else {
            return nil
        }
        let candidate = path.components.reduce(canonicalRoot) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
        let checked: URL?
        if followingFinalSymlink || path.isRoot {
            checked = Self.canonicalizingExistingAncestors(candidate)
        } else {
            checked = Self.canonicalizingExistingAncestors(
                candidate.deletingLastPathComponent()
            )?.appendingPathComponent(candidate.lastPathComponent)
        }
        guard let checked,
              Self.contains(checked, in: canonicalRoot) else {
            return nil
        }
        return checked
    }

    private func isInternalPath(_ path: SyncPath) -> Bool {
        guard let first = path.components.first else { return false }
        if capabilities.isCaseSensitive == true {
            return first == ".aetherloom"
        }
        return first.caseInsensitiveCompare(".aetherloom") == .orderedSame
    }

    private func snapshot(scope: SyncScope, status: ScanStatus) -> LocationSnapshot {
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

    private struct MutationContext: Sendable {
        let locationID: LocationID
        let capabilities: ProviderCapabilities
        let rootURL: URL
        let volumes: any VolumeInspecting
        let deadlines: ProviderDeadlines
        let nativeTrash: any LocalNativeTrashPerforming
        let relocation: any LocalRelocationPerforming
        let hook: any LocalMutationStarting
        let artifacts: LocalMutationArtifacts
        let quarantineTimestamp: String

        func store(
            from stagingURL: URL,
            at path: SyncPath,
            options: StoreOptions,
            receipt: ProviderMutationReceipt
        ) async -> Result<ItemObservation, ProviderError> {
            do {
                try hook.beforeMutation(receipt)
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
                let replacementDirectory = try FileManager.default.url(
                    for: .itemReplacementDirectory,
                    in: .userDomainMask,
                    appropriateFor: replacementTarget,
                    create: true
                )
                let temporary = replacementDirectory.appendingPathComponent(
                    receipt.id.uuidString
                )
                try FileManager.default.copyItem(at: stagingURL, to: temporary)
                let committedURL: URL
                let committedPath: SyncPath
                if let existing {
                    _ = try FileManager.default.replaceItemAt(
                        existing.url,
                        withItemAt: temporary,
                        backupItemName: nil,
                        options: [.usingNewMetadataOnly]
                    )
                    committedURL = existing.url
                    committedPath = existing.observation.path
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    committedURL = destination
                    committedPath = path
                }
                return .success(
                    try LocalFolderStorageProvider.observation(
                        locationID: locationID,
                        url: committedURL,
                        path: committedPath
                    )
                )
            } catch let error as ProviderError {
                return .failure(error)
            } catch {
                return .failure(.itemUnavailable(provider: locationID, path: path))
            }
        }

        func makeFolder(
            at path: SyncPath,
            receipt: ProviderMutationReceipt
        ) async -> Result<ItemObservation, ProviderError> {
            do {
                try hook.beforeMutation(receipt)
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
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
                return .success(
                    try LocalFolderStorageProvider.observation(
                        locationID: locationID,
                        url: destination,
                        path: path
                    )
                )
            } catch let error as ProviderError {
                return .failure(error)
            } catch {
                return .failure(.itemUnavailable(provider: locationID, path: path))
            }
        }

        func relocate(
            _ expected: ItemObservation,
            to newPath: SyncPath,
            receipt: ProviderMutationReceipt
        ) async -> Result<ItemObservation, ProviderError> {
            do {
                try hook.beforeMutation(receipt)
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
                    try FileManager.default.moveItem(at: source, to: destination)
                } else {
                    do {
                        try relocation.copyItem(at: source, to: destination)
                        guard try LocalFolderStorageProvider.equivalentTrees(
                            source,
                            destination
                        ) else {
                            throw ProviderError.itemUnavailable(
                                provider: locationID,
                                path: newPath
                            )
                        }
                    } catch {
                        if filesystemEntryExists(at: destination) {
                            let recovery = try quarantineURL(
                                destination,
                                originalPath: newPath
                            )
                            await artifacts.recordRecovery(recovery, for: newPath)
                        }
                        throw error
                    }
                    do {
                        try relocation.beforeSourceTrash(at: source)
                        try await trashCurrent(current, source: source)
                    } catch {
                        if filesystemEntryExists(at: destination) {
                            let recovery = try quarantineURL(
                                destination,
                                originalPath: newPath
                            )
                            await artifacts.recordRecovery(recovery, for: newPath)
                        }
                        throw error
                    }
                }
                return .success(
                    try LocalFolderStorageProvider.observation(
                        locationID: locationID,
                        url: destination,
                        path: newPath
                    )
                )
            } catch let error as ProviderError {
                return .failure(error)
            } catch {
                return .failure(.itemUnavailable(provider: locationID, path: expected.path))
            }
        }

        func trash(
            _ expected: ItemObservation,
            receipt: ProviderMutationReceipt
        ) async -> Result<Void, ProviderError> {
            do {
                try hook.beforeMutation(receipt)
                if let existing = try existingEntry(at: expected.path) {
                    guard existing.observation.kind == expected.kind,
                          existing.observation.version.isSameVersion(as: expected.version) else {
                        throw ProviderError.preconditionFailed(
                            provider: locationID,
                            path: expected.path
                        )
                    }
                    try await trashCurrent(existing.observation, source: existing.url)
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
                return .failure(error)
            } catch {
                return .failure(
                    .itemUnavailable(provider: locationID, path: expected.path)
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
            source: URL
        ) async throws {
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
                    startedAt: deadlines.now()
                )
                try persistTrashReceipt(trashReceipt)
                do {
                    let resultingURL = try nativeTrash.trashItem(at: source)
                    if let resultingURL {
                        await artifacts.recordRecovery(
                            resultingURL,
                            for: current.path
                        )
                        trashReceipt.recoveryPath = resultingURL.path
                    }
                    try persistTrashReceipt(trashReceipt)
                    return
                } catch {
                    // Native trash can move and then throw. Absence plus the
                    // write-ahead receipt is a recoverable success; never try a
                    // second destructive fallback against an absent source.
                    if try existingEntry(at: current.path) == nil {
                        return
                    }
                    let afterFailure = try LocalFolderStorageProvider.observation(
                        locationID: locationID,
                        url: source,
                        path: current.path
                    )
                    guard afterFailure.kind == current.kind,
                          afterFailure.version.isSameVersion(as: current.version) else {
                        throw ProviderError.preconditionFailed(
                            provider: locationID,
                            path: current.path
                        )
                    }
                }
            }

            let recoveryURL = try quarantineDestinationURL(
                originalPath: current.path
            )
            try persistTrashReceipt(
                LocalTrashReceipt(
                    observation: immediatelyCurrent,
                    method: .quarantine,
                    recoveryPath: recoveryURL.path,
                    startedAt: deadlines.now()
                )
            )
            try FileManager.default.moveItem(at: source, to: recoveryURL)
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
            let sourceResult = await withProviderDeadline(
                nanoseconds: deadlines.probeNanoseconds,
                clock: deadlines.clock
            ) {
                await volumes.volumeIdentity(for: source)
            }
            let destinationResult = await withProviderDeadline(
                nanoseconds: deadlines.probeNanoseconds,
                clock: deadlines.clock
            ) {
                await volumes.volumeIdentity(for: destinationParent)
            }
            guard case let .value(sourceIdentity?) = sourceResult,
                  case let .value(destinationIdentity?) = destinationResult else {
                throw ProviderError.unavailable(
                    provider: locationID,
                    reason: "A volume identity could not be determined before relocation."
                )
            }
            return sourceIdentity == destinationIdentity
        }

        private func resolvedURL(
            for path: SyncPath,
            followingFinalSymlink: Bool
        ) -> URL? {
            guard !path.components.contains(where: { $0 == "." || $0 == ".." }),
                  let canonicalRoot = LocalFolderStorageProvider
                    .canonicalizingExistingAncestors(rootURL) else {
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
            try CanonicalCoding.encoder().encode(receipt).write(
                to: receiptURL,
                options: .atomic
            )
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
            if receipt.method == .quarantine {
                guard let recoveryPath = receipt.recoveryPath,
                      filesystemEntryExists(
                          at: URL(fileURLWithPath: recoveryPath)
                      ) else {
                    return nil
                }
            } else if let recoveryPath = receipt.recoveryPath,
                      !filesystemEntryExists(at: URL(fileURLWithPath: recoveryPath)) {
                return nil
            }
            var observation = receipt.observation
            observation.isTrashed = true
            return observation
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
            guard let canonicalRoot = LocalFolderStorageProvider
                .canonicalizingExistingAncestors(rootURL) else {
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

        private func quarantineURL(
            _ source: URL,
            originalPath: SyncPath
        ) throws -> URL {
            let destination = try quarantineDestinationURL(originalPath: originalPath)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }

        private func quarantineDestinationURL(
            originalPath: SyncPath
        ) throws -> URL {
            guard let canonicalRoot = LocalFolderStorageProvider
                .canonicalizingExistingAncestors(rootURL) else {
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
    enum Method: String, Codable, Hashable, Sendable {
        case nativeTrash
        case quarantine
    }

    var observation: ItemObservation
    var method: Method
    var recoveryPath: String?
    var startedAt: Date
}

private struct LocalTrashReceiptKey: Codable, Hashable, Sendable {
    var location: LocationID
    var path: SyncPath
    var kind: ItemKind
}

private enum LocalObservationReadResult: Sendable {
    case observation(ItemObservation)
    case failed(LocalFileFailure)
}

private enum LocalFileOperationResult: Sendable {
    case succeeded
    case failed(LocalFileFailure)
}

private enum LocalByteComparisonResult: Sendable {
    case equal(Bool)
    case failed
}

private enum LocalDirectoryMembershipResult: Sendable {
    case children([String])
    case failed
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

protocol LocalRelocationPerforming: Sendable {
    func copyItem(at source: URL, to destination: URL) throws
    func beforeSourceTrash(at source: URL) throws
}

struct SystemLocalRelocationPerformer: LocalRelocationPerforming {
    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func beforeSourceTrash(at _: URL) throws {}
}
